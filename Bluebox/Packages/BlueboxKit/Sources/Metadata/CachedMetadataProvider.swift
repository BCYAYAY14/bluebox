import Domain
import Foundation

/// Keeps recent catalog answers in memory so going back to a page, Up Next
/// and the add-on lookups don't ask TMDB again, and shares one request
/// between callers that ask at the same time. When the network is down, an
/// answer past its lifetime is still better than an error, so it's used.
public final class CachedMetadataProvider: MetadataProvider, @unchecked Sendable {
    public let base: any MetadataProvider
    private let store: Store

    /// How long answers count as fresh.
    public struct Lifetimes: Sendable {
        public var detail: TimeInterval = 30 * 60
        public var lists: TimeInterval = 15 * 60
        public var search: TimeInterval = 5 * 60
        public var genres: TimeInterval = 24 * 3600
        public init() {}
    }

    private let lifetimes: Lifetimes

    public init(_ base: any MetadataProvider, lifetimes: Lifetimes = Lifetimes(), capacity: Int = 400,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.base = base
        self.lifetimes = lifetimes
        self.store = Store(capacity: capacity, now: now)
    }

    // MARK: The other catalog's keys

    /// Translates keys saved under the other catalog (`CatalogKeyBridge`).
    /// Nil leaves them as they are (the sample catalog, tests).
    public var keyBridge: CatalogKeyBridge? {
        get { filterLock.withLock { bridgeValue } }
        set { filterLock.withLock { bridgeValue = newValue } }
    }
    private var bridgeValue: CatalogKeyBridge?

    /// True when `base` keys titles by TMDB ID, false for IMDb (Cinemeta), nil for neither.
    private var usesTMDBKeys: Bool? {
        if base is TMDBService { return true }
        if base is CinemetaMetadataProvider { return false }
        return nil
    }

    /// `key` in `base`'s catalog when it was saved under the other one.
    private func nativeKey(for key: MediaKey) async -> MediaKey? {
        guard let bridge = keyBridge, let tmdb = usesTMDBKeys else { return nil }
        return await bridge.key(for: key, toTMDB: tmdb)
    }

    // MARK: Maturity

    private let filterLock = NSLock()
    private var filterValue: ContentFilter?
    /// Certifications seen on title pages, kept after the page leaves the cache.
    private var certifications: [MediaKey: String] = [:]

    /// The current profile's limit. Lists, search and Discover drop titles
    /// whose known certification is above it (the cache itself keeps everything,
    /// so switching profiles needs no new requests).
    public var contentFilter: ContentFilter? {
        get { filterLock.withLock { filterValue } }
        set { filterLock.withLock { filterValue = newValue } }
    }

    /// The certification Bluebox has seen for a title, if any.
    public func certification(for key: MediaKey) -> String? { filterLock.withLock { certifications[key] } }

    /// Records a certification learnt elsewhere (a title page, tests).
    public func noteCertification(_ certification: String?, for key: MediaKey) {
        guard let certification, !certification.isEmpty else { return }
        filterLock.withLock {
            if certifications.count > 5000 { certifications.removeAll(keepingCapacity: true) }
            certifications[key] = certification
        }
    }

    func filtered(_ page: Page<Title>) -> Page<Title> {
        guard let filter = contentFilter else { return page }
        let known = filterLock.withLock { certifications }
        return Page(items: page.items.filter { filter.allows($0, certification: known[$0.key]) },
                    page: page.page, totalPages: page.totalPages)
    }

    // MARK: Catalogue

    public func list(_ list: CatalogList, page: Int) async throws -> Page<Title> {
        filtered(try await store.value("list:\(list.rawValue):\(page)", lifetime: lifetimes.lists) { [base] in
            try await base.list(list, page: page)
        })
    }

    public func search(_ query: String, page: Int) async throws -> Page<Title> {
        filtered(try await store.value(Self.searchKey(query, page), lifetime: lifetimes.search) { [base] in
            try await base.search(query, page: page)
        })
    }

    /// A search answer still in memory, without asking: Search shows it as you
    /// type, with no debounce.
    public func cachedSearch(_ query: String, page: Int = 1) async -> Page<Title>? {
        let hit: Page<Title>? = await store.peek(Self.searchKey(query, page), lifetime: lifetimes.search)
        return hit.map(filtered)
    }

    private static func searchKey(_ query: String, _ page: Int) -> String {
        "search:\(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(page)"
    }

    public func discover(genre: Genre, kind: TitleKind, page: Int) async throws -> Page<Title> {
        filtered(try await store.value("discover:\(genre.id):\(kind):\(page)", lifetime: lifetimes.lists) { [base] in
            try await base.discover(genre: genre, kind: kind, page: page)
        })
    }

    public func genres() async throws -> [Genre] {
        try await store.value("genres", lifetime: lifetimes.genres) { [base] in try await base.genres() }
    }

