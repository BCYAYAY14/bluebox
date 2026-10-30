import Foundation
import Metadata

// Everything the "connect your own Supabase project" flow needs before a
// project is stored: checking what the user typed, telling the anon key apart
// from the service-role key, linking to the right dashboard pages, and probing
// the project for the tables setup.sql creates.

/// What kind of Supabase API key a string is. Only client-safe keys
/// (publishable, legacy anon) may be stored or sent.
public enum SupabaseKeyKind: Equatable, Sendable {
    case empty
    /// `sb_publishable_…`
    case publishable
    /// A legacy JWT with `role: anon`. `ref` is the project it belongs to, when present.
    case anon(ref: String?)
    /// `sb_secret_…`: full access, bypasses row level security.
    case secret
    /// A legacy JWT with `role: service_role`: full access, bypasses row level security.
    case serviceRole
    /// A JWT for some other role, such as a user's access token.
    case otherJWT(role: String?)
    case unrecognized

    public init(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { self = .empty; return }
        if key.hasPrefix("sb_publishable_") { self = key.count > 20 ? .publishable : .unrecognized; return }
        if key.hasPrefix("sb_secret_") { self = .secret; return }
        guard let claims = Self.jwtClaims(key) else { self = .unrecognized; return }
        switch claims["role"] as? String {
        case "anon": self = .anon(ref: claims["ref"] as? String)
        case "service_role": self = .serviceRole
        case let role: self = .otherJWT(role: role)
        }
    }

    /// True for the publishable and anon keys, which are meant to ship in apps.
    public var isClientSafe: Bool {
        switch self {
        case .publishable, .anon: true
        default: false
        }
    }

    /// True for keys that bypass row level security. Bluebox never stores or sends these.
    public var isPrivileged: Bool { self == .secret || self == .serviceRole }

    /// The project a legacy key was issued for.
    public var projectRef: String? { if case .anon(let ref) = self { ref } else { nil } }

    /// The payload of a JWT, without checking its signature (only the server can).
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Checks a project URL and key as they're typed, and turns them into a config.
public enum SupabaseSetupInput {
    public enum URLCheck: Equatable, Sendable {
        case empty
        /// Usable. `ref` is the project ref for hosted (`*.supabase.co`) projects.
        case valid(URL, ref: String?)
        case invalid(String)

        public var url: URL? { if case .valid(let u, _) = self { u } else { nil } }
        public var ref: String? { if case .valid(_, let r) = self { r } else { nil } }
    }

    public enum KeyCheck: Equatable, Sendable {
        case empty
        case valid(SupabaseKeyKind)
        /// A service-role or secret key: refused, with an explanation.
        case privileged(String)
        case invalid(String)

        public var isValid: Bool { if case .valid = self { true } else { false } }
    }

    static let hostedSuffix = ".supabase.co"

    /// Accepts a project URL, a bare project ref, an API URL with a path
    /// (`…/rest/v1/`), or a dashboard link (`supabase.com/dashboard/project/<ref>/…`).
    public static func checkURL(_ raw: String) -> URLCheck {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        if text.hasPrefix("sb_") || text.hasPrefix("eyJ") {
            return .invalid("That's a key. Paste it in the key field below, and the Project URL here.")
        }
        if isProjectRef(text) { return .valid(URL(string: "https://\(text)\(hostedSuffix)")!, ref: text) }
        if !text.contains("://") { text = "https://" + text }
        guard let comps = URLComponents(string: text), let host = comps.host?.lowercased(), !host.isEmpty,
              let scheme = comps.scheme?.lowercased() else {
            return .invalid("Enter the Project URL, like https://abcd1234.supabase.co.")
        }
        // A dashboard link carries the project ref.
        if host == "supabase.com" || host == "app.supabase.com" || host.hasSuffix(".supabase.com") {
            let parts = comps.path.split(separator: "/").map(String.init)
            if let i = parts.firstIndex(of: "project"), i + 1 < parts.count, isProjectRef(parts[i + 1]) {
                let ref = parts[i + 1]
                return .valid(URL(string: "https://\(ref)\(hostedSuffix)")!, ref: ref)
            }
            return .invalid("That's the Supabase website. Use your project's own URL, like https://abcd1234.supabase.co.")
        }
        let isLocal = host == "localhost" || host == "127.0.0.1" || host == "[::1]"
        guard scheme == "https" || (scheme == "http" && isLocal) else {
            return .invalid("Use an https:// address.")
        }
        guard host.contains(".") || isLocal else {
            return .invalid("Enter the full Project URL, like https://abcd1234.supabase.co.")
        }
        var base = URLComponents()
        base.scheme = scheme; base.host = comps.host; base.port = comps.port
        guard let url = base.url else { return .invalid("Enter the Project URL, like https://abcd1234.supabase.co.") }
        var ref: String?
        if host.hasSuffix(hostedSuffix) {
            let sub = String(host.dropLast(hostedSuffix.count))
            guard isProjectRef(sub) else {
                return .invalid("The Project URL is https://<project ref>.supabase.co. Copy it from Project Settings › API Keys.")
            }
            ref = sub
        }
        return .valid(url, ref: ref)
    }

