import Domain
import Foundation
import Persistence

/// Two-way sync of the watchlist and watched history with Trakt.
///
/// Watchlist: a three-way merge against the set both sides agreed on after the
/// last sync, so a removal on either side is carried over instead of being
/// undone by the other side still having the title. The first sync only adds.
///
/// History: titles marked watched on Trakt are imported as completed (normal
/// progress merging applies, so a newer rewatch in progress here wins).
/// Titles finished here since the last sync are sent to Trakt, unless Trakt
/// already has that play. Only TMDB-matched movies and episodes take part.
public actor TraktSync {
    public struct Report: Sendable, Equatable {
        public var pushed = 0
        /// Local records changed by what Trakt had.
        public var applied = 0
        public init(pushed: Int = 0, applied: Int = 0) { self.pushed = pushed; self.applied = applied }
    }

    let client: TraktClient
    let store: LibraryStore
    let prefs: PreferencesStore
    let now: @Sendable () -> Date
    /// Builds a full title (artwork, overview) for something added on Trakt.
    let resolveTitle: @Sendable (MediaKey) async -> Title?
    let ratings: TraktRatingsStore
    private var running = false

    public init(client: TraktClient, store: LibraryStore, prefs: PreferencesStore,
                now: @escaping @Sendable () -> Date = { Date() },
                resolveTitle: @escaping @Sendable (MediaKey) async -> Title? = { _ in nil }) {
        self.client = client; self.store = store; self.prefs = prefs; self.now = now; self.resolveTitle = resolveTitle
        ratings = TraktRatingsStore(prefs: prefs)
    }

    /// Forgets what was agreed with Trakt, e.g. after connecting another account.
    public func resetState() {
        for key in [Keys.watchlistBase, Keys.historyCursor, Keys.historyBase, Keys.ratingsBase, Keys.ratingsCursor, Keys.outbox] {
            prefs.set(String?.none, for: key)
        }
    }

    @discardableResult
    public func sync() async throws -> Report {
        guard !running else { return Report() }
        running = true
        defer { running = false }
        var report = Report()
        try await flushOutbox(&report)
        try await syncWatchlist(&report)
        try await syncHistory(&report)
        try await syncRatings(&report)
        return report
    }

    // MARK: Watchlist

    // TODO(lists): map your own lists (LibraryStore.lists()) to Trakt custom
    // lists (`users/me/lists`, `.../items`, `.../items/remove`) behind a
    // setting that's off by default. It needs a stored Trakt list ID per list
    // and the same three-way merge as below, per list. Only My List (this
    // watchlist) syncs with Trakt today.
    private func syncWatchlist(_ report: inout Report) async throws {
        let remoteItems = try await remoteWatchlist()
        let remote = Set(remoteItems.keys)
        let localTitles = try await store.watchlist().filter { $0.key.tmdbID != nil && $0.key.seriesKey == nil }
        let local = Set(localTitles.map(\.key))
        let base = prefs.value([MediaKey].self, for: Keys.watchlistBase).map(Set.init)
        let plan = WatchlistReconcile.plan(local: local, remote: remote, base: base)

        if !plan.addRemote.isEmpty {
            _ = try await client.post("sync/watchlist", TraktItems(plan.addRemote))
            report.pushed += plan.addRemote.count
        }
        if !plan.removeRemote.isEmpty {
            _ = try await client.post("sync/watchlist/remove", TraktItems(plan.removeRemote))
            report.pushed += plan.removeRemote.count
        }
        let byKey = Dictionary(localTitles.map { ($0.key, $0) }) { a, _ in a }
        for key in plan.removeLocal {
            if let t = byKey[key] { try await store.setWatchlisted(t, false); report.applied += 1 }
        }
        for key in plan.addLocal.sorted() {
            let fallback = remoteItems[key]!
            let title: Title
            if let cached = try? await store.title(for: key) { title = cached }
            else if let resolved = await resolveTitle(key) { title = resolved }
            else { title = fallback }
            try await store.setWatchlisted(title, true)
            report.applied += 1
        }
        prefs.set(plan.agreed.sorted(), for: Keys.watchlistBase)
    }

    private func remoteWatchlist() async throws -> [MediaKey: Title] {
        var out: [MediaKey: Title] = [:]
        let movies = try decode([TraktListItem].self, try await client.get("sync/watchlist/movies"))
        let shows = try decode([TraktListItem].self, try await client.get("sync/watchlist/shows"))
        for item in movies + shows {
            if let t = item.title { out[t.key] = t }
        }
        return out
    }

    // MARK: History

    /// Three-way merge of watched state (`HistoryReconcile`): plays go both
    /// ways, and so do removals (unwatching here, or removing a play on Trakt).
    private func syncHistory(_ report: inout Report) async throws {
        let started = now()
        let watched = try await remoteWatched()
        let base = Self.dates(prefs.value([String: Date].self, for: Keys.historyBase))
        let all = try await store.recent(limit: 100_000).filter { Self.syncsHistory($0.key) }
        let local = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        let plan = HistoryReconcile.plan(local: local, remote: watched, base: base)
        report.applied += try await store.importCompleted(plan.importLocal)
        for key in plan.markLocalUnwatched.sorted() {
            let old = local[key]
            _ = try await store.save(WatchProgress(key: key, position: 0, duration: old?.duration, updatedAt: now()))
            report.applied += 1
        }
        let adds = plan.addRemote.sorted { $0.key < $1.key }.compactMap { key, at in
            local[key].map { p -> WatchProgress in var p = p; p.updatedAt = at; return p }
        }
        for batch in adds.chunked(500) {
            _ = try await client.post("sync/history", TraktHistory(Array(batch)))
            report.pushed += batch.count
        }
        if !plan.removeRemote.isEmpty {
            _ = try await client.post("sync/history/remove", TraktEpisodeItems(plan.removeRemote))
            report.pushed += plan.removeRemote.count
        }
        prefs.set(Self.raw(plan.agreed), for: Keys.historyBase)
        prefs.set(started, for: Keys.historyCursor)
    }

    static func dates(_ raw: [String: Date]?) -> [MediaKey: Date]? {
        raw.map { Dictionary(uniqueKeysWithValues: $0.map { (MediaKey(rawValue: $0.key), $0.value) }) }
    }

    static func raw(_ dates: [MediaKey: Date]) -> [String: Date] {
        Dictionary(uniqueKeysWithValues: dates.map { ($0.key.rawValue, $0.value) })
    }

    /// TMDB-matched movies and episodes take part in history sync.
    static func syncsHistory(_ key: MediaKey) -> Bool {
        key.tmdbID != nil && (key.seriesKey != nil || key.isMovie)
    }

    private func remoteWatched() async throws -> [MediaKey: Date] {
        struct Movie: Decodable { let last_watched_at: String?; let movie: TraktMedia }
        struct Show: Decodable {
            struct Season: Decodable {
                struct Episode: Decodable { let number: Int; let last_watched_at: String? }
                let number: Int; let episodes: [Episode]
            }
            let show: TraktMedia; let seasons: [Season]?
        }
        var out: [MediaKey: Date] = [:]
        for m in try decode([Movie].self, try await client.get("sync/watched/movies")) {
            guard let id = m.movie.ids.tmdb, let at = m.last_watched_at.flatMap(TraktDate.parse) else { continue }
            out[.movie(tmdbID: id)] = at
        }
        for s in try decode([Show].self, try await client.get("sync/watched/shows")) {
            guard let id = s.show.ids.tmdb else { continue }
            for season in s.seasons ?? [] where season.number > 0 {
                for ep in season.episodes {
                    guard let at = ep.last_watched_at.flatMap(TraktDate.parse) else { continue }
                    out[.episode(seriesID: id, season: season.number, episode: ep.number)] = at
                }
            }
        }
        return out
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw TraktError.decoding(String(describing: T.self)) }
    }

    enum Keys {
        static let watchlistBase = "bluebox.trakt.watchlistBase"
        static let historyCursor = "bluebox.trakt.historyCursor"
        static let historyBase = "bluebox.trakt.historyBase"
        static let ratingsBase = "bluebox.trakt.ratingsBase"
        static let ratingsCursor = "bluebox.trakt.ratingsCursor"
        /// [MediaKey: Date]: plays Trakt should hear about (scrobbles that couldn't be sent).
        static let outbox = "bluebox.trakt.outbox"
    }

    // MARK: Ratings

    /// Ratings here (1–10). Setting one marks it for the next sync.
    public func rating(for key: MediaKey) -> Int? { ratings.all()[key]?.rating }

    public func setRating(_ rating: Int?, for key: MediaKey) {
        ratings.set(rating.map { min(max($0, 1), 10) }, for: key, at: now())
    }

    private func syncRatings(_ report: inout Report) async throws {
        let started = now()
        let remote = try await remoteRatings()
        let local = ratings.all()
        let base = Self.dates(prefs.value([String: Date].self, for: Keys.ratingsBase))
        let plan = RatingsReconcile.plan(local: local, remote: remote, base: base)
        if !plan.setRemote.isEmpty {
            _ = try await client.post("sync/ratings", TraktRatingItems(plan.setRemote.compactMapValues { l in
                l.rating.map { ($0, l.updatedAt) }
            }))
            report.pushed += plan.setRemote.count
        }
        if !plan.removeRemote.isEmpty {
            _ = try await client.post("sync/ratings/remove", TraktRatingItems(Dictionary(uniqueKeysWithValues: plan.removeRemote.map { ($0, (0, started)) })))
            report.pushed += plan.removeRemote.count
        }
        for (key, r) in plan.setLocal { ratings.set(r.rating, for: key, at: r.ratedAt); report.applied += 1 }
        for key in plan.removeLocal { ratings.set(nil, for: key, at: started); report.applied += 1 }
        ratings.dropRemovalMarkers()
        prefs.set(Self.raw(plan.agreed), for: Keys.ratingsBase)
        prefs.set(started, for: Keys.ratingsCursor)
    }

    private func remoteRatings() async throws -> [MediaKey: RemoteRating] {
        struct Entry: Decodable {
            struct Episode: Decodable { let season: Int?; let number: Int? }
            let rated_at: String?; let rating: Int; let type: String?
            let movie: TraktMedia?; let show: TraktMedia?; let episode: Episode?
        }
        var out: [MediaKey: RemoteRating] = [:]
        for kind in ["movies", "shows", "episodes"] {
            for e in try decode([Entry].self, try await client.get("sync/ratings/\(kind)")) {
                let at = e.rated_at.flatMap(TraktDate.parse) ?? .distantPast
                let key: MediaKey?
                switch kind {
                case "movies": key = e.movie?.ids.tmdb.map { .movie(tmdbID: $0) }
                case "shows": key = e.show?.ids.tmdb.map { .series(tmdbID: $0) }
                default:
                    if let id = e.show?.ids.tmdb, let s = e.episode?.season, let n = e.episode?.number {
                        key = .episode(seriesID: id, season: s, episode: n)
                    } else { key = nil }
                }
                if let key { out[key] = RemoteRating(rating: e.rating, ratedAt: at) }
            }
        }
        return out
    }

    // MARK: Scrobbling and the outbox

    public enum ScrobbleAction: String, Sendable { case start, pause, stop }

    /// Tells Trakt what's playing. A stop at 80% or more counts as a play on
    /// Trakt; if it can't be sent (offline, Trakt down), the play is kept and
    /// sent with the next sync. Start and pause are only live status, so a
    /// failed one is dropped.
    public func scrobble(_ action: ScrobbleAction, key: MediaKey, progress: Double) async {
        guard Self.syncsHistory(key) || key.imdbID != nil, await client.isConnected else { return }
        let percent = min(max(progress, 0), 100)
        do {
            try await client.scrobble(action.rawValue, TraktScrobbleBody(key: key, progress: percent))
        } catch {
            guard action == .stop, percent >= 80, Self.syncsHistory(key) else { return }
            var outbox = prefs.value([String: Date].self, for: Keys.outbox) ?? [:]
            outbox[key.rawValue] = now()
            prefs.set(outbox, for: Keys.outbox)
        }
    }

    /// Plays waiting from scrobbles that couldn't be sent.
    public var pendingPlays: Int { (prefs.value([String: Date].self, for: Keys.outbox) ?? [:]).count }

    private func flushOutbox(_ report: inout Report) async throws {
        let outbox = prefs.value([String: Date].self, for: Keys.outbox) ?? [:]
        guard !outbox.isEmpty else { return }
        let plays = outbox.map { WatchProgress(key: MediaKey(rawValue: $0.key), position: 1, duration: 1, isCompleted: true, updatedAt: $0.value) }
        _ = try await client.post("sync/history", TraktHistory(plays))
        report.pushed += plays.count
        prefs.set([String: Date]?.none, for: Keys.outbox)
    }
}

