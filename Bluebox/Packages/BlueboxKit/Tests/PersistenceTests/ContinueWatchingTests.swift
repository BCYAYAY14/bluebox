import Domain
import Foundation
@testable import Persistence
import Testing
import TestingSupport

@Suite struct ContinueWatchingTests {
    @Test func manyNewerRecordsThatDontCountDontHideOlderOnes() async throws {
        let store = try LibraryStore.make(inMemory: true)
        try await store.save(.fixture(.movie(tmdbID: 1), 900, at: 10))
        // 100 newer items taken out of Continue Watching (reset to 0) or barely started.
        for i in 0..<100 { try await store.save(.fixture(.movie(tmdbID: 100 + i), i.isMultiple(of: 2) ? 0 : 5, at: 1000 + Double(i))) }
        #expect(try await store.continueWatching(limit: 10).map(\.key) == [.movie(tmdbID: 1)])
    }

    @Test func removingASeriesKeepsItOutEvenWithOlderHalfWatchedEpisodes() async throws {
        let store = try LibraryStore.make(inMemory: true)
        let e1 = MediaKey.episode(seriesID: 2, season: 1, episode: 1)
        let e2 = MediaKey.episode(seriesID: 2, season: 1, episode: 2)
        try await store.save(.fixture(e1, 600, at: 10))
        try await store.save(.fixture(e2, 900, at: 20))
        #expect(try await store.continueWatching(limit: 10).map(\.key) == [e2])
        // What AppModel.removeFromContinueWatching does: a newer record at 0.
        try await store.save(.fixture(e2, 0, at: 30))
        #expect(try await store.continueWatching(limit: 10).isEmpty)
    }

    @Test func fillsUpToTheLimitAcrossPages() async throws {
        let store = try LibraryStore.make(inMemory: true)
        for i in 0..<120 { try await store.save(.fixture(.movie(tmdbID: i), 600, at: Double(i))) }
        let cw = try await store.continueWatching(limit: 100)
        #expect(cw.count == 100)
        #expect(cw.first?.key == .movie(tmdbID: 119))
        #expect(try await store.continueWatching(limit: 0).isEmpty)
    }
}
