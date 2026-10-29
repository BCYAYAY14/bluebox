import Domain
import Foundation
@testable import Metadata
import Testing
import TestingSupport

@Suite struct TMDBServiceTests {
    func service(_ http: FixtureHTTPClient, credential: TMDBCredential? = .readAccessToken("tok"), retries: Int = 2) -> TMDBService {
        TMDBService(credential: credential, http: http, maxRetries: retries, sleep: { _ in })
    }

    @Test func credentialDetection() {
        #expect(TMDBCredential("0123456789abcdef0123456789abcdef") == .apiKey("0123456789abcdef0123456789abcdef"))
        #expect(TMDBCredential("  eyJhbGciOiJIUzI1NiJ9.x.y \n") == .readAccessToken("eyJhbGciOiJIUzI1NiJ9.x.y"))
        #expect(TMDBCredential("   ") == nil)
    }

    @Test func bearerTokenGoesInHeaderNotURL() async throws {
        let http = FixtureHTTPClient()
        http.on("trending/all/week", .fixture("tmdb_trending"))
        _ = try await service(http).list(.trending, page: 1)
        let req = try #require(http.requests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(!req.url!.absoluteString.contains("tok"))
        #expect(req.url!.absoluteString.contains("language=en-US"))
    }

    @Test func apiKeyGoesInQuery() async throws {
        let http = FixtureHTTPClient()
        http.on("trending/all/week", .fixture("tmdb_trending"))
        _ = try await service(http, credential: .apiKey("k")).list(.trending, page: 1)
        let req = try #require(http.requests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.url!.query!.contains("api_key=k"))
    }

    @Test func trendingMapsMoviesAndSeriesAndDropsPeople() async throws {
        let http = FixtureHTTPClient()
        http.on("trending/all/week", .fixture("tmdb_trending"))
        let page = try await service(http).list(.trending, page: 1)
        #expect(page.items.map(\.key) == [.movie(tmdbID: 133701), .series(tmdbID: 1399), .movie(tmdbID: 555)])
        #expect(page.totalPages == 500)  // capped
        let tos = page.items[0]
        #expect(tos.year == 2012)
        #expect(tos.poster == Artwork(.poster, path: "/p1.jpg"))
        let got = page.items[1]
        #expect(got.kind == .series)
        #expect(got.backdrop == nil)
        #expect(page.items[2].releaseDate == nil)  // "" date
    }

    @Test func listEndpointsWithoutMediaTypeUseFallbackKind() async throws {
        let http = FixtureHTTPClient()
        http.on("movie/popular", .fixture("tmdb_popular_movies"))
        let page = try await service(http).list(.popularMovies, page: 2)
        #expect(page.items.first?.kind == .movie)
        #expect(page.page == 2 && page.hasMore)
    }

    @Test func movieDetail() async throws {
        let http = FixtureHTTPClient()
        http.on("movie/133701", .fixture("tmdb_movie_detail"))
        let d = try await service(http).detail(for: .movie(tmdbID: 133701))
        #expect(d.title.name == "Tears of Steel")
        #expect(d.runtimeMinutes == 12)
        #expect(d.tagline == nil)  // empty string normalized
        #expect(d.cast.map(\.name) == ["Derek de Lint", "Vanja Rukavina"])  // sorted by order
        #expect(d.crew.map(\.role) == ["Director", "Original Music Composer"])  // deduped, filtered
        #expect(d.logo?.path == "/logo-en.png")
        #expect(d.related.first?.key == .movie(tmdbID: 45745))
        #expect(d.certification == "PG-13")
        #expect(d.imdbID == "tt2285752")
        #expect(d.seasons.isEmpty)
        let q = http.requests[0].url!.query!
        #expect(q.contains("append_to_response=credits,images,recommendations,release_dates"))
    }