/// Ratings here, with removal markers, in preferences (Trakt syncs the
/// default profile only, like the rest of Trakt sync).
public final class TraktRatingsStore: @unchecked Sendable {
    private let prefs: PreferencesStore
    private let lock = NSLock()
    static let key = "bluebox.trakt.ratings"

    public init(prefs: PreferencesStore) { self.prefs = prefs }

    public func all() -> [MediaKey: LocalRating] {
        lock.withLock {
            let raw = prefs.value([String: LocalRating].self, for: Self.key) ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.map { (MediaKey(rawValue: $0.key), $0.value) })
        }
    }

    public func set(_ rating: Int?, for key: MediaKey, at date: Date) {
        lock.withLock {
            var raw = prefs.value([String: LocalRating].self, for: Self.key) ?? [:]
            raw[key.rawValue] = LocalRating(rating: rating, updatedAt: date)
            prefs.set(raw, for: Self.key)
        }
    }

    /// Once removals have reached Trakt, the markers aren't needed.
    func dropRemovalMarkers() {
        lock.withLock {
            let raw = (prefs.value([String: LocalRating].self, for: Self.key) ?? [:]).filter { $0.value.rating != nil }
            prefs.set(raw, for: Self.key)
        }
    }
}

/// The watchlist three-way merge, kept pure for testing.
public enum WatchlistReconcile {
    public struct Plan: Equatable, Sendable {
        public var addRemote: Set<MediaKey> = []
        public var removeRemote: Set<MediaKey> = []
        public var addLocal: Set<MediaKey> = []
        public var removeLocal: Set<MediaKey> = []
        /// What both sides hold once the plan is applied.
        public var agreed: Set<MediaKey> = []
    }

