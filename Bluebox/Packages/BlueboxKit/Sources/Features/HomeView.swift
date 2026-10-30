import DesignSystem
import Domain
import Observation
import Playback
import SwiftUI

/// A Continue Watching entry: something in progress, or (with `next`) the
/// episode after a finished one.
struct WatchEntry: Identifiable, Hashable {
    let progress: WatchProgress
    let title: Title
    var next: ContinueWatchingRules.NextEpisode?
    var id: MediaKey { progress.key }

    var label: String {
        if let next {
            let code = next.season.flatMap { s in next.episode.map { "S\(s)·E\($0)" } }
            if next.isNew { return (code.map { $0 + " · " } ?? "") + "New Episode" }
            return code.map { $0 + " · Next" } ?? "Next Episode"
        }
        if let (s, e) = progress.key.episodeNumbers {
            return "S\(s)·E\(e)" + (progress.remaining.map { " · " + Formatters.remaining($0) } ?? "")
        }
        return progress.remaining.map(Formatters.remaining) ?? ""
    }

    /// What the card's menu acts on: the next episode (not yet started) for a
    /// next-episode card, or the show (which plays its next episode) when
    /// which one isn't known yet.
    var menuEntry: WatchEntry? {
        guard let next else { return self }
        guard let key = next.key else { return nil }
        return WatchEntry(progress: WatchProgress(key: key, position: 0, duration: nil, updatedAt: progress.updatedAt), title: title)
    }
}

/// What Home shows: everything, or only series or movies (the chips on
/// iPhone, the TV Shows / Movies tabs on iPad and Mac).
enum HomeCategory: String, Hashable, CaseIterable {
    case all, series, movies

    var title: String {
        switch self {
        case .all: "Home"
        case .series: "TV Shows"
        case .movies: "Movies"
        }
    }

    var kind: TitleKind? {
        switch self {
        case .all: nil
        case .series: .series
        case .movies: .movie
        }
    }

    func includes(_ t: Title) -> Bool { kind.map { t.kind == $0 } ?? true }
}

struct HomeRow: Identifiable {
    enum Style { case poster, landscape, topTen }
    let id: String
    let title: String
    var titles: [Title]
    var style: Style = .poster
    var genre: (Genre, TitleKind)?
    /// Top Picks: why each title is there, shown on its card.
    var reasons: [MediaKey: String] = [:]
}

@Observable
@MainActor
final class HomeModel {
    var hero: Title?
    /// Trending titles the hero can be, in order: Not Interested on the hero moves it on.
    private(set) var heroCandidates: [Title] = []
    var continueWatching: [WatchEntry] = []
    var myList: [Title] = []
    var availableNow: [Title] = []
    /// The editorial rows (TMDB's lists and genres), in today's order.
    var rows: [HomeRow] = []
    /// Personal rows, from the profile's file at once, then rebuilt when stale.
    var topPicks: [ScoredPick] = []
    var because: [BecauseRow] = []
    /// The profile's Not Interested titles, left out of every row.
    var hidden: Set<MediaKey> = []
    var catalogError: Error?
    var isLoading = true
    private(set) var category: HomeCategory = .all
    @ObservationIgnored private var snapshot = PersonalHomeSnapshot()
    /// The library revision the library rows were last read at, so a full
    /// load doesn't also run the library-only reload after it.
    @ObservationIgnored private var libraryRevision: Int?

    /// What the personal rows are built from, read once per load (all local).
    struct Plan: Sendable {
        let history: HomeHistory
        let fingerprint: String
        /// Rows from the file that are still good (same history, under 6 hours old).
        let fresh: PersonalHomeSnapshot.Rows?
        /// Older rows to show while new ones are built.
        let stale: PersonalHomeSnapshot.Rows?
        let affinity: [Int: Double]
        let enoughHistory: Bool
        var needsRebuild: Bool { fresh == nil && enoughHistory }
    }

    func load(_ app: AppModel, category: HomeCategory) async {
        if category != self.category { rows = []; hero = nil; topPicks = []; because = []; isLoading = true }
        self.category = category
        catalogError = nil
        hidden = app.hiddenKeys()
        let started = ContinuousClock.now
        let profileID = app.currentProfileID
        libraryRevision = app.libraryRevision
        snapshot = await app.personalHome.load(profileID: profileID) ?? PersonalHomeSnapshot()
        let plan = Task { await self.makePlan(app, category: category) }
        async let library: Void = loadLibrary(app, plan: plan)
        async let available: Void = loadAvailable(app)
        async let catalog: Void = loadCatalog(app, plan: plan)
        async let personal: Void = loadBecauseYouWatched(app, plan: plan)
        _ = await (library, available, catalog, personal)
        await savePersonalRows(app, plan: await plan.value, profileID: profileID)
        isLoading = false
        Log.metadata.info("Home loaded (\(String(describing: category), privacy: .public)) in \(String(describing: ContinuousClock.now - started), privacy: .public)")
    }

    /// After a library change (watching, My List, a download): only the rows
    /// read from the library. The catalogue and the personal rows stay as
    /// they are until the next full load (sources, catalogue, category or
    /// profile change, or pull to refresh).
    func reloadLibraryRows(_ app: AppModel) async {
        // nil: the first full load hasn't started, and it reads these rows itself.
        guard let loaded = libraryRevision, loaded != app.libraryRevision else { return }
        libraryRevision = app.libraryRevision
        let store = app.store
        let ratings = app.ratingEntries()
        let history = Task { HomeHistory(records: (try? await store.recent(limit: 400)) ?? [], ratings: ratings) }
        async let library: Void = loadLibrary(app, history: history)
        async let available: Void = loadAvailable(app)
        _ = await (library, available)
    }

    /// Reads history and ratings, and the profile's file; works out taste only
    /// when the rows need building again.
    private func makePlan(_ app: AppModel, category: HomeCategory) async -> Plan {
        let store = app.store
        let history = HomeHistory(records: (try? await store.recent(limit: 400)) ?? [], ratings: app.ratingEntries(),
                                  tasteRows: app.featureSwitches.tasteRows)
        let fingerprint = history.fingerprint(category)
        let now = Date()
        let fresh = snapshot.freshRows(category.rawValue, fingerprint: fingerprint, now: now)
        let enough = history.allowsPersonalRows
        var affinity: [Int: Double] = [:]
        if let fresh {
            // The file's genre order stands in for the taste it came from.
            for (i, g) in fresh.genreOrder.enumerated() { affinity[g] = Double(fresh.genreOrder.count - i) }
        } else if enough {
            var keys = history.watched.prefix(60).map(\.key)
            let watchedKeys = Set(keys)
            keys += history.ratings.keys.filter { !watchedKeys.contains($0) && ($0.isMovie || $0.isSeries) }.prefix(40)
            var genres: [MediaKey: [Int]] = [:]
            for k in keys { if let t = try? await store.title(for: k) { genres[k] = t.genreIDs } }
            affinity = TasteRules.affinity(watched: history.watched, ratings: history.ratings, genres: genres, now: now)
        }
        return Plan(history: history, fingerprint: fingerprint, fresh: fresh,
                    stale: fresh == nil ? snapshot.rows[category.rawValue] : nil, affinity: affinity, enoughHistory: enough)
    }

