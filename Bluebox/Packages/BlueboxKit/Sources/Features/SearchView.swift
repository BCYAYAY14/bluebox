import DesignSystem
import Domain
import Metadata
import Observation
import SwiftUI

extension EnvironmentValues {
    /// Bumped when the Search tab or button is chosen again (or ⌘F): Search
    /// focuses its field. `RootView` pops the Search tab to its root first.
    @Entry var searchFocusRequest = 0
}

/// Paged title results with load-more and cancellation-safe updates.
///
/// Each query (or `reset`) starts a new generation. Loading is tracked per
/// generation: a request from an earlier query that is still answering (its
/// task was cancelled, but a shared request can outlive it) neither blocks the
/// new query nor writes into it.
@Observable
@MainActor
final class PagedTitles {
    private(set) var items: [Title] = []
    var error: Error?
    /// Whether the current query is loading a page. An earlier query's request doesn't count.
    var isLoading: Bool { loadingGeneration == generation }
    /// The items belong to the previous query: shown dimmed until the new
    /// answer replaces them. Set only when a fetch starts (not per keystroke:
    /// the field debounces before the query reaches here).
    private(set) var isStale = false
    var showsSkeleton: Bool { isLoading && items.isEmpty }
    /// The query these results are for (nil for `reset`).
    private(set) var query: String?
    private var page = 0
    private var totalPages = 1
    private var generation = 0
    private var loadingGeneration: Int?
    private var fetch: ((Int) async throws -> Page<Title>)?

    var hasMore: Bool { page < totalPages }
    var isEmptyResult: Bool { !isLoading && error == nil && page > 0 && items.isEmpty }
    /// Whether `query`'s first page is already showing.
    func answered(for query: String) -> Bool { self.query == query && page > 0 && error == nil }

    /// Starts over, clearing the grid (genre pages, an emptied search field).
    func reset(_ fetch: ((Int) async throws -> Page<Title>)?) async {
        generation += 1
        items = []; error = nil; page = 0; totalPages = 1; isStale = false; query = nil
        self.fetch = fetch
        if fetch != nil { await loadMore() }
    }

    /// Shows `query`'s results, keeping the previous ones on screen (dimmed)
    /// until its first page arrives. A `cached` first page shows at once.
    func load(_ query: String, cached: Page<Title>? = nil, fetch: @escaping (Int) async throws -> Page<Title>) async {
        generation += 1
        self.query = query
        self.fetch = fetch
        error = nil
        if let cached {
            items = Self.unique(cached.items)
            page = cached.page; totalPages = cached.totalPages; isStale = false
            return
        }
        page = 0; totalPages = 1
        isStale = !items.isEmpty
        await loadMore()
    }

    func loadMore() async {
        guard let fetch, hasMore, !isLoading else { return }
        let gen = generation
        loadingGeneration = gen
        defer { if loadingGeneration == gen { loadingGeneration = nil } }
        do {
            let result = try await fetch(page + 1)
            guard gen == generation else { return }
            if isStale {
                items = Self.unique(result.items)
                isStale = false
            } else {
                let seen = Set(items.map(\.key))
                items += Self.unique(result.items).filter { !seen.contains($0.key) }
            }
            page = result.page
            totalPages = result.totalPages
        } catch is CancellationError {
        } catch {
            guard gen == generation else { return }
            self.error = error
            if isStale { items = []; isStale = false }
        }
    }

    private static func unique(_ titles: [Title]) -> [Title] {
        var seen = Set<MediaKey>()
        return titles.filter { seen.insert($0.key).inserted }
    }
}

