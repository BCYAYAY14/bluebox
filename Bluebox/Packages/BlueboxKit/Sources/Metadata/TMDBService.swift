import Domain
import Foundation

/// TMDB credential. A v4 "API Read Access Token" (a JWT) is sent as a Bearer
/// header; a 32-character v3 API key is sent as the `api_key` query item.
public enum TMDBCredential: Sendable, Hashable {
    case readAccessToken(String)
    case apiKey(String)

    /// Picks the right form for a user-pasted string.
    public init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.count == 32, s.allSatisfy(\.isHexDigit) { self = .apiKey(s) } else { self = .readAccessToken(s) }
    }
}

/// TMDB v3 implementation of `MetadataProvider`.
///
/// - Retries 429 responses honoring `Retry-After` (bounded).
/// - Maps transport errors to `MetadataError` so the UI can show the right state.
/// - Never logs the credential (see `Redactor`).
public struct TMDBService: MetadataProvider {
    public static let apiBase = URL(string: "https://api.themoviedb.org/3/")!
    public static let imageBase = URL(string: "https://image.tmdb.org/t/p/")!

    let credential: TMDBCredential?
    let http: any HTTPClient
    let language: String
    let region: String
    let maxRetries: Int
    let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        credential: TMDBCredential?, http: any HTTPClient = URLSessionHTTPClient(),
        language: String = "en-US", region: String = "US", maxRetries: Int = 2,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.credential = credential; self.http = http; self.language = language; self.region = region
        self.maxRetries = maxRetries; self.sleep = sleep
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: Requests

