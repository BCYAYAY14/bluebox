import Domain
import Foundation
import SwiftData

// SwiftData schema. Titles are stored as encoded JSON blobs alongside a few
// indexed columns, so metadata shape changes don't require migrations.

@Model
final class WatchlistEntryRecord {
    @Attribute(.unique) var key: String
    var addedAt: Date
    var titleData: Data
    /// Removed entries are kept as tombstones so the removal can sync.
    var isRemoved: Bool = false
    /// Last add or remove. Nil on entries created before sync existed; `addedAt` stands in.
    var updatedAt: Date?
    /// Set when the entry changed locally and hasn't been pushed to the cloud yet.
    var needsSync: Bool = true
    /// My List's manual order. Optional so stores from before lists open
    /// (a lightweight migration); nil sorts by `addedAt`, newest first.
    var position: Double?

    init(key: String, addedAt: Date, titleData: Data, isRemoved: Bool = false, updatedAt: Date, needsSync: Bool,
         position: Double? = nil) {
        self.key = key; self.addedAt = addedAt; self.titleData = titleData
        self.isRemoved = isRemoved; self.updatedAt = updatedAt; self.needsSync = needsSync
        self.position = position
    }

    var effectiveUpdatedAt: Date { updatedAt ?? addedAt }
    var effectivePosition: Double { position ?? WatchlistEntry.defaultPosition(addedAt: addedAt) }
}

/// One of your own lists. My List isn't one of these: it's the watchlist entries.
@Model
final class UserListRecord {
    @Attribute(.unique) var id: String
    var name: String
    var symbol: String
    var position: Double
    var createdAt: Date
    var updatedAt: Date
    /// Deleted lists are kept as tombstones so the deletion can sync.
    var isRemoved: Bool = false
    var needsSync: Bool = true

    init(_ l: UserList, needsSync: Bool) {
        id = l.id; name = l.name; symbol = l.symbol; position = l.position
        createdAt = l.createdAt; updatedAt = l.updatedAt; isRemoved = l.isRemoved; self.needsSync = needsSync
    }

    func update(from l: UserList, needsSync: Bool) {
        name = l.name; symbol = l.symbol; position = l.position; createdAt = l.createdAt
        updatedAt = l.updatedAt; isRemoved = l.isRemoved; self.needsSync = needsSync
    }

    var value: UserList {
        UserList(id: id, name: name, symbol: symbol, position: position, createdAt: createdAt, isRemoved: isRemoved, updatedAt: updatedAt)
    }
}

/// A title on one of your own lists, keyed `listID/mediaKey`.
@Model
final class ListEntryRecord {
    @Attribute(.unique) var key: String
    var listID: String
    var mediaKey: String
    var position: Double
    var addedAt: Date
    var titleData: Data
    var isRemoved: Bool = false
    var updatedAt: Date
    var needsSync: Bool = true

    init(listID: String, mediaKey: MediaKey, position: Double, addedAt: Date, titleData: Data, isRemoved: Bool = false,
         updatedAt: Date, needsSync: Bool) {
        key = ListEntry.entryKey(listID: listID, key: mediaKey)
        self.listID = listID; self.mediaKey = mediaKey.rawValue; self.position = position; self.addedAt = addedAt
        self.titleData = titleData; self.isRemoved = isRemoved; self.updatedAt = updatedAt; self.needsSync = needsSync
    }
}

/// What smart lists need to know about a title that `Title` doesn't carry,
/// learned as the app goes (a title page's runtime, a 4K release seen).
/// Local only: a cache, rebuilt by browsing.
@Model
final class TitleFactsRecord {
    @Attribute(.unique) var key: String
    var runtimeMinutes: Int?
    /// Some source offered it in 4K when last looked at. Nil: never looked.
    var has4K: Bool?
    var updatedAt: Date

    init(key: String, runtimeMinutes: Int? = nil, has4K: Bool? = nil, updatedAt: Date = .now) {
        self.key = key; self.runtimeMinutes = runtimeMinutes; self.has4K = has4K; self.updatedAt = updatedAt
    }
}

@Model
final class ProgressRecord {
    @Attribute(.unique) var key: String
    /// Parent series key for episodes, so per-series queries don't parse keys.
    var seriesKey: String?
    var position: Double
    var duration: Double?
    var isCompleted: Bool
    var updatedAt: Date
    var deviceID: String?
    /// Set when the record changed locally and hasn't been pushed to the cloud yet.
    var needsSync: Bool
    /// This device's clock when the record last changed here, including changes
    /// pulled from the cloud. `updatedAt` is when it was *watched*, which can be
    /// long before it reached this device. Nil on records from older builds.
    var changedAt: Date?

    init(_ p: WatchProgress, needsSync: Bool) {
        key = p.key.rawValue; seriesKey = p.key.seriesKey?.rawValue; position = p.position; duration = p.duration
        isCompleted = p.isCompleted; updatedAt = p.updatedAt; deviceID = p.deviceID; self.needsSync = needsSync
        changedAt = .now
    }

    func update(from p: WatchProgress, needsSync: Bool) {
        position = p.position; duration = p.duration; isCompleted = p.isCompleted
        updatedAt = p.updatedAt; deviceID = p.deviceID; self.needsSync = needsSync
        changedAt = .now
    }

    var value: WatchProgress {
        WatchProgress(key: MediaKey(rawValue: key), position: position, duration: duration,
                      isCompleted: isCompleted, updatedAt: updatedAt, deviceID: deviceID)
    }
}

@Model
final class CachedTitleRecord {
    @Attribute(.unique) var key: String
    var titleData: Data
    var cachedAt: Date

    init(key: String, titleData: Data, cachedAt: Date) {
        self.key = key; self.titleData = titleData; self.cachedAt = cachedAt
    }
}

enum BlueboxSchema {
    /// Unversioned on purpose: every change so far is additive (new models, new
    /// optional attributes), which SwiftData migrates in place when a store opens.
    /// `LibraryStoreMigrationTests` opens a store written with the original models.
    static let models: [any PersistentModel.Type] = [WatchlistEntryRecord.self, ProgressRecord.self, CachedTitleRecord.self,
                                                     UserListRecord.self, ListEntryRecord.self, TitleFactsRecord.self]
}