    @Test func seriesDetailPutsSpecialsLast() async throws {
        let http = FixtureHTTPClient()
        http.on("tv/1399", .fixture("tmdb_tv_detail"))
        let d = try await service(http).detail(for: .series(tmdbID: 1399))
        #expect(d.seasons.map(\.number) == [1, 2, 0])
        #expect(d.logo?.path == "/neutral.png")
        #expect(d.certification == "TV-MA")
        #expect(d.runtimeMinutes == 60)
        #expect(d.related.first?.kind == .series)
        #expect(d.imdbID == "tt0944947")
        #expect(http.requests[0].url!.query!.contains("external_ids"))
    }

    @Test func season() async throws {
        let http = FixtureHTTPClient()
        http.on("tv/1399/season/1", .fixture("tmdb_season"))
        let s = try await service(http).season(1, of: .series(tmdbID: 1399))
        #expect(s.episodes.count == 2)
        #expect(s.episodes[0].key == .episode(seriesID: 1399, season: 1, episode: 1))
        #expect(s.episodes[0].still?.path == "/e1.jpg")
        #expect(s.episodes[1].still == nil)
    }

    @Test func genresAreDeduplicated() async throws {
        let http = FixtureHTTPClient()
        http.on("genre/movie/list", .fixture("tmdb_genres_movie"))
        http.on("genre/tv/list", .fixture("tmdb_genres_tv"))
        let g = try await service(http).genres()
        #expect(g.map(\.id).sorted() == [18, 28, 10759])
    }

    @Test func emptySearchMakesNoRequest() async throws {
        let http = FixtureHTTPClient()
        let page = try await service(http).search("   ", page: 1)
        #expect(page.items.isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test func missingCredential() async {
        await #expect(throws: MetadataError.missingCredentials) {
            try await service(FixtureHTTPClient(), credential: nil).list(.trending, page: 1)
        }
    }

    @Test func statusMapping() async {
        let http = FixtureHTTPClient()
        http.on("movie/1", .init(status: 401))
        http.on("movie/2", .init(status: 404))
        http.on("movie/3", .init(status: 418))
        let s = service(http)
        await #expect(throws: MetadataError.unauthorized) { try await s.detail(for: .movie(tmdbID: 1)) }
        await #expect(throws: MetadataError.notFound) { try await s.detail(for: .movie(tmdbID: 2)) }
        await #expect(throws: MetadataError.server(status: 418)) { try await s.detail(for: .movie(tmdbID: 3)) }
    }

    @Test func retriesRateLimitThenSucceeds() async throws {
        let http = FixtureHTTPClient()
        http.on("trending/all/week", .init(status: 429, headers: ["Retry-After": "1"]), .fixture("tmdb_trending"))
        let page = try await service(http).list(.trending, page: 1)
        #expect(page.items.count == 3)
        #expect(http.requests.count == 2)
    }

    @Test func rateLimitGivesUpAfterMaxRetries() async {
        let http = FixtureHTTPClient()
        http.on("trending/all/week", .init(status: 429, headers: ["Retry-After": "3"]))
        await #expect(throws: MetadataError.rateLimited(retryAfter: 3)) {
            try await service(http, retries: 1).list(.trending, page: 1)
        }
        #expect(http.requests.count == 2)
    }

    @Test func offlineIsReportedDistinctly() async {
        let http = FixtureHTTPClient()
        http.error = URLError(.notConnectedToInternet)
        await #expect(throws: MetadataError.offline) { try await service(http).list(.trending, page: 1) }
    }

    @Test func malformedJSONIsDecodingError() async {
        let http = FixtureHTTPClient()
        http.on("trending/all/week", .init(body: Data("{\"nope\":1}".utf8)))
        await #expect {
            try await service(http).list(.trending, page: 1)
        } throws: { ($0 as? MetadataError).map { if case .decoding = $0 { true } else { false } } ?? false }
    }

    @Test func imageURLBuckets() {
        let s = TMDBService(credential: nil)
        #expect(s.imageURL(for: Artwork(.poster, path: "/a.jpg"), width: 300)?.absoluteString == "https://image.tmdb.org/t/p/w342/a.jpg")
        #expect(s.imageURL(for: Artwork(.backdrop, path: "/b.jpg"), width: 2000)?.absoluteString == "https://image.tmdb.org/t/p/original/b.jpg")
        #expect(s.imageURL(for: Artwork(.still, path: "/c.jpg"), width: 1000)?.absoluteString == "https://image.tmdb.org/t/p/w300/c.jpg")
        #expect(s.imageURL(for: Artwork(.poster, path: "https://x.example/p.png"), width: 10)?.host() == "x.example")
    }
}

