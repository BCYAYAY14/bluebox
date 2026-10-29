import Domain
import Foundation
@testable import Metadata
import Testing
import TestingSupport

@Suite struct CinemetaTests {
    static let now = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!

    func provider(_ http: FixtureHTTPClient) -> CinemetaMetadataProvider {
        CinemetaMetadataProvider(http: http, base: URL(string: "https://cinemeta.test")!, now: { Self.now })
    }

    @Test func catalogMapsToIMDbKeyedTitlesAndDropsBadEntries() async throws {
        let http = FixtureHTTPClient()
        http.on("catalog/movie/top.json", .fixture("cinemeta_catalog_movie"))
        let page = try await provider(http).list(.popularMovies, page: 1)
        #expect(page.items.map(\.key) == [.movie(imdbID: "tt1727587"), .movie(imdbID: "tt1254207"), .movie(imdbID: "tt2285752")])
        let sintel = page.items[0]
        #expect(sintel.kind == .movie && sintel.name == "Sintel" && sintel.year == 2010)
        #expect(sintel.voteAverage == 7.4)
        #expect(sintel.poster == Artwork(.poster, path: "https://images.metahub.space/poster/small/tt1727587/img"))
        #expect(sintel.genreIDs == [CinemetaMapping.genre("Animation").id, CinemetaMapping.genre("Fantasy").id])
        #expect(page.items[1].year == 2008)  // from releaseInfo
        #expect(page.items[2].year == 2012)  // a numeric year
        #expect(page.items[2].genreIDs == [CinemetaMapping.genre("Sci-Fi").id])  // a bare string
        #expect(!page.hasMore)  // a short page is the last
        #expect(page.items[0].key.isMovie && page.items[0].key.imdbID == "tt1727587")
    }

