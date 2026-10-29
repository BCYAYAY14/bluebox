import Domain
import Foundation
import Metadata
@testable import Sync

/// In-memory stand-in for a Supabase project: GoTrue password sign-in, sign-up
/// (Confirm email off unless asked) and refresh, the sync RPCs (same merge
/// rules as the SQL migration) and keyset pulls.
final class FakeSupabase: HTTPClient, @unchecked Sendable {
    struct ProgressRowState { var row: ProgressRow; var serverTS: SyncTimestamp }
    struct WatchRowState { var row: WatchlistRow; var serverTS: SyncTimestamp }

    private let lock = NSLock()
    private var clock: Int64 = 1_800_000_000_000_000
    private var progress: [String: [String: ProgressRowState]] = [:]   // user → key → row
    private var watchlist: [String: [String: WatchRowState]] = [:]
    struct ProfileRowState { var row: ProfileRow; var serverTS: SyncTimestamp }
    private var profiles: [String: [String: ProfileRowState]] = [:]               // user → id → row
    struct SettingRowState { var row: SettingRow; var serverTS: SyncTimestamp }
    private var settings: [String: [String: SettingRowState]] = [:]               // user → key → row
    /// A project set up before account settings: its RPC and table answer 404.
    var settingsTableMissing = false
    struct ListRowState { var row: ListRow; var serverTS: SyncTimestamp }
    struct ListEntryRowState { var row: ListEntryRow; var serverTS: SyncTimestamp }
    private var lists: [String: [String: ListRowState]] = [:]                     // user|profile → id → row
    private var listEntries: [String: [String: ListEntryRowState]] = [:]          // user|profile → entry key → row
    /// A project set up before lists: their RPCs and tables answer 404.
    var listTablesMissing = false
    private var tokens: [String: String] = [:]                       // access token → user
    private var refreshTokens: [String: String] = [:]                // refresh token → user
    private(set) var log: [String] = []
    var rejectNextWithUnauthorized = false
    var rejectRefresh = false
    var validTokenHash = "hash-abc"
    var pageSize = 500
    /// Signs in any username without an account yet, so tests can skip sign-up.
    static let password = "correct horse battery"
    /// Address → password, for accounts made through `/signup`.
    private(set) var accounts: [String: String] = [:]
    /// "Confirm email" on: `/signup` answers without a session.
    var confirmEmail = false
    /// Makes `/signup` fail with this status and GoTrue error body.
    var signupFailure: (status: Int, body: String)?
    private(set) var lastSignupRequest: URLRequest?
    private(set) var lastPasswordRequest: URLRequest?
    private(set) var lastTokenHashType: String?

    /// Tokens as an implicit-flow link would carry them (`#access_token=…`).
    func mintLinkTokens(email: String) -> (access: String, refresh: String) {
        lock.withLock {
            let access = "access-\(UUID().uuidString)", refresh = "refresh-\(UUID().uuidString)"
            tokens[access] = "user-\(email)"; refreshTokens[refresh] = "user-\(email)"
            return (access, refresh)
        }
    }

