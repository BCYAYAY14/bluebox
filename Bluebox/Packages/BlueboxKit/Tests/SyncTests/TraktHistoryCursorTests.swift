import Domain
import Foundation
import Persistence
@testable import Sync
import Testing

@Suite struct TraktHistoryCursorTests {
    @Test func aPlayFinishedOnAnotherDeviceReachesTraktWhenItSyncsHereLater() async throws {
        let server = FakeTrakt()
        let (client, sync, store, _) = try TraktTests.make(server)
        try await TraktTests.connect(client)
        try await sync.sync()  // sets the history cursor to now
        #expect(server.historyBodies.isEmpty)

        // Watched on the Mac yesterday; Supabase brings it to this device only now.
        let yesterday = Date().addingTimeInterval(-86_400)
        try await store.applyRemote([WatchProgress(key: .movie(tmdbID: 77), position: 100, duration: 100, isCompleted: true,
                                                   updatedAt: yesterday)])
        try await sync.sync()
        let movies = server.historyBodies.first?["movies"] as? [[String: Any]]
        #expect((movies?.first?["ids"] as? [String: Any])?["tmdb"] as? Int == 77)

        // Sent once.
        try await sync.sync()
        #expect(server.historyBodies.count == 1)
    }
}
