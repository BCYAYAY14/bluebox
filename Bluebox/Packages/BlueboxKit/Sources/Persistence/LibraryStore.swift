import Domain
import Foundation
import SwiftData

/// SwiftData-backed implementation of the library, progress, and title-cache
/// repositories. All access is serialized on this actor's model context.
@ModelActor
public actor LibraryStore: LibraryRepository, ProgressRepository, TitleCache {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Opens (or creates) the on-disk store, or an in-memory one for tests and previews.
    public static func make(inMemory: Bool = false, url: URL? = nil) throws -> LibraryStore {
        let schema = Schema(BlueboxSchema.models)
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if let url {
            config = ModelConfiguration(schema: schema, url: url)
        } else {
            config = ModelConfiguration(schema: schema)
        }
        let container = try ModelContainer(for: schema, configurations: [config])
        return LibraryStore(modelContainer: container)
    }

    // MARK: Watchlist

    public func watchlist() throws -> [Title] {
        let d = FetchDescriptor<WatchlistEntryRecord>(predicate: #Predicate { !$0.isRemoved },
                                                      sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
        return try modelContext.fetch(d).compactMap { try? Self.decoder.decode(Title.self, from: $0.titleData) }
    }

    public func isOnWatchlist(_ key: MediaKey) throws -> Bool {
        let raw = key.rawValue
        return try modelContext.fetchCount(FetchDescriptor<WatchlistEntryRecord>(predicate: #Predicate { $0.key == raw && !$0.isRemoved })) > 0
    }

    public func setWatchlisted(_ title: Title, _ on: Bool) throws {
        let now = Date.now.millisecondRounded
        if let r = try watchlistRecord(title.key) {
            if r.isRemoved == !on { return try store([title]) }
            r.isRemoved = !on
            r.updatedAt = now
            r.needsSync = true
            if on {
                r.addedAt = now; r.titleData = try Self.encoder.encode(title)
                r.position = WatchlistEntry.defaultPosition(addedAt: now)
            }
        } else if on {
            modelContext.insert(WatchlistEntryRecord(key: title.key.rawValue, addedAt: now, titleData: try Self.encoder.encode(title),
                                                     updatedAt: now, needsSync: true,
                                                     position: WatchlistEntry.defaultPosition(addedAt: now)))
        }
        try modelContext.save()
        try store([title])
    }

    /// My List with each entry's manual position, in manual order.
    public func watchlistEntries() throws -> [WatchlistEntry] {
        let d = FetchDescriptor<WatchlistEntryRecord>(predicate: #Predicate { !$0.isRemoved })
        return try modelContext.fetch(d).sorted { a, b in
            a.effectivePosition != b.effectivePosition ? a.effectivePosition < b.effectivePosition : a.key < b.key
        }.compactMap { r in
            guard let title = try? Self.decoder.decode(Title.self, from: r.titleData) else { return nil }
            return WatchlistEntry(title: title, addedAt: r.addedAt, isRemoved: false, updatedAt: r.effectiveUpdatedAt,
                                  position: r.effectivePosition)
        }
    }

    /// Puts My List in this order (Edit › drag). Only entries whose place
    /// changed are touched, so a small move uploads a few rows, not the list.
    public func reorderWatchlist(_ keys: [MediaKey]) throws {
        let now = Date.now.millisecondRounded
        var changed = false
        for (i, key) in keys.enumerated() {
            guard let r = try watchlistRecord(key), !r.isRemoved, r.position != Double(i) else { continue }
            r.position = Double(i); r.updatedAt = now; r.needsSync = true
            changed = true
        }
        if changed { try modelContext.save() }
    }

    private func watchlistRecord(_ key: MediaKey) throws -> WatchlistEntryRecord? {
        let raw = key.rawValue
        var d = FetchDescriptor<WatchlistEntryRecord>(predicate: #Predicate { $0.key == raw })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    // MARK: Progress

    public func progress(for key: MediaKey) throws -> WatchProgress? {
        try record(key)?.value
    }

    public func progress(forSeries seriesKey: MediaKey) throws -> [WatchProgress] {
        let raw: String? = seriesKey.rawValue
        let d = FetchDescriptor<ProgressRecord>(predicate: #Predicate { $0.seriesKey == raw },
                                                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return try modelContext.fetch(d).map(\.value)
    }

    public func continueWatching(limit: Int) throws -> [WatchProgress] {
        let policy = ProgressPolicy.standard
        guard limit > 0 else { return [] }
        var d = FetchDescriptor<ProgressRecord>(predicate: #Predicate { !$0.isCompleted },
                                                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        // Page until the list is full: records that don't count (items taken out of
        // Continue Watching are reset to 0, barely started ones, other episodes of a
        // series already listed) can't crowd out older ones that do.
        let page = max(limit * 3, 50)
        d.fetchLimit = page
        var out: [WatchProgress] = []
        var seenSeries = Set<String>()
        var offset = 0
        while out.count < limit {
            d.fetchOffset = offset
            let batch = try modelContext.fetch(d)
            for p in batch.map(\.value) where out.count < limit {
                // One row per series, decided by its most recently touched unfinished
                // episode: if that one was taken out of Continue Watching (reset to 0),
                // an older half-watched episode mustn't bring the show back.
                if let s = p.key.seriesKey, !seenSeries.insert(s.rawValue).inserted { continue }
                if policy.isInProgress(p) { out.append(p) }
            }
            if batch.count < page { break }
            offset += page
        }
        return out
    }

    public func recent(limit: Int) throws -> [WatchProgress] {
        var d = FetchDescriptor<ProgressRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        d.fetchLimit = limit
        return try modelContext.fetch(d).map(\.value)
    }

    @discardableResult
    public func save(_ progress: WatchProgress) throws -> WatchProgress {
        try apply(progress, fromRemote: false)
    }

    /// Merges a record pulled from the cloud. It is not re-marked for upload.
    @discardableResult
    public func applyRemote(_ progress: WatchProgress) throws -> WatchProgress {
        try apply(progress, fromRemote: true)
    }

    public func pendingUploads() throws -> [WatchProgress] {
        try modelContext.fetch(FetchDescriptor<ProgressRecord>(predicate: #Predicate { $0.needsSync })).map(\.value)
    }

    public func markSynced(_ keys: [MediaKey], ifUpdatedAt dates: [MediaKey: Date]) throws {
        for key in keys {
            guard let r = try record(key), r.updatedAt == dates[key] else { continue }
            r.needsSync = false
        }
        try modelContext.save()
    }

    public func delete(_ key: MediaKey) throws {
        if let r = try record(key) { modelContext.delete(r); try modelContext.save() }
    }

    private func apply(_ incoming: WatchProgress, fromRemote: Bool) throws -> WatchProgress {
        var incoming = incoming
        incoming.updatedAt = incoming.updatedAt.millisecondRounded
        if let r = try record(incoming.key) {
            let (winner, changed) = ProgressMerge.apply(incoming: incoming, to: r.value)
            if changed {
                r.update(from: winner, needsSync: fromRemote ? false : true)
                try modelContext.save()
            }
            return winner
        }
        modelContext.insert(ProgressRecord(incoming, needsSync: !fromRemote))
        try modelContext.save()
        return incoming
    }

    // MARK: Sync

    /// Merges records pulled from the cloud in one save. Returns how many changed locally.
    @discardableResult
    public func applyRemote(_ items: [WatchProgress]) throws -> Int {
        var changed = 0
        for item in items {
            var incoming = item
            incoming.updatedAt = incoming.updatedAt.millisecondRounded
            if let r = try record(incoming.key) {
                let (winner, didChange) = ProgressMerge.apply(incoming: incoming, to: r.value)
                if didChange { r.update(from: winner, needsSync: false); changed += 1 }
            } else {
                modelContext.insert(ProgressRecord(incoming, needsSync: false))
                changed += 1
            }
        }
        if changed > 0 { try modelContext.save() }
        return changed
    }

    public func pendingWatchlistUploads() throws -> [WatchlistEntry] {
        try modelContext.fetch(FetchDescriptor<WatchlistEntryRecord>(predicate: #Predicate { $0.needsSync })).compactMap { r in
            guard let title = try? Self.decoder.decode(Title.self, from: r.titleData) else { return nil }
            return WatchlistEntry(title: title, addedAt: r.addedAt, isRemoved: r.isRemoved, updatedAt: r.effectiveUpdatedAt,
                                  position: r.position)
        }
    }

    /// Clears the upload flag for entries that haven't changed since they were pushed.
    public func markWatchlistSynced(ifUpdatedAt dates: [MediaKey: Date]) throws {
        for (key, date) in dates {
            guard let r = try watchlistRecord(key), r.effectiveUpdatedAt == date else { continue }
            r.needsSync = false
        }
        try modelContext.save()
    }

    /// Merges watchlist entries pulled from the cloud. Returns how many changed locally.
    @discardableResult
    public func applyRemoteWatchlist(_ entries: [WatchlistEntry]) throws -> Int {
        var changed = 0
        for e in entries {
            var incoming = e
            incoming.updatedAt = incoming.updatedAt.millisecondRounded
            let data = try Self.encoder.encode(incoming.title)
            if let r = try watchlistRecord(incoming.key) {
                guard let title = try? Self.decoder.decode(Title.self, from: r.titleData) else { continue }
                let existing = WatchlistEntry(title: title, addedAt: r.addedAt, isRemoved: r.isRemoved, updatedAt: r.effectiveUpdatedAt)
                guard WatchlistMerge.incomingWins(incoming, over: existing) else { continue }
                r.titleData = data; r.addedAt = incoming.addedAt; r.isRemoved = incoming.isRemoved
                r.updatedAt = incoming.updatedAt; r.needsSync = false
                // A server or build from before lists sends no position: keep ours.
                if let p = incoming.position { r.position = p }
            } else {
                modelContext.insert(WatchlistEntryRecord(key: incoming.key.rawValue, addedAt: incoming.addedAt, titleData: data,
                                                         isRemoved: incoming.isRemoved, updatedAt: incoming.updatedAt,
                                                         needsSync: false, position: incoming.position))
            }
            changed += 1
        }
        if changed > 0 {
            try modelContext.save()
            try store(entries.filter { !$0.isRemoved }.map(\.title))
        }
        return changed
    }

    // MARK: External history (Trakt)

    /// Completed movies and episodes, optionally only those that changed on this
    /// device after a date (by this device's clock). A play finished on another
    /// device last week but synced here today counts as changed today, so a
    /// cursor taken from this device's clock doesn't skip it.
    public func completedProgress(updatedAfter date: Date?) throws -> [WatchProgress] {
        let records = try modelContext.fetch(FetchDescriptor<ProgressRecord>(predicate: #Predicate { $0.isCompleted }))
        guard let date else { return records.map(\.value) }
        return records.filter { max($0.changedAt ?? $0.updatedAt, $0.updatedAt) > date }.map(\.value)
    }

    /// Marks items watched elsewhere as completed at the given times, in one
    /// save. Normal merging applies; changes are flagged for cloud upload.
    /// Returns how many records changed.
    @discardableResult
    public func importCompleted(_ watched: [MediaKey: Date]) throws -> Int {
        var changed = 0
        for (key, at) in watched {
            let existing = try record(key)
            if existing?.isCompleted == true { continue }
            let duration = existing?.value.duration
            let incoming = WatchProgress(key: key, position: duration ?? 0, duration: duration, isCompleted: true,
                                         updatedAt: at.millisecondRounded)
            if let existing {
                let (winner, didChange) = ProgressMerge.apply(incoming: incoming, to: existing.value)
                if didChange { existing.update(from: winner, needsSync: true); changed += 1 }
            } else {
                modelContext.insert(ProgressRecord(incoming, needsSync: true))
                changed += 1
            }
        }
        if changed > 0 { try modelContext.save() }
        return changed
    }

    /// Deletes every progress record, watchlist entry, list and list entry,
    /// without removal markers: this device chose another account's library,
    /// and the old one stays in its own account. Cached titles stay.
    public func eraseLibrary() throws {
        try modelContext.fetch(FetchDescriptor<ProgressRecord>()).forEach { modelContext.delete($0) }
        try modelContext.fetch(FetchDescriptor<WatchlistEntryRecord>()).forEach { modelContext.delete($0) }
        try modelContext.fetch(FetchDescriptor<ListEntryRecord>()).forEach { modelContext.delete($0) }
        try modelContext.fetch(FetchDescriptor<UserListRecord>()).forEach { modelContext.delete($0) }
        try modelContext.save()
    }

    /// Flags every progress record, watchlist entry, list and list entry for upload, e.g. after
    /// signing in to a different account.
    public func markAllNeedingSync() throws {
        try modelContext.fetch(FetchDescriptor<ProgressRecord>()).forEach { $0.needsSync = true }
        try modelContext.fetch(FetchDescriptor<WatchlistEntryRecord>()).forEach { $0.needsSync = true }
        try modelContext.fetch(FetchDescriptor<UserListRecord>()).forEach { $0.needsSync = true }
        try modelContext.fetch(FetchDescriptor<ListEntryRecord>()).forEach { $0.needsSync = true }
        try modelContext.save()
    }

    private func record(_ key: MediaKey) throws -> ProgressRecord? {
        let raw = key.rawValue
        var d = FetchDescriptor<ProgressRecord>(predicate: #Predicate { $0.key == raw })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    // MARK: Title cache

    public func store(_ titles: [Title]) throws {
        for t in titles {
            let raw = t.key.rawValue
            let data = try Self.encoder.encode(t)
            if let existing = try modelContext.fetch(FetchDescriptor<CachedTitleRecord>(predicate: #Predicate { $0.key == raw })).first {
                existing.titleData = data; existing.cachedAt = .now
            } else {
                modelContext.insert(CachedTitleRecord(key: raw, titleData: data, cachedAt: .now))
            }
        }
        try modelContext.save()
    }

    public func title(for key: MediaKey) throws -> Title? {
        let raw = key.rawValue
        guard let r = try modelContext.fetch(FetchDescriptor<CachedTitleRecord>(predicate: #Predicate { $0.key == raw })).first
        else { return nil }
        return try? Self.decoder.decode(Title.self, from: r.titleData)
    }
}