struct TitleGrid: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isDownloaded) private var isDownloaded
    let results: PagedTitles
    let width: CGFloat
    var onOpen: (Title) -> Void = { _ in }

    var body: some View {
        let inset = Spacing.pageInset(for: width)
        let metrics = CardMetrics(containerWidth: width)
        let (cols, cardWidth) = Self.columns(width: width, inset: inset, metrics: metrics)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: Spacing.cardGap), count: cols),
                  alignment: .leading, spacing: Spacing.l) {
            if results.showsSkeleton {
                ForEach(0..<(cols * 3), id: \.self) { _ in
                    SkeletonBlock(width: cardWidth, height: cardWidth * 1.5)
                }
            }
            ForEach(results.items) { t in
                TitleCardLink(t, onOpen: { onOpen(t) }) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        PosterCard(title: t.name, url: app.imageURL(t.poster, width: cardWidth), width: cardWidth,
                                   isDownloaded: isDownloaded(t.key))
                        Text(t.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(Self.meta(t)).font(.caption2).foregroundStyle(Palette.textSecondary)
                    }
                    .frame(width: cardWidth, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(t.name)
                    .accessibilityValue(Self.meta(t).replacingOccurrences(of: " · ", with: ", "))
                }
                .onAppear {
                    if t.key == results.items.last?.key { Task { await results.loadMore() } }
                }
            }
        }
        .padding(.horizontal, inset)
        // One sweep across every skeleton card, not one per card.
        .shimmering(active: results.showsSkeleton)
        .task(id: results.items.prefix(Self.prefetchCount).map(\.key)) { await prefetchPosters(cardWidth: cardWidth) }
        // The next page; a new query's progress shows in the header instead.
        if results.isLoading && !results.isStale && !results.items.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding()
        }
    }

    /// About four rows: the first screen plus the next.
    static let prefetchCount = 18

    /// Starts the top results' posters at the size the cards ask for, so they
    /// are in memory by the time the lazy grid gets to them.
    private func prefetchPosters(cardWidth: CGFloat) async {
        let urls = results.items.prefix(Self.prefetchCount).compactMap { app.imageURL($0.poster, width: cardWidth) }
        let pixels = Int(cardWidth * 2)
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { _ = try? await ImagePipeline.shared.image(for: url, maxPixelWidth: pixels) }
            }
        }
    }

    /// Three across on iPhone, as many as fit at poster width elsewhere.
    static func columns(width: CGFloat, inset: CGFloat, metrics: CardMetrics) -> (Int, CGFloat) {
        let usable = width - inset * 2
        let cols = width < 500 ? 3 : max(3, Int((usable + Spacing.cardGap) / (metrics.posterWidth + Spacing.cardGap)))
        return (cols, (usable - CGFloat(cols - 1) * Spacing.cardGap) / CGFloat(cols))
    }

    static func meta(_ t: Title) -> String {
        [t.kind == .movie ? "Movie" : "Series", t.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Search: a field, filter chips, then sectioned results; with nothing
/// typed, recent searches, Top Searches and genres.
///
/// The field keeps its own text (`SearchQueryField`, `DebouncedSearchable`)
/// and hands this view a query only once typing pauses, so a keystroke
/// redraws the field and nothing else.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.usesTopNav) private var usesTopNav
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The debounced, trimmed query.
    @State private var query = ""
    @State private var results = PagedTitles()
    /// The results drawn: rebuilt when results, people or chips change, not on every body.
    @State private var sections = SearchSections(top: nil, people: [], films: [], shows: [])
    @State private var filter = SearchFilter()
    /// Loaded when "Playable now" or "4K" is on.
    @State private var availability: SearchAvailability?
    @State private var genres: [Genre] = []
    @State private var topSearches: [Title] = []
    /// Top Searches and genres couldn't load (and there were none from before).
    @State private var browseFailed = false
    @State private var browseLoading = true
    /// People matching the query, and the query they're for.
    @State private var people: [Person] = []
    @State private var peopleQuery = ""
    /// My List and Continue Watching, matched as you type with no network.
    @State private var library: [Title] = []
    @State private var recents = RecentSearches()

    var body: some View {
        GeometryReader { geo in
            let inset = Spacing.pageInset(for: geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if usesTopNav || !query.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            if usesTopNav {
                                SearchQueryField(query: $query, results: results, onSubmit: remember)
                                    .padding(.horizontal, inset)
                            }
                            if !query.isEmpty { filterChips(inset: inset) }
                        }
                    }
                    if query.isEmpty {
                        browse(width: geo.size.width)
                    } else {
                        resultsBody(width: geo.size.width, inset: inset)
                    }
                }
                .padding(.vertical, Spacing.l)
                .animation(Motion.standard(reduceMotion), value: query.isEmpty)
            }
            .scrollDismissesKeyboard(.immediately)
            .scrollIndicators(.hidden)
            .reportsHeaderScroll()
        }
        .blueboxScreen()
        .navigationTitle("Search")
        #if os(iOS)
        // Pinned: with the default placement the field stayed hidden in the search tab.
        .modifier(DebouncedSearchable(query: $query, enabled: !usesTopNav, onSubmit: remember))
        #endif
        #if DEBUG
        .task {
            // Screenshots: `-search-query harbor` searches at once.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-search-query"), args.indices.contains(i + 1) { query = args[i + 1] }
        }
        #endif
        // Restarted (and the last one cancelled) whenever the query changes.
        .task(id: query) { await search(query) }
        .task(id: query) { await searchPeople(query) }
        .task(id: app.catalogMode == .live) { await loadBrowse() }
        .task(id: AvailabilityRequest(needed: filter.needsAvailability, downloads: app.downloadsRevision)) {
            guard filter.needsAvailability else { return }
            availability = await app.searchAvailability()
        }
        // Back online: the browse page and a failed search load again by themselves.
        .reloadsWhenBackOnline(browseFailed || results.error != nil) {
            if browseFailed { await loadBrowse() }
            if results.error != nil { await search(query) }
        }
        .task(id: app.currentProfileID) {
            recents = RecentSearches.load(profile: app.currentProfileID)
            filter = SearchFilterMemory.filter(profile: app.currentProfileID)
        }
        .onChange(of: app.searchHistoryRevision) { recents = RecentSearches.load(profile: app.currentProfileID) }
        .task(id: "\(app.currentProfileID)|\(app.libraryRevision)") { await loadLibrary() }
        .onChange(of: filter) { _, f in SearchFilterMemory.set(f, profile: app.currentProfileID) }
        .onChange(of: sectionInputs, initial: true) { _, inputs in rebuildSections(inputs) }
    }

    private struct AvailabilityRequest: Hashable { let needed: Bool; let downloads: Int }

    // MARK: Results

    /// Everything the sections depend on. Compared on change, so they're built
    /// once per answer rather than on every redraw.
    private struct SectionInputs: Equatable {
        var query: String
        var titles: [Title]
        var people: [Person]
        var filter: SearchFilter
        var availability: SearchAvailability?
    }

    private var sectionInputs: SectionInputs {
        let q = results.query ?? query
        return SectionInputs(query: q, titles: results.items, people: peopleQuery == q ? people : [],
                             filter: filter, availability: filter.needsAvailability ? availability : nil)
    }

    private func rebuildSections(_ inputs: SectionInputs) {
        sections = inputs.filter.sections(query: inputs.query, titles: inputs.titles, people: inputs.people,
                                          availability: inputs.availability ?? SearchAvailability())
        // A recent search typed before its results came in gets their picture now.
        guard recents.items.contains(where: { $0.artwork == nil && $0.query.caseInsensitiveCompare(inputs.query) == .orderedSame })
        else { return }
        let unfiltered = SearchSections.build(query: inputs.query, titles: inputs.titles, people: inputs.people)
        let (art, detail) = Self.preview(unfiltered.top)
        if recents.fillArtwork(for: inputs.query, artwork: art, detail: detail) { recents.save(profile: app.currentProfileID) }
    }

    /// The people search for the current query hasn't answered yet.
    private var peopleLoading: Bool {
        filter.includesPeople && app.hasPersonPages && peopleQuery != query
    }

    /// Waiting on "Playable now" / "4K" knowledge.
    private var availabilityLoading: Bool { filter.needsAvailability && availability == nil }

    @ViewBuilder private func resultsBody(width: CGFloat, inset: CGFloat) -> some View {
        let matches = libraryMatches
        let peopleHits = peopleQuery == query ? people : []
        if !matches.isEmpty { librarySection(matches, inset: inset) }
        if let error = results.error {
            if app.settings.isOffline || UserFacingError.isOffline(error) {
                OfflineMessage(reason: "Search needs the internet.") { Task { await search(query) } }
            } else {
                StateMessage(.failed, systemImage: "exclamationmark.magnifyingglass", title: "Search didn't finish",
                             message: UserFacingError.message(for: error, context: .catalog), actionTitle: "Try Again") {
                    Task { await search(query) }
                }
            }
        } else if results.isEmptyResult && results.query == query && peopleHits.isEmpty && !peopleLoading {
            if matches.isEmpty {
                StateMessage(systemImage: "film.stack", title: "No results for “\(query)”",
                             message: "Check the spelling, or try a different title, year or person.")
                // Something to tap instead of a dead end.
                if !topSearches.isEmpty { topSearchesSection(inset: inset) }
            }
        } else if results.showsSkeleton || (results.items.isEmpty && results.query != query) || availabilityLoading {
            // The sections' own shape straight away, so nothing jumps when they fill in.
            SearchResultsSkeleton(width: width, showsTitles: filter.includesTitles,
                                  showsPeople: filter.includesPeople && app.hasPersonPages)
        } else if sections.isEmpty && !peopleLoading {
            StateMessage(systemImage: "line.3.horizontal.decrease.circle", title: "Nothing matches these filters",
                         message: filter.needsAvailability ? Self.availabilityNote : nil,
                         actionTitle: "Show All") { set { $0 = SearchFilter() } }
        } else {
            // Top result, people, films, TV shows (the Apple TV app's layout).
            SearchResultsSections(sections: sections, results: results, width: width,
                                  peopleLoading: peopleLoading && !results.isStale) { remember(query) }
                // The last query's results stay, dimmed, until the new ones arrive: no blank flash.
                .opacity(results.isStale ? 0.4 : 1)
                .animation(.easeOut(duration: 0.15), value: results.isStale)
            if filter.needsAvailability {
                Text(Self.availabilityNote)
                    .font(.footnote).foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, inset)
            }
        }
    }

    private static let availabilityNote =
        "“Playable now” and “4K” go by your downloads, your debrid cloud, and releases found this session."

    private func filterChips(inset: CGFloat) -> some View {
        ChipRow(inset: inset) {
            ForEach(SearchFilter.Scope.allCases, id: \.self) { scope in
                FilterChip(scope.title, selected: filter.scope == scope) { set { $0.scope = scope } }
            }
            ChipDivider()
            FilterChip("Playable now", systemImage: "bolt.fill", selected: filter.playableNow) { set { $0.playableNow.toggle() } }
                .accessibilityHint("Only what's downloaded, in your debrid cloud, or found cached")
            FilterChip("4K", selected: filter.uhd) { set { $0.uhd.toggle() } }
            ChipDivider()
            ForEach(SearchFilter.decades + [SearchFilter.earlier], id: \.self) { d in
                FilterChip(SearchFilter.decadeTitle(d), selected: filter.decade == d) {
                    set { $0.decade = $0.decade == d ? nil : d }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    private func set(_ change: (inout SearchFilter) -> Void) {
        var f = filter
        change(&f)
        withAnimation(Motion.standard(reduceMotion)) { filter = f }
    }

    // MARK: Searching

    /// Shows a query's results: from memory at once when it was searched
    /// recently, otherwise from the network. The field has already waited for
    /// a pause in typing; the last results stay on screen, dimmed, until then.
    private func search(_ q: String) async {
        guard !q.isEmpty else { await results.reset(nil); return }
        if results.answered(for: q) { return }  // e.g. back from a title page
        let metadata = app.metadata
        let fetch: (Int) async throws -> Page<Title> = { try await metadata.search(q, page: $0) }
        if let cache = metadata as? CachedMetadataProvider, let hit = await cache.cachedSearch(q) {
            guard !Task.isCancelled else { return }
            await results.load(q, cached: hit, fetch: fetch)
            return
        }
        guard !Task.isCancelled else { return }
        await results.load(q, fetch: fetch)
    }

    /// People for Search's People row (TMDB only: without it there are no person pages).
    /// Shown from memory at once when searched recently. A failure just leaves the row out.
    private func searchPeople(_ q: String) async {
        guard !q.isEmpty, app.hasPersonPages, let extras = app.metadata as? any MetadataExtras else {
            people = []; peopleQuery = q
            return
        }
        if peopleQuery == q { return }
        if let cache = app.metadata as? CachedMetadataProvider, let hit = await cache.cachedPeople(q) {
            people = hit; peopleQuery = q
            return
        }
        let found = (try? await extras.searchPeople(q)) ?? []
        guard !Task.isCancelled else { return }
        people = found; peopleQuery = q
    }

    /// Top Searches and genres for the empty page. A failure with nothing
    /// saved shows the failed page (not skeletons forever).
    private func loadBrowse() async {
        browseLoading = true
        defer { browseLoading = false }
        var failed = false
        do { genres = try await app.metadata.genres() } catch { failed = true }
        do { topSearches = Array(try await app.metadata.list(.trending, page: 1).items.prefix(8)) } catch { failed = true }
        browseFailed = failed
    }

    // MARK: Your library

    private func loadLibrary() async {
        var titles = (try? await app.store.watchlist()) ?? []
        var seen = Set(titles.map(\.key))
        for p in (try? await app.store.continueWatching(limit: 50)) ?? [] {
            let key = p.key.seriesKey ?? p.key
            // Only what's already stored: this list is for instant matches, not more requests.
            if seen.insert(key).inserted, let t = try? await app.store.title(for: key) { titles.append(t) }
        }
        library = titles
    }

    private var libraryMatches: [Title] {
        guard !query.isEmpty, filter.includesTitles else { return [] }
        let known = availability ?? SearchAvailability()
        return Array(library.filter { $0.name.localizedStandardContains(query) && filter.matches($0, availability: known) }.prefix(12))
    }

    private func librarySection(_ titles: [Title], inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("In Your Library").font(Typography.rowTitle).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, inset)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Spacing.cardGap) {
                    ForEach(titles) { t in
                        TitleCardLink(t, onOpen: { remember(query) }) {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                PosterCard(title: t.name, url: app.imageURL(t.poster, width: 104), width: 104)
                                Text(t.name).font(.caption.weight(.semibold)).lineLimit(1)
                            }
                            .frame(width: 104, alignment: .leading)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(t.name)
                            .accessibilityValue("In your library")
                        }
                    }
                }
                .padding(.horizontal, inset)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func topSearchesSection(inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Top Searches").font(Typography.rowTitle).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Spacing.l)], spacing: Spacing.s) {
                ForEach(topSearches) { t in TopSearchRow(title: t) }
            }
        }
        .padding(.horizontal, inset)
    }

    // MARK: Recent searches

    /// A query worth keeping: submitted, or one whose result you opened.
    /// Keeps the top result's picture when the results are this query's.
    private func remember(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespaces)
        let (art, detail) = results.query == q ? Self.preview(sections.top) : (nil, nil)
        recents.add(q, artwork: art, detail: detail)
        recents.save(profile: app.currentProfileID)
    }

    private func forget(_ q: String) {
        withAnimation(Motion.standard(reduceMotion)) { recents.remove(q) }
        recents.save(profile: app.currentProfileID)
    }

    private func forgetAll() {
        withAnimation(Motion.standard(reduceMotion)) { recents.removeAll() }
        recents.save(profile: app.currentProfileID)
    }

    /// The picture and line a recent search shows for its top result.
    static func preview(_ top: SearchSections.Top?) -> (Artwork?, String?) {
        switch top {
        case .title(let t)?: (t.poster ?? t.backdrop, "\(t.name) · \(TitleGrid.meta(t))")
        case .person(let p)?: (p.profile, p.name)
        case nil: (nil, nil)
        }
    }

    // MARK: Browse (empty query)

    @ViewBuilder private func browse(width: CGFloat) -> some View {
        let inset = Spacing.pageInset(for: width)
        let phase = LoadPhase.resolve(hasContent: !topSearches.isEmpty || !genres.isEmpty, isLoading: browseLoading,
                                      failed: browseFailed, isOffline: app.settings.isOffline)
        VStack(alignment: .leading, spacing: Spacing.xl) {
            // Offline, Search can't do anything but your recent searches: say
            // so, and point to what still plays.
            if app.settings.isOffline {
                OfflineMessage(reason: "Search needs the internet.") { Task { await loadBrowse() } }
            } else if phase == .failed {
                StateMessage(.failed, systemImage: "exclamationmark.magnifyingglass", title: "Couldn't load Search",
                             message: "Top Searches and genres didn't load. Check your connection, then try again.",
                             actionTitle: "Try Again") { Task { await loadBrowse() } }
            }
            if !recents.isEmpty {
                // Searching one again moves it to the top.
                RecentSearchesList(recents: recents.items, onPick: { query = $0.query; remember($0.query) },
                                   onRemove: { forget($0.query) }, onClear: forgetAll)
                    .padding(.horizontal, inset)
            }

            if app.settings.isOffline {
                EmptyView()
            } else if !topSearches.isEmpty {
                topSearchesSection(inset: inset)
            } else if phase == .loading {
                // First load: the rows' shape, not a spinner. One sweep across all of it.
                VStack(alignment: .leading, spacing: Spacing.s) {
                    SkeletonBlock(width: 160, height: 20, radius: 4)
                    ForEach(0..<5, id: \.self) { _ in
                        HStack(spacing: Spacing.m) {
                            SkeletonBlock(width: 132, height: 74, radius: Radius.thumbnail)
                            SkeletonBlock(width: 140, height: 14, radius: 4)
                            Spacer()
                        }
                    }
                }
                .shimmering()
                .padding(.horizontal, inset)
            }

            if !genres.isEmpty && !app.settings.isOffline {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Browse by Genre").font(Typography.rowTitle).accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.s)], spacing: Spacing.s) {
                        ForEach(genres) { g in
                            // Neutral tiles: blue is for state and the one accent, not decoration.
                            NavigationLink(value: Route.genre(g, .movie)) {
                                Text(g.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .padding(Spacing.m)
                                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .bottomLeading)
                                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.edge))
                                    .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
                .padding(.horizontal, inset)
            }
        }
    }
}

