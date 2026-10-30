import Domain
import Foundation

/// Browsing without a TMDB key: Stremio's public Cinemeta catalogue
/// (https://v3-cinemeta.strem.io), which needs no key.
///
/// Titles are keyed by IMDb ID (`imdb:movie:tt…`, `imdb:tv:tt…:s1e2`), which
/// is also what Stremio add-ons look releases up by. Cinemeta knows cast and
/// crew by name only, so there are no person pages, and its trailers come
/// without a type or language.
public struct CinemetaMetadataProvider: MetadataProvider, MetadataExtras {
    public static let defaultBase = URL(string: "https://v3-cinemeta.strem.io")!

    let base: URL
    let http: any HTTPClient
    let now: @Sendable () -> Date
    private let metas = MetaCache()
    /// Cinemeta pages hold about 50 titles; `skip` moves through them.
    static let pageSize = 50
    /// Cinemeta catalogues run out after a few hundred titles.
    static let maxPages = 20

    public init(http: any HTTPClient = URLSessionHTTPClient(), base: URL = CinemetaMetadataProvider.defaultBase,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.http = http; self.base = base; self.now = now
    }

    // MARK: Lists

    public func list(_ list: CatalogList, page: Int) async throws -> Page<Title> {
        switch list {
        case .trending:
            async let movies = catalog("movie", "top", page: page)
            async let series = catalog("series", "top", page: page)
            return try await Self.interleave(movies, series, page: page)
        case .popularMovies: return try await catalog("movie", "top", page: page)
        case .popularSeries: return try await catalog("series", "top", page: page)
        case .topRated: return try await catalog("movie", "imdbRating", page: page)
        }
    }

    public func search(_ query: String, page: Int) async throws -> Page<Title> {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, page == 1 else { return Page(items: [], page: page, totalPages: page) }
        async let movies = catalog("movie", "top", extra: ["search": q], page: 1)
        async let series = catalog("series", "top", extra: ["search": q], page: 1)
        let merged = try await Self.interleave(movies, series, page: 1)
        return Page(items: merged.items, page: 1, totalPages: 1)
    }

    public func discover(genre: Genre, kind: TitleKind, page: Int) async throws -> Page<Title> {
        try await catalog(kind == .movie ? "movie" : "series", "top", extra: ["genre": genre.name], page: page)
    }

    public func genres() async throws -> [Genre] { Self.genreList }

    /// Cinemeta's genres with stable made-up IDs (it has names only).
    static let genreNames = [
        "Action", "Adventure", "Animation", "Biography", "Comedy", "Crime", "Documentary", "Drama", "Family", "Fantasy",
        "History", "Horror", "Mystery", "Romance", "Sci-Fi", "Sport", "Thriller", "War", "Western", "Reality-TV",
        "Talk-Show", "Game-Show",
    ]
    static let genreList = genreNames.enumerated().map { Genre(id: 9000 + $0.offset, name: $0.element) }

    // MARK: Details

    public func detail(for key: MediaKey) async throws -> TitleDetail {
        let meta = try await meta(for: key)
        guard let title = CinemetaMapping.title(meta, fallbackType: key.isMovie ? "movie" : "series") else {
            throw MetadataError.notFound
        }
        let seasons = Dictionary(grouping: meta.videos?.compactMap(\.value).filter { $0.season != nil } ?? []) { $0.season! }
            .map { number, eps in
                SeasonSummary(number: number, name: number == 0 ? "Specials" : "Season \(number)", episodeCount: eps.count)
            }
            .sorted { ($0.number == 0 ? Int.max : $0.number) < ($1.number == 0 ? Int.max : $1.number) }
        let credits = CinemetaMapping.credits(meta)
        return TitleDetail(
            title: title, runtimeMinutes: CinemetaMapping.minutes(meta.runtime),
            genres: (meta.genres ?? meta.genre ?? []).map(CinemetaMapping.genre),
            cast: credits.cast, crew: credits.directors + credits.creators + credits.writers,
            logo: meta.logo.map { Artwork(.logo, path: $0) }, seasons: title.kind == .series ? seasons : [],
            imdbID: meta.imdbID ?? meta.id
        )
    }

