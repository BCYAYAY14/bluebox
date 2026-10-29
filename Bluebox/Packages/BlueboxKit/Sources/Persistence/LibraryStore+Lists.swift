import Domain
import Foundation
import SwiftData

// Your own lists and their entries (UI review decision 10). My List is the
// watchlist (LibraryStore.swift); these sit beside it and sync the same way.

private let encoder = JSONEncoder()
private let decoder = JSONDecoder()

extension LibraryStore {
    // MARK: Lists

    /// Your lists, in the Lists grid's order.
    public func lists() throws -> [UserList] {
        let d = FetchDescriptor<UserListRecord>(predicate: #Predicate { !$0.isRemoved },
                                                sortBy: [SortDescriptor(\.position), SortDescriptor(\.createdAt)])
        return try modelContext.fetch(d).map(\.value)
    }

    public func list(_ id: String) throws -> UserList? {
        guard let r = try listRecord(id), !r.isRemoved else { return nil }
        return r.value
    }

    /// A new list, after the others.
    @discardableResult
    public func createList(name: String, symbol: String = UserList.defaultSymbol) throws -> UserList {
        guard let clean = UserList.cleanName(name) else { throw ListError.emptyName }
        let now = Date.now.millisecondRounded
        let last = try lists().map(\.position).max() ?? -1
        let list = UserList(name: clean, symbol: symbol, position: last + 1, createdAt: now, updatedAt: now)
        modelContext.insert(UserListRecord(list, needsSync: true))
        try modelContext.save()
        return list
    }

    /// Renames a list or changes its symbol.
    public func updateList(_ id: String, name: String, symbol: String) throws {
        guard let clean = UserList.cleanName(name) else { throw ListError.emptyName }
        guard let r = try listRecord(id), !r.isRemoved else { throw ListError.notFound }
        guard r.name != clean || r.symbol != symbol else { return }
        r.name = clean; r.symbol = symbol; r.updatedAt = .now.millisecondRounded; r.needsSync = true
        try modelContext.save()
    }

    /// Deletes a list: it and its entries become tombstones, so other devices delete them too.
    public func removeList(_ id: String) throws {
        guard let r = try listRecord(id), !r.isRemoved else { return }
        let now = Date.now.millisecondRounded
        r.isRemoved = true; r.updatedAt = now; r.needsSync = true
        for e in try entryRecords(id) where !e.isRemoved {
            e.isRemoved = true; e.updatedAt = now; e.needsSync = true
        }
        try modelContext.save()
    }

    /// Puts the lists in this order.
    public func reorderLists(_ ids: [String]) throws {
        let now = Date.now.millisecondRounded
        var changed = false
        for (i, id) in ids.enumerated() {
            guard let r = try listRecord(id), !r.isRemoved, r.position != Double(i) else { continue }
            r.position = Double(i); r.updatedAt = now; r.needsSync = true
            changed = true
        }
        if changed { try modelContext.save() }
    }

    // MARK: Entries

    /// A list's titles in manual order.
    public func entries(in listID: String) throws -> [ListEntry] {
        try entryRecords(listID).filter { !$0.isRemoved }.compactMap(Self.entry)
    }

    /// Every list's live entries, by list ID, for the Lists grid's covers and counts in one read.
    public func entriesByList() throws -> [String: [ListEntry]] {
        let live = Set(try lists().map(\.id))
        let d = FetchDescriptor<ListEntryRecord>(predicate: #Predicate { !$0.isRemoved },
                                                 sortBy: [SortDescriptor(\.position), SortDescriptor(\.addedAt)])
        var out: [String: [ListEntry]] = [:]
        for r in try modelContext.fetch(d) where live.contains(r.listID) {
            if let e = Self.entry(r) { out[r.listID, default: []].append(e) }
        }
        return out
    }

