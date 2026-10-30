import DesignSystem
import Domain
import Downloads
import SwiftUI

// A film collection's page (TMDB's collections: every Alien film, every
// Toy Story): its films in release order, with Play All, Download All and
// Add All to My List. Reached from a film's "Part of …" row.

/// What the collection page's buttons act on.
enum CollectionPlan {
    /// Films out by `now`, in release order: Play All and Download All skip
    /// ones announced but not out (no date, or a date still to come).
    static func released(_ parts: [Title], now: Date = .now) -> [Title] {
        parts.filter { $0.releaseDate.map { $0 <= now } ?? false }
    }

    /// Download All: released films not already downloaded or on their way.
    static func toDownload(_ parts: [Title], now: Date = .now, has: (MediaKey) -> Bool) -> [Title] {
        released(parts, now: now).filter { !has($0.key) }
    }

    /// Add All to My List: every film (unreleased ones too) not on it yet.
    static func toAdd(_ parts: [Title], onList: Set<MediaKey>) -> [Title] {
        parts.filter { !onList.contains($0.key) }
    }

    /// "4 films · 7 h 50 min" (the runtime only when some are known).
    static func summary(count: Int, minutes: Int) -> String {
        let films = "\(count) film\(count == 1 ? "" : "s")"
        guard minutes > 0 else { return films }
        let h = minutes / 60, m = minutes % 60
        let time = h == 0 ? "\(m) min" : m == 0 ? "\(h) h" : "\(h) h \(m) min"
        return "\(films) · \(time)"
    }
}

extension AppModel {
    /// Collections come from TMDB, like people's pages.
    public func collection(id: Int) async throws -> FilmCollection {
        guard let extras = metadata as? any MetadataExtras, id > 0 else { throw MetadataError.notFound }
        return try await extras.collection(id: id)
    }

    /// Plays the released films from the first: the first now, the rest through Up Next.
    func playCollection(_ c: FilmCollection) async {
        await playList(CollectionPlan.released(c.parts), shuffled: false)
    }

    /// True when `key` has a download that isn't failed or waiting out its Undo.
    func hasLiveDownload(_ key: MediaKey) -> Bool {
        downloads.records(for: key).contains { !$0.isFailed && !PendingDownloadDeletes.shared.contains($0.id) }
    }

    /// Download All: queues the released films not downloaded yet, in release
    /// order. Each shows "preparing" at once; one toast at the end says what
    /// happened, instead of an alert per film. Returns the films it asked for.
    @discardableResult
    func downloadCollection(_ c: FilmCollection) -> [Title] {
        let wanted = CollectionPlan.toDownload(c.parts) { hasLiveDownload($0) }
        guard !wanted.isEmpty else {
            showToast(AppToast("Nothing more to download", message: "\(c.name): every film that's out is already downloaded.",
                               style: .info))
            return []
        }
        preparingDownloads.formUnion(wanted.map(\.key))
        Task { [weak self] in
            guard let self else { return }
            var failed: [(Title, Error)] = []
            var heldForWiFi = 0
            for film in wanted {
                defer { self.preparingDownloads.remove(film.key) }
                do {
                    let (variant, resource) = try await self.downloadTarget(for: film.key)
                    let record = try self.downloads.enqueue(variant, key: film.key, title: film.name, subtitle: film.year.map(String.init),
                                                            artworkURL: self.imageURL(film.poster, width: 120), resource: resource)
                    if self.mobileDataDownloadNotice(for: record, title: film.name) != nil { heldForWiFi += 1 }
                } catch DownloadError.alreadyInQueue {
                    continue
                } catch {
                    failed.append((film, error))
                }
            }
            self.announceCollectionDownload(c, queued: wanted.count - failed.count, failed: failed, heldForWiFi: heldForWiFi)
            if failed.count < wanted.count { Task { _ = await EpisodeNotifications.requestPermission() } }
        }
        return wanted
    }

