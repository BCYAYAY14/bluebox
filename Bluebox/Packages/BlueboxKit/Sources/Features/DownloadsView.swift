import Addons
import DesignSystem
import Domain
import Downloads
import Playback
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The Downloads tab: a queue card at the top (overall progress and storage
/// as rings, what's running, speed, time left, network and free space; tap
/// for the queue), then your downloads as posters: Shows, each with its
/// episode count and opening the show's page, and Movies. The ⋯ menu sits
/// at the top. Smart Downloads is set in Settings › Downloads and each
/// show's Download Rules, not here.
///
/// Performance: this screen only re-renders when downloads come, go or
/// finish. Progress ticks reach the queue card and rows, which read
/// `downloadsRevision` in their own bodies.
struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.usesTopNav) private var usesTopNav
    @Environment(\.selectTab) private var selectTab
    @State private var shelves = DownloadShelves.make([])
    /// Any download at all, finished or not (the empty state otherwise).
    @State private var hasDownloads = false
    @State private var confirm: Confirmation?
    @State private var visible = false
    @State private var width: CGFloat = 390

    enum Confirmation: Identifiable {
        case deleteAll([DownloadRecord])
        case deleteWatched([DownloadRecord])
        case deleteShow(title: String, [DownloadRecord])
        var id: String {
            switch self {
            case .deleteAll: "all"
            case .deleteWatched: "watched"
            case .deleteShow(let t, _): "show." + t
            }
        }
    }

    var body: some View {
        let inset = Spacing.pageInset(for: width)
        let poster: CGFloat = width < 500 ? 108 : width < 900 ? 128 : 144
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if usesTopNav { titleRow }
                if hasDownloads {
                    NavigationLink { DownloadQueueView() } label: { DownloadQueueCard() }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("downloadsQueueCard")
                }
                if !hasDownloads {
                    emptyState
                } else if shelves.shows.isEmpty && shelves.movies.isEmpty {
                    Text("Finished downloads appear here.")
                        .font(.footnote).foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Spacing.xl)
                }
            }
            .padding(.horizontal, inset)
            .padding(.bottom, Spacing.s)

            if !shelves.shows.isEmpty {
                shelf("Shows", inset: inset) {
                    ForEach(shelves.shows) { show in
                        DownloadShowPoster(show: show, width: poster) {
                            confirm = .deleteShow(title: show.title, show.rows.map(\.record))
                        }
                    }
                }
            }
            if !shelves.movies.isEmpty {
                shelf("Movies", inset: inset) {
                    ForEach(shelves.movies) { row in DownloadPoster(model: row, width: poster).id(row.id) }
                }
            }
            Color.clear.frame(height: Spacing.xxl)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(Motion.standard(false), value: shelves.ids)
        .reportsHeaderScroll()
        .background { DownloadsChangeObserver { await reload() } }
        .blueboxScreen()
        .navigationTitle("Downloads")
        .toolbar {
            // Under the top bar (Mac, iPad) the menu sits beside the page title
            // instead: a window-toolbar item lands over the top bar's profile button.
            // Its own item with no shared glass behind it: the ⋯ draws its own
            // circle, and the system capsule around it read as a second ring.
            if hasDownloads && !usesTopNav {
                if #available(iOS 26.0, macOS 26.0, *) {
                    ToolbarItem(placement: .primaryAction) { actionsMenu }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) { actionsMenu }
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            switch c {
            case .deleteAll(let list):
                Button("Delete All Downloads", role: .destructive) { app.deleteDownloads(list) }
            case .deleteWatched(let list):
                Button("Delete \(list.count) Watched", role: .destructive) { app.deleteDownloads(list) }
            case .deleteShow(_, let list):
                Button("Delete \(list.count) Episode\(list.count == 1 ? "" : "s")", role: .destructive) { app.deleteDownloads(list) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            switch c {
            case .deleteAll(let list):
                Text("\(list.count) download\(list.count == 1 ? "" : "s") and \(Formatters.bytes(Self.bytes(list))) will be removed from this device, including unfinished ones.")
            case .deleteWatched(let list):
                Text("Frees \(Formatters.bytes(Self.bytes(list))). Movies and episodes you finished watching.")
            case .deleteShow(_, let list):
                Text("Frees \(Formatters.bytes(Self.bytes(list))) on this device.")
            }
        }
        .onAppear { visible = true; updateScreenAwake() }
        .onDisappear { visible = false; updateScreenAwake() }
    }

    private static func bytes(_ list: [DownloadRecord]) -> Int64 { list.reduce(0) { $0 + ($1.expectedBytes ?? $1.receivedBytes) } }

    // MARK: Page

    private var emptyState: some View {
        VStack(spacing: 0) {
            StateMessage(systemImage: "arrow.down.circle", title: "No downloads yet",
                         message: "Download a movie or an episode to watch it offline. Files in your own folders already play offline.")
            // Netflix's next step: go and pick something.
            Button("Find Something to Download") { selectTab(.home) }
                .buttonStyle(PlayButtonStyle())
                .accessibilityIdentifier("findSomethingToDownload")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xxxl)
    }

    private var titleRow: some View {
        HStack(alignment: .center) {
            Text("Downloads").font(Typography.pageTitle).accessibilityAddTraits(.isHeader)
            // Downloads belong to the device, not the profile: say so once there's more than one.
            if app.showsSharedTags { SharedTag() }
            Spacer()
            if hasDownloads { actionsMenu }
        }
        .padding(.top, Spacing.s)
    }

    @ViewBuilder private func shelf<Content: View>(_ title: String, inset: CGFloat,
                                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title).font(Typography.rowTitle).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, inset)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Spacing.m) { content() }
                    .padding(.horizontal, inset)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.bottom, Spacing.l)
    }

    private var actionsMenu: some View {
        BlueboxMenu("Manage Downloads") {
            let queue = app.downloads.queue()
            BlueboxMenuSection {
                BlueboxMenuButton("Pause All", systemImage: "pause", disabled: !queue.contains(where: \.isActive)) {
                    app.pauseAllDownloads()
                }
                BlueboxMenuButton("Resume All", systemImage: "arrow.down",
                                  disabled: !queue.contains { $0.state == .paused || $0.isFailed }) {
                    app.resumeAllDownloads()
                }
            }
            BlueboxMenuSection {
                BlueboxMenuButton("Delete Watched…", systemImage: "eye") {
                    Task {
                        let watched = await app.watchedDownloads()
                        if watched.isEmpty {
                            app.alert = AppAlert(title: "Nothing to delete", message: "None of your downloads has been watched to the end.")
                        } else {
                            confirm = .deleteWatched(watched)
                        }
                    }
                }
                BlueboxMenuButton("Delete All…", systemImage: "trash", role: .destructive) {
                    confirm = .deleteAll(app.downloads.all())
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Palette.glassFill))
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .fixedSize()
        .help("Manage Downloads")
        .accessibilityLabel("Manage Downloads")
        .accessibilityIdentifier("downloadsActions")
    }

    private var confirmTitle: String {
        switch confirm {
        case .deleteAll: "Delete all downloads?"
        case .deleteWatched(let list): "Delete \(list.count) watched download\(list.count == 1 ? "" : "s")?"
        case .deleteShow(let title, _): "Delete every download of \(title)?"
        case nil: ""
        }
    }

    /// Rebuilds the shelves from finished downloads. Progress ticks change
    /// nothing here, so the comparison leaves the page alone.
    private func reload() async {
        let manager = app.downloads
        let pending = PendingDownloadDeletes.shared
        // A download deleted a moment ago is gone from here while its Undo is offered.
        let all = manager.all().filter { !pending.contains($0.id) }
        let finished = all.filter { $0.state == .completed }.map { DownloadRowModel(record: $0, stats: nil, wait: nil) }
        let fresh = DownloadShelves.make(finished)
        if fresh.ids != shelves.ids || fresh.movies != shelves.movies { shelves = fresh }
        if hasDownloads != !all.isEmpty { hasDownloads = !all.isEmpty }
        updateScreenAwake()
    }

    /// Settings › Downloads › Keep Screen Awake: the screen stays on while
    /// you're watching torrents download here (without background downloading
    /// they stop when the screen locks).
    private func updateScreenAwake() {
        #if os(iOS)
        let keepAwake = visible && app.downloadSettings.keepScreenAwake && app.downloads.hasActiveTorrents
        if UIApplication.shared.isIdleTimerDisabled != keepAwake { UIApplication.shared.isIdleTimerDisabled = keepAwake }
        #endif
    }
}