/// A Top Searches entry: landscape thumbnail, title, and a play glyph, as in Netflix's search.
private struct TopSearchRow: View {
    @Environment(AppModel.self) private var app
    let title: Title
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: Route.title(title)) {
            HStack(spacing: Spacing.m) {
                ArtworkView(url: app.imageURL(title.backdrop ?? title.poster, width: 150), fallbackTitle: title.name,
                            kind: .backdrop, pixelWidth: 300, showsFallbackTitle: false)
                    .frame(width: 132, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(TitleGrid.meta(title)).font(.caption).foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: Spacing.s)
                Image(systemName: "play.circle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(hovering ? Palette.brandBright : .white)
                    .accessibilityHidden(true)
            }
            .padding(.trailing, Spacing.s)
            .background(hovering ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityElement(children: .combine)
    }
}

struct GenreView: View {
    @Environment(AppModel.self) private var app
    let genre: Genre
    @State var kind: TitleKind
    @State private var results = PagedTitles()

    init(genre: Genre, kind: TitleKind) { self.genre = genre; _kind = State(initialValue: kind) }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: Spacing.l) {
                    PageTitle(title: genre.name, inset: Spacing.pageInset(for: geo.size.width))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("Type", selection: $kind) {
                        Text("Movies").tag(TitleKind.movie)
                        Text("Series").tag(TitleKind.series)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    if let error = results.error {
                        if app.settings.isOffline || UserFacingError.isOffline(error) {
                            OfflineMessage(reason: "Genres need the internet.") { Task { await reload() } }
                        } else {
                            StateMessage(.failed, title: "Couldn't load \(genre.name)",
                                         message: UserFacingError.message(for: error, context: .catalog),
                                         actionTitle: "Try Again") { Task { await reload() } }
                        }
                    } else if results.isEmptyResult {
                        StateMessage(systemImage: "film", title: "Nothing here yet")
                    } else {
                        TitleGrid(results: results, width: geo.size.width)
                    }
                }
                .padding(.vertical, Spacing.l)
            }
            .reportsHeaderScroll()
        }
        .blueboxScreen()
        .navigationTitle(genre.name)
        .task(id: kind) { await reload() }
        .reloadsWhenBackOnline(results.error != nil) { await reload() }
    }

    private func reload() async {
        let m = app.metadata, g = genre, k = kind
        await results.reset { try await m.discover(genre: g, kind: k, page: $0) }
    }
}

