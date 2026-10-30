import Domain
import Foundation
import Metadata
import Persistence

/// Pushes local changes to Supabase and pulls everyone else's.
///
/// One pass:
/// 0. If this device last synced with a different account, stop with
///    `SyncError.accountChanged` until the user chooses (`approve` or `adopt`):
///    nothing (library, settings, keys) moves between accounts without a choice.
/// 1. If the signed-in user differs from the last one that synced this
///    profile, flag everything local for upload (the local library joins the
///    account: a device's first sign-in, or the user chose to add it).
/// 2. Push pending progress and watchlist entries through the `sync_*`
///    functions, which merge on the server and return the stored rows.
///    Rows that came back are merged locally, then the upload flags are cleared
///    for records that didn't change while the request was in flight.
/// 3. Pull rows changed since the saved cursor, in pages ordered by
///    (server_updated_at, media_key). Each pull starts a little before the
///    cursor so a row committed late by a concurrent transaction isn't missed;
///    merging is idempotent, so re-reading a few rows is harmless.
public actor SyncEngine {
    public struct Report: Sendable, Equatable {
        public var uploaded = 0
        /// Local records that changed because of what the server returned.
        public var applied = 0
        /// Settings keys (`SettingsSync`) another device changed, now written here.
        public var settingsChanged: [String] = []
        public init(uploaded: Int = 0, applied: Int = 0, settingsChanged: [String] = []) {
            self.uploaded = uploaded; self.applied = applied; self.settingsChanged = settingsChanged
        }
    }

    let auth: SupabaseAuth
    let config: SupabaseConfig
    let http: any HTTPClient
    let store: LibraryStore
    let prefs: PreferencesStore
    /// Whose library `store` holds. Rows on the server are scoped to it.
    public let profileID: String
    let profiles: ProfileStore?
    let settings: SettingsSync?
    static let batchSize = 200
    static let pageSize = 500
    /// How far before the saved cursor each pull starts.
    static let pullOverlapSeconds: Int64 = 120

    private var running = false
    private var rerun = false

    public init(auth: SupabaseAuth, config: SupabaseConfig, http: any HTTPClient, store: LibraryStore, prefs: PreferencesStore,
                profileID: String = Profile.defaultID, profiles: ProfileStore? = nil, settings: SettingsSync? = nil) {
        self.auth = auth; self.config = config; self.http = http; self.store = store; self.prefs = prefs
        self.profileID = profileID; self.profiles = profiles; self.settings = settings
    }

    /// Runs a sync pass. A call made while a pass is running makes that pass
    /// run once more instead of starting a second one in parallel.
    @discardableResult
    public func sync() async throws -> Report {
        if running { rerun = true; return Report() }
        running = true
        defer { running = false }
        var total = Report()
        repeat {
            rerun = false
            let r = try await runOnce()
            total.uploaded += r.uploaded; total.applied += r.applied; total.settingsChanged += r.settingsChanged
        } while rerun
        return total
    }

    private func runOnce() async throws -> Report {
        guard let session = await auth.currentSession else { throw SyncError.signedOut }
        if let previous = Self.previousAccount(prefs), previous != session.userID,
           prefs.value(String.self, for: Keys.approvedUserID) != session.userID {
            throw SyncError.accountChanged(previous: previous)
        }
        let lastUserKey = Keys.lastUserID(profile: profileID)
        if prefs.value(String.self, for: lastUserKey) != session.userID {
            try await store.markAllNeedingSync()
            if profileID == Profile.defaultID { profiles?.markAllNeedingSync() }
            prefs.set(session.userID, for: lastUserKey)
        }
        var report = Report()
        try await syncProfiles(user: session.userID, &report)
        try await syncSettings(user: session.userID, &report)
        try await pushProgress(&report)
        try await pushWatchlist(&report)
        try await pullProgress(user: session.userID, &report)
        try await pullWatchlist(user: session.userID, &report)
        try await syncLists(user: session.userID, &report)
        prefs.set(session.userID, for: Keys.lastAccountID)
        return report
    }

    // MARK: Account changes

    /// The account this device last synced with, or nil if it never has.
    /// Devices from before this was recorded fall back to the default
    /// profile's last user.
    public static func previousAccount(_ prefs: PreferencesStore) -> String? {
        prefs.value(String.self, for: Keys.lastAccountID) ?? prefs.value(String.self, for: Keys.lastUserID(profile: Profile.defaultID))
    }

    /// The user chose to add this device's library to `user`: the next pass
    /// flags it all for upload, as for a device's first sign-in.
    public static func approve(user: String, prefs: PreferencesStore) {
        prefs.set(user, for: Keys.approvedUserID)
    }

    /// The user chose `user`'s library and this device's was erased: nothing
    /// is flagged for upload, the account's library comes down.
    public static func adopt(user: String, profileIDs: [String], prefs: PreferencesStore) {
        for id in profileIDs + [Profile.defaultID] { prefs.set(user, for: Keys.lastUserID(profile: id)) }
        prefs.set(user, for: Keys.lastAccountID)
        prefs.set(user, for: Keys.approvedUserID)
    }

    // MARK: Push

    private func pushProgress(_ report: inout Report) async throws {
        let pending = try await store.pendingUploads()
        for batch in pending.chunked(Self.batchSize) {
            let rows = batch.map(ProgressRow.init)
            let data = try await authorized { try self.rpcRequest("sync_progress_for", items: rows, token: $0) }
            let stored = try decode([ProgressRow].self, data)
            report.applied += try await store.applyRemote(stored.compactMap(\.progress))
            try await store.markSynced(batch.map(\.key), ifUpdatedAt: Dictionary(batch.map { ($0.key, $0.updatedAt) }) { a, _ in a })
            report.uploaded += batch.count
        }
    }

    private func pushWatchlist(_ report: inout Report) async throws {
        let pending = try await store.pendingWatchlistUploads()
        for batch in pending.chunked(Self.batchSize) {
            let rows = batch.map(WatchlistRow.init)
            let data = try await authorized { try self.rpcRequest("sync_watchlist_for", items: rows, token: $0) }
            let stored = try decode([WatchlistRow].self, data)
            report.applied += try await store.applyRemoteWatchlist(stored.compactMap(\.entry))
            try await store.markWatchlistSynced(ifUpdatedAt: Dictionary(batch.map { ($0.key, $0.updatedAt) }) { a, _ in a })
            report.uploaded += batch.count
        }
    }

    // MARK: Lists

    /// Your own lists, then their entries, pushed and pulled like the watchlist.
    /// A project set up before lists has neither table: everything else still
    /// syncs, and the lists stay on this device until the migration runs.
    private func syncLists(user: String, _ report: inout Report) async throws {
        do {
            let lists = try await store.pendingListUploads()
            for batch in lists.chunked(Self.batchSize) {
                let rows = batch.map(ListRow.init)
                let data = try await authorized { try self.rpcRequest("sync_lists_for", items: rows, token: $0) }
                report.applied += try await store.applyRemoteLists(try decode([ListRow].self, data).compactMap(\.list))
                try await store.markListsSynced(ifUpdatedAt: Dictionary(batch.map { ($0.id, $0.updatedAt) }) { a, _ in a })
                report.uploaded += batch.count
            }
            let entries = try await store.pendingListEntryUploads()
            for batch in entries.chunked(Self.batchSize) {
                let rows = batch.map(ListEntryRow.init)
                let data = try await authorized { try self.rpcRequest("sync_list_entries_for", items: rows, token: $0) }
                report.applied += try await store.applyRemoteListEntries(try decode([ListEntryRow].self, data).compactMap(\.entry))
                try await store.markListEntriesSynced(ifUpdatedAt: Dictionary(batch.map { ($0.entryKey, $0.updatedAt) }) { a, _ in a })
                report.uploaded += batch.count
            }
            try await pull(table: "lists", columns: ListRow.columns, user: user, as: ListRow.self) { rows in
                try await self.store.applyRemoteLists(rows.compactMap(\.list))
            } report: { report.applied += $0 }
            try await pull(table: "list_entries", columns: ListEntryRow.columns, user: user, as: ListEntryRow.self) { rows in
                try await self.store.applyRemoteListEntries(rows.compactMap(\.entry))
            } report: { report.applied += $0 }
        } catch SyncError.server(let status, let message) where Self.isMissingTable(status: status, message: message) {
            return
        }
    }

    // MARK: Profiles

    private func syncProfiles(user: String, _ report: inout Report) async throws {
        guard let profiles else { return }
        let pending = profiles.pendingUploads()
        if !pending.isEmpty {
            let rows = pending.map(ProfileRow.init)
            let data = try await authorized { try self.rpcRequest("sync_profiles", items: rows, token: $0, profile: nil) }
            let stored = try decode([ProfileRow].self, data)
            report.applied += profiles.applyRemote(stored.compactMap(\.profile))
            profiles.markSynced(ifUpdatedAt: Dictionary(pending.map { ($0.id, $0.updatedAt) }) { a, _ in a })
            report.uploaded += pending.count
        }
        try await pull(table: "profiles", columns: ProfileRow.columns, user: user, as: ProfileRow.self, scoped: false) { rows in
            profiles.applyRemote(rows.compactMap(\.profile))
        } report: { report.applied += $0 }
    }

    // MARK: Settings

    /// Account-wide, like profiles. A project set up before account settings
    /// has no table: the library still syncs (Settings › Account says why keys don't).
    private func syncSettings(user: String, _ report: inout Report) async throws {
        guard let settings else { return }
        do {
            settings.begin(user: user)
            settings.adoptExisting()
            let pending = settings.pending()
            for batch in pending.chunked(Self.batchSize) {
                let rows = Array(batch)
                let data = try await authorized { try self.rpcRequest("sync_settings", items: rows, token: $0, profile: nil) }
                let stored = try decode([SettingRow].self, data)
                report.settingsChanged += settings.applyRemote(stored)
                settings.markSynced(rows)
                report.uploaded += rows.count
            }
            var changed: [String] = []
            try await pull(table: "account_settings", columns: SettingRow.columns, user: user, as: SettingRow.self, scoped: false) { rows in
                let keys = settings.applyRemote(rows)
                changed += keys
                return keys.count
            } report: { _ in }
            report.settingsChanged += changed
        } catch SyncError.server(let status, let message) where Self.isMissingTable(status: status, message: message) {
            return
        }
    }

    /// Deletes every Keychain value (`secret.*` rows) this account has on the
    /// server. A delete, not a removal marker, so no device's Keychain is
    /// touched; the device forgets its stamps so turning Sync API Keys on
    /// later uploads them again.
    public func removeSecretsFromServer() async throws {
        var c = URLComponents(url: config.endpoint("rest/v1/account_settings"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "key", value: "like.\(SettingsSync.secretPrefix)*")]
        _ = try await authorized { token in
            var req = self.baseRequest(c.url!, token: token)
            req.httpMethod = "DELETE"
            return req
        }
        settings?.forgetSecretStamps()
    }

    static func isMissingTable(status: Int, message: String?) -> Bool {
        let m = message ?? ""
        return status == 404 || m.contains("PGRST205") || m.contains("PGRST202")
            || ["account_settings", "lists", "list_entries"].contains(where: m.contains) && m.contains("does not exist")
    }

    // MARK: Pull

    private func pullProgress(user: String, _ report: inout Report) async throws {
        try await pull(table: "watch_progress", columns: ProgressRow.columns, user: user, as: ProgressRow.self) { rows in
            try await self.store.applyRemote(rows.compactMap(\.progress))
        } report: { report.applied += $0 }
    }

    private func pullWatchlist(user: String, _ report: inout Report) async throws {
        try await pull(table: "watchlist_entries", columns: WatchlistRow.columns, user: user, as: WatchlistRow.self) { rows in
            try await self.store.applyRemoteWatchlist(rows.compactMap(\.entry))
        } report: { report.applied += $0 }
    }

    private func pull<Row: PulledRow>(
        table: String, columns: String, user: String, as: Row.Type, scoped: Bool = true,
        apply: ([Row]) async throws -> Int, report: (Int) -> Void
    ) async throws {
        let cursorKey = Keys.cursor(user: user, table: table, profile: scoped ? profileID : nil)
        let saved = prefs.value(SyncCursor.self, for: cursorKey)
        var after = saved.map { SyncCursor(timestamp: $0.timestamp.adding(seconds: -Self.pullOverlapSeconds), mediaKey: "") }
        var newest = saved
        while true {
            let data = try await authorized {
                try self.selectRequest(table, columns: columns, after: after, token: $0, profile: scoped ? self.profileID : nil)
            }
            let rows = try decode([Row].self, data)
            report(try await apply(rows))
            guard let last = rows.last, let ts = SyncTimestamp(iso: last.serverUpdatedAt) else { break }
            let c = SyncCursor(timestamp: ts, mediaKey: last.mediaKey)
            after = c
            if newest.map({ c > $0 }) ?? true { newest = c }
            if rows.count < Self.pageSize { break }
        }
        if let newest { prefs.set(newest, for: cursorKey) }
    }

    // MARK: Requests

    /// Sends a request with a fresh access token, refreshing once on 401.
    private func authorized(_ make: (String) throws -> URLRequest) async throws -> Data {
        let token = try await auth.accessToken()
        do {
            return try await SupabaseTransport.send(try make(token), http: http)
        } catch SyncError.server(status: 401, _) {
            let fresh = try await auth.refresh()
            do {
                return try await SupabaseTransport.send(try make(fresh.accessToken), http: http)
            } catch SyncError.server(status: 401, _) {
                await auth.invalidate()
                throw SyncError.signedOut
            }
        }
    }

    private func rpcRequest<T: Encodable>(_ fn: String, items: [T], token: String, profile: String? = "") throws -> URLRequest {
        var req = baseRequest(config.endpoint("rest/v1/rpc/\(fn)"), token: token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let p = profile == "" ? profileID : profile
        req.httpBody = try Self.encoder.encode(RPCBody(profile: p, items: items))
        return req
    }

    struct RPCBody<T: Encodable>: Encodable {
        let profile: String?
        let items: [T]
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(profile, forKey: .profile)
            try c.encode(items, forKey: .items)
        }
        enum CodingKeys: String, CodingKey { case profile, items }
    }

    func selectRequest(_ table: String, columns: String, after: SyncCursor?, token: String, profile: String? = nil) throws -> URLRequest {
        var c = URLComponents(url: config.endpoint("rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "select", value: columns),
            URLQueryItem(name: "order", value: "server_updated_at.asc,\(Self.keyColumn(table)).asc"),
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
        ]
        if let profile { items.append(URLQueryItem(name: "profile_id", value: "eq.\(Self.quoted(profile))")) }
        if let after {
            let ts = Self.quoted(after.timestamp.iso), key = Self.quoted(after.mediaKey)
            let keyColumn = Self.keyColumn(table)
            items.append(URLQueryItem(name: "or", value: "(server_updated_at.gt.\(ts),and(server_updated_at.eq.\(ts),\(keyColumn).gt.\(key)))"))
        }
        c.queryItems = items
        // URLComponents leaves '+' alone, which servers read as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var req = baseRequest(c.url!, token: token)
        req.httpMethod = "GET"
        return req
    }

    static func keyColumn(_ table: String) -> String {
        switch table {
        case "profiles": "id"
        case "account_settings": "key"
        case "lists": "id"
        case "list_entries": "entry_key"
        default: "media_key"
        }
    }

    private func baseRequest(_ url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30
        return req
    }

    /// PostgREST filter value quoting, needed for ':' ',' '.' and parentheses.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try Self.decoder.decode(type, from: data) }
        catch { throw SyncError.decoding(String(describing: T.self)) }
    }

    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    enum Keys {
        /// The account this device last finished a pass with.
        static let lastAccountID = "bluebox.sync.lastAccountID"
        /// An account the user chose to bring this device's library into.
        static let approvedUserID = "bluebox.sync.approvedUserID"
        /// The default profile keeps the keys used before profiles existed.
        static func lastUserID(profile: String) -> String {
            profile == Profile.defaultID ? "bluebox.sync.lastUserID" : "bluebox.sync.lastUserID.\(profile)"
        }
        static func cursor(user: String, table: String, profile: String?) -> String {
            guard let profile, profile != Profile.defaultID else { return "bluebox.sync.cursor.\(user).\(table)" }
            return "bluebox.sync.cursor.\(user).\(profile).\(table)"
        }
    }
}

