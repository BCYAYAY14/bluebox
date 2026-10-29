import Domain
import Foundation
import Persistence
@testable import Sync
import Testing
import TestingSupport

@Suite struct ListsSyncTests {
    struct Device {
        let store: LibraryStore
        let engine: SyncEngine
    }

    func device(_ server: FakeSupabase) async throws -> Device {
        let store = try LibraryStore.make(inMemory: true)
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "sync.lists.\(UUID().uuidString)")!)
        let auth = SupabaseAuth(config: FakeSupabase.config, http: server, secrets: MemorySecretStore())
        _ = try await auth.signIn(username: "brian", password: FakeSupabase.password)
        return Device(store: store, engine: SyncEngine(auth: auth, config: FakeSupabase.config, http: server, store: store, prefs: prefs))
    }

    let movie = Title(key: .movie(tmdbID: 1), kind: .movie, name: "One")
    let show = Title(key: .series(tmdbID: 2), kind: .series, name: "Two")

    @Test func listsEntriesAndOrderReachTheOtherDevice() async throws {
        let server = FakeSupabase()
        let a = try await device(server), b = try await device(server)
        let list = try await a.store.createList(name: "Halloween", symbol: "moon.fill")
        try await a.store.setOnList(movie, listID: list.id, true)
        try await a.store.setOnList(show, listID: list.id, true)
        try await a.engine.sync()
        #expect(try await a.store.pendingListUploads().isEmpty)
        #expect(try await a.store.pendingListEntryUploads().isEmpty)

        try await b.engine.sync()
        #expect(try await b.store.lists().map(\.name) == ["Halloween"])
        #expect(try await b.store.list(list.id)?.symbol == "moon.fill")
        #expect(try await b.store.entries(in: list.id).map(\.key) == [movie.key, show.key])

        // B reorders and removes one; A follows.
        try await Task.sleep(for: .milliseconds(5))
        try await b.store.reorderList(list.id, keys: [show.key, movie.key])
        try await b.engine.sync()
        try await a.engine.sync()
        #expect(try await a.store.entries(in: list.id).map(\.key) == [show.key, movie.key])

        try await Task.sleep(for: .milliseconds(5))
        try await a.store.removeList(list.id)
        try await a.engine.sync()
        try await b.engine.sync()
        #expect(try await b.store.lists().isEmpty)
        #expect(try await b.store.listIDs(containing: movie.key).isEmpty)
    }

    @Test func myListOrderSyncs() async throws {
        let server = FakeSupabase()
        let a = try await device(server), b = try await device(server)
        try await a.store.setWatchlisted(movie, true)
        try await Task.sleep(for: .milliseconds(5))
        try await a.store.setWatchlisted(show, true)
        try await a.store.reorderWatchlist([movie.key, show.key])
        try await a.engine.sync()
        try await b.engine.sync()
        #expect(try await b.store.watchlistEntries().map(\.key) == [movie.key, show.key])
        // The recently-added order is untouched.
        #expect(try await b.store.watchlist().map(\.key) == [show.key, movie.key])
    }

    /// A project from before lists: the rest syncs and the lists wait on this device.
    @Test func projectWithoutListTablesStillSyncs() async throws {
        let server = FakeSupabase()
        server.listTablesMissing = true
        let a = try await device(server)
        let list = try await a.store.createList(name: "Mine")
        try await a.store.setOnList(movie, listID: list.id, true)
        try await a.store.setWatchlisted(show, true)
        let r = try await a.engine.sync()
        #expect(r.uploaded == 1)
        #expect(try await a.store.pendingWatchlistUploads().isEmpty)
        #expect(try await a.store.pendingListUploads().count == 1)
    }
}
