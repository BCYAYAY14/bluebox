import DesignSystem
import Domain
import Playback
import SwiftUI
import TorrentStreaming

/// Stats for nerds, over the top-left of the video while Tools › Stats is on:
/// four summary lines, a one-minute graph, sections that fold open and the
/// latest events. The copy button puts a report for bug reports on the
/// clipboard, with no links, keys or names in it.
struct PlayerStatsCard: View {
    let session: PlayerSession
    /// The torrent that's streaming, when it is one.
    var swarm: SwarmStats?
    var fileRanges: TorrentFileRanges?
    /// The room above the player's controls; the card scrolls inside it.
    var maxHeight: CGFloat
    let onCopied: () -> Void
    let onClose: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The sections kept open, by title (the same on every video).
    @AppStorage("playerStatsOpenSections") private var openSections = "Video,Buffer,Torrent"
    @State private var diagnostics: PlaybackDiagnostics?
    @State private var history = StatsHistory()
    @State private var contentHeight: CGFloat = 0

    static let width: CGFloat = 270
    static let shownEvents = 3

    var body: some View {
        let input = self.input
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                content(input)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(contentHeight, max(maxHeight - 40, 80)))
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: Self.width)
        .playerCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playerStats")
        .task(id: session.item?.key) {
            history.reset()
            while !Task.isCancelled {
                let d = session.engine.diagnostics()
                diagnostics = d
                let s = session.snapshot
                history.add(bitrate: d.bitrate, buffer: s.bufferedUntil > s.position ? s.bufferedUntil - s.position : 0,
                            download: swarm?.downloadRate)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Stats").font(.caption.weight(.bold))
            Spacer(minLength: Spacing.m)
            iconButton("doc.on.doc", label: "Copy Diagnostics", action: copy)
            iconButton("xmark", label: "Hide Stats", action: onClose)
        }
        .padding(.bottom, 4)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption2.weight(.bold))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.1), in: Circle())
                .frame(width: PanelMetrics.control, height: PanelMetrics.control)
                .contentShape(Circle())
        }
        .buttonStyle(PanelPressStyle())
        .accessibilityLabel(Text(ui: label))
        #if os(macOS)
        .help(Text(ui: label))
        #endif
    }

    @ViewBuilder private func content(_ input: PlaybackStatsInput) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            let lines = PlaybackStats.summary(input)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(verbatim: line)
                        .fontWeight(index == 0 ? .semibold : .regular)
                        .foregroundStyle(index == 0 ? Palette.textPrimary : Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            StatsGraph(history: history, showsDownload: swarm != nil)
                .padding(.vertical, 4)
            ForEach(PlaybackStats.sections(input)) { section in
                sectionView(section)
            }
            timeline(input.events)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionView(_ section: StatsSection) -> some View {
        let open = isOpen(section.title)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(Motion.standard(reduceMotion)) { toggle(section.title) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(ui: section.title).textCase(.uppercase).font(.caption2.weight(.bold)).tracking(0.6)
                    Spacer(minLength: Spacing.s)
                    if !open, let headline = section.headline {
                        (section.translatesHeadline ? Text(ui: headline) : Text(verbatim: headline)).font(.caption2.weight(.semibold)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
                .foregroundStyle(Palette.textTertiary)
                .frame(minHeight: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(open ? [.isHeader, .isSelected] : .isHeader)
            .accessibilityHint(Text(ui: open ? "Folds the section" : "Shows the section"))
            if open {
                ForEach(section.rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(ui: row.label).foregroundStyle(Palette.textSecondary)
                        Spacer(minLength: Spacing.s)
                        Group {
                            if row.translatesValue { Text(ui: row.value) } else { Text(verbatim: row.value) }
                        }
                        .fontWeight(.medium).lineLimit(2).multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func timeline(_ events: [PlaybackEvent]) -> some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Timeline").textCase(.uppercase).font(.caption2.weight(.bold)).tracking(0.6)
                    Spacer(minLength: Spacing.s)
                    Text(verbatim: "\(events.count)").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Palette.textTertiary)
                .frame(minHeight: 20)
                ForEach(events.suffix(Self.shownEvents).reversed()) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: PlaybackEventLog.clock(e.position)).foregroundStyle(Palette.textTertiary).frame(width: 46, alignment: .leading)
                        if e.kind != .info {
                            Image(systemName: e.kind == .error ? "exclamationmark.octagon.fill" : "hourglass")
                                .font(.caption2).foregroundStyle(e.kind == .error ? Palette.textPrimary : Palette.textSecondary)
                        }
                        (Text(ui: e.title) + Text(verbatim: e.detail.map { " · \($0)" } ?? ""))
                            .foregroundStyle(e.kind == .error ? Palette.textPrimary : Palette.textSecondary)
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: State

    private func isOpen(_ title: String) -> Bool { openSections.split(separator: ",").contains { $0 == title } }

    private func toggle(_ title: String) {
        var open = openSections.split(separator: ",").map(String.init)
        if let i = open.firstIndex(of: title) { open.remove(at: i) } else { open.append(title) }
        openSections = open.joined(separator: ",")
    }

    private var input: PlaybackStatsInput {
        let s = session.snapshot
        let d = diagnostics ?? PlaybackDiagnostics(engine: "–")
        let resource = session.currentResource
        var i = PlaybackStatsInput(diagnostics: d, snapshot: s)
        i.source = PlaybackStats.sourceKind(of: resource, kind: app.sourceConfigurations.first { $0.id == resource?.variant.sourceID }?.kind,
                                            addonsID: app.addons.id)
        if let item = session.item { i.title = [item.title, item.subtitle].compactMap { $0 }.joined(separator: " · ") }
        if let name = resource?.variant.displayName, !name.isEmpty { i.releaseName = (name as NSString).lastPathComponent }
        if let index = s.audioTracks.firstIndex(where: { $0.id == s.selectedAudioID }) {
            i.audioTrack = "\(s.audioTracks[index].label) (\(index + 1) of \(s.audioTracks.count))"
        }
        switch session.subtitleSelection {
        case .off: i.subtitle = "Off"
        case .embedded(let id), .external(let id):
            if let t = session.allSubtitleTracks.first(where: { $0.id == id }) {
                i.subtitle = [t.label, t.format, t.isExternal ? "file" : nil].compactMap { $0 }.joined(separator: " · ")
            }
        }
        i.subtitleOffset = session.subtitleOffset.seconds
        i.audioDelay = session.supportsAudioDelay ? session.audioDelay : nil
        i.seeking = session.isScrubbing ? "Scrubbing" : session.seekTarget.map { "Seeking to \(PlaybackEventLog.clock($0))" } ?? "No"
        i.swarm = swarm
        i.piecesAhead = swarm == nil ? nil : PlaybackStats.piecesAhead(ranges: fileRanges, position: s.position, duration: s.duration)
        i.events = session.events.events
        i.stalls = session.events.stalls
        i.stalledFor = session.events.stalledFor
        return i
    }

    private func copy() {
        var i = input
        i.diagnostics = session.engine.diagnostics()
        let text = PlaybackStats.report(i, app: "Bluebox \(AppVersion.display)", system: Self.system, device: Self.deviceModel, at: Date())
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        onCopied()
    }

    /// "macOS 27.0", "iOS 27.0".
    static var system: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let name = "macOS"
        #else
        let name = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
        return "\(name) \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    /// The hardware model ("Mac15,3", "iPhone17,1"): never the device's name.
    static var deviceModel: String {
        #if os(macOS) || targetEnvironment(macCatalyst)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "Unknown device" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "Unknown device" }
        return String(cString: bytes)
    }
}

/// The last minute of bitrate, buffer ahead and torrent download speed, each
/// line scaled to its own largest value.
struct StatsGraph: View {
    let history: StatsHistory
    let showsDownload: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                legend("Bitrate", Palette.brand, dashed: false)
                legend("Buffer", Palette.textPrimary, dashed: false)
                if showsDownload { legend("Download", Palette.textSecondary, dashed: true) }
                Spacer(minLength: 0)
                Text("Last 60 s").foregroundStyle(Palette.textTertiary)
            }
            .font(.caption2.weight(.semibold))
            Canvas { context, size in
                func draw(_ values: [Double], _ color: Color, dashed: Bool, floor: Double = 0) {
                    let v = StatsHistory.normalized(values, floor: floor)
                    guard v.count > 1 else { return }
                    let step = size.width / CGFloat(StatsHistory.length - 1)
                    let x0 = size.width - step * CGFloat(v.count - 1)
                    var path = Path()
                    for (n, value) in v.enumerated() {
                        let p = CGPoint(x: x0 + step * CGFloat(n), y: size.height - 1 - CGFloat(value) * (size.height - 4))
                        if n == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: dashed ? [3, 2] : []))
                }
                draw(history.bitrate, Palette.brand, dashed: false)
                // A steady buffer sits where it is on a 30-second scale, not pinned to the top.
                draw(history.buffer, Palette.textPrimary, dashed: false, floor: 30)
                if showsDownload { draw(history.download, Palette.textSecondary, dashed: true) }
            }
            .frame(height: 40)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Graph of the last minute"))
    }

    private func legend(_ title: String, _ color: Color, dashed: Bool) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: dashed ? 5 : 8, height: 2)
            Text(ui: title).foregroundStyle(Palette.textSecondary)
        }
    }
}