    public func season(_ number: Int, of seriesKey: MediaKey) async throws -> Season {
        guard let imdb = seriesKey.imdbID, seriesKey.isSeries else { throw MetadataError.notFound }
        let meta = try await meta(for: seriesKey)
        let episodes = (meta.videos ?? []).compactMap(\.value)
            .filter { $0.season == number }
            .compactMap { CinemetaMapping.episode($0, seriesIMDbID: imdb) }
            .sorted { $0.number < $1.number }
        guard !episodes.isEmpty else { throw MetadataError.notFound }
        return Season(seriesKey: seriesKey, number: number, name: number == 0 ? "Specials" : "Season \(number)",
                      episodes: episodes)
    }

    public func imageURL(for artwork: Artwork, width: Int) -> URL? {
        guard artwork.path.hasPrefix("http") else { return nil }
        return URL(string: CinemetaMapping.sized(artwork.path, width: width))
    }

    // MARK: Extras

    public func videos(for key: MediaKey, season: Int?) async throws -> [TitleVideo] {
        guard season == nil else { return [] }
        let meta = try await meta(for: key.seriesKey ?? key)
        return CinemetaMapping.videos(meta)
    }

    public func airing(for seriesKey: MediaKey) async throws -> AiringInfo {
        guard let imdb = seriesKey.imdbID, seriesKey.isSeries else { throw MetadataError.notFound }
        let meta = try await meta(for: seriesKey, maxAge: 0)
        return CinemetaMapping.airing(meta, seriesKey: seriesKey, imdbID: imdb, now: now())
    }

    public func credits(for key: MediaKey) async throws -> TitleCredits {
        CinemetaMapping.credits(try await meta(for: key))
    }

    // MARK: Requests

    func catalog(_ type: String, _ id: String, extra: [String: String] = [:], page: Int) async throws -> Page<Title> {
        let page = max(1, page)
        guard page <= Self.maxPages else { return Page(items: [], page: page, totalPages: page) }
        var extra = extra
        if page > 1 { extra["skip"] = "\((page - 1) * Self.pageSize)" }
        let list = try await get(CinemetaCatalog.self, path: Self.catalogPath(type: type, id: id, extra: extra))
        let items = (list.metas ?? []).compactMap(\.value).compactMap { CinemetaMapping.title($0, fallbackType: type) }
        let more = items.count >= Self.pageSize - 5 && page < Self.maxPages
        return Page(items: items, page: page, totalPages: more ? page + 1 : page)
    }

    /// `/catalog/movie/top/genre=Sci-Fi&skip=50.json`, each value percent-encoded.
    static func catalogPath(type: String, id: String, extra: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        let extras = extra.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
        return extras.isEmpty ? "/catalog/\(type)/\(id).json" : "/catalog/\(type)/\(id)/\(extras).json"
    }

    func meta(for key: MediaKey, maxAge: TimeInterval = 300) async throws -> CinemetaMeta {
        guard let imdb = (key.seriesKey ?? key).imdbID else { throw MetadataError.notFound }
        let type = key.isMovie ? "movie" : "series"
        let cacheKey = "\(type)/\(imdb)"
        if maxAge > 0, let hit = await metas.value(cacheKey, maxAge: maxAge, now: now()) { return hit }
        let response = try await get(CinemetaMetaResponse.self, path: "/meta/\(type)/\(imdb).json")
        guard let meta = response.meta else { throw MetadataError.notFound }
        await metas.store(meta, for: cacheKey, at: now())
        return meta
    }

    private func get<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        // Built as a string so the percent-encoding in `path` is kept as is.
        guard let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw MetadataError.notFound
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch let e as URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: throw MetadataError.offline
            case .cancelled: throw CancellationError()
            default: throw MetadataError.transport(e.localizedDescription)
            }
        }
        switch response.statusCode {
        case 200..<300:
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw MetadataError.decoding(String(describing: error)) }
        case 404: throw MetadataError.notFound
        case 429: throw MetadataError.rateLimited(retryAfter: nil)
        default: throw MetadataError.server(status: response.statusCode)
        }
    }

    /// Alternates two lists (movies, shows), dropping repeats.
    static func interleave(_ a: Page<Title>, _ b: Page<Title>, page: Int) -> Page<Title> {
        var out: [Title] = []
        var seen = Set<MediaKey>()
        for i in 0..<max(a.items.count, b.items.count) {
            for list in [a.items, b.items] where i < list.count && seen.insert(list[i].key).inserted { out.append(list[i]) }
        }
        return Page(items: out, page: page, totalPages: max(a.totalPages, b.totalPages))
    }

    private actor MetaCache {
        private var entries: [String: (meta: CinemetaMeta, at: Date)] = [:]
        func value(_ key: String, maxAge: TimeInterval, now: Date) -> CinemetaMeta? {
            guard let e = entries[key], now.timeIntervalSince(e.at) < maxAge else { return nil }
            return e.meta
        }
        func store(_ meta: CinemetaMeta, for key: String, at date: Date) {
            if entries.count > 100 { entries = [:] }
            entries[key] = (meta, date)
        }
    }
}

