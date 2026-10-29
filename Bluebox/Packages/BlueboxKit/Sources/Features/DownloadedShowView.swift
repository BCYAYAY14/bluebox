import DesignSystem
import Domain
import Downloads
import SwiftUI

/// A downloaded show, from its poster on the Downloads tab: the backdrop
/// and name, the show's Download Rules card, then its downloaded episodes
/// by season with "Up next" on the one you're up to. Tap an episode to
/// play; its menu deletes it.
struct DownloadedShowView: View {
    /// One season's download IDs, in episode order.
    struct SeasonIDs: Identifiable, Equatable {
        let number: Int
        let ids: [String]
        var id: Int { number }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let seriesKey: MediaKey
    let title: String
    let artworkURL: URL?

    /// Download IDs by season, in episode order: only changes when episodes come or go.
    @State private var seasons: [SeasonIDs] = []
    @State private var bytesBySeason: [Int: Int64] = [:]
    @State private var backdrop: URL?
    @State private var progress: [MediaKey: WatchProgress] = [:]
    @State private var episodes: [MediaKey: Episode] = [:]
    @State private var confirmDelete = false
    @State private var width: CGFloat = 390

    var body: some View {
        let inset = Spacing.pageInset(for: width)
        let upNext = upNextKey
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: Spacing.l) {
                    ShowDownloadRulesCard(series: seriesKey, showName: title)
                        .frame(maxWidth: 640, alignment: .leading)
                    ForEach(seasons) { season in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(seasonHeader(season.number, count: season.ids.count))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Palette.textSecondary)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(season.ids, id: \.self) { id in
                                DownloadedEpisodeRow(id: id, episodes: episodes, progress: progress, upNext: upNext)
                            }
                        }
                    }
                    if seasons.isEmpty {
                        Text("No episodes of \(title) are downloaded.")
                            .font(.footnote).foregroundStyle(Palette.textTertiary)
                    }
                }
                .padding(.horizontal, inset)
                .padding(.top, Spacing.m)
                .frame(maxWidth: 1000 + inset * 2, alignment: .leading)
            }
            .padding(.bottom, Spacing.xxl)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background { DownloadsChangeObserver { await reloadDownloads() } }
        .task(id: app.libraryRevision) { await loadProgress() }
        .task { await loadArtworkAndNames() }
        .blueboxScreen()
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // A flat Bluebox button: no system glass behind the ⋯'s own circle.
            if #available(iOS 26.0, macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { actions }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { actions }
            }
        }
        .confirmationDialog("Delete every download of \(title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete All Episodes", role: .destructive) {
                let all = app.downloads.all().filter { $0.mediaKey?.seriesKey == seriesKey }
                app.deleteDownloads(all)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkView(url: backdrop ?? artworkURL, fallbackTitle: title, kind: .backdrop, pixelWidth: Int(min(width, 1200) * 2),
                        showsFallbackTitle: false)
                .frame(maxWidth: .infinity)
                .frame(height: min(max(width * 0.42, 160), 320))
                .clipped()
            LinearGradient(colors: [.clear, Palette.background], startPoint: .center, endPoint: .bottom)
            Text(title)
                .font(Typography.display(compact: width < 600))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .padding(.horizontal, Spacing.pageInset(for: width))
                .padding(.bottom, Spacing.xs)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(height: min(max(width * 0.42, 160), 320))
    }

    private var actions: some View {
        BlueboxMenu("Show Actions") {
            BlueboxMenuSection {
                if let last = seasons.last?.ids.last.flatMap({ app.downloads.record(id: $0)?.mediaKey }) {
                    BlueboxMenuButton("Download Next 3 Episodes", systemImage: "square.stack.3d.down.forward") {
                        Task { await app.downloadNextEpisodesAnnounced(after: last, showTitle: title) }
                    }
                }
            }
            BlueboxMenuSection {
                BlueboxMenuButton("Delete All Episodes…", systemImage: "trash", role: .destructive) { confirmDelete = true }
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
        .accessibilityLabel("Show Actions")
    }

    /// "Season 1 · 4 episodes · 5.6 GB".
    private func seasonHeader(_ number: Int, count: Int) -> String {
        [number == 0 ? "Specials" : "Season \(number)", count == 1 ? "1 episode" : "\(count) episodes",
         bytesBySeason[number].map(Formatters.bytes)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The first downloaded episode, in order, that you haven't finished.
    private var upNextKey: MediaKey? {
        seasons.flatMap(\.ids).lazy.compactMap { app.downloads.record(id: $0)?.mediaKey }
            .first { progress[$0]?.isCompleted != true }
    }

    private func reloadDownloads() async {
        let pending = PendingDownloadDeletes.shared
        let records = app.downloads.all().filter { $0.mediaKey?.seriesKey == seriesKey && !pending.contains($0.id) }
        let grouped = Dictionary(grouping: records) { $0.mediaKey?.episodeNumbers?.season ?? 0 }
        let fresh = grouped.keys.sorted().map { n in
            SeasonIDs(number: n, ids: grouped[n]!.sorted { ($0.mediaKey?.episodeNumbers?.episode ?? 0) < ($1.mediaKey?.episodeNumbers?.episode ?? 0) }
                .map(\.id))
        }
        if fresh.map(\.ids) != seasons.map(\.ids) { seasons = fresh }
        let bytes = grouped.mapValues { $0.reduce(Int64(0)) { $0 + ($1.expectedBytes ?? $1.receivedBytes) } }
        if bytes != bytesBySeason { bytesBySeason = bytes }
    }

    private func loadProgress() async {
        let list = (try? await app.store.progress(forSeries: seriesKey)) ?? []
        progress = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
    }

    /// The show's backdrop and its episodes' names and stills (cached by the metadata provider).
    private func loadArtworkAndNames() async {
        if let t = await app.title(for: seriesKey) { backdrop = app.imageURL(t.backdrop, width: 1280) }
        var found: [MediaKey: Episode] = [:]
        let numbers = Set(app.downloads.all().compactMap { r in r.mediaKey?.seriesKey == seriesKey ? r.mediaKey?.episodeNumbers?.season : nil })
        for n in numbers.sorted() {
            guard let season = try? await app.metadata.season(n, of: seriesKey) else { continue }
            for ep in season.episodes { found[ep.key] = ep }
        }
        episodes = found
    }
}

/// One episode on a downloaded show's page: its still with a play mark,
/// "E2 · Name", then "Up next", "Watched" or how far along it is, and the
/// size. Reads its own download's progress.
struct DownloadedEpisodeRow: View {
    @Environment(AppModel.self) private var app
    let id: String
    let episodes: [MediaKey: Episode]
    let progress: [MediaKey: WatchProgress]
    let upNext: MediaKey?
    @State private var menuOpen = false

    var body: some View {
        let _ = app.downloadsRevision
        if let r = app.downloads.record(id: id), let key = r.mediaKey {
            let ep = episodes[key]
            let watched = progress[key]?.isCompleted == true
            Button {
                if r.state == .completed { Task { await app.playDownloadChecked(r) } } else { menuOpen = true }
            } label: {
                HStack(spacing: Spacing.m) {
                    thumbnail(r, still: ep?.still)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(r, ep)).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        HStack(spacing: 4) {
                            if key == upNext, r.state == .completed {
                                Text("Up next").foregroundStyle(Palette.brandBright)
                                Text("·")
                            }
                            Text(detail(r, watched: watched))
                        }
                        .font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .blueboxMenu(isPresented: $menuOpen, title: title(r, ep)) { DownloadActions.menu(r, app: app) }
            .contextMenu { DownloadActions.contextMenu(r, app: app) }
            .accessibilityElement(children: .combine)
            .accessibilityHint(r.state == .completed ? "Plays the download" : "Shows actions")
            .accessibilityAction(named: "Delete") { app.deleteDownloadWithUndo(r) }
        }
    }

    private func title(_ r: DownloadRecord, _ ep: Episode?) -> String {
        guard let n = r.mediaKey?.episodeNumbers else { return r.subtitle ?? r.title }
        return ep.map { "E\(n.episode) · \($0.name)" } ?? "Episode \(n.episode)"
    }

    /// "1.4 GB · Watched", "Downloading · 42%", "Better version available".
    private func detail(_ r: DownloadRecord, watched: Bool) -> String {
        if r.state != .completed { return DownloadRowModel(record: r, stats: app.downloads.liveStats(r.id), wait: app.downloads.wait(r.id)).status }
        if app.upgradeOffer(for: r) != nil { return "Better version available" }
        return [r.expectedBytes.map(Formatters.bytes), r.origin.resolution, watched ? "Watched" : nil].compactMap { $0 }
            .joined(separator: " · ")
    }

    private func thumbnail(_ r: DownloadRecord, still: Artwork?) -> some View {
        let w: CGFloat = 112, h = (w * 9 / 16).rounded()
        return ZStack(alignment: .bottom) {
            ArtworkView(url: still.flatMap { app.imageURL($0, width: w) } ?? r.artworkURL, fallbackTitle: r.title, kind: .still,
                        pixelWidth: Int(w * 2), showsFallbackTitle: false)
                .frame(width: w, height: h)
            Image(systemName: r.state == .completed ? "play.fill" : "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.4), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if r.state != .completed {
                EdgeProgressBar(fraction: r.fraction ?? 0, height: 3,
                                tint: r.state == .downloading ? Palette.brand : Palette.textTertiary)
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityHidden(true)
    }
}