/// Keyset position in a pulled table.
struct SyncCursor: Codable, Sendable, Comparable {
    var timestamp: SyncTimestamp
    var mediaKey: String
    static func < (a: Self, b: Self) -> Bool { (a.timestamp, a.mediaKey) < (b.timestamp, b.mediaKey) }
}

// MARK: Wire format

protocol PulledRow: Decodable, Sendable {
    var mediaKey: String { get }
    var serverUpdatedAt: String { get }
}

struct ProgressRow: Codable, PulledRow {
    static let columns = "media_key,position,duration,is_completed,updated_at,device_id,server_updated_at"
    var media_key: String
    var position: Double
    var duration: Double?
    var is_completed: Bool
    var updated_at: String
    var device_id: String?
    var server_updated_at: String?

    var mediaKey: String { media_key }
    var serverUpdatedAt: String { server_updated_at ?? "" }

    init(_ p: WatchProgress) {
        media_key = p.key.rawValue; position = p.position; duration = p.duration; is_completed = p.isCompleted
        updated_at = SyncTimestamp(p.updatedAt).iso; device_id = p.deviceID
    }

    var progress: WatchProgress? {
        guard let ts = SyncTimestamp(iso: updated_at), position.isFinite, position >= 0 else { return nil }
        return WatchProgress(key: MediaKey(rawValue: media_key), position: position, duration: duration,
                             isCompleted: is_completed, updatedAt: ts.date, deviceID: device_id)
    }
}