    public func detail(for key: MediaKey) async throws -> TitleDetail {
        if let native = await nativeKey(for: key) {
            // Saved under the other catalog: this catalog's page, under the saved key,
            // so progress, downloads and My List stay with it.
            return try await detail(for: native).rekeyed(to: key)
        }
        let detail: TitleDetail = try await store.value("detail:\(key.rawValue)", lifetime: lifetimes.detail) { [base] in
            try await base.detail(for: key)
        }
        noteCertification(detail.certification, for: key)
        guard let filter = contentFilter else { return detail }
        let known = filterLock.withLock { certifications }
        return TitleDetail(title: detail.title, tagline: detail.tagline, runtimeMinutes: detail.runtimeMinutes, genres: detail.genres,
                           cast: detail.cast, crew: detail.crew, logo: detail.logo, seasons: detail.seasons,
                           related: detail.related.filter { filter.allows($0, certification: known[$0.key]) },
                           certification: detail.certification, imdbID: detail.imdbID)
    }

    /// A title's detail still in memory, without asking (Home's next-episode
    /// cards use its seasons when they're there).
    public func cachedDetail(for key: MediaKey) async -> TitleDetail? {
        await store.peek("detail:\(key.rawValue)", lifetime: lifetimes.detail)
    }

    /// Airing info still in memory (the new-episode check fills it), without asking.
    public func cachedAiring(for seriesKey: MediaKey) async -> AiringInfo? {
        await store.peek("airing:\(seriesKey.rawValue)", lifetime: Self.airingLifetime * 24)
    }

    public func season(_ number: Int, of seriesKey: MediaKey) async throws -> Season {
        if let native = await nativeKey(for: seriesKey) {
            return try await season(number, of: native).rekeyed(to: seriesKey)
        }
        return try await store.value("season:\(seriesKey.rawValue):\(number)", lifetime: lifetimes.detail) { [base] in
            try await base.season(number, of: seriesKey)
        }
    }

    public func imageURL(for artwork: Artwork, width: Int) -> URL? {
        base.imageURL(for: artwork, width: width)
    }

    /// Forgets everything (pull to refresh, a new credential).
    public func removeAll() async { await store.removeAll() }

    private actor Store {
        private struct Entry { let value: any Sendable; let stored: Date; var used: Date }
        /// One request shared by everyone asking for the same key. It's
        /// cancelled when the last of them is (Search drops a query on the
        /// next keystroke), so abandoned requests don't keep the connection busy.
        private struct Flight { let id: UUID; let task: Task<any Sendable, Error>; var waiters: Int }
        private var entries: [String: Entry] = [:]
        private var inflight: [String: Flight] = [:]
        private let capacity: Int
        private let now: @Sendable () -> Date

        init(capacity: Int, now: @escaping @Sendable () -> Date) {
            self.capacity = capacity
            self.now = now
        }

        func peek<T: Sendable>(_ key: String, lifetime: TimeInterval) -> T? {
            let date = now()
            guard let hit = entries[key], let value = hit.value as? T, date.timeIntervalSince(hit.stored) < lifetime else { return nil }
            entries[key]?.used = date
            return value
        }

        func value<T: Sendable>(_ key: String, lifetime: TimeInterval,
                                fetch: @escaping @Sendable () async throws -> T) async throws -> T {
            if let hit: T = peek(key, lifetime: lifetime) { return hit }
            try Task.checkCancellation()
            let flight: Flight
            if var running = inflight[key] {
                running.waiters += 1
                inflight[key] = running
                flight = running
            } else {
                flight = Flight(id: UUID(), task: Task { try await fetch() as any Sendable }, waiters: 1)
                inflight[key] = flight
            }
            let id = flight.id
            do {
                let fetched = try await withTaskCancellationHandler {
                    try await flight.task.value
                } onCancel: {
                    Task { await self.leave(key, id: id) }
                }
                if inflight[key]?.id == id { inflight[key] = nil }
                guard let value = fetched as? T else { throw MetadataError.decoding("cache type mismatch") }
                entries[key] = Entry(value: value, stored: now(), used: now())
                trim()
                return value
            } catch {
                if inflight[key]?.id == id { inflight[key] = nil }
                // Offline or TMDB down: an old answer beats an error page.
                if Self.isConnectivity(error), let stale = entries[key]?.value as? T { return stale }
                throw error
            }
        }

        /// A caller stopped waiting; the request goes when nobody is left.
        private func leave(_ key: String, id: UUID) {
            guard var flight = inflight[key], flight.id == id else { return }
            flight.waiters -= 1
            if flight.waiters > 0 { inflight[key] = flight; return }
            inflight[key] = nil
            flight.task.cancel()
        }

        func removeAll() { entries = [:] }

        func put<T: Sendable>(_ key: String, _ value: T) {
            entries[key] = Entry(value: value, stored: now(), used: now())
            trim()
        }

        private func trim() {
            guard entries.count > capacity else { return }
            let excess = entries.count - capacity
            for key in entries.sorted(by: { $0.value.used < $1.value.used }).prefix(excess).map(\.key) {
                entries[key] = nil
            }
        }

        static func isConnectivity(_ error: Error) -> Bool {
            switch error as? MetadataError {
            case .offline, .transport, .rateLimited, .server: true
            default: error is URLError
            }
        }
    }
}

