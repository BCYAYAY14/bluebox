import CoreGraphics
import Foundation
import Playback
import TorrentStreaming

/// Playback speed: the presets in the Speed card, and − and + in 0.05 steps
/// (also `[` and `]` on the Mac).
enum PlaybackSpeed {
    static let presets: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    static let step: Float = 0.05
    /// What both engines accept.
    static let range: ClosedRange<Float> = 0.25...4
    /// Holding → (Mac) or pressing and holding the video (iPhone).
    static let hold: Float = 2

    /// `rate` moved `steps` steps of 0.05 along the grid: a rate between two
    /// steps (1.12) goes to the next one in that direction (1.15 or 1.10).
    static func stepped(_ rate: Float, by steps: Int) -> Float {
        guard steps != 0 else { return clamp(rate) }
        let units = Double(rate) / Double(step)
        let base = steps > 0 ? (units + 1e-3).rounded(.down) : (units - 1e-3).rounded(.up)
        return clamp(Float((base + Double(steps)) * Double(step)))
    }

    static func clamp(_ rate: Float) -> Float {
        guard rate.isFinite else { return 1 }
        let r = min(max(rate, range.lowerBound), range.upperBound)
        return Float((Double(r) * 100).rounded() / 100)
    }

    static func isNormal(_ rate: Float) -> Bool { abs(rate - 1) < 0.001 }

    /// "1×", "1.15×", "0.5×".
    static func label(_ rate: Float) -> String {
        String(format: "%g×", (Double(rate) * 100).rounded() / 100)
    }
}

/// One control in the player's bottom bar.
enum PlayerBarItem: String, CaseIterable, Identifiable {
    case playPause, skipBack, skipForward, volume, lock
    case previous, next, episodes, tracks, speed, tools
    case pip, fullScreen
    var id: String { rawValue }
}

/// Which controls the bottom bar shows, and where. The set depends only on
/// the platform and the width, never on the video (chapters, episodes, PiP):
/// controls that don't apply are dimmed, so nothing moves between videos.
struct PlayerBarLayout: Equatable {
    enum Platform { case mac, phone, pad }

    /// Left: playback (Mac) or the screen lock (touch).
    var leading: [PlayerBarItem]
    /// The title sits in the middle when there's room (Mac and iPad).
    var showsTitle: Bool
    /// Right: groups split by thin dividers.
    var trailing: [[PlayerBarItem]]

    var all: [PlayerBarItem] { leading + trailing.flatMap { $0 } }

    /// Below this width the title leaves the bar for the top bar.
    static let titleMinWidth: CGFloat = 640

    static func make(platform: Platform, width: CGFloat) -> PlayerBarLayout {
        switch platform {
        case .mac:
            PlayerBarLayout(leading: [.playPause, .skipBack, .skipForward, .volume],
                            showsTitle: width >= titleMinWidth,
                            trailing: [[.previous, .next], [.episodes, .tracks, .speed, .tools], [.pip, .fullScreen]])
        case .pad:
            // PiP, AirPlay and rotation stay in the top bar on touch screens.
            PlayerBarLayout(leading: [.lock], showsTitle: width >= titleMinWidth,
                            trailing: [[.previous, .next], [.episodes, .tracks, .speed, .tools]])
        case .phone:
            PlayerBarLayout(leading: [.lock], showsTitle: false,
                            trailing: [[.previous, .next], [.episodes, .tracks, .speed, .tools]])
        }
    }

    /// What the video offers, for dimming the controls that don't apply.
    struct Context: Equatable {
        var isSeries = false
        var hasPreviousEpisode = false
        var hasNextEpisode = false
        var chapterCount = 0
        var pipAvailable = false
        var isSwitching = false
    }

    /// Previous and next step through episodes in a series, or chapters in a film.
    enum StepTarget: Equatable { case episode, chapter, none }

    static func stepTarget(_ c: Context) -> StepTarget {
        if c.isSeries { return .episode }
        return c.chapterCount > 1 ? .chapter : .none
    }

    static func isEnabled(_ item: PlayerBarItem, in c: Context) -> Bool {
        switch item {
        case .previous:
            switch stepTarget(c) {
            case .episode: c.hasPreviousEpisode && !c.isSwitching
            case .chapter: true
            case .none: false
            }
        case .next:
            switch stepTarget(c) {
            case .episode: c.hasNextEpisode && !c.isSwitching
            case .chapter: true
            case .none: false
            }
        case .episodes: c.isSeries
        case .pip: c.pipAvailable
        default: true
        }
    }
}

/// Where a panel card goes: centred over the button that opened it, kept
/// inside the stage, its bottom edge just above the bar.
enum PanelPlacement {
    struct Frame: Equatable {
        /// Leading edge, in the stage's coordinates.
        var x: CGFloat
        /// Distance from the stage's bottom edge to the card's bottom edge.
        var bottom: CGFloat
        var maxHeight: CGFloat
    }

    /// - Parameters:
    ///   - anchor: the button's frame in the stage.
    ///   - barTop: the top of the bottom bar; the card stays above it (Mac). Nil lets it cover the timeline (phones).
    static func frame(anchor: CGRect?, width: CGFloat, stage: CGSize, barTop: CGFloat?, topInset: CGFloat,
                      margin: CGFloat = 12, gap: CGFloat = 8) -> Frame {
        let w = min(width, max(stage.width - margin * 2, 0))
        let centre = anchor?.midX ?? (stage.width - w / 2 - margin)
        let x = min(max(centre - w / 2, margin), max(stage.width - w - margin, margin))
        var top = anchor?.minY ?? (stage.height - 60)
        if let barTop { top = min(top, barTop) }
        let bottom = stage.height - top + gap
        return Frame(x: x, bottom: bottom, maxHeight: max(top - gap - topInset, 120))
    }
}

/// The ring that stands in for play while a video waits.
enum BufferProgress {
    /// How full the ring is, 0…1, or nil when there's no measure (the ring spins).
    /// VLC reports its fill; otherwise it's the seconds buffered ahead out of
    /// the few AVPlayer usually wants before it resumes.
    static func fraction(status: PlaybackStatus, bufferFill: Double?, position: TimeInterval,
                         bufferedUntil: TimeInterval, target: TimeInterval = 5) -> Double? {
        guard status == .loading || status == .buffering else { return nil }
        if let bufferFill, bufferFill.isFinite { return min(max(bufferFill, 0), 1) }
        guard status == .buffering, bufferedUntil > position, target > 0 else { return nil }
        return min((bufferedUntil - position) / target, 0.99)
    }

    /// One short line under the ring: "Buffering · 3.1 MB/s", "Connecting · 12 peers found".
    static func caption(status: PlaybackStatus, torrent: SwarmStats?, elapsed: TimeInterval) -> String? {
        guard status == .loading || status == .buffering else { return nil }
        let verb = status == .loading ? "Opening" : "Buffering"
        guard let t = torrent else {
            if status == .loading { return elapsed > 12 ? "Opening · still connecting" : "Opening" }
            return "Buffering"
        }
        if t.connectedPeers == 0 {
            return t.knownPeers > 0 ? "Connecting · \(t.knownPeers) peers found" : "Connecting to peers"
        }
        if t.downloadRate > 0 {
            return "\(verb) · " + ByteCountFormatter.string(fromByteCount: Int64(t.downloadRate), countStyle: .file) + "/s"
        }
        return "\(verb) · \(t.connectedPeers) peer\(t.connectedPeers == 1 ? "" : "s")"
    }
}