struct WatchlistRow: Codable, PulledRow {
    /// Every column, not a list: `position` only exists once the lists
    /// migration has run, and naming it would fail the pull on older projects.
    static let columns = "*"
    var media_key: String
    var title: Title
    var added_at: String
    var is_removed: Bool
    var updated_at: String
    var server_updated_at: String?
    /// My List's manual order; absent from older servers and builds.
    var position: Double?

    var mediaKey: String { media_key }
    var serverUpdatedAt: String { server_updated_at ?? "" }

    init(_ e: WatchlistEntry) {
        media_key = e.key.rawValue; title = e.title; added_at = SyncTimestamp(e.addedAt).iso
        is_removed = e.isRemoved; updated_at = SyncTimestamp(e.updatedAt).iso; position = e.position
    }

    var entry: WatchlistEntry? {
        guard let added = SyncTimestamp(iso: added_at), let updated = SyncTimestamp(iso: updated_at),
              title.key.rawValue == media_key else { return nil }
        return WatchlistEntry(title: title, addedAt: added.date, isRemoved: is_removed, updatedAt: updated.date,
                              position: position.flatMap { $0.isFinite ? $0 : nil })
    }
}

struct ListRow: Codable, PulledRow {
    static let columns = "id,name,symbol,position,created_at,is_removed,updated_at,server_updated_at"
    var id: String
    var name: String
    var symbol: String
    var position: Double
    var created_at: String
    var is_removed: Bool
    var updated_at: String
    var server_updated_at: String?