    static let config = SupabaseConfig(url: "https://fake.supabase.co", publishableKey: "sb_publishable_test")!

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock { handle(request) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func count(_ prefix: String) -> Int { lock.withLock { log.filter { $0.hasPrefix(prefix) }.count } }

    private func tick() -> SyncTimestamp { clock += 1; return SyncTimestamp(microseconds: clock) }

    private func issue(user: String, email: String) -> Data {
        let access = "access-\(UUID().uuidString)", refresh = "refresh-\(UUID().uuidString)"
        tokens[access] = user; refreshTokens[refresh] = user
        let json: [String: Any] = ["access_token": access, "refresh_token": refresh, "expires_in": 3600,
                                   "user": ["id": user, "email": email]]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func handle(_ req: URLRequest) -> (Int, Data) {
        let path = req.url!.path
        log.append("\(req.httpMethod ?? "GET") \(path)")
        guard req.value(forHTTPHeaderField: "apikey") == Self.config.publishableKey else { return (401, Data()) }
        let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let grant = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "grant_type" }?.value
        switch path {
        case "/auth/v1/signup":
            lastSignupRequest = req
            if let signupFailure { return (signupFailure.status, Data(signupFailure.body.utf8)) }
            guard let email = body["email"] as? String, let password = body["password"] as? String else { return (400, Data()) }
            if accounts[email] != nil {
                return (422, Data(#"{"code":422,"error_code":"user_already_exists","msg":"User already registered"}"#.utf8))
            }
            accounts[email] = password
            if confirmEmail {
                // Confirmation on: the user, without a session.
                return (200, try! JSONSerialization.data(withJSONObject: ["id": "user-\(email)", "email": email, "aud": "authenticated"]))
            }
            return (200, issue(user: "user-\(email)", email: email))
        case "/auth/v1/token" where grant == "password":
            lastPasswordRequest = req
            guard let email = body["email"] as? String, let password = body["password"] as? String,
                  accounts[email].map({ $0 == password }) ?? (password == Self.password) else {
                return (400, Data(#"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#.utf8))
            }
            return (200, issue(user: "user-\(email)", email: email))
        case "/auth/v1/verify" where body["token_hash"] != nil:
            guard body["token_hash"] as? String == validTokenHash, let type = body["type"] as? String else {
                return (403, Data(#"{"code":403,"error_code":"otp_expired","msg":"Email link is invalid or has expired"}"#.utf8))
            }
            lastTokenHashType = type
            return (200, issue(user: "user-link@example.com", email: "link@example.com"))
        case "/auth/v1/user":
            let bearer = req.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
            guard let user = tokens[bearer] else { return (401, Data(#"{"msg":"invalid JWT"}"#.utf8)) }
            return (200, try! JSONSerialization.data(withJSONObject: ["id": user, "email": String(user.dropFirst(5))]))
        case "/auth/v1/token":
            guard !rejectRefresh, let rt = body["refresh_token"] as? String, let user = refreshTokens.removeValue(forKey: rt) else {
                return (400, Data(#"{"msg":"Invalid Refresh Token"}"#.utf8))
            }
            return (200, issue(user: user, email: String(user.dropFirst(5))))
        case "/auth/v1/logout":
            return (204, Data())
        default: break
        }
        let bearer = req.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        guard !rejectNextWithUnauthorized, let user = tokens[bearer] else {
            rejectNextWithUnauthorized = false
            return (401, Data(#"{"message":"JWT expired"}"#.utf8))
        }
        let dec = JSONDecoder(), enc = JSONEncoder()
        struct Body<T: Decodable>: Decodable { let profile: String?; let items: [T] }
        // Library rows are stored per "user|profile"; the old RPCs mean the default profile.
        let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let pulledProfile = query.first { $0.name == "profile_id" }?.value.map { String($0.dropFirst(4).dropLast()) } ?? "default"
        switch path {
        case "/rest/v1/rpc/sync_progress", "/rest/v1/rpc/sync_progress_for":
            let body = try! dec.decode(Body<ProgressRow>.self, from: req.httpBody!)
            let items = body.items
            let scope = "\(user)|\(body.profile ?? "default")"
            var table = progress[scope, default: [:]]
            for i in items {
                if let e = table[i.media_key], !progressIncomingWins(i, over: e.row) { continue }
                var r = i; let ts = tick(); r.server_updated_at = ts.iso
                table[i.media_key] = .init(row: r, serverTS: ts)
            }
            progress[scope] = table
            return (200, try! enc.encode(items.compactMap { table[$0.media_key]?.row }))
        case "/rest/v1/rpc/sync_watchlist", "/rest/v1/rpc/sync_watchlist_for":
            let body = try! dec.decode(Body<WatchlistRow>.self, from: req.httpBody!)
            let items = body.items
            let scope = "\(user)|\(body.profile ?? "default")"
            var table = watchlist[scope, default: [:]]
            for i in items {
                if let e = table[i.media_key], !watchIncomingWins(i, over: e.row) { continue }
                var r = i; let ts = tick(); r.server_updated_at = ts.iso
                if r.position == nil { r.position = table[i.media_key]?.row.position }  // coalesce, as the SQL does
                table[i.media_key] = .init(row: r, serverTS: ts)
            }
            watchlist[scope] = table
            return (200, try! enc.encode(items.compactMap { table[$0.media_key]?.row }))
        case "/rest/v1/rpc/sync_profiles":
            let items = try! dec.decode(Body<ProfileRow>.self, from: req.httpBody!).items
            var table = profiles[user, default: [:]]
            for i in items {
                if let e = table[i.id] {
                    let iu = SyncTimestamp(iso: i.updated_at)!, eu = SyncTimestamp(iso: e.row.updated_at)!
                    guard iu > eu || (iu == eu && e.row.is_removed && !i.is_removed) else { continue }
                }
                var r = i; let ts = tick(); r.server_updated_at = ts.iso
                table[i.id] = .init(row: r, serverTS: ts)
            }
            profiles[user] = table
            return (200, try! enc.encode(items.compactMap { table[$0.id]?.row }))
        case "/rest/v1/rpc/sync_settings" where !settingsTableMissing:
            let items = try! dec.decode(Body<SettingRow>.self, from: req.httpBody!).items
            var table = settings[user, default: [:]]
            for i in items {
                if let e = table[i.key], !(SyncTimestamp(iso: i.updated_at)! > SyncTimestamp(iso: e.row.updated_at)!) { continue }
                var r = i; let ts = tick(); r.server_updated_at = ts.iso
                if r.is_removed { r.value = nil }
                table[i.key] = .init(row: r, serverTS: ts)
            }
            settings[user] = table
            return (200, try! enc.encode(items.compactMap { table[$0.key]?.row }))
        case "/rest/v1/rpc/sync_lists_for" where !listTablesMissing:
            let body = try! dec.decode(Body<ListRow>.self, from: req.httpBody!)
            let scope = "\(user)|\(body.profile ?? "default")"
            var table = lists[scope, default: [:]]
            for i in body.items {
                if let e = table[i.id], !listIncomingWins(i.updated_at, i.is_removed, over: e.row.updated_at, e.row.is_removed) { continue }
                var r = i; let ts = tick(); r.server_updated_at = ts.iso
                table[i.id] = .init(row: r, serverTS: ts)
            }
            lists[scope] = table
            return (200, try! enc.encode(body.items.compactMap { table[$0.id]?.row }))
        case "/rest/v1/rpc/sync_list_entries_for" where !listTablesMissing:
            let body = try! dec.decode(Body<ListEntryRow>.self, from: req.httpBody!)
            let scope = "\(user)|\(body.profile ?? "default")"
            var table = listEntries[scope, default: [:]]
            for i in body.items {
                let key = "\(i.list_id)/\(i.media_key)"
                if let e = table[key], !listIncomingWins(i.updated_at, i.is_removed, over: e.row.updated_at, e.row.is_removed) { continue }
                var r = i; let ts = tick(); r.server_updated_at = ts.iso; r.entry_key = key
                table[key] = .init(row: r, serverTS: ts)
            }
            listEntries[scope] = table
            return (200, try! enc.encode(body.items.compactMap { table["\($0.list_id)/\($0.media_key)"]?.row }))
        case "/rest/v1/lists" where !listTablesMissing:
            let rows = (lists["\(user)|\(pulledProfile)"] ?? [:]).values.map { ($0.serverTS, $0.row.id, $0.row) }
            return (200, try! enc.encode(page(rows, req)))
        case "/rest/v1/list_entries" where !listTablesMissing:
            let rows = (listEntries["\(user)|\(pulledProfile)"] ?? [:]).values.map { ($0.serverTS, $0.row.entry_key ?? "", $0.row) }
            return (200, try! enc.encode(page(rows, req)))
        case "/rest/v1/account_settings" where !settingsTableMissing:
            let rows = (settings[user] ?? [:]).values.map { ($0.serverTS, $0.row.key, $0.row) }
            return (200, try! enc.encode(page(rows, req)))
        case "/rest/v1/watch_progress":
            let rows = (progress["\(user)|\(pulledProfile)"] ?? [:]).values.map { ($0.serverTS, $0.row.media_key, $0.row) }
            return (200, try! enc.encode(page(rows, req)))
        case "/rest/v1/watchlist_entries":
            let rows = (watchlist["\(user)|\(pulledProfile)"] ?? [:]).values.map { ($0.serverTS, $0.row.media_key, $0.row) }
            return (200, try! enc.encode(page(rows, req)))
        case "/rest/v1/profiles":
            let rows = (profiles[user] ?? [:]).values.map { ($0.serverTS, $0.row.id, $0.row) }
            return (200, try! enc.encode(page(rows, req)))
        default:
            return (404, Data())
        }
    }

    private func page<R>(_ rows: [(SyncTimestamp, String, R)], _ req: URLRequest) -> [R] {
        let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        var after: (SyncTimestamp, String)?
        if let or = q.first(where: { $0.name == "or" })?.value {
            // (server_updated_at.gt."TS",and(server_updated_at.eq."TS",media_key.gt."KEY"))
            let quoted = or.split(separator: "\"", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
            after = (SyncTimestamp(iso: quoted[0])!, quoted[2])
        }
        let limit = Int(q.first { $0.name == "limit" }?.value ?? "") ?? 1000
        return rows
            .filter { r in after.map { r.0 > $0.0 || (r.0 == $0.0 && r.1 > $0.1) } ?? true }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .prefix(min(limit, pageSize)).map(\.2)
    }

    private func progressIncomingWins(_ i: ProgressRow, over e: ProgressRow) -> Bool {
        let iu = SyncTimestamp(iso: i.updated_at)!, eu = SyncTimestamp(iso: e.updated_at)!
        if iu != eu { return iu > eu }
        if i.is_completed != e.is_completed { return i.is_completed }
        if i.position != e.position { return i.position > e.position }
        return (i.device_id ?? "") > (e.device_id ?? "")
    }

    private func listIncomingWins(_ iu: String, _ ir: Bool, over eu: String, _ er: Bool) -> Bool {
        let i = SyncTimestamp(iso: iu)!, e = SyncTimestamp(iso: eu)!
        if i != e { return i > e }
        return er && !ir
    }

    /// The server's copy of a list entry, for asserting what was pushed.
    func listEntry(user: String, profile: String = "default", _ key: String) -> ListEntryRow? {
        lock.withLock { listEntries["\(user)|\(profile)"]?[key]?.row }
    }

    private func watchIncomingWins(_ i: WatchlistRow, over e: WatchlistRow) -> Bool {
        let iu = SyncTimestamp(iso: i.updated_at)!, eu = SyncTimestamp(iso: e.updated_at)!
        if iu != eu { return iu > eu }
        return e.is_removed && !i.is_removed
    }
}