// MARK: - Wire format

/// Decodes to nil instead of failing the whole list when one entry is odd.
struct Lenient<T: Decodable & Sendable>: Decodable, Sendable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct CinemetaCatalog: Decodable, Sendable { let metas: [Lenient<CinemetaMeta>]? }
struct CinemetaMetaResponse: Decodable, Sendable { let meta: CinemetaMeta? }

struct CinemetaMeta: Decodable, Sendable {
    struct Trailer: Decodable, Sendable { let source: String?; let type: String? }
    struct TrailerStream: Decodable, Sendable { let title: String?; let ytId: String? }
    struct Video: Decodable, Sendable {
        let id: String?
        let name: String?
        let title: String?
        let season: Int?
        let episode: Int?
        let number: Int?
        let overview: String?
        let description: String?
        let released: String?
        let firstAired: String?
        let thumbnail: String?
    }

    let id: String?
    let imdbID: String?
    let type: String?
    let name: String?
    let description: String?
    let releaseInfo: String?
    let released: String?
    let year: String?
    let runtime: String?
    let genres: [String]?
    let genre: [String]?
    let imdbRating: String?
    let poster: String?
    let background: String?
    let logo: String?
    let cast: [String]?
    let director: [String]?
    let writer: [String]?
    let status: String?
    let trailers: [Trailer]?
    let trailerStreams: [TrailerStream]?
    let videos: [Lenient<Video>]?
    /// The TMDB ID Cinemeta knows for it (`CatalogKeyBridge`).
    let moviedbID: Int?

    enum CodingKeys: String, CodingKey {
        case moviedbID = "moviedb_id"
        case id, imdbID = "imdb_id", type, name, description, releaseInfo, released, year, runtime, genres, genre
        case imdbRating, poster, background, logo, cast, director, writer, status, trailers, trailerStreams, videos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ k: CodingKeys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s }
            if let n = try? c.decodeIfPresent(Double.self, forKey: k) { return String(n) }
            return nil
        }
        func strings(_ k: CodingKeys) -> [String]? {
            if let a = try? c.decodeIfPresent([String].self, forKey: k) { return a }
            return string(k).map { [$0] }
        }
        id = string(.id); imdbID = string(.imdbID); type = string(.type); name = string(.name)
        description = string(.description); releaseInfo = string(.releaseInfo); released = string(.released)
        year = string(.year); runtime = string(.runtime); genres = strings(.genres); genre = strings(.genre)
        imdbRating = string(.imdbRating); poster = string(.poster); background = string(.background); logo = string(.logo)
        cast = strings(.cast); director = strings(.director); writer = strings(.writer); status = string(.status)
        trailers = try? c.decodeIfPresent([Trailer].self, forKey: .trailers)
        trailerStreams = try? c.decodeIfPresent([TrailerStream].self, forKey: .trailerStreams)
        videos = try? c.decodeIfPresent([Lenient<Video>].self, forKey: .videos)
        moviedbID = string(.moviedbID).flatMap { SafeNumber.int64($0, in: 1...Int64(Int32.max)) }.map { Int($0) }
    }
}

// MARK: - Mapping

