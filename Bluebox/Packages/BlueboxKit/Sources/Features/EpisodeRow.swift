import DesignSystem
import Domain
import Downloads
import SwiftUI

/// What an episode row can do, beyond playing.
struct EpisodeRowActions {
    var play: () -> Void
    var playFromStart: () -> Void
    var setWatched: (Bool) -> Void
    /// Nil when add-ons are off.
    var chooseRelease: (() -> Void)?
    var download: () -> Void
    var deleteDownload: (DownloadRecord) -> Void
}

/// One episode, Netflix-style: a 16:9 thumbnail with a play mark, the number
/// and title, the runtime (and time left on the episode you're up to), the
/// round download button at the end, and two lines of synopsis underneath.
/// The whole row plays. With the profile's spoiler guard on, an episode you
/// haven't watched yet keeps its still blurred and its synopsis hidden until
/// you press Show (or choose Show Spoilers from its menu).
struct EpisodeRow: View {
    let episode: Episode
    let progress: WatchProgress?
    let isPlayable: Bool
    /// The episode Play would start: outlined in blue, with the time left.
    let isNext: Bool
    let canDownload: Bool
    let thumbnailWidth: CGFloat
    let imageURL: URL?
    let seriesName: String
    let download: DownloadRecord?
    /// Asked to download, and a release is being found: the button turns at once.
    var isPreparing = false
    let actions: EpisodeRowActions

    @State private var hovering = false
    /// Show was pressed: this row's still and synopsis are visible until it leaves the screen.
    @State private var revealed = false
    @State private var gate = QuickActionGate()
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var guarded: Bool {
        SpoilerGuard.hides(isOn: app.featureSwitches.spoilerGuard, progress: progress, revealed: revealed)
    }

    private var thumbnailHeight: CGFloat { (thumbnailWidth * 9 / 16).rounded() }
    private var isWatched: Bool { progress?.isCompleted == true }
    private var startedFraction: Double? {
        guard let p = progress else { return nil }
        if p.isCompleted { return 1 }
        guard p.position > 0 else { return nil }
        return p.fraction
    }
    private var showsDownloadButton: Bool { download != nil || isPreparing || (canDownload && isPlayable) }
    private var large: Bool { thumbnailWidth >= 160 }

