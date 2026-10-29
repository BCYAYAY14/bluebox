import Addons
import DesignSystem
import Domain
import Downloads
import SwiftUI

/// The download queue, from the Downloads tab's queue card. Each row shows
/// how much is in, the speed and the time left, with where it comes from on
/// the next line ("Torrent · 42 peers", "Real-Debrid", "Direct"). The bar is
/// blue while downloading, grey while paused or waiting, and amber when
/// stalled or failed, with the reason. Drag to reorder; swipe left to
/// delete, right to pause or resume.
///
/// The list only rebuilds when the queue's members or order change; each
/// row follows its own download's progress.
struct DownloadQueueView: View {
    @Environment(AppModel.self) private var app
    @State private var ids: [String] = []
    @State private var anyActive = false
    @State private var anyStopped = false

    var body: some View {
        List {
            if ids.isEmpty {
                StateMessage(systemImage: "checkmark.circle", title: "Nothing downloading",
                             message: "Downloads you start, and the next episodes Smart Downloads fetches, line up here.")
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.xxl)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(ids, id: \.self) { id in
                DownloadQueueRow(id: id)
                    .listRowInsets(EdgeInsets(top: Spacing.s, leading: Spacing.l, bottom: Spacing.s, trailing: Spacing.m))
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Palette.separator)
            }
            .onMove { from, to in
                var order = ids
                order.move(fromOffsets: from, toOffset: to)
                ids = order
                app.reorderDownloads(order)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(Motion.standard(false), value: ids)
        .background { DownloadsChangeObserver { reload() } }
        .blueboxScreen()
        .navigationTitle("Queue")
        .toolbar {
            // Flat text, no system glass (UI review: toolbar buttons).
            if #available(iOS 26.0, macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { allButton }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { allButton }
            }
        }
    }

    @ViewBuilder private var allButton: some View {
        if anyActive {
            Button("Pause All") { app.pauseAllDownloads() }
                .buttonStyle(PressableStyle())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.brandBright)
                .fixedSize()  // a toolbar item otherwise truncates it to "Pause…"
                .accessibilityIdentifier("queuePauseAll")
        } else if anyStopped {
            Button("Resume All") { app.resumeAllDownloads() }
                .buttonStyle(PressableStyle())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.brandBright)
                .fixedSize()
                .accessibilityIdentifier("queueResumeAll")
        }
    }

    private func reload() {
        let pending = PendingDownloadDeletes.shared
        let queue = app.downloads.queue().filter { !pending.contains($0.id) }
        let fresh = queue.map(\.id)
        if fresh != ids { ids = fresh }
        let active = queue.contains(where: \.isActive)
        let stopped = queue.contains { $0.state == .paused || $0.isFailed }
        if active != anyActive { anyActive = active }
        if stopped != anyStopped { anyStopped = stopped }
    }
}

