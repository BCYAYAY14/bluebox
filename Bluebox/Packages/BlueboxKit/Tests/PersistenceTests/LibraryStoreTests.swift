import Domain
import Foundation
@testable import Persistence
import Testing
import TestingSupport

@Suite struct LibraryStoreTests {
    let movie = Title(key: .movie(tmdbID: 1), kind: .movie, name: "One")
    let show = Title(key: .series(tmdbID: 2), kind: .series, name: "Two")

    @Test func watchlistAddRemoveOrder() async throws {
        let store = try LibraryStore.make(inMemory: true)
        try await store.setWatchlisted(movie, true)
        try await Task.sleep(for: .milliseconds(5))
        try await store.setWatchlisted(show, true)
        try await store.setWatchlisted(show, true)  // idempotent
        #expect(try await store.watchlist().map(\.key) == [show.key, movie.key])  // newest first
        #expect(try await store.isOnWatchlist(movie.key))
        try await store.setWatchlisted(movie, false)
        #expect(try await !store.isOnWatchlist(movie.key))
        #expect(try await store.title(for: movie.key)?.name == "One")  // cached even after removal
    }

    @Test func progressSaveMergesAndRejectsStale() async throws {
        let store = try LibraryStore.make(inMemory: true)
        let k = movie.key
        try await store.save(.fixture(k, 600, at: 100))
        let kept = try await store.save(.fixture(k, 900, at: 50))   // stale
        #expect(kept.position == 600)
        try await store.save(.fixture(k, 300, at: 200))             // newer rewind wins
        #expect(try await store.progress(for: k)?.position == 300)
    }

    @Test func continueWatchingOnePerSeriesNewestFirst() async throws {
        let store = try LibraryStore.make(inMemory: true)
        let e1 = MediaKey.episode(seriesID: 2, season: 1, episode: 1)
        let e2 = MediaKey.episode(seriesID: 2, season: 1, episode: 2)
        try await store.save(.fixture(e1, 1000, at: 10))
        try await store.save(.fixture(e2, 500, at: 20))
        try await store.save(.fixture(movie.key, 700, at: 15))
        try await store.save(.fixture(.movie(tmdbID: 3), 3500, completed: true, at: 30))   // done
        try await store.save(.fixture(.movie(tmdbID: 4), 5, at: 40))                      // barely started
        let cw = try await store.continueWatching(limit: 10)
        #expect(cw.map(\.key) == [e2, movie.key])
        #expect(try await store.progress(forSeries: show.key).map(\.key) == [e2, e1])
        #expect(try await store.recent(limit: 2).map(\.key) == [.movie(tmdbID: 4), .movie(tmdbID: 3)])
    }

    @Test func syncBookkeeping() async throws {
        let store = try LibraryStore.make(inMemory: true)
        let k = movie.key
        try await store.save(.fixture(k, 600, at: 100))
        #expect(try await store.pendingUploads().map(\.key) == [k])
        // A newer local write between push and ack must stay pending.
        try await store.save(.fixture(k, 700, at: 101))
        try await store.markSynced([k], ifUpdatedAt: [k: Date(timeIntervalSince1970: 100)])
        #expect(try await store.pendingUploads().count == 1)
        try await store.markSynced([k], ifUpdatedAt: [k: Date(timeIntervalSince1970: 101)])
        #expect(try await store.pendingUploads().isEmpty)
        // Remote records don't get queued for upload.
        try await store.applyRemote(.fixture(.movie(tmdbID: 9), 100, at: 5))
        #expect(try await store.pendingUploads().isEmpty)
    }

    @Test func deleteAndPersistAcrossReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bluebox-\(UUID()).store")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try LibraryStore.make(url: url)
            try await store.save(.fixture(movie.key, 600, at: 100))
            try await store.save(.fixture(show.key, 60, at: 100))
            try await store.delete(show.key)
        }
        let reopened = try LibraryStore.make(url: url)
        #expect(try await reopened.progress(for: movie.key)?.position == 600)
        #expect(try await reopened.progress(for: show.key) == nil)
    }
}