    private func announceCollectionDownload(_ c: FilmCollection, queued: Int, failed: [(Title, Error)], heldForWiFi: Int) {
        if !failed.isEmpty {
            let names = failed.prefix(3).map(\.0.name).joined(separator: ", ") + (failed.count > 3 ? "…" : "")
            let reason = UserFacingError.message(for: failed[0].1, context: .download)
            let title = queued == 0 ? "Couldn't download \(c.name)"
                                    : "Couldn't download \(failed.count) of \(failed.count + queued) films"
            showToast(AppToast(title, message: "\(names): \(reason)", style: .error, actionTitle: "Try Again") { [weak self] in
                self?.downloadCollection(c)
            })
        } else if heldForWiFi > 0 {
            showToast(AppToast("Will download on Wi‑Fi", message: "\(c.name) · \(heldForWiFi) film\(heldForWiFi == 1 ? "" : "s") queued",
                               style: .info))
        } else {
            showToast(AppToast("Downloading \(queued) film\(queued == 1 ? "" : "s")", message: c.name, style: .success))
        }
    }

    /// Add All to My List: the films not on it yet, with one toast and Undo.
    /// Returns the films it added.
    @discardableResult
    func addCollectionToMyList(_ c: FilmCollection) async -> [Title] {
        let onList: Set<MediaKey>
        do { onList = Set(try await store.watchlist().map(\.key)) } catch {
            report(error, title: "Couldn't update My List")
            return []
        }
        let adding = CollectionPlan.toAdd(c.parts, onList: onList)
        guard !adding.isEmpty else {
            showToast(AppToast("Already on My List", message: c.name, style: .info))
            return []
        }
        var added: [Title] = []
        do {
            for t in adding {
                try await store.setWatchlisted(t, true)
                added.append(t)
            }
        } catch {
            report(error, title: "Couldn't update My List")
        }
        noteLibraryChanged()
        guard !added.isEmpty else { return [] }
        showToast(AppToast("Added \(added.count) film\(added.count == 1 ? "" : "s") to My List", message: c.name,
                           style: .success, actionTitle: "Undo") { [weak self] in
            Task {
                for t in added { try? await self?.store.setWatchlisted(t, false) }
                self?.noteLibraryChanged()
            }
        })
        return added
    }
}

// MARK: - Page