/// One download in the queue. Reads its own progress, so ticks re-render
/// just this row.
struct DownloadQueueRow: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var menuOpen = false

    var body: some View {
        let _ = app.downloadsRevision
        let manager = app.downloads
        if let record = manager.record(id: id) {
            let model = DownloadQueueRowModel(record: record, stats: manager.liveStats(id), wait: manager.wait(id),
                                              idle: manager.idleSeconds(id), debridName: debridName,
                                              addonsID: app.addons.id)
            row(model)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { app.deleteDownloadWithUndo(record) } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    switch record.state {
                    case .downloading, .queued:
                        Button { app.pauseDownload(record) } label: { Label("Pause", systemImage: "pause.fill") }.tint(Palette.brandDeep)
                    case .paused:
                        Button { Task { await app.resumeDownload(record) } } label: { Label("Resume", systemImage: "arrow.down") }
                            .tint(Palette.brand)
                    case .failed:
                        Button { Task { await app.resumeDownload(record) } } label: { Label("Retry", systemImage: "arrow.clockwise") }
                            .tint(Palette.brand)
                    case .completed:
                        EmptyView()
                    }
                }
                .contextMenu { DownloadActions.contextMenu(record, app: app) }
                .blueboxMenu(isPresented: $menuOpen, title: record.title) {
                    DownloadActions.menu(record, app: app, details: DownloadRowModel(record: record, stats: manager.liveStats(id), wait: nil).speedLine)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "Delete") { app.deleteDownloadWithUndo(record) }
        }
    }

    private var debridName: String {
        let d = app.addonSettings.debrid
        return d == .none ? "Debrid" : d.title
    }

    private func row(_ m: DownloadQueueRowModel) -> some View {
        Button { menuOpen = true } label: {
            HStack(alignment: .top, spacing: Spacing.m) {
                ArtworkView(url: m.record.artworkURL, fallbackTitle: m.record.title, kind: .poster, pixelWidth: 80,
                            showsFallbackTitle: false)
                    .frame(width: 36, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                    Text(m.progressLine).font(.caption.monospacedDigit()).foregroundStyle(Palette.textSecondary)
                        .contentTransition(.numericText())
                    Text(m.sourceLine).font(.caption)
                        .foregroundStyle(m.tone == .stalled ? SwarmHealth.fair : Palette.textTertiary)
                    bar(m).padding(.top, 5)
                }
                .lineLimit(1)
                Image(systemName: "line.3.horizontal")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.top, Spacing.s)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func bar(_ m: DownloadQueueRowModel) -> some View {
        let tint: Color = switch m.tone {
        case .running: Palette.brand
        case .stalled: SwarmHealth.fair
        case .waiting: Palette.textTertiary
        }
        return EdgeProgressBar(fraction: m.record.fraction ?? 0, height: 3, tint: tint)
            .clipShape(Capsule())
    }
}

/// What a queue row says. Pure, so it's tested directly.
struct DownloadQueueRowModel {
    enum Tone: Equatable { case running, waiting, stalled }

    let record: DownloadRecord
    let stats: DownloadLiveStats?
    let wait: DownloadWait?
    /// Seconds since new bytes arrived (`DownloadManager.idleSeconds`).
    let idle: TimeInterval?
    let debridName: String
    /// The add-ons source: its HTTPS downloads are debrid links.
    let addonsID: SourceID

    var title: String {
        let episode = record.subtitle ?? record.mediaKey?.episodeNumbers.map { "S\($0.season)·E\($0.episode)" }
        return [record.title, episode].compactMap { $0 }.joined(separator: " · ")
    }

    var stall: String? { DownloadStall.reason(record, stats: stats, idle: idle) }

    var tone: Tone {
        if record.isFailed || stall != nil { return .stalled }
        return record.state == .downloading ? .running : .waiting
    }

    /// "1.1 of 2.3 GB · 3.1 MB/s · 6 min", "Paused · 0.4 of 2.4 GB", "Waiting for Wi‑Fi".
    var progressLine: String {
        let amount = record.expectedBytes.map { "\(Formatters.bytes(record.receivedBytes)) of \(Formatters.bytes($0))" }
        switch record.state {
        case .downloading:
            if stats?.isConnecting == true { return "Finding peers…" }
            var parts = [amount ?? Formatters.bytes(record.receivedBytes)]
            if stall != nil { parts.append("stalled") } else if let stats, stats.bytesPerSecond > 0 {
                parts.append("\(Formatters.bytes(Int64(stats.bytesPerSecond)))/s")
                if let eta = stats.eta(remaining: record.remainingBytes) { parts.append(Formatters.remaining(eta)) }
            }
            return parts.joined(separator: " · ")
        case .queued:
            return wait?.message ?? "Queued"
        case .paused:
            return ["Paused", amount].compactMap { $0 }.joined(separator: " · ")
        case .failed:
            return ["Stopped", amount].compactMap { $0 }.joined(separator: " · ")
        case .completed:
            return record.expectedBytes.map(Formatters.bytes) ?? "Downloaded"
        }
    }

    /// Where it comes from, or why it's stuck: "Torrent · 42 peers",
    /// "Real-Debrid", "Direct", "No peers for 2 min", a failure's reason.
    var sourceLine: String {
        if let message = record.failureMessage { return message + " · Retry" }
        if let stall { return stall }
        let source: String
        if record.isTorrent {
            let peers = stats?.peers.map { $0 == 1 ? "1 peer" : "\($0) peers" }
            source = ["Torrent", record.state == .downloading ? peers : nil].compactMap { $0 }.joined(separator: " · ")
        } else if record.origin.sourceID == addonsID {
            source = debridName
        } else {
            source = "Direct"
        }
        let size = record.state == .queued ? record.expectedBytes.map(Formatters.bytes) : nil
        return [source, size].compactMap { $0 }.joined(separator: " · ")
    }
}