    /// Continue Watching (one row that moves on to the next episode) and My
    /// List. Each entry's title is looked up side by side (a cache miss is a
    /// catalogue request each). A row whose read fails keeps what it showed
    /// rather than vanishing (it's the local library, so that's rare).
    func loadLibrary(_ app: AppModel, plan: Task<Plan, Never>) async {
        await loadLibrary(app, history: Task { await plan.value.history })
    }

    private func loadLibrary(_ app: AppModel, history: Task<HomeHistory, Never>) async {
        let progressRead = try? await app.store.continueWatching(limit: 20)
        if let progress = progressRead {
            let records = await history.value.records
            let now = Date()
            var shows: [MediaKey] = []
            for p in records where now.timeIntervalSince(p.updatedAt) <= ContinueWatchingRules.nextUpWindow {
                if let s = p.key.seriesKey, !shows.contains(s) { shows.append(s) }
                if shows.count >= 30 { break }
            }
            let info = await app.showInfo(for: shows)
            let entries = ContinueWatchingRules.build(inProgress: progress, recent: records, shows: info,
                                                      announced: app.features.tracker.notified, now: now)
            let titles = await app.titles(for: entries.map { $0.progress.key.seriesKey ?? $0.progress.key })
            continueWatching = zip(entries, titles).compactMap { e, t in
                t.flatMap { category.includes($0) ? WatchEntry(progress: e.progress, title: $0, next: e.next) : nil }
            }
        }
        if let list = try? await app.store.watchlist() { myList = list.filter(category.includes) }
    }

    /// Ready to Play, from your sources. A source that can't be reached
    /// (a media server while offline) keeps its titles from the last load.
    func loadAvailable(_ app: AppModel) async {
        var keys: [MediaKey] = []
        var seen = Set<MediaKey>()
        var anyFailed = false
        for source in await app.registry.enabled(with: .play) {
            do {
                for v in try await source.catalog() {
                    if let k = v.mediaKey?.seriesKey ?? v.mediaKey, seen.insert(k).inserted { keys.append(k) }
                }
            } catch {
                anyFailed = true
            }
        }
        let titles = await app.titles(for: keys).compactMap { $0 }.filter(category.includes)
        if anyFailed {
            // Keep what was there and add anything new.
            let kept = availableNow.filter(category.includes)
            availableNow = kept + titles.filter { t in !kept.contains { $0.key == t.key } }
        } else {
            availableNow = titles
        }
    }

