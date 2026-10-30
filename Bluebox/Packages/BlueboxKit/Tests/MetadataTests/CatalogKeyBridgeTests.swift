import Domain
import Foundation
@testable import Metadata
import Testing
import TestingSupport

/// Titles saved under the other catalog still open, under the saved key.
@Suite struct CatalogKeyBridgeTests {
    static let base = URL(string: "https://cinemeta.test")!

    static func json(_ s: String) -> FixtureHTTPClient.Reply { .init(body: Data(s.utf8)) }

    @Test func aTMDBKeyOpensOnCinemetaUnderItsOwnKey() async throws {
        let http = FixtureHTTPClient()
        // Two "House"s: only the second carries TMDB's 1408.
        http.on("catalog/series/top/search=House.json", Self.json("""
        {"metas":[{"id":"tt9000001","type":"series","name":"House","releaseInfo":"2004"},
                  {"id":"tt0412142","type":"series","name":"House","releaseInfo":"2004-2012"}]}
        """))
        http.on("meta/series/tt9000001.json", Self.json(#"{"meta":{"id":"tt9000001","type":"series","name":"House","moviedb_id":5}}"#))
        http.on("meta/series/tt0412142.json", Self.json("""
        {"meta":{"id":"tt0412142","type":"series","name":"House","releaseInfo":"2004-2012","moviedb_id":1408,
         "videos":[{"id":"tt0412142:1:1","name":"Pilot","season":1,"episode":1},
                   {"id":"tt0412142:1:2","name":"Paternity","season":1,"episode":2}]}}
        """))
        let saved = MediaKey.series(tmdbID: 1408)
        let bridge = CatalogKeyBridge(http: http, base: Self.base)
        bridge.savedTitle = { key in
            key == saved ? Title(key: saved, kind: .series, name: "House",
                                 releaseDate: ISO8601DateFormatter().date(from: "2004-11-16T00:00:00Z")) : nil
        }
        let catalog = CachedMetadataProvider(CinemetaMetadataProvider(http: http, base: Self.base))
        catalog.keyBridge = bridge

        let detail = try await catalog.detail(for: saved)
        #expect(detail.title.key == saved)
        #expect(detail.imdbID == "tt0412142")
        #expect(detail.seasons.map(\.number) == [1])
        let season = try await catalog.season(1, of: saved)
        #expect(season.seriesKey == saved)
        #expect(season.episodes.map(\.key) == [.episode(seriesID: 1408, season: 1, episode: 1),
                                              .episode(seriesID: 1408, season: 1, episode: 2)])
        // Learnt once: the second page asks Cinemeta nothing new about the match.
        let searches = http.requests.filter { $0.url!.path.contains("search=") }.count
        _ = try await catalog.detail(for: saved)
        #expect(http.requests.filter { $0.url!.path.contains("search=") }.count == searches)
    }

    @Test func anIMDbKeyOpensOnTMDBUnderItsOwnKey() async throws {
        let http = FixtureHTTPClient()
        http.on("meta/series/tt0944947.json", Self.json(#"{"meta":{"id":"tt0944947","type":"series","name":"Game of Thrones","moviedb_id":1399}}"#))
        http.on("tv/1399", .fixture("tmdb_tv_detail"))
        let catalog = CachedMetadataProvider(TMDBService(credential: .readAccessToken("tok"), http: http, maxRetries: 0, sleep: { _ in }))
        catalog.keyBridge = CatalogKeyBridge(http: http, base: Self.base)

        let saved = MediaKey.series(imdbID: "tt0944947")
        let detail = try await catalog.detail(for: saved)
        #expect(detail.title.key == saved)
        #expect(detail.seasons.map(\.number) == [1, 2, 0])
    }

    @Test func keysAlreadyInTheCatalogAreLeftAlone() async {
        let http = FixtureHTTPClient()
        let bridge = CatalogKeyBridge(http: http, base: Self.base)
        #expect(await bridge.key(for: .series(imdbID: "tt1"), toTMDB: false) == nil)
        #expect(await bridge.key(for: .series(tmdbID: 1), toTMDB: true) == nil)
        #expect(http.requests.isEmpty)
    }
}
