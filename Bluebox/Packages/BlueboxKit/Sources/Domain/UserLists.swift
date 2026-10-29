import Foundation

// Lists (UI review decision 10): My List stays the default list, backed by the
// watchlist entries so Trakt keeps working; your own lists are these. Both sync
// with the same rules as the watchlist: newest `updatedAt` wins, and a removal
// is kept as a tombstone so it reaches other devices.

/// One of your own lists ("Halloween", "Watch with Mia").
public struct UserList: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// An SF Symbol name.
    public var symbol: String
    /// Order in the Lists grid, smallest first.
    public var position: Double
    public var createdAt: Date
    public var isRemoved: Bool
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, symbol: String = UserList.defaultSymbol, position: Double = 0,
                createdAt: Date = .now, isRemoved: Bool = false, updatedAt: Date = .now) {
        self.id = id; self.name = name; self.symbol = symbol; self.position = position
        self.createdAt = createdAt; self.isRemoved = isRemoved; self.updatedAt = updatedAt
    }

    public static let defaultSymbol = "list.bullet"
    /// Longest name the server accepts.
    public static let maxNameLength = 60

    /// Names are trimmed and capped; an empty one isn't a name.
    public static func cleanName(_ raw: String) -> String? {
        let s = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
        return s.isEmpty ? nil : s
    }
}

/// A title on one of your own lists.
public struct ListEntry: Hashable, Codable, Sendable {
    public var listID: String
    public var title: Title
    /// Manual order within the list, smallest first.
    public var position: Double
    public var addedAt: Date
    public var isRemoved: Bool
    public var updatedAt: Date

    public var key: MediaKey { title.key }
    /// The row's identity: one entry per title per list.
    public var entryKey: String { ListEntry.entryKey(listID: listID, key: title.key) }

    public init(listID: String, title: Title, position: Double, addedAt: Date, isRemoved: Bool = false, updatedAt: Date) {
        self.listID = listID; self.title = title; self.position = position; self.addedAt = addedAt
        self.isRemoved = isRemoved; self.updatedAt = updatedAt
    }

    /// Matches the server's generated `entry_key` column (`list_id || '/' || media_key`).
    public static func entryKey(listID: String, key: MediaKey) -> String { "\(listID)/\(key.rawValue)" }
}

/// The watchlist's rule, for lists and their entries (mirrored by
/// `sync_lists_for` and `sync_list_entries_for` in the Supabase migration).
public enum ListMerge {
    public static func incomingWins(updatedAt incoming: Date, removed incomingRemoved: Bool,
                                    over existing: Date, removed existingRemoved: Bool) -> Bool {
        if incoming != existing { return incoming > existing }
        return existingRemoved && !incomingRemoved
    }
}