/// Runs `action` whenever downloads change (and when a delete's Undo runs
/// out), from its own body: the screen holding it doesn't re-render on
/// every progress tick, only when `action` changes its state.
struct DownloadsChangeObserver: View {
    @Environment(AppModel.self) private var app
    let action: () async -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: "\(app.downloadsRevision)-\(PendingDownloadDeletes.shared.revision)") { await action() }
    }
}

// MARK: - Queue card

/// Everything in progress at a glance, for the queue card. Pure, so it's tested directly.
struct DownloadQueueSummary: Equatable {
    var downloading = 0
    var queued = 0
    var paused = 0
    var failed = 0
    var receivedBytes: Int64 = 0
    var expectedBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    /// Why the queue isn't moving, when nothing transfers.
    var waitReason: String?

    init(queue: [DownloadRecord], stats: (String) -> DownloadLiveStats?, wait: (String) -> DownloadWait?) {
        for r in queue {
            switch r.state {
            case .downloading: downloading += 1
            case .queued: queued += 1
            case .paused: paused += 1
            case .failed: failed += 1
            case .completed: continue
            }
            receivedBytes += r.receivedBytes
            expectedBytes += max(r.expectedBytes ?? r.receivedBytes, r.receivedBytes)
            if r.state == .downloading { bytesPerSecond += stats(r.id)?.bytesPerSecond ?? 0 }
        }
        if downloading == 0, queued > 0 {
            // The first waiting download's reason speaks for the queue ("Waiting for Wi‑Fi").
            waitReason = queue.first { $0.state == .queued }.flatMap { wait($0.id) }.map(\.message)
        }
    }