    public static func checkKey(_ raw: String) -> KeyCheck {
        let kind = SupabaseKeyKind(raw)
        switch kind {
        case .empty: return .empty
        case .publishable, .anon: return .valid(kind)
        case .secret, .serviceRole:
            return .privileged("That's a \(kind == .secret ? "secret" : "service-role") key. It bypasses row level security, so it must never go in an app. Bluebox won't store or send it. Use the publishable key (sb_publishable_…) or the anon key instead, and if you've shared this one, rotate it in the dashboard.")
        case .otherJWT:
            return .invalid("That isn't an API key. Copy the publishable key (sb_publishable_…) or the anon key from Project Settings › API Keys.")
        case .unrecognized:
            return .invalid("That doesn't look like a Supabase key. The publishable key starts with sb_publishable_; the legacy anon key starts with eyJ.")
        }
    }

    /// A config ready to connect, or the reason it isn't.
    public static func config(url: String, key: String) throws -> SupabaseConfig {
        let u = checkURL(url), k = checkKey(key)
        switch k {
        case .privileged: throw SupabaseSetupError.privilegedKey
        case .invalid(let why): throw SupabaseSetupError.invalidKey(why)
        case .empty: throw SupabaseSetupError.invalidKey("Paste the publishable or anon key.")
        case .valid: break
        }
        guard case .valid(let parsed, let ref) = u else {
            if case .invalid(let why) = u { throw SupabaseSetupError.invalidURL(why) }
            throw SupabaseSetupError.invalidURL("Paste the Project URL.")
        }
        if case .valid(let kind) = k, let keyRef = kind.projectRef, let ref, keyRef != ref {
            throw SupabaseSetupError.keyForAnotherProject
        }
        guard let config = SupabaseConfig(url: parsed.absoluteString, publishableKey: key) else {
            throw SupabaseSetupError.invalidURL("Enter the Project URL, like https://abcd1234.supabase.co.")
        }
        return config
    }

    static func isProjectRef(_ s: String) -> Bool {
        s.count == 20 && s.allSatisfy { ($0.isLetter && $0.isLowercase && $0.isASCII) || ($0.isNumber && $0.isASCII) }
    }
}

/// Links into the Supabase dashboard. Without a project ref, `_` lets the
/// dashboard ask which project.
public enum SupabaseDashboard {
    public enum Page: String, Sendable {
        case sqlEditor = "sql/new"
        case apiKeys = "settings/api-keys"
        case providers = "auth/providers"
        case users = "users"
    }

    public static let projects = URL(string: "https://supabase.com/dashboard/projects")!
    /// Sign-up (and sign-in) for a Supabase account.
    public static let signUp = URL(string: "https://supabase.com/dashboard/sign-up")!
    /// Account › Access Tokens: "Generate new token".
    public static let accessTokens = URL(string: "https://supabase.com/dashboard/account/tokens")!

    public static func url(_ page: Page, ref: String?) -> URL {
        URL(string: "https://supabase.com/dashboard/project/\(ref ?? "_")/\(page.rawValue)")!
    }

    /// The project ref for a hosted project URL.
    public static func ref(for url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), host.hasSuffix(SupabaseSetupInput.hostedSuffix) else { return nil }
        let sub = String(host.dropLast(SupabaseSetupInput.hostedSuffix.count))
        return SupabaseSetupInput.isProjectRef(sub) ? sub : nil
    }
}

