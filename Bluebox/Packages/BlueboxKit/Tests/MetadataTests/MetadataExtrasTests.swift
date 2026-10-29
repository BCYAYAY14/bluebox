import Domain
import Foundation
@testable import Metadata
import Testing
import TestingSupport

@Suite struct MetadataExtrasTests {
    func service(_ http: FixtureHTTPClient, language: String = "en-US") -> TMDBService {
        TMDBService(credential: .readAccessToken("tok"), http: http, language: language, maxRetries: 0, sleep: { _ in })
    }

    @Test func videosKeepYouTubeAndRankOfficialTrailersInYourLanguageFirst() async throws {
        let http = FixtureHTTPClient()
        http.on("movie/45745/videos", .fixture("tmdb_movie_videos"))
        let videos = try await service(http).videos(for: .movie(tmdbID: 45745), season: nil)
        #expect(!videos.contains { $0.name == "Vimeo Trailer" })
        #expect(videos.map(\.youtubeKey) == ["eRsGyueVLvQ", "de000000001", "fan00000001", "teaser00001", "bts00000001", "clip0000001"])
        #expect(videos[0].kind == .trailer && videos[0].isOfficial && videos[0].language == "en")
        #expect(videos[0].thumbnailURL?.absoluteString == "https://i.ytimg.com/vi/eRsGyueVLvQ/hqdefault.jpg")
        #expect(videos[0].publishedAt == ISO8601DateFormatter().date(from: "2010-09-27T10:00:00Z"))
        let query = try #require(http.requests.first?.url?.query)
        #expect(query.contains("include_video_language=en,null"))
    }

    @Test func germanCatalogPrefersGermanTrailerAndAsksForEnglishToo() async throws {
        let http = FixtureHTTPClient()
        http.on("movie/45745/videos", .fixture("tmdb_movie_videos"))
        let videos = try await service(http, language: "de-DE").videos(for: .movie(tmdbID: 45745), season: nil)
        #expect(videos.first?.youtubeKey == "de000000001")
        #expect(http.requests.first?.url?.query?.contains("include_video_language=de,en,null") == true)
        #expect(VideoRanking.heroTrailer(videos, language: "de")?.youtubeKey == "de000000001")
    }

    @Test func seasonVideosUseTheSeasonEndpoint() async throws {
        let http = FixtureHTTPClient()
        http.on("tv/9100001/season/2/videos", .fixture("tmdb_movie_videos"))
        let videos = try await service(http).videos(for: .episode(seriesID: 9_100_001, season: 2, episode: 3), season: 2)
        #expect(videos.allSatisfy { $0.season == 2 })
    }

    @Test func airingMapsLastAndNextEpisodes() async throws {
        let http = FixtureHTTPClient()
        http.on("tv/9100001", .fixture("tmdb_tv_airing"))
        let info = try await service(http).airing(for: .series(tmdbID: 9_100_001))
        #expect(info.status == "Returning Series" && info.isOngoing)
        #expect(info.lastEpisode?.key == .episode(seriesID: 9_100_001, season: 2, episode: 4))
        #expect(info.lastEpisode?.still == Artwork(.still, path: "/s2e4.jpg"))
        #expect(info.nextEpisode?.key == .episode(seriesID: 9_100_001, season: 2, episode: 5))
        #expect(info.nextEpisode?.airDate == TMDBMapping.date("2026-10-31"))
        await #expect(throws: MetadataError.notFound) { try await service(http).airing(for: .movie(tmdbID: 1)) }
    }

    @Test func movieCreditsSplitDirectorsWritersCastAndKeyCrew() async throws {
        let http = FixtureHTTPClient()
        http.on("movie/45745/credits", .fixture("tmdb_movie_credits"))
        let c = try await service(http).credits(for: .movie(tmdbID: 45745))
        #expect(c.directors.map(\.name) == ["Colin Levy"])
        #expect(c.writers.map(\.name) == ["Esther Wouda"])  // once, though credited twice
        #expect(c.cast.map(\.role) == ["Sintel", "Shaman"])  // billing order
        #expect(c.crew.map(\.role) == ["Producer", "Original Music Composer"])  // no grips
        #expect(c.hasPersonPages)
        #expect(c.departments.map(\.name) == ["Director", "Cast", "Writing", "Production", "Sound"])
    }