@Suite struct SecretStoreTests {
    @Test func memoryStore() throws {
        let s = MemorySecretStore()
        try s.write("abc", for: SecretAccount.tmdb)
        #expect(try s.read(SecretAccount.tmdb) == "abc")
        try s.write(nil, for: SecretAccount.tmdb)
        #expect(try s.read(SecretAccount.tmdb) == nil)
    }
}

@Suite struct LibraryStoreSyncTests {
    let movie = Title(key: .movie(tmdbID: 1), kind: .movie, name: "One")

    @Test func watchlistRemovalIsATombstoneThatSyncs() async throws {
        let store = try LibraryStore.make(inMemory: true)
        try await store.setWatchlisted(movie, true)
        #expect(try await store.pendingWatchlistUploads().map(\.isRemoved) == [false])
        let added = try await store.pendingWatchlistUploads()[0]
        try await store.markWatchlistSynced(ifUpdatedAt: [movie.key: added.updatedAt])
        #expect(try await store.pendingWatchlistUploads().isEmpty)

        try await Task.sleep(for: .milliseconds(5))
        try await store.setWatchlisted(movie, false)
        #expect(try await store.watchlist().isEmpty)
        #expect(try await !store.isOnWatchlist(movie.key))
        let pending = try await store.pendingWatchlistUploads()
        #expect(pending.map(\.isRemoved) == [true])
        #expect(pending[0].updatedAt > added.updatedAt)
    }

    @Test func remoteWatchlistMergeFollowsWatchlistMerge() async throws {
        let store = try LibraryStore.make(inMemory: true)
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(try await store.applyRemoteWatchlist([WatchlistEntry(title: movie, addedAt: t0, updatedAt: t0)]) == 1)
        #expect(try await store.isOnWatchlist(movie.key))
        #expect(try await store.pendingWatchlistUploads().isEmpty)
        // Older removal loses; tie removal loses to present; newer removal wins.
        #expect(try await store.applyRemoteWatchlist([WatchlistEntry(title: movie, addedAt: t0, isRemoved: true, updatedAt: t0.addingTimeInterval(-1))]) == 0)
        #expect(try await store.applyRemoteWatchlist([WatchlistEntry(title: movie, addedAt: t0, isRemoved: true, updatedAt: t0)]) == 0)
        #expect(try await store.applyRemoteWatchlist([WatchlistEntry(title: movie, addedAt: t0, isRemoved: true, updatedAt: t0.addingTimeInterval(1))]) == 1)
        #expect(try await !store.isOnWatchlist(movie.key))
    }

    @Test func timestampsAreStoredAtMillisecondPrecision() async throws {
        let store = try LibraryStore.make(inMemory: true)
        let raw = Date(timeIntervalSince1970: 1_000.123_456_789)
        let saved = try await store.save(WatchProgress(key: movie.key, position: 60, duration: 600, updatedAt: raw))
        #expect(saved.updatedAt == Date(millisecondsSince1970: 1_000_123))
        let pending = try await store.pendingUploads()
        try await store.markSynced([movie.key], ifUpdatedAt: [movie.key: pending[0].updatedAt])
        #expect(try await store.pendingUploads().isEmpty)
    }

    @Test func batchRemoteApplyCountsChangesAndSkipsStale() async throws {
        let store = try LibraryStore.make(inMemory: true)
        try await store.save(.fixture(movie.key, 600, at: 100))
        let n = try await store.applyRemote([.fixture(movie.key, 900, at: 50), .fixture(.movie(tmdbID: 2), 10, at: 1)])
        #expect(n == 1)
        #expect(try await store.progress(for: movie.key)?.position == 600)
        #expect(try await store.pendingUploads().map(\.key) == [movie.key])  // local record still pending
    }
}