    /// The lists (by ID) a title is on, for the ticks in Add to List.
    public func listIDs(containing key: MediaKey) throws -> Set<String> {
        let raw = key.rawValue
        let d = FetchDescriptor<ListEntryRecord>(predicate: #Predicate { $0.mediaKey == raw && !$0.isRemoved })
        let live = Set(try lists().map(\.id))
        return Set(try modelContext.fetch(d).map(\.listID)).intersection(live)
    }

    public func isOnList(_ key: MediaKey, listID: String) throws -> Bool {
        guard let r = try entryRecord(listID: listID, key: key) else { return false }
        return !r.isRemoved
    }

    /// Adds a title at the end of a list, or takes it off.
    public func setOnList(_ title: Title, listID: String, _ on: Bool) throws {
        guard try listRecord(listID).map({ !$0.isRemoved }) == true else { throw ListError.notFound }
        let now = Date.now.millisecondRounded
        if let r = try entryRecord(listID: listID, key: title.key) {
            guard r.isRemoved == on else { return try store([title]) }
            r.isRemoved = !on; r.updatedAt = now; r.needsSync = true
            if on {
                r.addedAt = now; r.titleData = try encoder.encode(title)
                r.position = try nextPosition(listID)
            }
        } else if on {
            modelContext.insert(ListEntryRecord(listID: listID, mediaKey: title.key, position: try nextPosition(listID), addedAt: now,
                                                titleData: try encoder.encode(title), updatedAt: now, needsSync: true))
        } else {
            return
        }
        try modelContext.save()
        try store([title])
    }

    /// Takes several titles off a list in one save (Edit › Remove).
    public func removeFromList(_ keys: [MediaKey], listID: String) throws {
        let now = Date.now.millisecondRounded
        var changed = false
        for key in keys {
            guard let r = try entryRecord(listID: listID, key: key), !r.isRemoved else { continue }
            r.isRemoved = true; r.updatedAt = now; r.needsSync = true
            changed = true
        }
        if changed { try modelContext.save() }
    }

    /// Puts a list's titles in this order; only moved entries change.
    public func reorderList(_ listID: String, keys: [MediaKey]) throws {
        let now = Date.now.millisecondRounded
        var changed = false
        for (i, key) in keys.enumerated() {
            guard let r = try entryRecord(listID: listID, key: key), !r.isRemoved, r.position != Double(i) else { continue }
            r.position = Double(i); r.updatedAt = now; r.needsSync = true
            changed = true
        }
        if changed { try modelContext.save() }
    }

    // MARK: Sync

    public func pendingListUploads() throws -> [UserList] {
        try modelContext.fetch(FetchDescriptor<UserListRecord>(predicate: #Predicate { $0.needsSync })).map(\.value)
    }

    public func pendingListEntryUploads() throws -> [ListEntry] {
        try modelContext.fetch(FetchDescriptor<ListEntryRecord>(predicate: #Predicate { $0.needsSync })).compactMap(Self.entry)
    }

    /// Clears upload flags for lists unchanged since they were pushed.
    public func markListsSynced(ifUpdatedAt dates: [String: Date]) throws {
        for (id, date) in dates {
            guard let r = try listRecord(id), r.updatedAt == date else { continue }
            r.needsSync = false
        }
        try modelContext.save()
    }

    /// Clears upload flags for entries (by `entryKey`) unchanged since they were pushed.
    public func markListEntriesSynced(ifUpdatedAt dates: [String: Date]) throws {
        for (key, date) in dates {
            guard let r = try entryRecord(key), r.updatedAt == date else { continue }
            r.needsSync = false
        }
        try modelContext.save()
    }

    /// Merges lists pulled from the cloud. Returns how many changed locally.
    @discardableResult
    public func applyRemoteLists(_ lists: [UserList]) throws -> Int {
        var changed = 0
        for l in lists {
            var incoming = l
            incoming.updatedAt = incoming.updatedAt.millisecondRounded
            if let r = try listRecord(incoming.id) {
                guard ListMerge.incomingWins(updatedAt: incoming.updatedAt, removed: incoming.isRemoved,
                                             over: r.updatedAt, removed: r.isRemoved) else { continue }
                r.update(from: incoming, needsSync: false)
            } else {
                modelContext.insert(UserListRecord(incoming, needsSync: false))
            }
            changed += 1
        }
        if changed > 0 { try modelContext.save() }
        return changed
    }

    /// Merges list entries pulled from the cloud. An entry can arrive before
    /// its list (they're separate tables); it shows once the list does.
    @discardableResult
    public func applyRemoteListEntries(_ entries: [ListEntry]) throws -> Int {
        var changed = 0
        var titles: [Title] = []
        for e in entries {
            var incoming = e
            incoming.updatedAt = incoming.updatedAt.millisecondRounded
            let data = try encoder.encode(incoming.title)
            if let r = try entryRecord(incoming.entryKey) {
                guard ListMerge.incomingWins(updatedAt: incoming.updatedAt, removed: incoming.isRemoved,
                                             over: r.updatedAt, removed: r.isRemoved) else { continue }
                r.titleData = data; r.position = incoming.position; r.addedAt = incoming.addedAt
                r.isRemoved = incoming.isRemoved; r.updatedAt = incoming.updatedAt; r.needsSync = false
            } else {
                modelContext.insert(ListEntryRecord(listID: incoming.listID, mediaKey: incoming.key, position: incoming.position,
                                                    addedAt: incoming.addedAt, titleData: data, isRemoved: incoming.isRemoved,
                                                    updatedAt: incoming.updatedAt, needsSync: false))
            }
            if !incoming.isRemoved { titles.append(incoming.title) }
            changed += 1
        }
        if changed > 0 {
            try modelContext.save()
            try store(titles)
        }
        return changed
    }

    // MARK: Title facts

    /// Runtimes and 4K seen, by key, for smart lists.
    public func titleFacts(for keys: [MediaKey]) throws -> [MediaKey: TitleFacts] {
        let wanted = Set(keys.map(\.rawValue))
        guard !wanted.isEmpty else { return [:] }
        var out: [MediaKey: TitleFacts] = [:]
        for r in try modelContext.fetch(FetchDescriptor<TitleFactsRecord>()) where wanted.contains(r.key) {
            out[MediaKey(rawValue: r.key)] = TitleFacts(runtimeMinutes: r.runtimeMinutes, has4K: r.has4K)
        }
        return out
    }

    /// Remembers what was learned about a title. Nil fields leave what's known.
    public func noteTitleFacts(_ key: MediaKey, runtimeMinutes: Int? = nil, has4K: Bool? = nil) throws {
        guard runtimeMinutes != nil || has4K != nil else { return }
        let raw = key.rawValue
        var d = FetchDescriptor<TitleFactsRecord>(predicate: #Predicate { $0.key == raw })
        d.fetchLimit = 1
        if let r = try modelContext.fetch(d).first {
            let runtime = runtimeMinutes ?? r.runtimeMinutes, fourK = has4K ?? r.has4K
            guard runtime != r.runtimeMinutes || fourK != r.has4K else { return }
            r.runtimeMinutes = runtime; r.has4K = fourK; r.updatedAt = .now
        } else {
            modelContext.insert(TitleFactsRecord(key: raw, runtimeMinutes: runtimeMinutes, has4K: has4K))
        }
        try modelContext.save()
    }

    // MARK: Private

    private func listRecord(_ id: String) throws -> UserListRecord? {
        var d = FetchDescriptor<UserListRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    private func entryRecords(_ listID: String) throws -> [ListEntryRecord] {
        let d = FetchDescriptor<ListEntryRecord>(predicate: #Predicate { $0.listID == listID },
                                                 sortBy: [SortDescriptor(\.position), SortDescriptor(\.addedAt)])
        return try modelContext.fetch(d)
    }

    private func entryRecord(listID: String, key: MediaKey) throws -> ListEntryRecord? {
        try entryRecord(ListEntry.entryKey(listID: listID, key: key))
    }

    private func entryRecord(_ entryKey: String) throws -> ListEntryRecord? {
        var d = FetchDescriptor<ListEntryRecord>(predicate: #Predicate { $0.key == entryKey })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    /// After the last live entry, so an added or re-added title goes to the end.
    private func nextPosition(_ listID: String) throws -> Double {
        (try entryRecords(listID).filter { !$0.isRemoved }.map(\.position).max() ?? -1) + 1
    }

    private static func entry(_ r: ListEntryRecord) -> ListEntry? {
        guard let title = try? decoder.decode(Title.self, from: r.titleData) else { return nil }
        return ListEntry(listID: r.listID, title: title, position: r.position, addedAt: r.addedAt,
                         isRemoved: r.isRemoved, updatedAt: r.updatedAt)
    }
}

/// What's known about a title beyond `Title`, for smart lists.
public struct TitleFacts: Hashable, Sendable {
    public var runtimeMinutes: Int?
    public var has4K: Bool?
    public init(runtimeMinutes: Int? = nil, has4K: Bool? = nil) { self.runtimeMinutes = runtimeMinutes; self.has4K = has4K }
}

public enum ListError: Error, Equatable, LocalizedError {
    case emptyName, notFound
    public var errorDescription: String? {
        switch self {
        case .emptyName: "A list needs a name."
        case .notFound: "That list isn't there any more."
        }
    }
}