// MARK: - Extras (trailers, airing, people)

extension CachedMetadataProvider: MetadataExtras {
    private var extras: (any MetadataExtras)? { base as? any MetadataExtras }

    /// Videos rarely change; airing info changes when an episode is announced.
    static let videosLifetime: TimeInterval = 6 * 3600
    static let airingLifetime: TimeInterval = 3600
    static let peopleLifetime: TimeInterval = 24 * 3600

    public func videos(for key: MediaKey, season: Int?) async throws -> [TitleVideo] {
        guard let extras else { throw MetadataError.notFound }
        if let native = await nativeKey(for: key) { return try await videos(for: native, season: season) }
        return try await store.value("videos:\(key.rawValue):\(season.map(String.init) ?? "-")", lifetime: Self.videosLifetime) {
            try await extras.videos(for: key, season: season)
        }
    }

    public func airing(for seriesKey: MediaKey) async throws -> AiringInfo {
        guard let extras else { throw MetadataError.notFound }
        if let native = await nativeKey(for: seriesKey) { return try await airing(for: native).rekeyed(to: seriesKey) }
        return try await store.value("airing:\(seriesKey.rawValue)", lifetime: Self.airingLifetime) {
            try await extras.airing(for: seriesKey)
        }
    }

    /// Asks the service again (the new-episode check), keeping the old answer if that fails.
    public func freshAiring(for seriesKey: MediaKey) async throws -> AiringInfo {
        guard let extras else { throw MetadataError.notFound }
        if let native = await nativeKey(for: seriesKey) { return try await freshAiring(for: native).rekeyed(to: seriesKey) }
        let info = try await extras.airing(for: seriesKey)
        await store.put("airing:\(seriesKey.rawValue)", info)
        return info
    }

    public func upcomingMovies(page: Int) async throws -> Page<Title> {
        guard let extras else { return Page(items: [], page: 1, totalPages: 1) }
        return try await store.value("upcoming:\(page)", lifetime: lifetimes.lists) {
            try await extras.upcomingMovies(page: page)
        }
    }

    public func credits(for key: MediaKey) async throws -> TitleCredits {
        guard let extras else { throw MetadataError.notFound }
        if let native = await nativeKey(for: key) { return try await credits(for: native) }
        return try await store.value("credits:\(key.rawValue)", lifetime: lifetimes.detail) {
            try await extras.credits(for: key)
        }
    }

    public func person(id: Int) async throws -> Person {
        guard let extras else { throw MetadataError.notFound }
        return try await store.value("person:\(id)", lifetime: Self.peopleLifetime) { try await extras.person(id: id) }
    }

    public func searchPeople(_ query: String) async throws -> [Person] {
        guard let extras else { return [] }
        let key = "people:" + query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await store.value(key, lifetime: lifetimes.search) { try await extras.searchPeople(query) }
    }

    /// A people search still in memory, without asking (shown as you type).
    public func cachedPeople(_ query: String) async -> [Person]? {
        await store.peek("people:" + query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), lifetime: lifetimes.search)
    }

    public func filmography(personID: Int) async throws -> Filmography {
        guard let extras else { throw MetadataError.notFound }
        return try await store.value("filmography:\(personID)", lifetime: Self.peopleLifetime) {
            try await extras.filmography(personID: personID)
        }
    }
}

extension TitleDetail {
    /// The same page under `key` (a key saved under the other catalog).
    func rekeyed(to key: MediaKey) -> TitleDetail {
        let t = title
        let renamed = Title(key: key, kind: t.kind, name: t.name, overview: t.overview, releaseDate: t.releaseDate,
                            genreIDs: t.genreIDs, voteAverage: t.voteAverage, poster: t.poster, backdrop: t.backdrop)
        return TitleDetail(title: renamed, tagline: tagline, runtimeMinutes: runtimeMinutes, genres: genres, cast: cast,
                           crew: crew, logo: logo, seasons: seasons, related: related, certification: certification,
                           imdbID: imdbID ?? key.imdbID)
    }
}

extension Episode {
    /// The same episode under `seriesKey`.
    func rekeyed(to seriesKey: MediaKey) -> Episode {
        Episode(key: seriesKey.episode(season: seasonNumber, episode: number) ?? key, seasonNumber: seasonNumber,
                number: number, name: name, overview: overview, airDate: airDate, runtimeMinutes: runtimeMinutes, still: still)
    }
}

extension AiringInfo {
    func rekeyed(to seriesKey: MediaKey) -> AiringInfo {
        AiringInfo(seriesKey: seriesKey, status: status, lastEpisode: lastEpisode?.rekeyed(to: seriesKey),
                   nextEpisode: nextEpisode?.rekeyed(to: seriesKey))
    }
}

extension Season {
    /// The same season with its episodes under `seriesKey` (a key saved under the other catalog).
    func rekeyed(to seriesKey: MediaKey) -> Season {
        Season(seriesKey: seriesKey, number: number, name: name, overview: overview,
               episodes: episodes.map { $0.rekeyed(to: seriesKey) })
    }
}
