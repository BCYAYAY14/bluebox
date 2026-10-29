import Domain
import Foundation
@testable import Persistence
import SwiftData
import Testing

/// The models as they were before lists, to write a store an older build would have left.
enum OriginalSchema {
    @Model final class WatchlistEntryRecord {
        @Attribute(.unique) var key: String
        var addedAt: Date
        var titleData: Data
        var isRemoved: Bool = false
        var updatedAt: Date?
        var needsSync: Bool = true
        init(key: String, addedAt: Date, titleData: Data) { self.key = key; self.addedAt = addedAt; self.titleData = titleData }
    }

    @Model final class ProgressRecord {
        @Attribute(.unique) var key: String
        var seriesKey: String?
        var position: Double
        var duration: Double?
        var isCompleted: Bool
        var updatedAt: Date
        var deviceID: String?
        var needsSync: Bool
        var changedAt: Date?
        init(key: String, position: Double, updatedAt: Date) {
            self.key = key; self.position = position; isCompleted = false; self.updatedAt = updatedAt; needsSync = false
        }
    }

    @Model final class CachedTitleRecord {
        @Attribute(.unique) var key: String
        var titleData: Data
        var cachedAt: Date
        init(key: String, titleData: Data, cachedAt: Date) { self.key = key; self.titleData = titleData; self.cachedAt = cachedAt }
    }
}

@Suite struct ListsStoreTests {
    let movie = Title(key: .movie(tmdbID: 1), kind: .movie, name: "One")
    let show = Title(key: .series(tmdbID: 2), kind: .series, name: "Two")
    let film = Title(key: .movie(tmdbID: 3), kind: .movie, name: "Three")