    func loadCatalog(_ app: AppModel, plan planTask: Task<Plan, Never>) async {
        let m = app.metadata
        let category = category
        do {
            // Each list on its own: one failed request costs a row, not the whole page.
            async let trending = Self.attempt { try await m.list(.trending, page: 1) }
            async let movies = Self.attempt { try await m.list(.popularMovies, page: 1) }
            async let series = Self.attempt { try await m.list(.popularSeries, page: 1) }
            async let topRated = Self.attempt { try await m.list(.topRated, page: 1) }
            async let genres = Self.attempt { try await m.genres() }
            let (rt, rmv, rsr, rtr, rg) = await (trending, movies, series, topRated, genres)
            let lists = [rt, rmv, rsr, rtr]
            if let firstError = lists.compactMap(\.failure).first, lists.allSatisfy({ $0.failure != nil }) {
                throw firstError
            }
            let plan = await planTask.value
            // Discovery rows leave out what you've watched or rated Not for Me (Top 10s keep their ranks).
            let seen = plan.history.discoveryExcluded
            let fresh = { (items: [Title]) in items.filter { !seen.contains($0.key) } }
            let empty = Page<Title>(items: [], page: 1, totalPages: 1)
            let t = (try? rt.get()) ?? empty, mv = (try? rmv.get()) ?? empty
            let sr = (try? rsr.get()) ?? empty, tr = (try? rtr.get()) ?? empty
            let g = (try? rg.get()) ?? []
            let trendingHere = t.items.filter(category.includes)
            // The hero stays editorial: trending, skipping what you've watched.
            let heroPool = fresh(trendingHere).isEmpty ? trendingHere : fresh(trendingHere)
            heroCandidates = heroPool.filter { $0.backdrop != nil } + heroPool.filter { $0.backdrop == nil }
            if heroCandidates.isEmpty { heroCandidates = Array((category == .movies ? mv.items : sr.items).prefix(1)) }
            hero = heroCandidates.first { !hidden.contains($0.key) } ?? heroCandidates.first

            let topShows = HomeRow(id: "top-series", title: "Top 10 TV Shows Today", titles: Array(sr.items.prefix(10)), style: .topTen)
            let topMovies = HomeRow(id: "top-movies", title: "Top 10 Movies Today", titles: Array(mv.items.prefix(10)), style: .topTen)
            var built: [HomeRow]
            switch category {
            case .all:
                built = [
                    HomeRow(id: "trending", title: "Trending Now", titles: fresh(t.items)),
                    topShows,
                    HomeRow(id: "movies", title: "Popular Movies", titles: fresh(mv.items)),
                    HomeRow(id: "series", title: "Bingeworthy Series", titles: fresh(sr.items), style: .landscape),
                    topMovies,
                    HomeRow(id: "acclaimed", title: "Critically Acclaimed", titles: fresh(tr.items)),
                ]
            case .movies:
                built = [
                    topMovies,
                    HomeRow(id: "movies", title: "Popular Movies", titles: fresh(mv.items)),
                    HomeRow(id: "trending", title: "Trending Movies", titles: fresh(trendingHere), style: .landscape),
                    HomeRow(id: "acclaimed", title: "Critically Acclaimed Movies", titles: fresh(tr.items.filter(category.includes))),
                ]
            case .series:
                built = [
                    topShows,
                    HomeRow(id: "series", title: "Popular TV Shows", titles: fresh(sr.items)),
                    HomeRow(id: "trending", title: "Trending Shows", titles: fresh(trendingHere), style: .landscape),
                    HomeRow(id: "acclaimed", title: "Critically Acclaimed Shows", titles: fresh(tr.items.filter(category.includes))),
                ]
            }
            built.removeAll { $0.titles.isEmpty }
            rows = Self.withoutRepeats(built)

            // A few genre rows, fetched concurrently and dropped if empty: your
            // strongest genres first, then the usual ones (as many as before).
            let kind = category.kind ?? .movie
            let picks = GenreRowOrder.pick(available: g, affinity: plan.affinity, kind: kind, count: category == .all ? 3 : 4)
            let genreRows = await withTaskGroup(of: (Int, HomeRow?).self) { group in
                for (i, genre) in picks.enumerated() {
                    group.addTask {
                        let page = try? await m.discover(genre: genre, kind: kind, page: 1)
                        guard let items = page?.items, !items.isEmpty else { return (i, nil) }
                        let name = kind == .series ? "\(genre.name) Shows" : "\(genre.name) Movies"
                        return (i, HomeRow(id: "genre-\(genre.id)", title: name, titles: items, genre: (genre, kind)))
                    }
                }
                var out: [(Int, HomeRow?)] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
            let unseenGenreRows = genreRows.compactMap { row -> HomeRow? in
                var r = row
                r.titles = fresh(row.titles)
                return r.titles.isEmpty ? nil : r
            }
            rows = Self.withoutRepeats(built + unseenGenreRows)

            // Top Picks: the ~140 titles just loaded, scored by your taste (well under a millisecond).
            if plan.needsRebuild {
                let candidates = t.items + mv.items + sr.items + tr.items + genreRows.flatMap(\.titles)
                let started = plan.history.records.filter { $0.position > 0 || $0.isCompleted }.map { $0.key.seriesKey ?? $0.key }
                let names = Dictionary(g.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                let scored = TopPicks.picks(candidates: candidates.filter(category.includes), affinity: plan.affinity,
                                            excluded: seen.union(started).union(hidden), genreNames: names, now: .now)
                topPicks = scored.count >= TopPicks.minimumPicks ? scored : []
            } else if !plan.enoughHistory {
                topPicks = []
            }
            try? await app.store.store(t.items + mv.items + sr.items)
        } catch {
            catalogError = error
            if hero == nil { hero = availableNow.first }
        }
    }

    /// "Because You Watched" your two most recent titles: TMDB's
    /// recommendations, which come with a title's detail (so usually from
    /// memory or the profile's file), minus what you've watched or hidden.
    func loadBecauseYouWatched(_ app: AppModel, plan planTask: Task<Plan, Never>) async {
        let plan = await planTask.value
        guard plan.enoughHistory else { topPicks = []; because = []; return }
        // The file's rows at once; new ones replace them below if they're stale.
        if let rows = plan.fresh ?? plan.stale {
            if topPicks.isEmpty || plan.fresh != nil { topPicks = rows.topPicks }
            because = rows.because
        }
        guard plan.needsRebuild else { return }
        let now = Date()
        let seeds = plan.history.seeds
        let seedTitles = await app.titles(for: seeds)
        let cached = seeds.map { snapshot.freshRecommendations(for: $0, now: now) }
        let m = app.metadata
        let fetched: [[Title]?] = await concurrentMap(Array(zip(seeds, cached))) { pair in
            if let cached = pair.1 { return cached }
            return try? await m.detail(for: pair.0).related
        }
        let excluded = plan.history.discoveryExcluded.union(hidden)
        var shown = Set<MediaKey>()
        var built: [BecauseRow] = []
        for (i, seed) in seeds.enumerated() {
            guard let recs = fetched[i], let seedTitle = seedTitles[i] else { continue }
            if cached[i] == nil { snapshot.recommendations[seed.rawValue] = .init(fetchedAt: now, titles: recs) }
            let titles = recs.filter { $0.key != seed && !excluded.contains($0.key) && !shown.contains($0.key) && !seeds.contains($0.key) }
            guard titles.count >= 3 else { continue }
            shown.formUnion(titles.map(\.key))
            built.append(BecauseRow(seed: seedTitle, titles: titles))
        }
        because = built
    }

    /// Keeps freshly built rows in the profile's file. Not after a failed
    /// catalogue (Top Picks would be empty for the wrong reason).
    private func savePersonalRows(_ app: AppModel, plan: Plan, profileID: String) async {
        guard plan.needsRebuild, catalogError == nil, !rows.isEmpty else { return }
        let order = plan.affinity.filter { $0.value > 0 }.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }.map(\.key)
        snapshot.rows[category.rawValue] = .init(fingerprint: plan.fingerprint, builtAt: .now, topPicks: topPicks,
                                                 because: because, genreOrder: order)
        snapshot.prune(now: .now)
        await app.personalHome.save(snapshot, profileID: profileID)
    }

    /// The personal rows as they're shown, for this category.
    func personalRows(_ profile: Profile) -> [HomeRow] {
        var out: [HomeRow] = []
        let picks = topPicks.filter { category.includes($0.title) }
        if picks.count >= TopPicks.minimumPicks {
            out.append(HomeRow(id: "top-picks", title: HomeRowTitles.topPicks(profile), titles: picks.map(\.title), style: .landscape,
                               reasons: Dictionary(picks.map { ($0.title.key, $0.reason) }, uniquingKeysWith: { a, _ in a })))
        }
        for b in because {
            let titles = b.titles.filter(category.includes)
            if titles.count >= 3 {
                out.append(HomeRow(id: "because-\(b.seed.key.rawValue)", title: HomeRowTitles.becauseYouWatched(b.seed.name), titles: titles))
            }
        }
        return out
    }

    /// Editorial and personal rows taking turns, minus hidden titles.
    func visibleRows(_ profile: Profile) -> [HomeRow] {
        HomeLayout.hiding(hidden, from: HomeLayout.interleave(editorial: rows, personal: personalRows(profile)))
    }

    /// The hero, moved on to the next trending title if it was hidden.
    var visibleHero: Title? {
        guard let hero, hidden.contains(hero.key) else { return hero }
        return heroCandidates.first { !hidden.contains($0.key) } ?? hero
    }

    /// The lists overlap (Popular Movies starts with Top 10 Movies; with
    /// Cinemeta the same few titles fill most rows), so each title appears
    /// once: the first row and the Top 10 rows stay as they are, later rows
    /// drop titles already shown in those or above them, and a row left with
    /// fewer than `minimum` goes.
    static func withoutRepeats(_ rows: [HomeRow], minimum: Int = 5) -> [HomeRow] {
        let kept = rows.prefix(1) + rows.dropFirst().filter { $0.style == .topTen }
        var seen = Set(kept.flatMap { $0.titles.map(\.key) })
        var out: [HomeRow] = []
        for (i, row) in rows.enumerated() {
            guard i > 0, row.style != .topTen else { out.append(row); continue }
            let fresh = row.titles.filter { !seen.contains($0.key) }
            guard fresh.count == row.titles.count || fresh.count >= minimum else { continue }
            seen.formUnion(fresh.map(\.key))
            out.append(HomeRow(id: row.id, title: row.title, titles: fresh, style: row.style, genre: row.genre))
        }
        return out
    }

    private static func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let e) = self { e } else { nil } }
}

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isDownloaded) private var isDownloaded
    var category: HomeCategory = .all
    @State private var model = HomeModel()
    @Environment(\.pushRoute) private var pushRoute
    @Environment(\.openSettingsPage) private var openSettingsPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("bluebox.firstRunCardDismissed") private var firstRunDismissed = false

    /// The welcome card: until it's closed, on Home's everything view.
    /// Hidden in UI tests unless `-first-run-card` asks for it.
    private var showsFirstRunCard: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard !firstRunDismissed, category == .all else { return false }
        return !args.contains("-ui-testing") || args.contains("-first-run-card")
    }

    var body: some View {
        GeometryReader { geo in
            let inset = Spacing.pageInset(for: geo.size.width)
            let metrics = CardMetrics(containerWidth: geo.size.width)
            let compact = geo.size.width < 600
            let heroTop = compact ? geo.safeAreaInsets.top : 0
            // Built once per body pass: interleaving and hiding isn't free,
            // and it used to run three times (here, the ForEach, the animation).
            let visibleRows = model.visibleRows(app.currentProfile)
            let rowIDs = visibleRows.map(\.id)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.rowGap) {
                    Group {
                        if let hero = model.visibleHero {
                            HeroView(title: hero, width: geo.size.width, inset: inset, topInset: heroTop)
                                .id(hero.key)
                        } else if model.isLoading {
                            HeroSkeleton(width: geo.size.width, inset: inset, topInset: heroTop)
                        }
                    }
                    .padding(.bottom, compact ? 0 : -Spacing.xl)

                    // First thing under the hero, so the hero still leads the page.
                    if showsFirstRunCard {
                        firstRunCard
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(.horizontal, inset)
                    }

                    // Offline: a slim card pointing to Downloads; everything saved stays under it.
                    if app.settings.isOffline {
                        OfflineBanner()
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(.horizontal, inset)
                            .padding(.top, model.hero == nil && compact ? geo.safeAreaInsets.top : 0)
                            .transition(.opacity)
                    } else if let error = model.catalogError {
                        if model.rows.isEmpty {
                            StateMessage(.failed, systemImage: "wifi.exclamationmark", title: "Couldn't load the catalog",
                                         message: catalogErrorMessage(error), actionTitle: "Try Again") {
                                Task { await model.load(app, category: category) }
                            }
                            // With no hero above it, keep clear of the logo and category chips.
                            .padding(.top, model.hero == nil && compact ? geo.safeAreaInsets.top : 0)
                        } else {
                            // The rows from before stay; say they're not fresh.
                            StaleNotice(offline: false) { Task { await model.load(app, category: category) } }
                                .padding(.horizontal, inset)
                        }
                    }

                    if !model.continueWatching.isEmpty {
                        ShelfRow(HomeRowTitles.continueWatching(app.currentProfile, profiles: app.profiles.count), items: model.continueWatching, inset: inset,
                                 itemWidth: metrics.landscapeWidth,
                                 seeAll: { pushRoute(.continueWatching) }) { entry in
                            ResumeCardButton(entry, play: { Task { await resume(entry) } },
                                             details: { pushRoute(.title(entry.title)) },
                                             remove: removeAction(entry)) {
                                LandscapeCard(title: entry.title.name, subtitle: entry.label,
                                              url: app.imageURL(entry.title.backdrop, width: metrics.landscapeWidth),
                                              width: metrics.landscapeWidth, progress: entry.next == nil ? entry.progress.fraction : nil,
                                              showsPlayGlyph: true)
                                    .overlay(alignment: .topLeading) {
                                        if entry.next?.isNew == true { NewEpisodeTag().padding(Spacing.s) }
                                    }
                            }
                            .accessibilityHint(entry.next == nil ? "Resumes playback" : "Plays the next episode")
                        }
                        .modifier(ChromeTextCap())
                    }

                    if !model.availableNow.isEmpty {
                        posterRow("Ready to Play", titles: model.availableNow, metrics: metrics, inset: inset)
                    }

                    if !model.myList.isEmpty {
                        posterRow(HomeRowTitles.myList(app.currentProfile, profiles: app.profiles.count), titles: model.myList, metrics: metrics, inset: inset,
                                  seeAll: { pushRoute(.myList) })
                    }

                    // Editorial and personal rows take turns (Top Picks, Because You Watched).
                    ForEach(visibleRows) { row in
                        switch row.style {
                        case .poster:
                            posterRow(row.title, titles: row.titles, metrics: metrics, inset: inset,
                                      seeAll: row.genre.map { g in { pushRoute(.genre(g.0, g.1)) } })
                        case .topTen:
                            ShelfRow(row.title, items: Array(row.titles.enumerated().map { RankedTitle(rank: $0.offset + 1, title: $0.element) }),
                                     inset: inset, itemWidth: metrics.topTenWidth) { r in
                                TitleCardLink(r.title) {
                                    TopTenCard(rank: r.rank, title: r.title.name, url: app.imageURL(r.title.poster, width: metrics.posterWidth),
                                               posterWidth: metrics.posterWidth)
                                }
                            }
                        case .landscape:
                            ShelfRow(row.title, items: row.titles, inset: inset, itemWidth: metrics.landscapeWidth) { t in
                                TitleCardLink(t) {
                                    LandscapeCard(title: t.name, subtitle: row.reasons[t.key] ?? subtitle(for: t),
                                                  url: app.imageURL(t.backdrop, width: metrics.landscapeWidth), width: metrics.landscapeWidth)
                                }
                            }
                        }
                    }
                    .modifier(ChromeTextCap())

                    if model.isLoading && model.rows.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in
                            ShelfPlaceholder(inset: inset, width: metrics.posterWidth, height: metrics.posterHeight)
                        }
                    }

                    CatalogFooter(mode: app.catalogMode).padding(.horizontal, inset)
                }
                .padding(.bottom, Spacing.xxxl)
                .background(alignment: .top) {
                    // Navy wash behind the inset hero on iPhone (Netflix tints this from the art).
                    // It scrolls away with the hero.
                    if compact { NavyGlow(height: geo.safeAreaInsets.top + geo.size.width * 1.55) }
                }
            }
            .scrollIndicators(.hidden)
            #if DEBUG
            .modifier(DebugHomeScroll())
            #endif
            .reportsHeaderScroll()
            .ignoresSafeArea(edges: .top)
            // Rows, the hero and the skeletons crossfade as loads land, instead of popping in
            // (personal rows too, and a title folding out after Not Interested).
            .animation(Motion.standard(reduceMotion), value: rowIDs)
            .animation(Motion.standard(reduceMotion), value: model.visibleHero?.key)
            .animation(Motion.standard(reduceMotion), value: model.continueWatching.map(\.id))
            .animation(Motion.standard(reduceMotion), value: model.myList.map(\.key))
            .animation(Motion.standard(reduceMotion), value: model.hidden)
        }
        .blueboxScreen()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .navigationTitle(category.title)
        // The whole page: when what it's built from changes.
        .task(id: "\(app.sourcesRevision)-\(app.catalogMode == .live)-\(category)-\(app.currentProfileID)-\(app.featureSwitches.tasteRows)") {
            await model.load(app, category: category)
        }
        // Watching, My List or a download: only the rows read from the library.
        .task(id: app.libraryRevision) { await model.reloadLibraryRows(app) }
        .refreshable { await refresh() }
        .refreshShortcut { await refresh() }
        // A failed catalogue loads again by itself once the network or the app comes back.
        .onChange(of: app.settings.network.isOnline) { _, online in
            if online, model.catalogError != nil { Task { await model.load(app, category: category) } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.catalogError != nil { Task { await model.load(app, category: category) } }
        }
        // Not Interested (or Undo): the title folds out of its row at once, no reload.
        .onChange(of: app.hiddenRevision) { model.hidden = app.hiddenKeys() }
    }

    /// Says offline only when the device is; otherwise points at what usually blocks one app.
    private func catalogErrorMessage(_ error: Error) -> String {
        if app.settings.isOffline {
            return "You're offline. The catalog loads again by itself when you reconnect."
        }
        switch error as? MetadataError {
        case .offline?, .transport?:
            #if os(iOS)
            return "Bluebox couldn't reach the catalog, though this device is online. If it keeps happening, check that Bluebox is allowed to use Wi‑Fi and mobile data in the Settings app (Apps › Bluebox)."
            #else
            return "Bluebox couldn't reach the catalog, though this Mac is online. Check a VPN, firewall or content blocker, then try again."
            #endif
        default:
            return UserFacingError.message(for: error, context: .catalog)
        }
    }

    /// Pull to refresh (⌘R on Mac): skips the catalogue cache.
    private func refresh() async {
        await app.refreshCatalog()
        await model.load(app, category: category)
    }

    private func subtitle(for t: Title) -> String? {
        [t.year.map(String.init), t.kind == .series ? "Series" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func posterRow(_ title: String, titles: [Title], metrics: CardMetrics, inset: CGFloat,
                           seeAll: (() -> Void)? = nil) -> some View {
        ShelfRow(title, items: titles, inset: inset, itemWidth: metrics.posterWidth, seeAll: seeAll) { t in
            TitleCardLink(t) {
                PosterCard(title: t.name, url: app.imageURL(t.poster, width: metrics.posterWidth),
                           width: metrics.posterWidth, isDownloaded: isDownloaded(t.key))
            }
        }
        .modifier(ChromeTextCap())
    }

    /// Resumes, or plays the next episode from the start (asking which one
    /// it is when Home couldn't tell).
    private func resume(_ entry: WatchEntry) async {
        if let next = entry.next {
            guard let key = next.key, let (s, e) = key.episodeNumbers else {
                await app.playNextEpisode(after: entry.progress.key, seriesName: entry.title.name)
                return
            }
            await app.play(NowPlayingItem(key: key, title: entry.title.name, subtitle: "S\(s)·E\(e)",
                                          artworkURL: app.imageURL(entry.title.backdrop, width: 640)), resume: false)
            return
        }
        let p = entry.progress
        let subtitle = p.key.episodeNumbers.map { "S\($0.season)·E\($0.episode)" }
        await app.play(NowPlayingItem(key: p.key, title: entry.title.name, subtitle: subtitle,
                                      artworkURL: app.imageURL(entry.title.backdrop, width: 640)))
    }

    /// Remove from Row: resets an item in progress; a next-episode card is
    /// set aside until you watch the show again. Not offered when the next
    /// episode isn't known.
    private func removeAction(_ entry: WatchEntry) -> (@MainActor () -> Void)? {
        guard let next = entry.next else { return { Task { await app.removeFromContinueWatching(entry.progress) } } }
        guard next.key != nil else { return nil }
        return { Task { await app.dismissUpNext(entry) } }
    }

    private var firstRunCard: some View {
        FirstRunCard(mode: app.catalogMode, setUpCatalog: { openSettingsPage(.catalog) }) {
            withAnimation(Motion.standard(reduceMotion)) { firstRunDismissed = true }
        }
        .transition(.opacity)
    }
}

/// Shelf headers, chips and hero buttons stop growing at the largest
/// non-accessibility text size: past it they truncate ("Continue W…") or
/// break words, and the cards they sit on are a fixed size anyway.
struct ChromeTextCap: ViewModifier {
    func body(content: Content) -> some View {
        content.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// First launch: where Play finds video, and, without a TMDB token, how to
/// get the full catalog. Closed once, it stays closed.
struct FirstRunCard: View {
    let mode: AppModel.CatalogMode
    let setUpCatalog: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .center, spacing: Spacing.s) {
                Text("Welcome to Bluebox")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .padding(.trailing, -Spacing.m)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("firstRunClose")
            }
            .frame(minHeight: 32)
            Text("Play streams torrents your add-ons find, peer to peer. Debrid, your own files and media servers are in Settings › Sources.")
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if mode != .live {
                HStack(spacing: Spacing.m) {
                    tmdbLine
                    Spacer(minLength: 0)
                    setUpButton
                }
                .padding(.top, Spacing.xs)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.l)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous).strokeBorder(Palette.edge))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRunCard")
    }

    private var tmdbLine: some View {
        Text("Add a free TMDB token for the full catalog.")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var setUpButton: some View {
        Button("Set Up", action: setUpCatalog)
            .buttonStyle(SecondaryButtonStyle())
            .fixedSize()
            .accessibilityIdentifier("firstRunSetUp")
    }
}