    var mediaKey: String { id }
    var serverUpdatedAt: String { server_updated_at ?? "" }

    init(_ l: UserList) {
        id = l.id; name = l.name; symbol = l.symbol; position = l.position; created_at = SyncTimestamp(l.createdAt).iso
        is_removed = l.isRemoved; updated_at = SyncTimestamp(l.updatedAt).iso
    }

    var list: UserList? {
        guard let created = SyncTimestamp(iso: created_at), let updated = SyncTimestamp(iso: updated_at), !id.isEmpty,
              let clean = UserList.cleanName(name), position.isFinite else { return nil }
        return UserList(id: id, name: clean, symbol: symbol.isEmpty ? UserList.defaultSymbol : symbol, position: position,
                        createdAt: created.date, isRemoved: is_removed, updatedAt: updated.date)
    }
}

struct ListEntryRow: Codable, PulledRow {
    static let columns = "list_id,media_key,entry_key,title,position,added_at,is_removed,updated_at,server_updated_at"
    var list_id: String
    var media_key: String
    /// Generated by the server (`list_id/media_key`); never sent.
    var entry_key: String?
    var title: Title
    var position: Double
    var added_at: String
    var is_removed: Bool
    var updated_at: String
    var server_updated_at: String?

    var mediaKey: String { entry_key ?? ListEntry.entryKey(listID: list_id, key: MediaKey(rawValue: media_key)) }
    var serverUpdatedAt: String { server_updated_at ?? "" }