    @Test func pagesSearchAndGenresBuildCatalogPaths() async throws {
        #expect(CinemetaMetadataProvider.catalogPath(type: "movie", id: "top", extra: [:]) == "/catalog/movie/top.json")
        #expect(CinemetaMetadataProvider.catalogPath(type: "series", id: "top", extra: ["genre": "Sci-Fi", "skip": "50"])
                == "/catalog/series/top/genre=Sci-Fi&skip=50.json")
        #expect(CinemetaMetadataProvider.catalogPath(type: "movie", id: "top", extra: ["search": "big buck & co"])
                == "/catalog/movie/top/search=big%20buck%20%26%20co.json")

        let http = FixtureHTTPClient()
        http.on(".json", .fixture("cinemeta_catalog_movie"))
        let p = provider(http)
        _ = try await p.list(.topRated, page: 3)
        #expect(http.requests.last?.url?.absoluteString == "https://cinemeta.test/catalog/movie/imdbRating/skip=100.json")
        let found = try await p.search("sintel", page: 1)
        #expect(found.items.count == 3)  // movie and series answers merged without repeats
        #expect(http.requests.contains { $0.url!.absoluteString.hasSuffix("/catalog/series/top/search=sintel.json") })
        let genres = try await p.genres()
        #expect(genres.count == CinemetaMetadataProvider.genreNames.count && Set(genres.map(\.id)).count == genres.count)
        _ = try await p.discover(genre: genres[0], kind: .series, page: 1)
        #expect(http.requests.last?.url?.absoluteString == "https://cinemeta.test/catalog/series/top/genre=Action.json")
    }

    @Test func seriesDetailSeasonsAndEpisodes() async throws {
        let http = FixtureHTTPClient()
        http.on("meta/series/tt9999901.json", .fixture("cinemeta_meta_series"))
        let p = provider(http)
        let key = MediaKey.series(imdbID: "tt9999901")
        let d = try await p.detail(for: key)
        #expect(d.title.kind == .series && d.title.name == "Open Show" && d.imdbID == "tt9999901")
        #expect(d.seasons.map(\.number) == [1, 2, 0])  // specials last
        #expect(d.seasons.map(\.episodeCount) == [2, 2, 1])
        #expect(d.runtimeMinutes == 48)
        #expect(d.cast.map(\.name) == ["Lead Actor", "Second Lead"])
        #expect(d.logo != nil)

        let s1 = try await p.season(1, of: key)
        #expect(s1.episodes.map(\.number) == [1, 2])
        #expect(s1.episodes[0].key == .episode(imdbSeriesID: "tt9999901", season: 1, episode: 1))
        #expect(s1.episodes[0].key.seriesKey == key)
        #expect(s1.episodes[0].overview == "One.")
        #expect(s1.episodes[0].still?.path.hasPrefix("https://episodes.metahub.space") == true)
        #expect(s1.episodes[1].airDate == ISO8601DateFormatter().date(from: "2024-03-08T05:00:00Z"))
        #expect(try await p.season(2, of: key).episodes.first?.name == "Return")  // "title" when no "name"
        #expect(http.requests.count == 1)  // one meta request serves detail and seasons
        await #expect(throws: MetadataError.notFound) { try await p.season(7, of: key) }
    }

    @Test func movieDetailCreditsAndTrailers() async throws {
        let http = FixtureHTTPClient()
        http.on("meta/movie/tt1727587.json", .fixture("cinemeta_meta_movie"))
        let p = provider(http)
        let key = MediaKey.movie(imdbID: "tt1727587")
        let d = try await p.detail(for: key)
        #expect(d.seasons.isEmpty && d.runtimeMinutes == 15 && d.genres.map(\.name) == ["Animation", "Fantasy"])
        let c = try await p.credits(for: key)
        #expect(c.directors.map(\.name) == ["Colin Levy"] && c.writers.map(\.name) == ["Esther Wouda"])
        #expect(c.cast.map(\.name) == ["Halina Reijn", "Thom Hoffman"])
        #expect(!c.hasPersonPages && c.cast.allSatisfy { $0.id < 0 })
        #expect(Set((c.directors + c.writers + c.cast).map(\.id)).count == 4)
        let videos = try await p.videos(for: key, season: nil)
        #expect(videos.map(\.youtubeKey) == ["eRsGyueVLvQ"] && videos[0].kind == .trailer)
        await #expect(throws: MetadataError.notFound) { try await p.person(id: 1) }
    }

    @Test func airingSplitsAiredAndUpcomingEpisodes() async throws {
        let http = FixtureHTTPClient()
        http.on("meta/series/tt9999901.json", .fixture("cinemeta_meta_series"))
        let info = try await provider(http).airing(for: .series(imdbID: "tt9999901"))
        #expect(info.lastEpisode?.key == .episode(imdbSeriesID: "tt9999901", season: 2, episode: 1))
        #expect(info.nextEpisode?.key == .episode(imdbSeriesID: "tt9999901", season: 2, episode: 2))
        #expect(info.status == "Continuing" && info.isOngoing)
    }

    @Test func imagesPickAMetahubSize() {
        let p = CinemetaMetadataProvider(http: FixtureHTTPClient())
        let poster = Artwork(.poster, path: "https://images.metahub.space/poster/small/tt1/img")
        #expect(p.imageURL(for: poster, width: 150)?.absoluteString == "https://images.metahub.space/poster/small/tt1/img")
        #expect(p.imageURL(for: poster, width: 400)?.absoluteString == "https://images.metahub.space/poster/medium/tt1/img")
        #expect(p.imageURL(for: poster, width: 1200)?.absoluteString == "https://images.metahub.space/poster/large/tt1/img")
        #expect(p.imageURL(for: Artwork(.poster, path: "/tmdb.jpg"), width: 100) == nil)
    }

    @Test func errorsMapLikeTMDB() async {
        let http = FixtureHTTPClient()
        http.on("meta/movie/tt0000001.json", .init(status: 404))
        await #expect(throws: MetadataError.notFound) { try await provider(http).detail(for: .movie(imdbID: "tt0000001")) }
        http.error = URLError(.notConnectedToInternet)
        await #expect(throws: MetadataError.offline) { try await provider(http).list(.trending, page: 1) }
        // TMDB keys aren't Cinemeta's.
        await #expect(throws: MetadataError.notFound) { try await provider(FixtureHTTPClient()).detail(for: .movie(tmdbID: 603)) }
    }
}