/// A collection: its poster, name, film count and runtime, overview and the
/// three bulk buttons, then its films in release order with their years.
/// Films open through `Route.title`, so this sits inside a NavigationStack.
struct CollectionView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the film's row knew, shown while the collection loads.
    let ref: CollectionRef

    @State private var collection: FilmCollection?
    @State private var totalMinutes = 0
    @State private var error: String?
    @State private var failedOffline = false
    @State private var overviewExpanded = false
    @State private var confirmDownload = false

    private var name: String { collection?.name ?? ref.name }
    private var released: [Title] { CollectionPlan.released(collection?.parts ?? []) }

    var body: some View {
        GeometryReader { geo in
            let inset = Spacing.pageInset(for: geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    header(inset: inset)
                    if let error, collection == nil {
                        if failedOffline {
                            OfflineMessage(reason: "Collections need the internet.") { Task { await load() } }
                        } else {
                            StateMessage(.failed, title: "Couldn't load this collection", message: error,
                                         actionTitle: "Try Again") { Task { await load() } }
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        films(width: geo.size.width, inset: inset)
                    }
                }
                .padding(.vertical, Spacing.l)
            }
            .reportsHeaderScroll()
        }
        .blueboxScreen()
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: ref.id) { await load() }
        .reloadsWhenBackOnline(error != nil && collection == nil) { await load() }
        .confirmationDialog(downloadQuestion, isPresented: $confirmDownload, titleVisibility: .visible) {
            Button(downloadCount == 1 ? "Download 1 Film" : "Download \(downloadCount) Films") {
                if let collection { app.downloadCollection(collection) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloads continue in the background and you can cancel them from Downloads.")
        }
    }

    private var downloadCount: Int {
        CollectionPlan.toDownload(collection?.parts ?? []) { app.hasLiveDownload($0) }.count
    }

    private var downloadQuestion: String { "Download \(name)?" }

    private func load() async {
        do {
            let c = try await app.collection(id: ref.id)
            let runtimes = await app.runtimes(for: c.parts)
            totalMinutes = c.parts.reduce(0) { $0 + (runtimes[$1.key] ?? 0) }
            withAnimation(collection == nil ? nil : Motion.snappy(reduceMotion)) { collection = c }
            error = nil
        } catch is CancellationError {
        } catch {
            failedOffline = app.settings.isOffline || UserFacingError.isOffline(error)
            self.error = UserFacingError.message(for: error, context: .catalog)
        }
    }

    // MARK: Header

    private func header(inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .bottom, spacing: Spacing.m) {
                ArtworkView(url: app.imageURL(collection?.poster ?? ref.poster, width: 96), fallbackTitle: name, kind: .poster,
                            pixelWidth: 192, showsFallbackTitle: false)
                    .frame(width: 96, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(name).font(Typography.pageTitle).foregroundStyle(Palette.textPrimary).lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    if let collection {
                        Text(CollectionPlan.summary(count: collection.parts.count, minutes: totalMinutes))
                            .font(Typography.meta).foregroundStyle(Palette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let overview = collection?.overview, !overview.isEmpty {
                Text(overview)
                    .font(Typography.body).foregroundStyle(Palette.textPrimary.opacity(0.88))
                    .lineLimit(overviewExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640, alignment: .leading)
                    .onTapGesture { withAnimation(Motion.standard(reduceMotion)) { overviewExpanded.toggle() } }
                    .accessibilityAddTraits(.isStaticText)
            }
            HeroButtonRow(spacing: Spacing.s) {
                Button { Task { if let collection { await app.playCollection(collection) } } } label: {
                    Label("Play All", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PlayButtonStyle(fullWidth: true))
                .disabled(released.isEmpty)
                .accessibilityIdentifier("collection.playAll")
                Button { confirmDownload = true } label: {
                    Label("Download All", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                .disabled(released.isEmpty)
                .accessibilityIdentifier("collection.downloadAll")
                Button { Task { if let collection { await app.addCollectionToMyList(collection) } } } label: {
                    Label("Add All to My List", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                .disabled(collection?.parts.isEmpty ?? true)
                .accessibilityIdentifier("collection.addAll")
            }
            .frame(maxWidth: 640)
        }
        .padding(.horizontal, inset)
    }

    // MARK: Films

    @ViewBuilder private func films(width: CGFloat, inset: CGFloat) -> some View {
        let metrics = CardMetrics(containerWidth: width)
        let grid = FittedGrid(width: width - inset * 2, minimum: metrics.posterWidth, gap: Spacing.cardGap)
        if let collection {
            LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Spacing.l) {
                ForEach(collection.parts) { t in
                    TitleCardLink(t) {
                        VStack(alignment: .leading, spacing: 4) {
                            PosterCard(title: t.name, url: app.imageURL(t.poster, width: grid.itemWidth), width: grid.itemWidth,
                                       isDownloaded: app.isDownloaded(t.key))
                            Group {
                                if let year = t.year, released.contains(t) {
                                    Text(verbatim: String(year))
                                } else {
                                    Text("Coming Soon")
                                }
                            }
                            .font(Typography.caption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
            .padding(.horizontal, inset)
        } else if error == nil {
            LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Spacing.cardGap) {
                ForEach(0..<grid.count, id: \.self) { _ in
                    SkeletonBlock(width: grid.itemWidth, height: grid.itemWidth * 1.5)
                }
            }
            .shimmering()
            .padding(.horizontal, inset)
        }
    }
}

/// "Part of the Alien Collection" on a film's page: opens the collection.
struct CollectionRow: View {
    @Environment(AppModel.self) private var app
    let ref: CollectionRef
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: Route.collection(ref)) {
            HStack(spacing: Spacing.m) {
                ArtworkView(url: app.imageURL(ref.backdrop ?? ref.poster, width: 96), fallbackTitle: ref.name, kind: .backdrop,
                            pixelWidth: 192, showsFallbackTitle: false)
                    .frame(width: 80, height: 45)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Part of").font(Typography.caption).foregroundStyle(Palette.textTertiary)
                    Text(ref.name).font(Typography.cardTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.textTertiary)
            }
            .padding(Spacing.s)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(hovering ? Palette.surface : Palette.surface.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.edge))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("title.collection")
    }
}