/// Continue Watching's actions: the same Bluebox quick-action menu as every
/// poster (Resume, Play Next Episode once an episode is done or nearly so,
/// My List, Mark as Watched, Download, Go to Show, Share, Remove from Row),
/// on touch and hold or right-click, and on hover from a ⋯ on the card.
/// One menu, where there used to be a system context menu and a different ⋯ menu.
struct ContinueWatchingActions: ViewModifier {
    @Environment(AppModel.self) private var app
    let entry: WatchEntry
    let details: @MainActor () -> Void
    let remove: @MainActor () -> Void
    var gate: QuickActionGate?
    @State private var hovering = false
    /// The ⋯'s menu is open. The ⋯ stays while it is: the menu's backdrop
    /// ends the card's hover, and taking the ⋯ away closed its menu at once.
    @State private var menuOpen = false

    private var offersNext: Bool { entry.next == nil && entry.progress.key.episodeNumbers != nil && entry.progress.isNearlyFinished }
    private var subject: QuickActionSubject { QuickActionSubject(title: entry.title, entry: entry.menuEntry, remove: remove) }

    func body(content: Content) -> some View {
        content
            .quickActions(subject, opened: gate)
            .overlay(alignment: .topTrailing) {
                QuickActionsMoreButton(subject: subject, size: 28) { menuOpen = $0 }
                    .padding(Spacing.s)
                    .opacity(hovering || menuOpen ? 1 : 0)
                    .allowsHitTesting(hovering || menuOpen)
                    .accessibilityHidden(true)  // the same actions are in the rotor
            }
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .accessibilityAction(named: "Details", details)
            .accessibilityAction(named: "Remove from Row", remove)
            .modifier(OptionalAction(name: offersNext ? "Play Next Episode" : nil, action: playNext))
    }

