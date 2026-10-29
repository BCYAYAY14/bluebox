import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// What the Downloads Live Activity shows: the whole queue, not one item.
/// Values are rounded when made (`DownloadsActivityState.summary` in Features),
/// so a jittering speed doesn't count as a change worth an ActivityKit update.
public struct DownloadsActivityState: Codable, Hashable, Sendable {
    /// The item transferring now (or next in line).
    public var title: String
    /// "S1·E2" for an episode.
    public var subtitle: String?
    /// Downloading or queued.
    public var activeCount: Int
    /// The whole queue's speed.
    public var bytesPerSecond: Double
    /// At the current speed; nil while unknown (no speed yet, sizes unknown).
    public var secondsLeft: Int?
    /// 0…1 over the queue's known sizes.
    public var fraction: Double

    public init(title: String, subtitle: String? = nil, activeCount: Int, bytesPerSecond: Double, secondsLeft: Int?, fraction: Double) {
        self.title = title; self.subtitle = subtitle; self.activeCount = activeCount
        self.bytesPerSecond = bytesPerSecond; self.secondsLeft = secondsLeft; self.fraction = fraction
    }

    /// "42%"
    public var percentText: String { "\(Int((fraction * 100).rounded(.down)))%" }

    /// "3 downloading · 8.4 MB/s · 12 min left"; parts that aren't known yet are left out.
    public var detailLine: String {
        var parts = ["\(activeCount) downloading"]
        if bytesPerSecond >= 1_000 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s")
        }
        if let secondsLeft { parts.append(Self.timeLeft(secondsLeft)) }
        return parts.joined(separator: " · ")
    }

    /// "12 min left", "1 h 5 min left", "< 1 min left"
    public static func timeLeft(_ seconds: Int) -> String {
        if seconds < 60 { return "< 1 min left" }
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
    }
}

/// Lets ActivityKit updates through at most once per `minimumInterval`:
/// the system budgets Live Activity updates, and progress ticks arrive about
/// every second. A state equal to the last one sent is dropped; one that comes
/// too soon is held, and the caller sends the newest held state at `waitUntil`.
public struct ActivityUpdateThrottle<State: Equatable & Sendable>: Sendable {
    public enum Decision: Equatable, Sendable {
        case sendNow
        /// Send the newest state then (one deferred send covers every offer before it).
        case waitUntil(Date)
        case unchanged
    }

    public let minimumInterval: TimeInterval
    public private(set) var lastSent: State?
    public private(set) var lastSentAt: Date?

    public init(minimumInterval: TimeInterval = 5) { self.minimumInterval = minimumInterval }

    public func decide(_ state: State, now: Date) -> Decision {
        guard let lastSentAt else { return .sendNow }
        if lastSent == state { return .unchanged }
        let due = lastSentAt.addingTimeInterval(minimumInterval)
        return now >= due ? .sendNow : .waitUntil(due)
    }

    public mutating func didSend(_ state: State, at date: Date) { lastSent = state; lastSentAt = date }

    /// A new activity starts a fresh budget.
    public mutating func reset() { lastSent = nil; lastSentAt = nil }
}

/// The app's blue (`Palette.brand`, #3D7BFF), repeated here because the
/// extension doesn't link DesignSystem.
public enum DownloadsActivityStyle {
    public static let brand = (red: 0.24, green: 0.48, blue: 1.0)
}

#if canImport(ActivityKit) && os(iOS)
/// The Downloads Live Activity. Nothing is fixed for its lifetime (the queue
/// changes under it), so everything is in the content state.
public struct DownloadsActivityAttributes: ActivityAttributes {
    public typealias ContentState = DownloadsActivityState
    public init() {}
}
#endif