    /// `base` is what both sides held after the last sync, or nil before the first.
    public static func plan(local: Set<MediaKey>, remote: Set<MediaKey>, base: Set<MediaKey>?) -> Plan {
        var p = Plan()
        guard let base else {
            p.addRemote = local.subtracting(remote)
            p.addLocal = remote.subtracting(local)
            p.agreed = local.union(remote)
            return p
        }
        p.addRemote = local.subtracting(remote).subtracting(base)
        p.removeLocal = local.intersection(base).subtracting(remote)
        p.addLocal = remote.subtracting(local).subtracting(base)
        p.removeRemote = remote.intersection(base).subtracting(local)
        p.agreed = local.union(p.addLocal).subtracting(p.removeLocal)
        return p
    }
}

// MARK: Wire format

struct TraktIDs: Codable, Sendable {
    var tmdb: Int?
    var imdb: String?
    init(tmdb: Int? = nil, imdb: String? = nil) { self.tmdb = tmdb; self.imdb = imdb }

    /// IDs of a movie or series key (TMDB or IMDb).
    init?(_ key: MediaKey) {
        if let id = key.tmdbID { self.init(tmdb: id) } else if let id = key.imdbID { self.init(imdb: id) } else { return nil }
    }
}

/// `/scrobble/*` body: a movie, or a show plus the episode's numbers.
struct TraktScrobbleBody: Encodable {
    struct Media: Encodable { let ids: TraktIDs }
    struct Episode: Encodable { let season: Int; let number: Int }
    let movie: Media?
    let show: Media?
    let episode: Episode?
    let progress: Double

