import Domain
import Foundation
@testable import Metadata
import Testing

/// Hits the real Cinemeta (no key). Run with BLUEBOX_LIVE_CINEMETA=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_LIVE_CINEMETA"] == "1"))
struct CinemetaLiveTests {
    let provider = CinemetaMetadataProvider()

    @Test func catalogsSearchAndAnOpenMovie() async throws {
        let trending = try await provider.list(.trending, page: 1)
        #expect(trending.items.count > 40)
        #expect(trending.items.contains { $0.kind == .series } && trending.items.contains { $0.kind == .movie })
        let page2 = try await provider.list(.popularMovies, page: 2)
        #expect(!page2.items.isEmpty)
        // Cinemeta's search doesn't index the small open films, so search a big show and open Sintel by ID.
        let found = try await provider.search("Breaking Bad", page: 1)
        #expect(found.items.contains { $0.key == .series(imdbID: "tt0903747") })
        let detail = try await provider.detail(for: .movie(imdbID: "tt1727587"))
        #expect(detail.imdbID == "tt1727587" && detail.title.year == 2010)
        let genre = try await provider.discover(genre: CinemetaMetadataProvider.genreList[0], kind: .movie, page: 1)
        #expect(!genre.items.isEmpty)
    }

    @Test func seriesSeasonsAndAiring() async throws {
        let key = MediaKey.series(imdbID: "tt0903747")
        let detail = try await provider.detail(for: key)
        #expect(detail.seasons.first?.number == 1 && detail.seasons.count >= 5)
        let s1 = try await provider.season(1, of: key)
        #expect(s1.episodes.first?.key == .episode(imdbSeriesID: "tt0903747", season: 1, episode: 1))
        let airing = try await provider.airing(for: key)
        #expect(airing.lastEpisode != nil && airing.nextEpisode == nil)
    }
}