    init(_ e: ListEntry) {
        list_id = e.listID; media_key = e.key.rawValue; title = e.title; position = e.position
        added_at = SyncTimestamp(e.addedAt).iso; is_removed = e.isRemoved; updated_at = SyncTimestamp(e.updatedAt).iso
    }

    var entry: ListEntry? {
        guard let added = SyncTimestamp(iso: added_at), let updated = SyncTimestamp(iso: updated_at),
              title.key.rawValue == media_key, !list_id.isEmpty, position.isFinite else { return nil }
        return ListEntry(listID: list_id, title: title, position: position, addedAt: added.date, isRemoved: is_removed,
                         updatedAt: updated.date)
    }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}

struct ProfileRow: Codable, PulledRow {
    static let columns = "id,name,symbol,color,is_removed,updated_at,server_updated_at"
    var id: String
    var name: String
    var symbol: String
    var color: Int
    var is_removed: Bool
    var updated_at: String
    var server_updated_at: String?

    var mediaKey: String { id }
    var serverUpdatedAt: String { server_updated_at ?? "" }

    init(_ p: Profile) {
        id = p.id; name = p.name; symbol = p.symbol; color = p.color; is_removed = p.isRemoved
        updated_at = SyncTimestamp(p.updatedAt).iso
    }

    var profile: Profile? {
        guard let ts = SyncTimestamp(iso: updated_at), !id.isEmpty else { return nil }
        return Profile(id: id, name: String(name.prefix(40)), symbol: symbol, color: max(0, min(color, 15)),
                       isRemoved: is_removed, updatedAt: ts.date)
    }
}