    init(key: MediaKey, progress: Double) {
        self.progress = (progress * 100).rounded() / 100
        if let series = key.seriesKey, let n = key.episodeNumbers, let ids = TraktIDs(series) {
            movie = nil; show = Media(ids: ids); episode = Episode(season: n.season, number: n.episode)
        } else {
            movie = TraktIDs(key).map(Media.init); show = nil; episode = nil
        }
    }
}

/// Movies, shows and episodes by ID for `/sync/history/remove`.
struct TraktEpisodeItems: Encodable {
    struct Item: Encodable { let ids: TraktIDs }
    struct EpisodeNumber: Encodable { let number: Int }
    struct Season: Encodable { let number: Int; let episodes: [EpisodeNumber] }
    struct Show: Encodable { let ids: TraktIDs; let seasons: [Season] }
    let movies: [Item]
    let shows: [Show]

    init(_ keys: Set<MediaKey>) {
        movies = keys.filter(\.isMovie).sorted().compactMap { TraktIDs($0).map(Item.init) }
        var shows: [Int: [Int: [Int]]] = [:]
        for key in keys {
            guard let id = key.seriesKey?.tmdbID, let n = key.episodeNumbers else { continue }
            shows[id, default: [:]][n.season, default: []].append(n.episode)
        }
        self.shows = shows.keys.sorted().map { id in
            Show(ids: TraktIDs(tmdb: id), seasons: shows[id]!.keys.sorted().map { s in
                Season(number: s, episodes: shows[id]![s]!.sorted().map(EpisodeNumber.init))
            })
        }
    }
}

/// `/sync/ratings` (and `/remove`) body: movies, shows, and episodes nested by show and season.
struct TraktRatingItems: Encodable {
    struct Rated: Encodable { let ids: TraktIDs; let rating: Int?; let rated_at: String? }
    struct RatedEpisode: Encodable { let number: Int; let rating: Int?; let rated_at: String? }
    struct Season: Encodable { let number: Int; let episodes: [RatedEpisode] }
    struct Show: Encodable {
        let ids: TraktIDs; let rating: Int?; let rated_at: String?; let seasons: [Season]?
    }
    let movies: [Rated]
    let shows: [Show]