    var isEmpty: Bool { downloading + queued + paused + failed == 0 }
    var fraction: Double { expectedBytes > 0 ? Double(receivedBytes) / Double(expectedBytes) : 0 }

    /// "3 downloading · 2 queued", "2 paused", "All downloads finished".
    var headline: String {
        var parts: [String] = []
        if downloading > 0 { parts.append("\(downloading) downloading") }
        if queued > 0 { parts.append("\(queued) queued") }
        if paused > 0 { parts.append("\(paused) paused") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "All downloads finished" : parts.joined(separator: " · ")
    }

    /// "8.4 MB/s · about 12 min left", or why it waits.
    var detail: String? {
        if downloading > 0 {
            var parts = ["\(Formatters.bytes(Int64(bytesPerSecond)))/s"]
            let left = expectedBytes - receivedBytes
            if bytesPerSecond > 1_000, left > 0 { parts.append("about " + Formatters.remaining(Double(left) / bytesPerSecond)) }
            return parts.joined(separator: " · ")
        }
        return waitReason
    }
}

/// The card at the top of Downloads: rings for the queue's progress and the
/// storage, what's running and how fast, the network and free space.
/// Reads download progress in its own body, so ticks re-render only this.
struct DownloadQueueCard: View {
    @Environment(AppModel.self) private var app
    @State private var storage: DownloadStorage?