    func makeRequest(_ path: String, query: [String: String] = [:]) throws -> URLRequest {
        guard let credential else { throw MetadataError.missingCredentials }
        var c = URLComponents(url: Self.apiBase.appending(path: path), resolvingAgainstBaseURL: false)!
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "language", value: language))
        var request: URLRequest
        switch credential {
        case .apiKey(let k):
            items.append(URLQueryItem(name: "api_key", value: k))
            c.queryItems = items
            request = URLRequest(url: c.url!)
        case .readAccessToken(let t):
            c.queryItems = items
            request = URLRequest(url: c.url!)
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return request
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:]) async throws -> T {
        let request = try makeRequest(path, query: query)
        var attempt = 0
        while true {
            try Task.checkCancellation()
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
                do { return try decoder.decode(T.self, from: data) }
                catch {
                    Log.metadata.error("Decode failed for \(Redactor.redact(request.url!), privacy: .public): \(String(describing: error), privacy: .public)")
                    throw MetadataError.decoding(String(describing: error))
                }
            case 401: throw MetadataError.unauthorized
            case 404: throw MetadataError.notFound
            case 429:
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                guard attempt < maxRetries else { throw MetadataError.rateLimited(retryAfter: retryAfter) }
                attempt += 1
                try await sleep(min(retryAfter ?? Double(attempt), 10))
            case 500..<600 where attempt < maxRetries:
                attempt += 1
                try await sleep(Double(attempt))
            default:
                throw MetadataError.server(status: response.statusCode)
            }
        }
    }

    // MARK: MetadataProvider

    public func list(_ list: CatalogList, page: Int) async throws -> Page<Title> {
        let (path, kind): (String, TitleKind?) = switch list {
        case .trending: ("trending/all/week", nil)
        case .popularMovies: ("movie/popular", .movie)
        case .popularSeries: ("tv/popular", .series)
        case .topRated: ("movie/top_rated", .movie)
        }
        return try await titles(path, kind: kind, query: ["page": "\(page)", "region": region])
    }

    public func search(_ query: String, page: Int) async throws -> Page<Title> {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Page(items: [], page: 1, totalPages: 1) }
        return try await titles("search/multi", kind: nil, query: ["query": q, "page": "\(page)", "include_adult": "false"])
    }

    public func discover(genre: Genre, kind: TitleKind, page: Int) async throws -> Page<Title> {
        let path = kind == .movie ? "discover/movie" : "discover/tv"
        return try await titles(path, kind: kind, query: [
            "with_genres": "\(genre.id)", "page": "\(page)", "sort_by": "popularity.desc", "include_adult": "false",
        ])
    }

    public func genres() async throws -> [Genre] {
        async let movie = get(TMDBGenreList.self, "genre/movie/list")
        async let tv = get(TMDBGenreList.self, "genre/tv/list")
        var seen = Set<Int>()
        return try await (movie.genres + tv.genres).compactMap { g in
            seen.insert(g.id).inserted ? Genre(id: g.id, name: g.name) : nil
        }
    }

    public func detail(for key: MediaKey) async throws -> TitleDetail {
        guard let id = key.tmdbID else { throw MetadataError.notFound }
        let lang = String(language.prefix(2))
        let imageLangs = "\(lang),null"
        if key.rawValue.hasPrefix("tmdb:movie:") {
            let d = try await get(TMDBMovieDetail.self, "movie/\(id)", query: [
                "append_to_response": "credits,images,recommendations,release_dates", "include_image_language": imageLangs,
            ])
            let title = Title(
                key: .movie(tmdbID: d.id), kind: .movie, name: d.title, overview: d.overview ?? "",
                releaseDate: TMDBMapping.date(d.releaseDate), genreIDs: (d.genres ?? []).map(\.id),
                voteAverage: d.voteAverage, poster: TMDBMapping.art(.poster, d.posterPath),
                backdrop: TMDBMapping.art(.backdrop, d.backdropPath)
            )
            let people = TMDBMapping.people(d.credits)
            let cert = d.releaseDates?.results.first { $0.iso31661 == region }?
                .releaseDates.compactMap(\.certification).first { !$0.isEmpty }
            return TitleDetail(
                title: title, tagline: d.tagline.flatMap { $0.isEmpty ? nil : $0 }, runtimeMinutes: d.runtime,
                genres: (d.genres ?? []).map { Genre(id: $0.id, name: $0.name) }, cast: people.cast, crew: people.crew,
                logo: TMDBMapping.logo(d.images, language: lang),
                related: (d.recommendations?.results ?? []).compactMap { TMDBMapping.title($0, fallbackKind: .movie) },
                certification: cert, imdbID: TMDBMapping.imdbID(d.imdbId)
            )
        } else {
            let d = try await get(TMDBSeriesDetail.self, "tv/\(id)", query: [
                "append_to_response": "credits,images,recommendations,content_ratings,external_ids", "include_image_language": imageLangs,
            ])
            let title = Title(
                key: .series(tmdbID: d.id), kind: .series, name: d.name, overview: d.overview ?? "",
                releaseDate: TMDBMapping.date(d.firstAirDate), genreIDs: (d.genres ?? []).map(\.id),
                voteAverage: d.voteAverage, poster: TMDBMapping.art(.poster, d.posterPath),
                backdrop: TMDBMapping.art(.backdrop, d.backdropPath)
            )
            let people = TMDBMapping.people(d.credits)
            // Season 0 ("Specials") goes last so the default season is S1.
            let seasons = (d.seasons ?? [])
                .map { SeasonSummary(number: $0.seasonNumber, name: $0.name ?? "Season \($0.seasonNumber)",
                                     episodeCount: $0.episodeCount ?? 0, poster: TMDBMapping.art(.poster, $0.posterPath)) }
                .sorted { ($0.number == 0 ? Int.max : $0.number) < ($1.number == 0 ? Int.max : $1.number) }
            return TitleDetail(
                title: title, tagline: d.tagline.flatMap { $0.isEmpty ? nil : $0 },
                runtimeMinutes: d.episodeRunTime?.first,
                genres: (d.genres ?? []).map { Genre(id: $0.id, name: $0.name) }, cast: people.cast, crew: people.crew,
                logo: TMDBMapping.logo(d.images, language: lang), seasons: seasons,
                related: (d.recommendations?.results ?? []).compactMap { TMDBMapping.title($0, fallbackKind: .series) },
                certification: d.contentRatings?.results.first { $0.iso31661 == region }?.rating,
                imdbID: TMDBMapping.imdbID(d.externalIds?.imdbId)
            )
        }
    }

    public func season(_ number: Int, of seriesKey: MediaKey) async throws -> Season {
        guard let id = seriesKey.tmdbID else { throw MetadataError.notFound }
        let d = try await get(TMDBSeasonDetail.self, "tv/\(id)/season/\(number)")
        let episodes = (d.episodes ?? []).map { e in
            Episode(
                key: .episode(seriesID: id, season: e.seasonNumber, episode: e.episodeNumber),
                seasonNumber: e.seasonNumber, number: e.episodeNumber, name: e.name ?? "Episode \(e.episodeNumber)",
                overview: e.overview ?? "", airDate: TMDBMapping.date(e.airDate), runtimeMinutes: e.runtime,
                still: TMDBMapping.art(.still, e.stillPath)
            )
        }
        return Season(seriesKey: .series(tmdbID: id), number: d.seasonNumber, name: d.name ?? "Season \(number)",
                      overview: d.overview ?? "", episodes: episodes)
    }

    public func imageURL(for artwork: Artwork, width: Int) -> URL? {
        if artwork.path.hasPrefix("http") { return URL(string: artwork.path) }
        return Self.imageBase.appending(path: Self.sizeBucket(for: artwork.kind, width: width)).appending(path: artwork.path)
    }

    /// Picks the smallest TMDB size bucket that is at least `width` pixels.
    static func sizeBucket(for kind: Artwork.Kind, width: Int) -> String {
        let buckets: [Int] = switch kind {
        case .poster: [92, 154, 185, 342, 500, 780]
        case .backdrop: [300, 780, 1280]
        case .logo: [45, 92, 154, 185, 300, 500]
        case .still: [92, 185, 300]
        case .profile: [45, 185]
        }
        if let b = buckets.first(where: { $0 >= width }) { return "w\(b)" }
        // Above the largest bucket: still and profile cap at their max (TMDB has
        // an h632 profile and original, but originals can be huge).
        return kind == .backdrop || kind == .poster ? "original" : "w\(buckets.last!)"
    }

    private func titles(_ path: String, kind: TitleKind?, query: [String: String]) async throws -> Page<Title> {
        let page = try await get(TMDBPage<TMDBListItem>.self, path, query: query)
        // TMDB caps pagination at 500 pages.
        return Page(items: page.results.compactMap { TMDBMapping.title($0, fallbackKind: kind) },
                    page: page.page, totalPages: min(page.totalPages ?? page.page, 500))
    }
}