    private func playNext() {
        Task { await app.playNextEpisode(after: entry.progress.key, seriesName: entry.title.name) }
    }
}

/// A round ⋯ that opens a card's quick-action menu.
struct QuickActionsMoreButton: View {
    let subject: QuickActionSubject
    var size: CGFloat = 28
    var filled = true
    var onOpenChange: (@MainActor (Bool) -> Void)?

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: filled ? size * 0.48 : 15, weight: .bold))
            .foregroundStyle(filled ? Palette.textPrimary : Palette.textSecondary)
            .frame(width: size, height: size)
            .background { if filled { Circle().fill(Palette.elevated) } }
            .overlay { if filled { Circle().strokeBorder(Palette.edge) } }
            .frame(width: filled ? size : 44, height: filled ? size : 44)
            .contentShape(Rectangle())
            .quickActions(subject, tapToOpen: true, onOpenChange: onOpenChange)
            .accessibilityLabel("More for \(subject.title.name)")
            .accessibilityAddTraits(.isButton)
    }
}

/// A Continue Watching or episode card: a tap resumes, a hold or right-click
/// opens the quick-action menu (and the tap that ends the hold doesn't resume).
struct ResumeCardButton<Label: View>: View {
    let entry: WatchEntry
    let play: () -> Void
    let details: @MainActor () -> Void
    var remove: (@MainActor () -> Void)?
    var style: Style = .pressable
    let label: Label
    @State private var gate = QuickActionGate()