    /// `ratings` is key → (rating, when). A rating of 0 means "remove" (no rating sent).
    init(_ ratings: [MediaKey: (Int, Date)]) {
        func fields(_ r: (Int, Date)) -> (Int?, String?) { r.0 > 0 ? (r.0, TraktDate.format(r.1)) : (nil, nil) }
        movies = ratings.filter { $0.key.isMovie }.sorted { $0.key < $1.key }.compactMap { key, r in
            TraktIDs(key).map { let f = fields(r); return Rated(ids: $0, rating: f.0, rated_at: f.1) }
        }
        var showRatings: [Int: (Int, Date)] = [:]
        var episodes: [Int: [Int: [RatedEpisode]]] = [:]
        for (key, r) in ratings {
            if key.isSeries, let id = key.tmdbID {
                showRatings[id] = r
            } else if let id = key.seriesKey?.tmdbID, let n = key.episodeNumbers {
                let f = fields(r)
                episodes[id, default: [:]][n.season, default: []].append(RatedEpisode(number: n.episode, rating: f.0, rated_at: f.1))
            }
        }
        shows = Set(showRatings.keys).union(episodes.keys).sorted().map { id in
            let f = showRatings[id].map(fields) ?? (nil, nil)
            let seasons = episodes[id].map { s in
                s.keys.sorted().map { Season(number: $0, episodes: s[$0]!.sorted { $0.number < $1.number }) }
            }
            return Show(ids: TraktIDs(tmdb: id), rating: f.0, rated_at: f.1, seasons: seasons)
        }
    }
}

struct TraktMedia: Decodable, Sendable {
    let title: String?
    let year: Int?
    let ids: TraktIDs
}

struct TraktListItem: Decodable, Sendable {
    let type: String
    let movie: TraktMedia?
    let show: TraktMedia?

    /// A bare title from the list entry, used when nothing better is available.
    var title: Title? {
        let (media, kind): (TraktMedia?, TitleKind) = type == "movie" ? (movie, .movie) : (show, .series)
        guard let media, let id = media.ids.tmdb, type == "movie" || type == "show" else { return nil }
        let key: MediaKey = kind == .movie ? .movie(tmdbID: id) : .series(tmdbID: id)
        let date = media.year.flatMap { DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt, year: $0, month: 1, day: 1).date }
        return Title(key: key, kind: kind, name: media.title ?? "Untitled", releaseDate: date)
    }
}

/// `{ movies: [...], shows: [...] }` for watchlist add/remove.
struct TraktItems: Encodable {
    struct Item: Encodable { let ids: TraktIDs }
    let movies: [Item]
    let shows: [Item]
    init(_ keys: Set<MediaKey>) {
        movies = keys.filter { $0.rawValue.hasPrefix("tmdb:movie:") }.sorted().compactMap { $0.tmdbID.map { Item(ids: TraktIDs(tmdb: $0)) } }
        shows = keys.filter { $0.rawValue.hasPrefix("tmdb:tv:") }.sorted().compactMap { $0.tmdbID.map { Item(ids: TraktIDs(tmdb: $0)) } }
    }
}

/// `/sync/history` body: movies with a watch time, episodes grouped by show and season.
struct TraktHistory: Encodable {
    struct Movie: Encodable { let ids: TraktIDs; let watched_at: String }
    struct Episode: Encodable { let number: Int; let watched_at: String }
    struct Season: Encodable { let number: Int; let episodes: [Episode] }
    struct Show: Encodable { let ids: TraktIDs; let seasons: [Season] }
    let movies: [Movie]
    let shows: [Show]

    init(_ items: [WatchProgress]) {
        var movies: [Movie] = []
        var shows: [Int: [Int: [Episode]]] = [:]
        for p in items.sorted(by: { $0.key < $1.key }) {
            let at = TraktDate.format(p.updatedAt)
            if let series = p.key.seriesKey?.tmdbID, let n = p.key.episodeNumbers {
                shows[series, default: [:]][n.season, default: []].append(Episode(number: n.episode, watched_at: at))
            } else if let id = p.key.tmdbID {
                movies.append(Movie(ids: TraktIDs(tmdb: id), watched_at: at))
            }
        }
        self.movies = movies
        self.shows = shows.keys.sorted().map { id in
            Show(ids: TraktIDs(tmdb: id), seasons: shows[id]!.keys.sorted().map { Season(number: $0, episodes: shows[id]![$0]!) })
        }
    }
}

enum TraktDate {
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}