/// Why connecting to a project failed, in words the user can act on.
public enum SupabaseSetupError: LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case invalidKey(String)
    case privilegedKey
    case keyForAnotherProject
    case offline
    case unreachable(String)
    case notSupabase
    case badKey
    case tablesMissing
    case tablesOutdated
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let why), .invalidKey(let why): why
        case .privilegedKey: "That's a service-role or secret key. Bluebox never stores or sends those: use the publishable or anon key."
        case .keyForAnotherProject: "That key belongs to a different project than the URL. Copy both from the same project's API Keys page."
        case .offline: "You're offline. Connect to the internet and try again."
        case .unreachable(let why): "Couldn't reach that project: \(why) Check the Project URL."
        case .notSupabase: "That address answers, but not like a Supabase project. Check the Project URL."
        case .badKey: "The project rejected that key. Copy the publishable or anon key again from Project Settings › API Keys."
        case .tablesMissing: "The project is reachable, but Bluebox's tables are missing. Run setup.sql in the SQL Editor, then try again."
        case .tablesOutdated: "The project has an older version of Bluebox's tables. Set up with an access token instead (it adds only what's missing), or run Backend/supabase/migrations/20261028000000_profiles.sql in the SQL Editor, then try again."
        case .server(let status): "The project returned an error (\(status)). Try again in a minute; if it keeps happening, check the project's status in the dashboard."
        }
    }

    /// True when running setup.sql is the fix.
    public var needsSetupSQL: Bool { self == .tablesMissing || self == .tablesOutdated }
}

/// A migration the user can copy into the SQL Editor to fix a warning.
public struct SupabaseSetupScript: Hashable, Sendable {
    public let fileName: String
    public let sql: String
}

/// What a project's Auth settings (`/auth/v1/settings`) say about signing in.
public struct SupabaseProjectReport: Equatable, Sendable {
    /// The Email provider is on (Authentication › Sign In / Providers › Email).
    /// Usernames are stored as synthetic addresses, so it must be.
    public var emailEnabled: Bool
    /// New accounts can't be created; only existing ones can sign in. Automatic
    /// setup turns this on once the first account exists.
    public var signupsDisabled: Bool
    /// "Confirm email" is on: a new account would wait for an email that never comes.
    public var confirmEmailRequired: Bool
    /// Set up before account settings: the library syncs, keys and settings don't.
    public var settingsTableMissing: Bool
    /// Set up before private Realtime channels: remote control and instant sync
    /// can't join until the realtime.messages policies are added.
    public var realtimePrivateMissing: Bool

    public init(emailEnabled: Bool = true, signupsDisabled: Bool = false, confirmEmailRequired: Bool = false,
                settingsTableMissing: Bool = false, realtimePrivateMissing: Bool = false) {
        self.emailEnabled = emailEnabled; self.signupsDisabled = signupsDisabled
        self.confirmEmailRequired = confirmEmailRequired; self.settingsTableMissing = settingsTableMissing
        self.realtimePrivateMissing = realtimePrivateMissing
    }

    /// Things the user should fix in the dashboard, or empty.
    public var warnings: [String] {
        var w: [String] = []
        if !emailEnabled {
            w.append("Username sign-in needs Supabase's Email provider, which is off. Turn on Authentication › Sign In / Providers › Email.")
        }
        if confirmEmailRequired && !signupsDisabled {
            w.append("New accounts on this server must confirm an email, which Bluebox doesn't use. Turn off Authentication › Sign In / Providers › Email › Confirm email.")
        }
        if settingsTableMissing {
            w.append("API keys, add-ons and settings don't sync yet: this server is missing a newer table. Set it up again with an access token (it adds only what's missing), or copy 20261029000000_account_settings.sql below and run it in the SQL Editor.")
        }
        if realtimePrivateMissing {
            w.append("Remote control and instant sync are off: this server doesn't have Bluebox's private-channel rules yet. Set it up again with an access token, or copy 20261030000000_realtime_private.sql below and run it in the SQL Editor. Then turn off Realtime › Settings › Allow public access.")
        }
        return w
    }

    /// The migrations that fix `warnings`, for Copy buttons under them.
    public var scripts: [SupabaseSetupScript] {
        var s: [SupabaseSetupScript] = []
        if settingsTableMissing {
            s.append(.init(fileName: "20261029000000_account_settings.sql", sql: SupabaseSetupFiles.accountSettingsMigrationSQL))
        }
        if realtimePrivateMissing {
            s.append(.init(fileName: "20261030000000_realtime_private.sql", sql: SupabaseSetupFiles.realtimePrivateMigrationSQL))
        }
        return s
    }
}