    /// A store written before lists opens, keeps My List and progress, and takes lists.
    @Test func storeFromBeforeListsOpensAndKeepsEverything() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bluebox-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "library.store")
        let added = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let schema = Schema([OriginalSchema.WatchlistEntryRecord.self, OriginalSchema.ProgressRecord.self,
                                 OriginalSchema.CachedTitleRecord.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let context = ModelContext(container)
            context.insert(OriginalSchema.WatchlistEntryRecord(key: movie.key.rawValue, addedAt: added, titleData: try JSONEncoder().encode(movie)))
            context.insert(OriginalSchema.WatchlistEntryRecord(key: show.key.rawValue, addedAt: added.addingTimeInterval(60),
                                                                titleData: try JSONEncoder().encode(show)))
            context.insert(OriginalSchema.ProgressRecord(key: film.key.rawValue, position: 120, updatedAt: added))
            try context.save()
        }

        let store = try LibraryStore.make(url: url)
        #expect(try await store.watchlist().map(\.key) == [show.key, movie.key])
        #expect(try await store.progress(for: film.key)?.position == 120)
        // No stored position: newest added first, as before.
        #expect(try await store.watchlistEntries().map(\.key) == [show.key, movie.key])
        #expect(try await store.lists().isEmpty)
        let list = try await store.createList(name: "Halloween", symbol: "moon.fill")
        try await store.setOnList(film, listID: list.id, true)
        #expect(try await store.entries(in: list.id).map(\.key) == [film.key])
    }

    @Test func listCRUDAndTombstones() async throws {
        let store = try LibraryStore.make(inMemory: true)
        await #expect(throws: ListError.emptyName) { try await store.createList(name: "   ") }
        let a = try await store.createList(name: "  Halloween  ", symbol: "moon.fill")
        let b = try await store.createList(name: "Watch with Mia")
        #expect(a.name == "Halloween")
        #expect(try await store.lists().map(\.id) == [a.id, b.id])

        try await store.updateList(a.id, name: "Spooky", symbol: "flame")
        #expect(try await store.list(a.id)?.name == "Spooky")
        #expect(try await store.list(a.id)?.symbol == "flame")

        try await store.setOnList(movie, listID: a.id, true)
        try await store.setOnList(show, listID: a.id, true)
        try await store.setOnList(movie, listID: b.id, true)
        try await store.setOnList(movie, listID: a.id, true)  // idempotent
        #expect(try await store.entries(in: a.id).map(\.key) == [movie.key, show.key])  // added at the end
        #expect(try await store.listIDs(containing: movie.key) == [a.id, b.id])
        #expect(try await store.isOnList(show.key, listID: a.id))

        try await store.setOnList(movie, listID: a.id, false)
        #expect(try await store.entries(in: a.id).map(\.key) == [show.key])
        // Removal is a tombstone waiting to sync.
        let pending = try await store.pendingListEntryUploads()
        #expect(pending.first { $0.listID == a.id && $0.key == movie.key }?.isRemoved == true)

        // Re-adding puts it at the end again.
        try await store.setOnList(movie, listID: a.id, true)
        #expect(try await store.entries(in: a.id).map(\.key) == [show.key, movie.key])

        // Deleting a list tombstones it and its entries.
        try await store.removeList(a.id)
        #expect(try await store.lists().map(\.id) == [b.id])
        #expect(try await store.listIDs(containing: movie.key) == [b.id])
        #expect(try await store.pendingListUploads().first { $0.id == a.id }?.isRemoved == true)
        #expect(try await store.pendingListEntryUploads().filter { $0.listID == a.id }.allSatisfy(\.isRemoved))
        await #expect(throws: ListError.notFound) { try await store.setOnList(film, listID: a.id, true) }
    }

    @Test func manualOrdering() async throws {
        let store = try LibraryStore.make(inMemory: true)
        let list = try await store.createList(name: "Queue")
        for t in [movie, show, film] { try await store.setOnList(t, listID: list.id, true) }
        try await store.markListEntriesSynced(ifUpdatedAt: Dictionary(uniqueKeysWithValues:
            try await store.pendingListEntryUploads().map { ($0.entryKey, $0.updatedAt) }))
        try await store.reorderList(list.id, keys: [film.key, movie.key, show.key])
        #expect(try await store.entries(in: list.id).map(\.key) == [film.key, movie.key, show.key])
        try await store.removeFromList([movie.key, show.key], listID: list.id)
        #expect(try await store.entries(in: list.id).map(\.key) == [film.key])

        // My List: newest first until reordered, then the manual order; a new add goes on top.
        try await store.setWatchlisted(movie, true)
        try await Task.sleep(for: .milliseconds(5))
        try await store.setWatchlisted(show, true)
        #expect(try await store.watchlistEntries().map(\.key) == [show.key, movie.key])
        try await store.reorderWatchlist([movie.key, show.key])
        #expect(try await store.watchlistEntries().map(\.key) == [movie.key, show.key])
        #expect(try await store.pendingWatchlistUploads().allSatisfy { $0.position != nil })
        try await store.setWatchlisted(film, true)
        #expect(try await store.watchlistEntries().map(\.key) == [film.key, movie.key, show.key])

        // The Lists grid's order.
        let second = try await store.createList(name: "Second")
        try await store.reorderLists([second.id, list.id])
        #expect(try await store.lists().map(\.id) == [second.id, list.id])
    }

    @Test func remoteMergeNewestWinsAndTiesKeepPresent() async throws {
        let store = try LibraryStore.make(inMemory: true)
        let list = try await store.createList(name: "Mine")
        let older = UserList(id: list.id, name: "Older", position: 0, createdAt: list.createdAt, updatedAt: list.updatedAt.addingTimeInterval(-10))
        #expect(try await store.applyRemoteLists([older]) == 0)
        let newer = UserList(id: list.id, name: "Renamed", position: 0, createdAt: list.createdAt, updatedAt: list.updatedAt.addingTimeInterval(10))
        #expect(try await store.applyRemoteLists([newer]) == 1)
        #expect(try await store.list(list.id)?.name == "Renamed")

        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let removed = ListEntry(listID: list.id, title: movie, position: 0, addedAt: t, isRemoved: true, updatedAt: t)
        let present = ListEntry(listID: list.id, title: movie, position: 0, addedAt: t, isRemoved: false, updatedAt: t)
        #expect(try await store.applyRemoteListEntries([removed]) == 1)
        #expect(try await store.applyRemoteListEntries([present]) == 1)   // tie: present wins
        #expect(try await store.applyRemoteListEntries([removed]) == 0)   // and stays
        #expect(try await store.entries(in: list.id).map(\.key) == [movie.key])
        // Remote rows aren't queued for upload.
        #expect(try await store.pendingListEntryUploads().isEmpty)
    }

    @Test func titleFactsMerge() async throws {
        let store = try LibraryStore.make(inMemory: true)
        try await store.noteTitleFacts(movie.key, runtimeMinutes: 95)
        try await store.noteTitleFacts(movie.key, has4K: true)
        #expect(try await store.titleFacts(for: [movie.key, show.key]) == [movie.key: TitleFacts(runtimeMinutes: 95, has4K: true)])
    }
}
