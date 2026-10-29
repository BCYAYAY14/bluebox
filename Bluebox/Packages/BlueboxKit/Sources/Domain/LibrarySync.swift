import Foundation

/// A watchlist entry as it is synced. Removals are kept as tombstones
/// (`isRemoved`) so they reach other devices instead of being resurrected.
public struct WatchlistEntry: Hashable, Codable, Sendable {
    public var title: Title
    public var addedAt: Date
    public var isRemoved: Bool
    public var updatedAt: Date
    /// My List's manual order (smallest first). Nil from builds and servers
    /// before lists: such an entry sorts by when it was added, newest first.
    public var position: Double?

    public var key: MediaKey { title.key }

    public init(title: Title, addedAt: Date, isRemoved: Bool = false, updatedAt: Date, position: Double? = nil) {
        self.title = title; self.addedAt = addedAt; self.isRemoved = isRemoved; self.updatedAt = updatedAt
        self.position = position
    }

    /// Newest added first until the list is reordered by hand.
    public static func defaultPosition(addedAt: Date) -> Double { -addedAt.timeIntervalSince1970 }
}

/// Deterministic merge for watchlist entries (mirrored by `sync_watchlist` in
/// the Supabase migration): the newer `updatedAt` wins; on an exact tie, an
/// entry that is present beats a removal; otherwise the existing value stays.
public enum WatchlistMerge {
    public static func incomingWins(_ incoming: WatchlistEntry, over existing: WatchlistEntry) -> Bool {
        if incoming.updatedAt != existing.updatedAt { return incoming.updatedAt > existing.updatedAt }
        return existing.isRemoved && !incoming.isRemoved
    }
}

public extension Date {
    /// Whole milliseconds since 1970. Sync timestamps are stored at this
    /// precision on every side, so a value survives a round trip through the
    /// server unchanged and equality checks stay exact.
    var millisecondsSince1970: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(millisecondsSince1970 ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// This date rounded to the nearest millisecond.
    var millisecondRounded: Date { Date(millisecondsSince1970: millisecondsSince1970) }
}