    enum Style { case pressable, plain }

    init(_ entry: WatchEntry, style: Style = .pressable, play: @escaping () -> Void, details: @escaping @MainActor () -> Void,
         remove: (@MainActor () -> Void)? = nil, @ViewBuilder label: () -> Label) {
        self.entry = entry; self.style = style; self.play = play; self.details = details; self.remove = remove
        self.label = label()
    }

    var body: some View {
        let button = Button {
            guard !gate.consumeHold() else { return }
            play()
        } label: { label }
        Group {
            switch style {
            case .pressable: button.buttonStyle(PressableStyle())
            case .plain: button.buttonStyle(PressableStyle(scale: 1))
            }
        }
        .modifier(OptionalRemoveActions(entry: entry, details: details, remove: remove, gate: gate))
    }
}

/// Continue Watching gets Remove from Row and the hover ⋯; other episode cards just the menu.
private struct OptionalRemoveActions: ViewModifier {
    let entry: WatchEntry
    let details: @MainActor () -> Void
    let remove: (@MainActor () -> Void)?
    let gate: QuickActionGate

    func body(content: Content) -> some View {
        if let remove {
            content.modifier(ContinueWatchingActions(entry: entry, details: details, remove: remove, gate: gate))
        } else {
            content.quickActions(QuickActionSubject(title: entry.title, entry: entry.menuEntry), opened: gate)
        }
    }
}

private struct OptionalAction: ViewModifier {
    let name: String?
    let action: () -> Void
    func body(content: Content) -> some View {
        if let name { content.accessibilityAction(named: name, action) } else { content }
    }
}

extension View {

    /// ⌘R runs `action` on Mac, where there's no pull to refresh.
    func refreshShortcut(_ action: @escaping @MainActor () async -> Void) -> some View {
        #if os(macOS)
        background {
            Button("Refresh") { Task { await action() } }
                .keyboardShortcut("r", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        #else
        self
        #endif
    }
}

struct RankedTitle: Identifiable {
    let rank: Int
    let title: Title
    var id: MediaKey { title.key }
}

/// The featured title. On iPhone it's an inset poster card over a navy glow,
/// as in Netflix's app; on wider screens, full-bleed backdrop art.
struct HeroView: View {
    @Environment(AppModel.self) private var app
    let title: Title
    let width: CGFloat
    let inset: CGFloat
    /// Status bar plus the header, which the iPhone card sits below.
    var topInset: CGFloat = 0
    @Environment(\.pushRoute) private var pushRoute
    @State private var onList = false
    @State private var playable = false
    /// A series you've started: the episode Resume (or Play) would start.
    @State private var seriesTarget: SeriesCursor.Target?
    @State private var genres: [String] = []
    /// Drives the entrance and the slow drift of the artwork.
    @State private var appeared = false
    /// After a few seconds the overview fades and the title settles smaller.
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The muted preview (iPad and Mac): loaded a second after the hero shows,
    /// visible once it plays, gone again when it ends.
    @State private var trailer: TitleVideo?
    @State private var trailerPlaying = false
    @State private var trailerMuted = true
    /// iPad and Mac: Home kept alive behind another tab stops its preview.
    @Environment(\.isTabVisible) private var isTabVisible
    /// Set once the slow push-in has been skipped to its end (the tab was hidden).
    @State private var kenBurnsDone = false
    @Environment(\.zoomNamespace) private var zoomNamespace
    @State private var zoomID = UUID()

    var isCompact: Bool { width < 600 }
    static func wideHeight(_ width: CGFloat) -> CGFloat { min(max(width * 0.52, 440), 700) }
    var cardWidth: CGFloat { width - inset * 2 }
    var cardHeight: CGFloat { cardWidth * 1.3 }

    var body: some View {
        Group {
            if isCompact { compact } else { wide }
        }
        .onAppear { appeared = true }
        .task(id: title.key) {
            settled = false
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.9)) { settled = true }
        }
        .task(id: title.key) {
            onList = (try? await app.store.isOnWatchlist(title.key)) ?? false
            let all = (try? await app.metadata.genres()) ?? []
            genres = title.genreIDs.compactMap { id in all.first { $0.id == id }?.name }.prefix(3).map { $0 }
        }
        // Again after watching (progress moves on) or a source change.
        .task(id: "\(title.key.rawValue)|\(app.libraryRevision)|\(app.sourcesRevision)") { await loadPlayable() }
        .onChange(of: app.libraryRevision) {
            Task { onList = (try? await app.store.isOnWatchlist(title.key)) ?? false }
        }
        // Runs again whenever Home reappears; stops while the player is up
        // (on Mac the library stays alive under it) or previews are off.
        .task(id: previewID) { await loadTrailer() }
        .onDisappear { stopTrailer() }
        .onChange(of: isTabVisible) { _, visible in
            // Hidden mid push-in: jump to where it rests, rather than animate a full-window layer no one sees.
            if !visible, appeared, !kenBurnsDone {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { kenBurnsDone = true }
            }
        }
    }

    /// Movies play straight from the hero. A series does once you've started
    /// it: the next episode, worked out as the title page does
    /// (`SeriesCursor`); otherwise More Info, where the episode list is.
    private func loadPlayable() async {
        if title.kind == .movie {
            playable = await app.availability(for: title.key).isPlayable
            return
        }
        let target = await seriesResumeTarget()
        guard !Task.isCancelled else { return }
        seriesTarget = target
        playable = target != nil
    }

    private func seriesResumeTarget() async -> SeriesCursor.Target? {
        guard title.key.isSeries else { return nil }
        let progress = (try? await app.store.progress(forSeries: title.key)) ?? []
        guard progress.contains(where: { $0.isCompleted || $0.position > 0 }),
              let detail = try? await app.metadata.detail(for: title.key),
              let target = SeriesCursor.target(series: title.key, progress: progress, seasons: detail.seasons),
              await app.availability(for: target.key).isPlayable else { return nil }
        return target
    }

    // MARK: Preview

    private var previewID: String {
        "\(title.key.rawValue)|\(app.features.autoplayPreviews)|\(app.canAutoplayPreviews)|\(app.activePlayer == nil && app.preparingItem == nil)|\(isTabVisible)"
    }