/// Checks a project answers with a key and has Bluebox's tables, without
/// signing in or writing anything.
public enum SupabaseProjectProbe {
    public static func check(_ config: SupabaseConfig, http: any HTTPClient) async throws -> SupabaseProjectReport {
        // Never send a key that bypasses row level security, even to check it.
        guard SupabaseKeyKind(config.publishableKey).isClientSafe else { throw SupabaseSetupError.privilegedKey }

        let (settingsData, settingsStatus) = try await get(config, "auth/v1/settings", timeout: 15, http: http)
        switch settingsStatus {
        case 200..<300: break
        case 401, 403: throw SupabaseSetupError.badKey
        case 404: throw SupabaseSetupError.notSupabase
        default: throw SupabaseSetupError.server(settingsStatus)
        }
        guard let settings = (try? JSONSerialization.jsonObject(with: settingsData)) as? [String: Any] else {
            throw SupabaseSetupError.notSupabase
        }
        let external = settings["external"] as? [String: Any]
        var report = SupabaseProjectReport(emailEnabled: (external?["email"] as? Bool) ?? true,
                                           signupsDisabled: (settings["disable_signup"] as? Bool) ?? false,
                                           confirmEmailRequired: (settings["mailer_autoconfirm"] as? Bool).map { !$0 } ?? false)

        // The first migration's table, then the newest one's.
        if try await tableMissing("watch_progress", config, http) { throw SupabaseSetupError.tablesMissing }
        if try await tableMissing("profiles", config, http) { throw SupabaseSetupError.tablesOutdated }
        report.settingsTableMissing = try await tableMissing("account_settings", config, http)
        report.realtimePrivateMissing = try await functionMissing("bluebox_realtime_private", config, http)
        return report
    }

    /// A function PostgREST doesn't know answers 404 with PGRST202.
    static func functionMissing(_ name: String, _ config: SupabaseConfig, _ http: any HTTPClient) async throws -> Bool {
        let (data, status) = try await get(config, "rest/v1/rpc/\(name)", timeout: 15, http: http)
        let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
        if code == "PGRST202" || status == 404 { return true }
        if status >= 500 { throw SupabaseSetupError.server(status) }
        return false
    }

    /// PostgREST says "no such table" with 404 and PGRST205 (or 42P01 on older
    /// versions). Anything else, including "permission denied" (setup.sql
    /// locks the anon role out), means the table is there.
    static func tableMissing(_ table: String, _ config: SupabaseConfig, _ http: any HTTPClient) async throws -> Bool {
        let (data, status) = try await get(config, "rest/v1/\(table)", query: [URLQueryItem(name: "select", value: "*"),
                                                                            URLQueryItem(name: "limit", value: "0")],
                                           timeout: 15, http: http)
        let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
        if ["PGRST205", "42P01", "PGRST106"].contains(code ?? "") { return true }
        if status == 404 { return true }
        if status == 401 || status == 403, code == nil { throw SupabaseSetupError.badKey }
        if status >= 500 { throw SupabaseSetupError.server(status) }
        return false
    }

    static func get(_ config: SupabaseConfig, _ path: String, query: [URLQueryItem] = [], timeout: TimeInterval,
                    http: any HTTPClient) async throws -> (Data, Int) {
        var c = URLComponents(url: config.endpoint(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        req.timeoutInterval = timeout
        do {
            let (data, response) = try await http.send(req)
            return (data, response.statusCode)
        } catch let e as URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                throw SupabaseSetupError.offline
            case .cannotFindHost, .dnsLookupFailed:
                throw SupabaseSetupError.unreachable("no server has that name.")
            case .timedOut:
                throw SupabaseSetupError.unreachable("it didn't answer in time.")
            case .cannotConnectToHost:
                throw SupabaseSetupError.unreachable("the server refused the connection.")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                throw SupabaseSetupError.unreachable("its secure connection failed.")
            case .appTransportSecurityRequiresSecureConnection:
                throw SupabaseSetupError.unreachable("it needs an https:// address.")
            default:
                throw SupabaseSetupError.unreachable(e.localizedDescription)
            }
        } catch {
            throw SupabaseSetupError.unreachable(error.localizedDescription)
        }
    }
}