    @Test func seriesCreditsUseAggregateRolesAndCreators() async throws {
        let http = FixtureHTTPClient()
        http.on("tv/9100001/aggregate_credits", .fixture("tmdb_tv_aggregate_credits"))
        http.on("tv/9100001", .fixture("tmdb_tv_airing"))
        let c = try await service(http).credits(for: .series(tmdbID: 9_100_001))
        #expect(c.creators.map(\.name) == ["Ada Creator"])
        #expect(c.cast.first?.role == "The Lead")  // the role with the most episodes
        #expect(c.writers.map(\.name) == ["Pat Writer"])
        #expect(c.crew.map(\.name) == ["Sam Producer"])
        #expect(c.directors.isEmpty)
    }

    @Test func personAndFilmography() async throws {
        let http = FixtureHTTPClient()
        http.on("person/21", .fixture("tmdb_person"))
        http.on("person/21/combined_credits", .fixture("tmdb_person_combined_credits"))
        let p = try await service(http).person(id: 21)
        #expect(p.name == "Colin Levy" && p.department == "Directing" && p.placeOfBirth == "Amsterdam, Netherlands")
        #expect(p.birthday == TMDBMapping.date("1990-05-04"))
        #expect(p.age(on: TMDBMapping.date("2026-10-28")!) == 36)

        let f = try await service(http).filmography(personID: 21)
        // One Sintel entry with both roles; the talk show and the undated film stay out of Known For.
        let sintel = try #require(f.movies.first { $0.title.key == .movie(tmdbID: 45745) })
        #expect(sintel.roles == ["Cameo", "Director"])
        #expect(f.movies.filter { $0.title.key == .movie(tmdbID: 45745) }.count == 1)
        #expect(f.knownFor.map(\.title.key) == [.movie(tmdbID: 45745), .series(tmdbID: 9_100_001)])
        // By year, newest first; unreleased first of all.
        #expect(f.movies.map(\.title.name) == ["Next Open Film", "Tears of Steel", "Sintel"])
        #expect(f.shows.map(\.title.name) == ["Open Show", "Late Talk"])
        #expect(f.shows.first?.roleText == "Director · 3 episodes")
    }

    @Test func peopleSearchMapsAndCaches() async throws {
        let http = FixtureHTTPClient()
        let json = #"{"page":1,"total_pages":1,"results":[{"id":2037,"name":"Cillian Murphy","profile_path":"/c.jpg","known_for_department":"Acting","popularity":40.5},{"id":99,"name":"Cillian Scott","profile_path":null,"known_for_department":null,"popularity":1}]}"#
        http.on("search/person", .init(body: Data(json.utf8)))
        let people = try await service(http).searchPeople("cillian")
        #expect(people.map(\.name) == ["Cillian Murphy", "Cillian Scott"])
        #expect(people[0].department == "Acting" && people[0].profile?.path == "/c.jpg")
        #expect(people[1].profile == nil)
        #expect(http.requests.last?.url?.query()?.contains("query=cillian") == true)

        let cached = CachedMetadataProvider(service(http))
        _ = try await cached.searchPeople("Cillian ")
        _ = try await cached.searchPeople("cillian")
        #expect(http.requests.filter { $0.url!.path.hasSuffix("search/person") }.count == 2)  // one above, one cached here
        #expect(await cached.cachedPeople("CILLIAN")?.count == 2)
        // Nothing to search for asks nothing.
        #expect(try await service(http).searchPeople("  ").isEmpty)
        // Providers without people answer empty, not with a failure.
        #expect(try await CachedMetadataProvider(SampleMetadataProvider()).searchPeople("x").isEmpty)
    }

    @Test func cachedProviderForwardsAndCachesExtras() async throws {
        let http = FixtureHTTPClient()
        http.on("movie/45745/videos", .fixture("tmdb_movie_videos"))
        http.on("tv/9100001", .fixture("tmdb_tv_airing"))
        let cached = CachedMetadataProvider(service(http))
        _ = try await cached.videos(for: .movie(tmdbID: 45745), season: nil)
        _ = try await cached.videos(for: .movie(tmdbID: 45745), season: nil)
        #expect(http.requests.filter { $0.url!.path.hasSuffix("videos") }.count == 1)
        _ = try await cached.airing(for: .series(tmdbID: 9_100_001))
        _ = try await cached.airing(for: .series(tmdbID: 9_100_001))
        _ = try await cached.freshAiring(for: .series(tmdbID: 9_100_001))
        #expect(http.requests.filter { $0.url!.path.hasSuffix("tv/9100001") }.count == 2)

        // The sample catalog has no extras.
        let sample = CachedMetadataProvider(SampleMetadataProvider())
        await #expect(throws: MetadataError.notFound) { try await sample.person(id: 1) }
        #expect(try await sample.upcomingMovies(page: 1).items.isEmpty)
    }
}