    /// `heroTrailer` answers nil on mobile data, in Low Data Mode, offline, or
    /// with Settings › Playback › Autoplay Previews off.
    private func loadTrailer() async {
        stopTrailer()
        guard !isCompact, isTabVisible, app.activePlayer == nil, app.preparingItem == nil, let video = await app.heroTrailer(for: title) else { return }
        try? await Task.sleep(for: .seconds(1))  // the artwork first, then the preview fades in over it
        guard !Task.isCancelled else { return }
        trailerMuted = true
        trailer = video
    }

    private func stopTrailer() {
        trailer = nil
        trailerPlaying = false
    }

    /// The preview over the backdrop, filling it like the art does.
    @ViewBuilder private func trailerLayer(height: CGFloat) -> some View {
        if let trailer {
            let w = max(width, height * 16 / 9)
            TrailerPlayerView(youtubeKey: trailer.youtubeKey, muted: trailerMuted, showsControls: false,
                              onReady: { withAnimation(.easeInOut(duration: 0.8)) { trailerPlaying = true } },
                              onEnd: { withAnimation(.easeInOut(duration: 0.8)) { stopTrailer() } })
                .frame(width: w, height: w * 9 / 16)
                .frame(width: width, height: height)
                .clipped()
                .opacity(trailerPlaying ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    /// Netflix's round mute button at the hero's right edge, while a preview plays.
    @ViewBuilder private var muteButton: some View {
        if trailer != nil, trailerPlaying {
            Button { trailerMuted.toggle() } label: {
                Image(systemName: trailerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.black.opacity(0.35)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
                    .contentTransition(.symbolEffect(.replace))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help(trailerMuted ? "Unmute" : "Mute")
            .accessibilityLabel(trailerMuted ? "Unmute Preview" : "Mute Preview")
            .accessibilityIdentifier("heroMute")
            .transition(.opacity)
        }
    }

    // MARK: iPhone

    private var compact: some View {
        ZStack(alignment: .bottom) {
            ArtworkView(url: app.imageURL(title.poster ?? title.backdrop, width: cardWidth),
                        fallbackTitle: title.name, kind: .poster, pixelWidth: Int(cardWidth * 2), showsFallbackTitle: false)
                .frame(width: cardWidth, height: cardHeight)
            // The bottom 30% is solid black: posters print their own title
            // there, which showed through behind ours and the buttons.
            LinearGradient(stops: [.init(color: .clear, location: 0.38), .init(color: .black.opacity(0.82), location: 0.58),
                                   .init(color: .black, location: 0.7), .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: Spacing.m) {
                Text(title.name)
                    .font(Typography.display(compact: true))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 10)
                    .accessibilityAddTraits(.isHeader)
                    .rise(appeared, delay: 0.05, reduceMotion: reduceMotion)
                if !genres.isEmpty {
                    Text(genres.joined(separator: " • "))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .rise(appeared, delay: 0.12, reduceMotion: reduceMotion)
                }
                HeroButtonRow {
                    primaryButton(fullWidth: true)
                    myListButton(fullWidth: true)
                }
                .modifier(ChromeTextCap())
                .successHaptic(onList)
                .rise(appeared, delay: 0.2, reduceMotion: reduceMotion)
            }
            .padding(Spacing.l)
        }
        .frame(width: cardWidth, height: cardHeight)
        // Like Netflix: the card itself opens the title (its buttons still work).
        .contentShape(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .onTapGesture { pushRoute(.title(title), zoomFrom: zoomNamespace == nil ? nil : zoomID) }
        .accessibilityAction(named: "More Info") { pushRoute(.title(title)) }
        .clipShape(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .modifier(ZoomSource(id: zoomID, namespace: zoomNamespace))
        .overlay(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 24, y: 14)
        .padding(.horizontal, inset)
        .padding(.top, topInset + Spacing.s)
    }

    // MARK: iPad and Mac

    private var wide: some View {
        let height = Self.wideHeight(width)
        return ZStack(alignment: .bottomLeading) {
            ArtworkView(url: app.imageURL(title.backdrop ?? title.poster, width: width),
                        fallbackTitle: title.name, kind: .backdrop, pixelWidth: Int(width * 2), showsFallbackTitle: false)
                .frame(width: width, height: height)
                // Ken Burns: one 10 s push-in that then rests (24 s overlapped the
                // first scrolls of every visit). It used to repeat
                // forever, which kept a full-window layer animating at display
                // rate for as long as Home existed, even under the player on Mac.)
                .scaleEffect((appeared || kenBurnsDone) && !reduceMotion ? 1.06 : 1, anchor: UnitPoint(x: 0.6, y: 0.4))
                .animation(reduceMotion || kenBurnsDone ? nil : .easeOut(duration: 10), value: appeared)
                // A fresh view drops an animation still in flight.
                .id(kenBurnsDone)
            trailerLayer(height: height)
            // Legibility: bottom fade into the page, plus a left fade for the text.
            LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: Palette.background.opacity(0.7), location: 0.78),
                                   .init(color: Palette.background, location: 1)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [Palette.background.opacity(0.85), Palette.background.opacity(0.3), .clear],
                           startPoint: .leading, endPoint: UnitPoint(x: 0.65, y: 0.5))
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
            VStack(alignment: .leading, spacing: Spacing.m) {
                if !genres.isEmpty {
                    HStack(spacing: 6) {
                        // Grey, not blue: blue marks state only.
                        Image(systemName: title.kind == .series ? "tv" : "film").font(.caption.weight(.bold))
                            .foregroundStyle(Palette.textSecondary)
                        Text(title.kind == .series ? "SERIES" : "FILM").font(.caption.weight(.heavy)).tracking(2.4)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .rise(appeared, delay: 0, reduceMotion: reduceMotion)
                }
                Text(title.name)
                    .font(Typography.display(compact: false))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 10)
                    .accessibilityAddTraits(.isHeader)
                    .scaleEffect(settled ? 0.8 : 1, anchor: .bottomLeading)
                    .rise(appeared, delay: 0.05, reduceMotion: reduceMotion)
                    .frame(maxWidth: 640, alignment: .leading)
                if !settled, !title.overview.isEmpty {
                    Text(title.overview).font(.body).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
                        .frame(maxWidth: 520, alignment: .leading)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                        .rise(appeared, delay: 0.15, reduceMotion: reduceMotion)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                HStack(spacing: Spacing.m) {
                    primaryButton(fullWidth: false)
                    if playable {
                        NavigationLink(value: Route.title(title)) { Label("More Info", systemImage: "info.circle") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    myListButton(fullWidth: false)
                }
                .modifier(ChromeTextCap())
                .successHaptic(onList)
                .rise(appeared, delay: 0.25, reduceMotion: reduceMotion)
                .padding(.top, Spacing.xs)
            }
            .padding(.horizontal, inset)
            .padding(.bottom, Spacing.xxl + Spacing.xl)
        }
        .overlay(alignment: .bottomTrailing) {
            muteButton
                .padding(.trailing, inset)
                .padding(.bottom, Spacing.xxl + Spacing.xl + 2)
        }
        .frame(width: width, height: height)
        .clipped()
    }

    // MARK: Buttons

    @ViewBuilder private func primaryButton(fullWidth: Bool) -> some View {
        if playable, let target = seriesTarget {
            let code = "S\(target.season)·E\(target.episode)"
            Button {
                Task {
                    await app.play(NowPlayingItem(key: target.key, title: title.name, subtitle: code,
                                                  artworkURL: app.imageURL(title.backdrop, width: 640)), resume: true)
                }
            } label: { Label((target.isResume ? "Resume " : "Play ") + code, systemImage: "play.fill") }
            .buttonStyle(PrimaryButtonStyle(fullWidth: fullWidth))
            .accessibilityIdentifier("heroPlay")
        } else if playable {
            Button {
                Task { await app.play(NowPlayingItem(key: title.key, title: title.name, subtitle: title.year.map(String.init))) }
            } label: { Label("Play", systemImage: "play.fill") }
            .buttonStyle(PrimaryButtonStyle(fullWidth: fullWidth))
            .accessibilityIdentifier("heroPlay")
        } else {
            NavigationLink(value: Route.title(title)) {
                Label("More Info", systemImage: "info.circle")
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: fullWidth))
            .accessibilityIdentifier("heroInfo")
        }
    }

    private func myListButton(fullWidth: Bool) -> some View {
        Button {
            let on = !onList
            Task {
                await app.optimistic(on ? "Couldn't add to My List" : "Couldn't remove from My List",
                                     from: !on, to: on, apply: { onList = $0 }) { try await app.setOnMyList(title, on) }
            }
        } label: {
            Label("My List", systemImage: onList ? "checkmark" : "plus")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(SecondaryButtonStyle(fullWidth: fullWidth))
        .accessibilityValue(onList ? "On My List" : "Not on My List")
    }
}

/// The iPhone hero's buttons (and the title page's secondary ones): side by
/// side at equal widths when every label fits on one line that way,
/// otherwise stacked at full width (a long "Resume S2·E10", large text)
/// rather than wrapping inside the button. Empty views (a Download button
/// with nothing to download) take no column.
struct HeroButtonRow: Layout {
    var spacing: CGFloat = Spacing.m
    var stackedSpacing: CGFloat = Spacing.s

    private func columnWidth(_ width: CGFloat, _ count: Int) -> CGFloat {
        (width - spacing * CGFloat(max(count - 1, 0))) / CGFloat(max(count, 1))
    }

    private func fitsSideBySide(_ width: CGFloat, _ subviews: [LayoutSubview]) -> Bool {
        let column = columnWidth(width, subviews.count)
        return subviews.allSatisfy { $0.sizeThatFits(.unspecified).width <= column }
    }

    private func visible(_ subviews: Subviews) -> [LayoutSubview] {
        subviews.filter { $0.sizeThatFits(.unspecified) != .zero }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews all: Subviews, cache: inout ()) -> CGSize {
        let subviews = visible(all)
        guard !subviews.isEmpty else { return .zero }
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let width = proposal.width ?? widest * CGFloat(subviews.count) + spacing * CGFloat(max(subviews.count - 1, 0))
        if fitsSideBySide(width, subviews) {
            let column = columnWidth(width, subviews.count)
            let height = subviews.map { $0.sizeThatFits(.init(width: column, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let heights = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + stackedSpacing * CGFloat(max(subviews.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews all: Subviews, cache: inout ()) {
        let subviews = visible(all)
        for view in all where view.sizeThatFits(.unspecified) == .zero {
            view.place(at: bounds.origin, proposal: .zero)
        }
        if fitsSideBySide(bounds.width, subviews) {
            let column = columnWidth(bounds.width, subviews.count)
            for (i, view) in subviews.enumerated() {
                view.place(at: CGPoint(x: bounds.minX + CGFloat(i) * (column + spacing), y: bounds.minY),
                           proposal: .init(width: column, height: bounds.height))
            }
        } else {
            var y = bounds.minY
            for view in subviews {
                let height = view.sizeThatFits(.init(width: bounds.width, height: nil)).height
                view.place(at: CGPoint(x: bounds.minX, y: y), proposal: .init(width: bounds.width, height: height))
                y += height + stackedSpacing
            }
        }
    }
}

/// The hero's shape while Home loads.
struct HeroSkeleton: View {
    let width: CGFloat
    let inset: CGFloat
    let topInset: CGFloat

    var body: some View {
        if width < 600 {
            SkeletonBlock(width: width - inset * 2, height: (width - inset * 2) * 1.3, radius: Radius.hero)
                .padding(.horizontal, inset)
                .padding(.top, topInset + Spacing.s)
        } else {
            ZStack(alignment: .bottomLeading) {
                Palette.surface.opacity(0.5)
                VStack(alignment: .leading, spacing: Spacing.m) {
                    SkeletonBlock(width: 360, height: 48)
                    SkeletonBlock(width: 480, height: 16)
                    SkeletonBlock(width: 420, height: 16)
                    HStack(spacing: Spacing.m) {
                        SkeletonBlock(width: 120, height: 44, radius: Radius.control)
                        SkeletonBlock(width: 120, height: 44, radius: Radius.control)
                    }
                }
                .shimmering()
                .padding(.horizontal, inset)
                .padding(.bottom, Spacing.xxl + Spacing.xl)
            }
            .frame(width: width, height: HeroView.wideHeight(width))
        }
    }
}

/// TMDB attribution (required) and sample-mode notice.
struct CatalogFooter: View {
    let mode: AppModel.CatalogMode
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            switch mode {
            case .sample:
                Label("Showing the built-in sample catalog. Add a TMDB token in Settings for the full catalog.", systemImage: "info.circle")
            case .cinemeta:
                Label("Catalog from Cinemeta, Stremio's free catalog. Add a TMDB token in Settings › Catalog for cast pages, more artwork and fuller details.",
                      systemImage: "info.circle")
            case .live:
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
            }
        }
        .font(.caption)
        .foregroundStyle(Palette.textTertiary)
    }
}

extension View {
    /// Fades and lifts into place once `on` is true, after `delay`.
    func rise(_ on: Bool, delay: Double, reduceMotion: Bool) -> some View {
        opacity(on ? 1 : 0)
            .offset(y: on || reduceMotion ? 0 : 18)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.6).delay(delay), value: on)
    }
}

/// Continue Watching's blue tag on a show that just aired an episode.
struct NewEpisodeTag: View {
    var body: some View {
        Text("New Episode")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Palette.brand, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 3)
            .accessibilityHidden(true)  // the card's subtitle says it too
    }
}

#if DEBUG
/// Screenshots: `-home-scroll-y 900` scrolls Home down that far once it has loaded.
private struct DebugHomeScroll: ViewModifier {
    @State private var position = ScrollPosition(edge: .top)
    private let target: CGFloat? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-home-scroll-y"), i + 1 < args.count else { return nil }
        return Double(args[i + 1]).map { CGFloat($0) }
    }()

    func body(content: Content) -> some View {
        if let target {
            content
                .scrollPosition($position)
                .task {
                    // Again after each load lands (rows arriving can move the page back).
                    for _ in 0..<4 {
                        try? await Task.sleep(for: .seconds(2))
                        position.scrollTo(y: target)
                    }
                }
        } else {
            content
        }
    }
}
#endif