enum CinemetaMapping {
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        return TMDBMapping.date(String(s.prefix(10)))
    }

    /// "2008–2013" or "1999" → 1 January of the first year.
    static func yearDate(_ s: String?) -> Date? {
        guard let s, let year = Int(s.prefix(4)) else { return nil }
        return DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt, year: year, month: 1, day: 1).date
    }

    static func minutes(_ runtime: String?) -> Int? {
        guard let runtime else { return nil }
        let digits = runtime.prefix { $0.isNumber }
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }

    static func genre(_ name: String) -> Genre {
        CinemetaMetadataProvider.genreList.first { $0.name == name }
            ?? Genre(id: 9500 + abs(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 400 }), name: name)
    }

    static func title(_ m: CinemetaMeta, fallbackType: String) -> Title? {
        let imdb = m.imdbID ?? m.id
        guard let imdb, imdb.hasPrefix("tt"), let name = m.name, !name.isEmpty else { return nil }
        let isMovie = (m.type ?? fallbackType) == "movie"
        let genreIDs = (m.genres ?? m.genre ?? []).map { genre($0).id }
        return Title(key: isMovie ? .movie(imdbID: imdb) : .series(imdbID: imdb), kind: isMovie ? .movie : .series,
                     name: name, overview: m.description ?? "",
                     releaseDate: date(m.released) ?? yearDate(m.releaseInfo ?? m.year), genreIDs: genreIDs,
                     voteAverage: m.imdbRating.flatMap(Double.init),
                     poster: m.poster.map { Artwork(.poster, path: $0) }, backdrop: m.background.map { Artwork(.backdrop, path: $0) })
    }

    static func episode(_ v: CinemetaMeta.Video, seriesIMDbID: String) -> Episode? {
        guard let season = v.season, let number = v.episode ?? v.number else { return nil }
        return Episode(key: .episode(imdbSeriesID: seriesIMDbID, season: season, episode: number),
                       seasonNumber: season, number: number, name: v.name ?? v.title ?? "Episode \(number)",
                       overview: v.overview ?? v.description ?? "", airDate: date(v.released ?? v.firstAired),
                       still: v.thumbnail.map { Artwork(.still, path: $0) })
    }

    /// Cast names only; IDs are negative and stable within the title, and
    /// there are no person pages behind them.
    static func credits(_ m: CinemetaMeta) -> TitleCredits {
        var next = 0
        func people(_ names: [String]?, role: String) -> [CreditPerson] {
            (names ?? []).filter { !$0.isEmpty }.map { name in
                next -= 1
                return CreditPerson(id: next, name: name, role: role)
            }
        }
        let isMovie = m.type != "series"
        let directors = people(m.director, role: "Director")
        let writers = people(m.writer, role: isMovie ? "Writer" : "Creator")
        return TitleCredits(directors: isMovie ? directors : [], creators: isMovie ? [] : writers,
                            writers: isMovie ? writers : [], cast: people(m.cast, role: ""),
                            crew: isMovie ? [] : directors, hasPersonPages: false)
    }

    static func videos(_ m: CinemetaMeta) -> [TitleVideo] {
        let keys = (m.trailerStreams ?? []).compactMap(\.ytId) + (m.trailers ?? []).compactMap(\.source)
        var seen = Set<String>()
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }.enumerated().map { i, key in
            TitleVideo(id: "cinemeta-\(key)", youtubeKey: key, name: i == 0 ? "Trailer" : "Trailer \(i + 1)",
                       kind: .trailer, isOfficial: true)
        }
    }

    static func airing(_ m: CinemetaMeta, seriesKey: MediaKey, imdbID: String, now: Date) -> AiringInfo {
        let episodes = (m.videos ?? []).compactMap(\.value).filter { ($0.season ?? 0) > 0 }
            .compactMap { episode($0, seriesIMDbID: imdbID) }
            .filter { $0.airDate != nil }
            .sorted { ($0.airDate!, $0.seasonNumber, $0.number) < ($1.airDate!, $1.seasonNumber, $1.number) }
        let last = episodes.last { $0.airDate! <= now }
        let next = episodes.first { $0.airDate! > now }
        return AiringInfo(seriesKey: seriesKey, status: m.status, lastEpisode: last, nextEpisode: next)
    }

    /// Metahub images come in small, medium and large.
    static func sized(_ url: String, width: Int) -> String {
        guard url.contains("images.metahub.space") else { return url }
        let size = width <= 200 ? "small" : width <= 700 ? "medium" : "large"
        return url.replacingOccurrences(of: #"/(small|medium|large)/"#, with: "/\(size)/", options: .regularExpression)
    }
}