    var body: some View {
        Button {
            guard !gate.consumeHold() else { return }
            actions.play()
        } label: {
            VStack(alignment: .leading, spacing: large ? Spacing.s + 2 : Spacing.s) {
                HStack(alignment: .center, spacing: Spacing.m) {
                    thumbnail
                    titleBlock
                    Spacer(minLength: 0)
                    // Room for the download button, drawn over the row so it isn't inside this button.
                    if showsDownloadButton { Color.clear.frame(width: 44, height: 1) }
                }
                if !episode.overview.isEmpty, guarded {
                    SpoilerHiddenSynopsis(large: large)
                        // Room for Show, drawn over the row so it isn't inside this button.
                        .padding(.trailing, 56)
                } else if !episode.overview.isEmpty {
                    Text(episode.overview)
                        .font(large ? .callout : .footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Spacing.m - 2)
            .background(background)
            .overlay {
                if isNext {
                    RoundedRectangle(cornerRadius: Radius.hero - 4, style: .continuous)
                        .strokeBorder(Palette.brand.opacity(0.6), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.hero - 4, style: .continuous))
        }
        .buttonStyle(EpisodeRowButtonStyle())
        .disabled(!isPlayable)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isPlayable ? "Plays the episode" : "Not available in your sources")
        .accessibilityIdentifier("episode.\(episode.seasonNumber).\(episode.number)")
        .overlay(alignment: .topTrailing) {
            if showsDownloadButton {
                EpisodeDownloadButton(record: download, canDownload: canDownload, isPreparing: isPreparing,
                                      episodeNumber: episode.number, start: actions.download, delete: actions.deleteDownload)
                    .frame(height: thumbnailHeight)
                    .padding(.top, Spacing.m - 2)
                    .padding(.trailing, Spacing.xs)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Beside the hidden-synopsis line. Without a synopsis there's no
            // room under the download button: the row's menu reveals it instead.
            if guarded, !episode.overview.isEmpty {
                SpoilerRevealButton { withAnimation(Motion.snappy(reduceMotion)) { revealed = true } }
                    .padding(.trailing, Spacing.xs)
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .opacity(isPlayable || download?.state == .completed ? 1 : 0.55)
        .blueboxContextMenu("\(episode.number). \(episode.name)", gate: gate) { menu }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: Radius.hero - 4, style: .continuous)
            .fill(isNext ? Palette.surface : hovering ? Palette.surface.opacity(0.8) : .clear)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(episode.number). \(episode.name)")
                .font((large ? Font.body : .subheadline).weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                if let r = episode.runtimeMinutes { Text(Formatters.runtime(minutes: r)) }
                if isNext, let p = progress, !p.isCompleted, p.position > 0, let left = p.remaining {
                    if episode.runtimeMinutes != nil { Text("·") }
                    Text(Formatters.remaining(left)).foregroundStyle(Palette.brandBright).fontWeight(.bold)
                }
            }
            .font(large ? .subheadline : .caption)
            .foregroundStyle(Palette.textSecondary)
            if !isPlayable && download?.state != .completed {
                Text("Not in your sources").font(.caption).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            ArtworkView(url: imageURL, fallbackTitle: "E\(episode.number)", kind: .still,
                        pixelWidth: Int(thumbnailWidth * 2), showsFallbackTitle: false)
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .spoilerBlurred(guarded)
            if isPlayable || download?.state == .completed {
                Image(systemName: "play.fill")
                    .font(.system(size: large ? 13 : 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: large ? 34 : 28, height: large ? 34 : 28)
                    .background(.black.opacity(0.4), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                    .scaleEffect(hovering && !reduceMotion ? 1.1 : 1)
            }
            // Watched is a full bar, the same mark as a part-watched one.
            if let f = startedFraction {
                EdgeProgressBar(fraction: f, height: 3, tint: Palette.brand)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: thumbnailWidth, height: thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    /// The row's menu, on hold or right-click: Bluebox's own, like every poster's.
    @BlueboxMenuBuilder private var menu: [BlueboxMenuEntry] {
        BlueboxMenuTitle("\(episode.number). \(episode.name)", subtitle: menuSubtitle)
        BlueboxMenuSection {
            if isPlayable {
                BlueboxMenuButton(progress.map { !$0.isCompleted && $0.position > 0 } == true ? "Resume" : "Play",
                                  systemImage: "play.fill") { actions.play() }
                if progress.map({ $0.position > 0 }) == true {
                    BlueboxMenuButton("Play from Start", systemImage: "arrow.counterclockwise") { actions.playFromStart() }
                }
            }
            if guarded {
                BlueboxMenuButton("Show Spoilers", systemImage: "eye") { revealed = true }
            }
            if isWatched {
                BlueboxMenuButton("Mark as Unwatched", systemImage: "eye.slash") { actions.setWatched(false) }
            } else {
                BlueboxMenuButton("Mark as Watched", systemImage: "checkmark.circle") { actions.setWatched(true) }
            }
        }
        if let choose = actions.chooseRelease {
            BlueboxMenuSection {
                BlueboxMenuButton("Choose Release…", systemImage: "list.bullet.rectangle") { choose() }
            }
        }
        if let download {
            BlueboxMenuSection {
                BlueboxMenuButton(download.state == .completed ? "Delete Download" : "Cancel Download",
                                  systemImage: "trash", role: .destructive) { actions.deleteDownload(download) }
            }
        } else if canDownload && isPlayable {
            BlueboxMenuSection {
                BlueboxMenuButton("Download", systemImage: "arrow.down.circle") { actions.download() }
            }
        }
    }

    private var menuSubtitle: String {
        var parts = ["S\(episode.seasonNumber)·E\(episode.number)"]
        if let r = episode.runtimeMinutes { parts.append(Formatters.runtime(minutes: r)) }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = ["Episode \(episode.number), \(episode.name)"]
        if let r = episode.runtimeMinutes { parts.append(Formatters.runtime(minutes: r)) }
        if isWatched { parts.append("Watched") } else if let f = startedFraction { parts.append("\(Int(f * 100)) percent watched") }
        if isNext { parts.append("Up next") }
        if guarded { parts.append("Picture and synopsis hidden to avoid spoilers") }
        if download?.state == .completed { parts.append("Downloaded") }
        return parts.joined(separator: ", ")
    }
}

/// Dims on press; scales a touch on iOS.
private struct EpisodeRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            #if os(iOS)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            #endif
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// The round download control at the end of an episode row: an outlined ↓,
/// a progress ring with a stop square while downloading, ⋯ while queued, and a
/// blue check once it's saved. Anything but ↓ opens a small menu.
struct EpisodeDownloadButton: View {
    @Environment(AppModel.self) private var app
    let record: DownloadRecord?
    let canDownload: Bool
    var isPreparing = false
    let episodeNumber: Int
    let start: () -> Void
    let delete: (DownloadRecord) -> Void

    private let size: CGFloat = 30

    var body: some View {
        Group {
            if let record {
                BlueboxMenu("Download") {
                    menu(for: record)
                } label: {
                    glyph(for: record).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(label(for: record))
                .transition(.opacity)
            } else if isPreparing {
                // Tapped a moment ago: a turning ring while the release is found.
                Circle()
                    .strokeBorder(Palette.textTertiary.opacity(0.6), lineWidth: 1.5)
                    .overlay(SpinningArc())
                    .frame(width: size, height: size)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Preparing download of episode \(episodeNumber)")
                    .transition(.opacity)
            } else {
                Button(action: start) {
                    Circle()
                        .strokeBorder(Palette.textTertiary, lineWidth: 1.5)
                        .overlay(Image(systemName: "arrow.down").font(.system(size: 13, weight: .bold)))
                        .frame(width: size, height: size)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(haptic: true))
                .accessibilityLabel("Download episode \(episodeNumber)")
                .transition(.opacity)
            }
        }
        .animation(Motion.snappy(false), value: isPreparing)
        .animation(Motion.snappy(false), value: record?.state)
        .foregroundStyle(Palette.textPrimary)
        .help(record.map(label(for:)) ?? "Download")
        .accessibilityIdentifier("episodeDownload.\(episodeNumber)")
    }

    @ViewBuilder private func glyph(for r: DownloadRecord) -> some View {
        switch r.state {
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Palette.brand, in: Circle())
        case .downloading:
            ProgressRing(fraction: r.fraction ?? 0)
                .overlay(RoundedRectangle(cornerRadius: 1.5).fill(.white).frame(width: 9, height: 9))
                .frame(width: size, height: size)
        case .queued:
            Circle()
                .strokeBorder(Palette.textTertiary, lineWidth: 1.5)
                .overlay(Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.textSecondary))
                .frame(width: size, height: size)
        case .paused:
            ProgressRing(fraction: r.fraction ?? 0, tint: Palette.textSecondary)
                .overlay(Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold)))
                .frame(width: size, height: size)
        case .failed:
            Circle()
                .strokeBorder(SwarmHealth.fair, lineWidth: 1.5)
                .overlay(Image(systemName: "exclamationmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(SwarmHealth.fair))
                .frame(width: size, height: size)
        }
    }

    @BlueboxMenuBuilder private func menu(for r: DownloadRecord) -> [BlueboxMenuEntry] {
        switch r.state {
        case .completed:
            BlueboxMenuButton("Play Download", systemImage: "play.fill") { Task { await app.playDownloadChecked(r) } }
            BlueboxMenuSection {
                BlueboxMenuButton("Delete Download", systemImage: "trash", role: .destructive) { delete(r) }
            }
        case .downloading, .queued:
            if r.state == .queued {
                BlueboxMenuButton("Download First", systemImage: "arrow.up.to.line") { app.prioritizeDownload(r) }
            }
            BlueboxMenuButton("Pause Download", systemImage: "pause.fill") { app.pauseDownload(r) }
            BlueboxMenuSection {
                BlueboxMenuButton("Cancel Download", systemImage: "xmark", role: .destructive) { delete(r) }
            }
        case .paused:
            BlueboxMenuButton("Resume Download", systemImage: "arrow.down") { Task { await app.resumeDownload(r) } }
            BlueboxMenuSection {
                BlueboxMenuButton("Cancel Download", systemImage: "xmark", role: .destructive) { delete(r) }
            }
        case .failed(let message):
            BlueboxMenuNote(message)
            BlueboxMenuSection {
                BlueboxMenuButton("Try Again", systemImage: "arrow.clockwise") { Task { await app.resumeDownload(r) } }
                BlueboxMenuButton("Remove", systemImage: "trash", role: .destructive) { delete(r) }
            }
        }
    }

    private func label(for r: DownloadRecord) -> String {
        switch r.state {
        case .completed: "Downloaded"
        case .downloading: "Downloading, \(Int((r.fraction ?? 0) * 100)) percent"
        case .queued: "Download queued"
        case .paused: "Download paused at \(Int((r.fraction ?? 0) * 100)) percent"
        case .failed: "Download failed"
        }
    }
}