@Suite struct SampleProviderTests {
    let p = SampleMetadataProvider()

    @Test func seriesSeasonsAndEpisodesAreConsistent() async throws {
        let key = MediaKey.series(tmdbID: 9_100_001)
        let d = try await p.detail(for: key)
        #expect(d.seasons.count == 2)
        let s2 = try await p.season(2, of: key)
        #expect(s2.episodes.count == 8)
        #expect(s2.episodes[0].name == "Return Tide")
        #expect(s2.episodes[0].key.seriesKey == key)
        await #expect(throws: MetadataError.notFound) { try await p.season(3, of: key) }
    }

    @Test func fictionalIDsNeverCollideWithOpenMovies() {
        let ids = SampleMetadataProvider.titles.compactMap(\.key.tmdbID)
        #expect(Set(ids).count == ids.count)
    }

    @Test func searchMatchesNameAndOverview() async throws {
        #expect(try await p.search("steel", page: 1).items.map(\.name) == ["Tears of Steel"])
        #expect(try await p.search("dragon", page: 1).items.map(\.name) == ["Sintel"])
    }
}

@Suite struct OMDbServiceTests {
    @Test func mapsScoresAndCaches() async throws {
        let http = FixtureHTTPClient()
        http.on("/", .fixture("omdb_matrix"))
        let s = OMDbService(apiKey: " key ", http: http)
        let r = try #require(try await s.ratings(imdbID: "tt0133093"))
        #expect(r == ExternalRatings(imdb: "8.7", imdbVotes: "2,206,416", rottenTomatoes: "83%", metacritic: "73"))
        _ = try await s.ratings(imdbID: "tt0133093")
        #expect(http.requests.count == 1)
        let q = URLComponents(url: http.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(q.contains(URLQueryItem(name: "apikey", value: "key")) && q.contains(URLQueryItem(name: "i", value: "tt0133093")))
    }

    @Test func missingValuesAndErrors() async throws {
        let http = FixtureHTTPClient()
        http.on("/", .init(body: Data(#"{"Response":"True","imdbRating":"N/A","Metascore":"N/A","Ratings":[]}"#.utf8)))
        #expect(try await OMDbService(apiKey: "k", http: http).ratings(imdbID: "tt1") == nil)

        let bad = FixtureHTTPClient()
        bad.on("/", .init(status: 401, body: Data(#"{"Response":"False","Error":"Invalid API key!"}"#.utf8)))
        await #expect(throws: MetadataError.unauthorized) { try await OMDbService(apiKey: "k", http: bad).ratings(imdbID: "tt1") }

        let limit = FixtureHTTPClient()
        limit.on("/", .init(body: Data(#"{"Response":"False","Error":"Request limit reached!"}"#.utf8)))
        await #expect(throws: MetadataError.rateLimited(retryAfter: nil)) { try await OMDbService(apiKey: "k", http: limit).ratings(imdbID: "tt1") }

        let missing = FixtureHTTPClient()
        missing.on("/", .init(body: Data(#"{"Response":"False","Error":"Incorrect IMDb ID."}"#.utf8)))
        #expect(try await OMDbService(apiKey: "k", http: missing).ratings(imdbID: "tt1") == nil)
    }
}