    var body: some View {
        let _ = app.downloadsRevision
        let manager = app.downloads
        let summary = DownloadQueueSummary(queue: manager.queue(), stats: manager.liveStats, wait: manager.wait)
        HStack(spacing: Spacing.m) {
            ring(summary.isEmpty ? 1 : summary.fraction, tint: summary.downloading > 0 ? Palette.brand : Palette.textTertiary) {
                Image(systemName: summary.isEmpty ? "checkmark" : summary.downloading > 0 ? "arrow.down" : "pause.fill")
                    .font(.system(size: 13, weight: .bold))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.headline).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                if let detail = summary.detail {
                    Text(detail).font(.caption.monospacedDigit()).foregroundStyle(Palette.textSecondary)
                        .contentTransition(.numericText())
                }
                Label(networkLine, systemImage: networkSymbol)
                    .font(.caption).foregroundStyle(Palette.textTertiary)
                    .labelStyle(CompactLabelStyle())
            }
            .lineLimit(1)
            Spacer(minLength: Spacing.s)
            if let storage { storageRing(storage) }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(Spacing.m)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous).strokeBorder(Palette.edge))
        .contentShape(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the download queue")
        .task {
            // Walking the folder is cheap but not free: every few seconds while shown.
            while !Task.isCancelled {
                storage = await Task.detached { manager.storage() }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func ring<Inner: View>(_ fraction: Double, tint: Color, @ViewBuilder inner: () -> Inner) -> some View {
        ProgressRing(fraction: fraction, lineWidth: 3.5, tint: tint)
            .frame(width: 44, height: 44)
            .overlay { inner().foregroundStyle(Palette.textPrimary) }
    }

    /// Bluebox's share of the storage limit, or of the device when there's none.
    private func storageRing(_ s: DownloadStorage) -> some View {
        let limit = app.downloadSettings.storageLimitBytes
        let total = limit ?? (s.freeBytes.map { $0 + s.usedBytes } ?? s.usedBytes)
        let fraction = total > 0 ? Double(s.usedBytes) / Double(total) : 0
        return VStack(spacing: 2) {
            ProgressRing(fraction: fraction, lineWidth: 3, tint: fraction > 0.9 ? SwarmHealth.fair : Palette.textSecondary)
                .frame(width: 30, height: 30)
            Text(Formatters.bytes(s.usedBytes)).font(.caption2.monospacedDigit()).foregroundStyle(Palette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloads use \(Formatters.bytes(s.usedBytes))" + (limit.map { " of \(Formatters.bytes($0))" } ?? ""))
    }

    /// "Wi‑Fi · 41 GB free", "Mobile data · 41 GB free", "Offline".
    private var networkLine: String {
        let c = app.downloads.currentConditions
        let network = !c.isOnline ? "Offline" : c.isExpensive ? "Mobile data" : Self.unmetered
        return [network, storage?.freeBytes.map { "\(Formatters.bytes($0)) free" }].compactMap { $0 }.joined(separator: " · ")
    }

    private var networkSymbol: String {
        let c = app.downloads.currentConditions
        return !c.isOnline ? "wifi.slash" : c.isExpensive ? "antenna.radiowaves.left.and.right" : "wifi"
    }

    #if os(iOS)
    private static let unmetered = "Wi‑Fi"
    #else
    private static let unmetered = "Online"
    #endif
}

/// An icon and text with a tight gap, for one-line captions.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

// MARK: - Models

/// One row's data, so rows re-render when speed or the waiting reason changes.
struct DownloadRowModel: Identifiable, Equatable {
    let record: DownloadRecord
    let stats: DownloadLiveStats?
    let wait: DownloadWait?
    var id: String { record.id }

    var episodeLabel: String? {
        record.subtitle ?? record.mediaKey?.episodeNumbers.map { "S\($0.season)·E\($0.episode)" }
    }

    /// One short line: "62% · 2m left", the reason it's waiting, "Paused · 40%",
    /// or why it failed. The speed is in the menu (`speedLine`).
    var status: String {
        let percent = record.fraction.map { "\(Int(($0 * 100).rounded(.down)))%" }
        switch record.state {
        case .queued:
            return wait?.message ?? "Queued"
        case .downloading:
            if let stats, stats.isConnecting { return "Finding peers…" }
            guard stats != nil || record.receivedBytes > 0 else { return "Starting…" }
            var parts = [percent].compactMap { $0 }
            if let stats, let eta = stats.eta(remaining: record.remainingBytes) { parts.append(Formatters.remaining(eta)) }
            return parts.isEmpty ? "Downloading…" : parts.joined(separator: " · ")
        case .paused:
            return "Paused" + (percent.map { " · \($0)" } ?? "")
        case .completed:
            return record.expectedBytes.map(Formatters.bytes) ?? "Downloaded"
        case .failed(let reason):
            return reason
        }
    }

    /// "4.2 MB/s · 12 peers · 1.1 GB of 1.8 GB" while downloading, for the menu.
    var speedLine: String? {
        guard record.state == .downloading, let stats else { return nil }
        var parts: [String] = []
        if stats.bytesPerSecond > 0 { parts.append(Formatters.bytes(Int64(stats.bytesPerSecond)) + "/s") }
        if let peers = stats.peers, peers > 0 { parts.append(peers == 1 ? "1 peer" : "\(peers) peers") }
        if let total = record.expectedBytes, total > 0 {
            parts.append("\(Formatters.bytes(record.receivedBytes)) of \(Formatters.bytes(total))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The tab's sections: what's still downloading, finished movies, and
/// finished episodes grouped by show.
struct DownloadShelves {
    struct Show: Identifiable, Equatable {
        let id: String
        let title: String
        let artworkURL: URL?
        /// Episodes in order.
        let rows: [DownloadRowModel]
        var seriesKey: MediaKey { MediaKey(rawValue: id) }
        var seasons: [Int] { Array(Set(rows.compactMap { $0.record.mediaKey?.episodeNumbers?.season })).sorted() }
        var bytes: Int64 { rows.reduce(0) { $0 + ($1.record.expectedBytes ?? $1.record.receivedBytes) } }
        var lastEpisodeKey: MediaKey? { rows.last?.record.mediaKey }

        /// "Season 1 · 3 episodes · 4.1 GB", or "2 seasons · 7 episodes · 9 GB".
        var summary: String {
            let s = seasons
            let seasonText = s.count == 1 ? "Season \(s[0])" : s.isEmpty ? nil : "\(s.count) seasons"
            let n = rows.count
            return [seasonText, n == 1 ? "1 episode" : "\(n) episodes", Formatters.bytes(bytes)]
                .compactMap { $0 }.joined(separator: " · ")
        }

        /// "Season 2 · 3.7 GB", for under a poster.
        var shortSummary: String {
            let s = seasons
            let seasonText = s.count == 1 ? (s[0] == 0 ? "Specials" : "Season \(s[0])") : s.isEmpty ? nil : "\(s.count) seasons"
            return [seasonText, Formatters.bytes(bytes)].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var active: [DownloadRowModel]
    var movies: [DownloadRowModel]
    var shows: [Show]
    var running: Int { active.filter { $0.record.state == .downloading }.count }
    /// What the page animates on: only changes when downloads come or go.
    var ids: [String] { shows.map { "\($0.id)#\($0.rows.count)" } + movies.map(\.id) }

    static func make(_ rows: [DownloadRowModel]) -> DownloadShelves {
        let active = rows.filter { $0.record.state != .completed }.sorted { $0.record.sortOrder < $1.record.sortOrder }
        let finished = rows.filter { $0.record.state == .completed }
        var series: [MediaKey: [DownloadRowModel]] = [:]
        var movies: [DownloadRowModel] = []
        for row in finished {
            if let s = row.record.mediaKey?.seriesKey { series[s, default: []].append(row) } else { movies.append(row) }
        }
        let shows = series.map { key, rows in
            let sorted = rows.sorted { order($0) < order($1) }
            return Show(id: key.rawValue, title: sorted.first?.record.title ?? "Series",
                        artworkURL: sorted.first { $0.record.artworkURL != nil }?.record.artworkURL, rows: sorted)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        movies.sort { ($0.record.completedAt ?? $0.record.createdAt) > ($1.record.completedAt ?? $1.record.createdAt) }
        return DownloadShelves(active: active, movies: movies, shows: shows)
    }

    static func order(_ row: DownloadRowModel) -> Int {
        guard let (s, e) = row.record.mediaKey?.episodeNumbers else { return 0 }
        return s * 10_000 + e
    }
}

// MARK: - Posters

/// A finished movie on the Movies shelf: its poster with a small blue
/// check, the title, and its size, or "Better version available" when an
/// upgrade was found. Tap to play; the menu has Swap and Delete.
struct DownloadPoster: View {
    @Environment(AppModel.self) private var app
    let model: DownloadRowModel
    let width: CGFloat
    @State private var menuOpen = false

    private var record: DownloadRecord { model.record }
    private var height: CGFloat { (width * 1.5).rounded() }

    var body: some View {
        let upgrade = app.upgradeOffer(for: record)
        Button {
            if record.state == .completed { Task { await app.playDownloadChecked(record) } } else { menuOpen = true }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ArtworkView(url: record.artworkURL, fallbackTitle: record.title, kind: .poster, pixelWidth: Int(width * 2))
                        .frame(width: width, height: height)
                    if record.state == .completed { CheckDot(size: 20).padding(6) }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.title).font(.footnote.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                    Text(upgrade != nil ? "Better version available" : model.status)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(upgrade != nil ? Palette.brandBright : Palette.textTertiary)
                }
                .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .blueboxMenu(isPresented: $menuOpen, title: record.title) { DownloadActions.menu(record, app: app, details: model.speedLine) }
        .contextMenu { DownloadActions.contextMenu(record, app: app) }
        .accessibilityLabel([record.title, upgrade != nil ? "Better version available" : "Downloaded"].joined(separator: ", "))
        .accessibilityHint("Plays the download")
        .accessibilityIdentifier("downloadPoster")
    }
}

/// A show on the Shows shelf: its poster with how many episodes are saved
/// ("4 EP"), the name and the season and size. Opens the show's page.
struct DownloadShowPoster: View {
    let show: DownloadShelves.Show
    let width: CGFloat
    let deleteAll: () -> Void

    var body: some View {
        NavigationLink {
            DownloadedShowView(seriesKey: show.seriesKey, title: show.title, artworkURL: show.artworkURL)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(url: show.artworkURL, fallbackTitle: show.title, kind: .poster, pixelWidth: Int(width * 2))
                    .frame(width: width, height: (width * 1.5).rounded())
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Text("\(show.rows.count) EP")
                            .font(.caption2.weight(.heavy).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(show.title).font(.footnote.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                    // The episode count is on the badge.
                    Text(show.shortSummary).font(.caption).foregroundStyle(Palette.textTertiary)
                }
                .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button(role: .destructive, action: deleteAll) { Label("Delete All Episodes", systemImage: "trash") }
        }
        .accessibilityLabel("\(show.title), \(show.summary)")
        .accessibilityHint("Opens the show's downloads")
        .accessibilityIdentifier("downloadShowPoster")
    }
}

// MARK: - Actions

/// The actions a download offers, as a Bluebox menu (tap) and a context menu.
@MainActor
enum DownloadActions {
    /// - Parameter details: a line about it (speed, peers, how much is in), shown first.
    @BlueboxMenuBuilder
    static func menu(_ r: DownloadRecord, app: AppModel, details: String? = nil) -> [BlueboxMenuEntry] {
        if let details { [BlueboxMenuEntry.note(details)] }
        if let offer = app.upgradeOffer(for: r) {
            BlueboxMenuSection("Better version available") {
                BlueboxMenuButton("Swap", systemImage: "arrow.triangle.2.circlepath", subtitle: offer.label) {
                    Task { await app.swapDownload(r, to: offer) }
                }
            }
        }
        BlueboxMenuSection {
            switch r.state {
            case .completed:
                BlueboxMenuButton("Play", systemImage: "play.fill") { Task { await app.playDownloadChecked(r) } }
                if app.canOpenDownloadsInInfuse {
                    BlueboxMenuButton("Open in Infuse", systemImage: "arrow.up.forward.app") {
                        Task { await app.playDownloadChecked(r, inInfuse: true) }
                    }
                }
            case .downloading, .queued:
                BlueboxMenuButton("Pause", systemImage: "pause.fill") { app.pauseDownload(r) }
            case .paused:
                BlueboxMenuButton("Resume", systemImage: "arrow.down") { Task { await app.resumeDownload(r) } }
            case .failed:
                BlueboxMenuButton("Retry", systemImage: "arrow.clockwise") { Task { await app.resumeDownload(r) } }
            }
            if r.state == .queued || r.state == .paused {
                BlueboxMenuButton("Download First", systemImage: "arrow.up.to.line") { app.prioritizeDownload(r) }
            }
            if let key = r.mediaKey, key.episodeNumbers != nil {
                BlueboxMenuButton("Download Next 3 Episodes", systemImage: "square.stack.3d.down.forward") {
                    Task { await app.downloadNextEpisodesAnnounced(after: key, showTitle: r.title) }
                }
            }
        }
        BlueboxMenuSection {
            BlueboxMenuButton(r.state == .completed ? "Delete Download" : "Cancel Download", systemImage: "trash",
                              role: .destructive) { app.deleteDownloadWithUndo(r) }
        }
    }

    @ViewBuilder
    static func contextMenu(_ r: DownloadRecord, app: AppModel) -> some View {
        if let offer = app.upgradeOffer(for: r) {
            Button { Task { await app.swapDownload(r, to: offer) } } label: {
                Label("Swap for \(offer.label)", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        switch r.state {
        case .completed:
            Button { Task { await app.playDownloadChecked(r) } } label: { Label("Play", systemImage: "play.fill") }
            if app.canOpenDownloadsInInfuse {
                Button { Task { await app.playDownloadChecked(r, inInfuse: true) } } label: {
                    Label("Open in Infuse", systemImage: "arrow.up.forward.app")
                }
            }
        case .downloading, .queued:
            Button { app.pauseDownload(r) } label: { Label("Pause", systemImage: "pause") }
        case .paused:
            Button { Task { await app.resumeDownload(r) } } label: { Label("Resume", systemImage: "arrow.down") }
        case .failed:
            Button { Task { await app.resumeDownload(r) } } label: { Label("Retry", systemImage: "arrow.clockwise") }
        }
        if r.state == .queued || r.state == .paused {
            Button { app.prioritizeDownload(r) } label: { Label("Download First", systemImage: "arrow.up.to.line") }
        }
        if let key = r.mediaKey, key.episodeNumbers != nil {
            Button { Task { await app.downloadNextEpisodesAnnounced(after: key, showTitle: r.title) } } label: {
                Label("Download Next 3 Episodes", systemImage: "square.stack.3d.down.forward")
            }
        }
        Button(role: .destructive) { app.deleteDownloadWithUndo(r) } label: {
            Label(r.state == .completed ? "Delete Download" : "Cancel Download", systemImage: "trash")
        }
    }
}

// MARK: - Title page

/// The title page's Download button, under Play. One shape in every state:
/// "Download S2·E3", "Downloading · 62%" with the progress filling the
/// button, "Paused · 40%", "Downloaded" (or "Better Version Available").
/// Once there's a download, a tap opens its options (Pause, Cancel, Swap,
/// Go to Downloads…) instead of acting at once. Opening the page is when a
/// finished download looks for a better release (at most daily).
struct DownloadButton: View {
    @Environment(AppModel.self) private var app
    @Environment(\.selectTab) private var selectTab
    let key: MediaKey
    let title: String
    var subtitle: String?
    /// Full width under a full-width Play (iPhone).
    var fullWidth = false
    @State private var canDownload = false

    var body: some View {
        // Reads downloadsRevision (and pending deletes), so this refreshes with progress.
        let record = app.visibleDownload(for: key)
        Group {
            if let record {
                let upgrade = app.upgradeOffer(for: record)
                BlueboxMenu("Download") { menu(for: record) } label: {
                    DownloadButtonFace(text: upgrade != nil ? "Better Version Available" : text(for: record),
                                       symbol: upgrade != nil ? "arrow.triangle.2.circlepath" : symbol(for: record),
                                       fraction: record.state == .completed ? nil : record.fraction,
                                       active: record.state == .downloading, fullWidth: fullWidth)
                }
                .accessibilityLabel(accessibilityText(for: record) + (upgrade != nil ? ", better version available" : ""))
                .accessibilityHint("Shows download options")
            } else if app.preparingDownloads.contains(key) {
                // Tapped a moment ago: answers at once while a release is found.
                DownloadButtonFace(text: "Preparing Download…", symbol: "arrow.down.circle.dotted", fraction: nil,
                                   active: true, fullWidth: fullWidth)
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityLabel("Preparing download")
            } else if canDownload {
                HStack(spacing: 2) {
                    Button { start() } label: {
                        DownloadButtonFace(text: subtitle.map { "Download \($0)" } ?? "Download", symbol: "arrow.down.circle",
                                           fullWidth: fullWidth, trailingSquare: key.episodeNumbers != nil)
                    }
                    .buttonStyle(PressableStyle(haptic: true))
                    if key.episodeNumbers != nil {
                        BlueboxMenu("Download Options") {
                            BlueboxMenuButton("Download Episode", systemImage: "arrow.down.circle") { start() }
                            BlueboxMenuButton("Download This and the Next 3", systemImage: "square.stack.3d.down.forward") {
                                Task {
                                    await app.startDownload(key: key, title: title, subtitle: subtitle)
                                    await app.downloadNextEpisodes(after: key, count: 3)
                                }
                            }
                        } label: {
                            DownloadButtonFace(text: nil, symbol: "chevron.down", fullWidth: false, leadingSquare: true)
                        }
                        .accessibilityLabel("More Download Options")
                    }
                }
            } else {
                // An empty Group has no view to hang `.task` on, so the check below would never run.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .accessibilityIdentifier("downloadButton")
        .task(id: "\(key.rawValue)-\(app.sourcesRevision)") {
            canDownload = await app.downloadableVariant(for: key) != nil
            await app.checkForUpgrade(key)
        }
    }

    private func text(for r: DownloadRecord) -> String {
        let percent = r.fraction.map { "\(Int(($0 * 100).rounded(.down)))%" }
        switch r.state {
        case .completed: return "Downloaded"
        case .downloading: return percent.map { "Downloading · \($0)" } ?? "Starting Download…"
        case .queued: return "Download Queued"
        case .paused: return "Paused" + (percent.map { " · \($0)" } ?? "")
        case .failed: return "Download Failed"
        }
    }

    private func symbol(for r: DownloadRecord) -> String {
        switch r.state {
        case .completed: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle"
        case .queued: "clock"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.circle"
        }
    }

    @BlueboxMenuBuilder private func menu(for r: DownloadRecord) -> [BlueboxMenuEntry] {
        if let offer = app.upgradeOffer(for: r) {
            BlueboxMenuSection("Better version available") {
                BlueboxMenuButton("Swap", systemImage: "arrow.triangle.2.circlepath",
                                  subtitle: "\(offer.label). Yours stays until it's in.") {
                    Task { await app.swapDownload(r, to: offer) }
                }
            }
        }
        switch r.state {
        case .completed:
            BlueboxMenuButton("Play Download", systemImage: "play.fill") { Task { await app.playDownloadChecked(r) } }
            if key.episodeNumbers != nil {
                BlueboxMenuButton("Download Next 3 Episodes", systemImage: "square.stack.3d.down.forward") {
                    Task { await app.downloadNextEpisodesAnnounced(after: key, showTitle: r.title) }
                }
            }
        case .downloading, .queued:
            BlueboxMenuButton("Pause Download", systemImage: "pause.fill") { app.pauseDownload(r) }
            if r.state == .queued {
                BlueboxMenuButton("Download First", systemImage: "arrow.up.to.line") { app.prioritizeDownload(r) }
            }
        case .paused:
            BlueboxMenuButton("Resume Download", systemImage: "arrow.down") { Task { await app.resumeDownload(r) } }
        case .failed(let message):
            BlueboxMenuNote(message)
            BlueboxMenuSection {
                BlueboxMenuButton("Try Again", systemImage: "arrow.clockwise") { Task { await app.resumeDownload(r) } }
            }
        }
        BlueboxMenuSection {
            BlueboxMenuButton("Go to Downloads", systemImage: "arrow.down.circle") { selectTab(.downloads) }
        }
        BlueboxMenuSection {
            BlueboxMenuButton(r.state == .completed ? "Delete Download" : r.isFailed ? "Remove" : "Cancel Download",
                              systemImage: r.state == .completed ? "trash" : "xmark", role: .destructive) {
                app.deleteDownloadWithUndo(r)
            }
        }
    }

    private func accessibilityText(for r: DownloadRecord) -> String {
        switch r.state {
        case .completed: "Downloaded"
        case .downloading: "Downloading, \(Int((r.fraction ?? 0) * 100)) percent"
        case .queued: "Download queued"
        case .paused: "Download paused at \(Int((r.fraction ?? 0) * 100)) percent"
        case .failed: "Download failed"
        }
    }

    private func start() { Task { await app.startDownload(key: key, title: title, subtitle: subtitle) } }
}

/// The Download button's look: the secondary grey button, with the progress
/// filling it from the leading edge (blue while downloading, grey paused).
private struct DownloadButtonFace: View {
    let text: String?
    let symbol: String
    var fraction: Double?
    var active = false
    let fullWidth: Bool
    /// Squared-off edges where the split button's two halves meet.
    var trailingSquare = false
    var leadingSquare = false

    private var shape: UnevenRoundedRectangle {
        let r = Radius.control
        return UnevenRoundedRectangle(topLeadingRadius: leadingSquare ? 2 : r, bottomLeadingRadius: leadingSquare ? 2 : r,
                                      bottomTrailingRadius: trailingSquare ? 2 : r, topTrailingRadius: trailingSquare ? 2 : r,
                                      style: .continuous)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(text == nil ? .caption.weight(.bold) : Typography.button)
            if let text {
                Text(text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.numericText())
            }
        }
        .font(Typography.button)
        .foregroundStyle(.white)
        .padding(.horizontal, text == nil ? 0 : Spacing.l)
        .frame(width: text == nil ? 44 : nil)
        .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
        .background {
            ZStack(alignment: .leading) {
                Palette.glassFill
                if let fraction {
                    GeometryReader { geo in
                        (active ? Palette.brand.opacity(0.45) : Color.white.opacity(0.12))
                            .frame(width: geo.size.width * min(max(fraction, 0), 1))
                    }
                    .animation(.easeOut(duration: 0.3), value: fraction)
                }
            }
            .clipShape(shape)
        }
        .contentShape(shape)
    }
}
