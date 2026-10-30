import Domain
import Foundation
@testable import Metadata
import Testing
import TestingSupport

@Suite struct FilmCollectionTests {
    func service(_ http: FixtureHTTPClient) -> TMDBService {
        TMDBService(credential: .readAccessToken("tok"), http: http, language: "en-US", maxRetries: 0, sleep: { _ in })
    }

    /// TMDB's parts come in its own order, not release order; one is announced without a date.
    static let collectionJSON = #"""
    {"id":8091,"name":"Alien Collection","overview":"Ripley and the xenomorphs.","poster_path":"/coll.jpg","backdrop_path":"/collbg.jpg",
     "parts":[
      {"id":126889,"media_type":"movie","title":"Alien: Covenant","release_date":"2017-05-09","poster_path":"/cov.jpg","genre_ids":[27]},
      {"id":348,"media_type":"movie","title":"Alien","release_date":"1979-05-25","poster_path":"/alien.jpg","genre_ids":[27,878]},
      {"id":9999001,"media_type":"movie","title":"Alien: Next","release_date":"","genre_ids":[16]},
      {"id":679,"media_type":"movie","title":"Aliens","release_date":"1986-07-18","genre_ids":[28]}
     ]}
    """#

    @Test func collectionParsesInReleaseOrderWithUndatedLast() async throws {
        let http = FixtureHTTPClient()
        http.on("collection/8091", .init(body: Data(Self.collectionJSON.utf8)))
        let c = try await service(http).collection(id: 8091)
        #expect(c.name == "Alien Collection" && c.overview == "Ripley and the xenomorphs.")
        #expect(c.poster?.path == "/coll.jpg" && c.backdrop?.path == "/collbg.jpg")
        #expect(c.parts.map(\.name) == ["Alien", "Aliens", "Alien: Covenant", "Alien: Next"])
        #expect(c.parts.allSatisfy { $0.kind == .movie })
        #expect(c.parts.last?.releaseDate == nil)
        #expect(c.ref == CollectionRef(id: 8091, name: "Alien Collection", poster: c.poster, backdrop: c.backdrop))
    }

    @Test func aFilmNamesItsCollection() async throws {
        var json = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("tmdb_movie_detail")) as? [String: Any])
        json["belongs_to_collection"] = ["id": 8091, "name": "Alien Collection", "poster_path": "/coll.jpg", "backdrop_path": NSNull()]
        let http = FixtureHTTPClient()
        http.on("movie/133701", .init(body: try JSONSerialization.data(withJSONObject: json)))
        let d = try await service(http).detail(for: .movie(tmdbID: 133701))
        #expect(d.collection?.id == 8091 && d.collection?.name == "Alien Collection")
        #expect(d.collection?.poster?.path == "/coll.jpg" && d.collection?.backdrop == nil)

        // Not in a collection (the plain fixture), or one without a name: no row.
        let plain = FixtureHTTPClient()
        plain.on("movie/133701", .fixture("tmdb_movie_detail"))
        #expect(try await service(plain).detail(for: .movie(tmdbID: 133701)).collection == nil)
        json["belongs_to_collection"] = ["id": 8091]
        let nameless = FixtureHTTPClient()
        nameless.on("movie/133701", .init(body: try JSONSerialization.data(withJSONObject: json)))
        #expect(try await service(nameless).detail(for: .movie(tmdbID: 133701)).collection == nil)
    }

    @Test func cachedCollectionIsAskedOnceAndKeepsToTheProfilesLimit() async throws {
        let http = FixtureHTTPClient()
        http.on("collection/8091", .init(body: Data(Self.collectionJSON.utf8)))
        let cached = CachedMetadataProvider(service(http))
        _ = try await cached.collection(id: 8091)
        #expect(try await cached.collection(id: 8091).parts.count == 4)
        #expect(http.requests.count == 1)
        // A kids' profile: unrated films show only when they're family genres (the animated one here).
        cached.contentFilter = ContentFilter(maximum: .age7, familyOnlyWhenUnrated: true)
        #expect(try await cached.collection(id: 8091).parts.map(\.name) == ["Alien: Next"])
    }

    @Test func providersWithoutCollectionsSayNotFound() async throws {
        await #expect(throws: MetadataError.notFound) { try await CachedMetadataProvider(SampleMetadataProvider()).collection(id: 1) }
    }
}
