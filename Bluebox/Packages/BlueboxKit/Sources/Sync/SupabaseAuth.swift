import Domain
import Foundation
import Metadata
import Persistence

public enum SyncError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured
    case signedOut
    case rateLimited
    case offline
    case server(status: Int, message: String?)
    case decoding(String)
    /// A username that breaks the rules (`BlueboxUsername`).
    case invalidUsername(String)
    /// A password Bluebox or the project refuses, with the reason.
    case weakPassword(String)
    case wrongPassword
    case usernameTaken
    /// The project asks new accounts to confirm an email, which a username can't do.
    case confirmEmailRequired
    /// An account made while the project still asked for confirmation.
    case accountNotConfirmed
    case signupsDisabled
    case emailSignInDisabled
    /// This device last synced with another account (its user ID): nothing
    /// syncs until the user chooses what happens to the device's library.
    case accountChanged(previous: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Connect your server first, in Settings › Account & Sync."
        case .signedOut: "You've been signed out. Sign in again to keep syncing."
        case .rateLimited: "Too many attempts. Wait a minute and try again."
        case .offline: "You're offline. Changes will sync when you reconnect."
        case .server(let status, let message):
            status == 0 ? (message ?? "The connection failed.")
                : message.map { "The server returned an error (\(status)): \($0)" } ?? "The server returned an error (\(status))."
        case .decoding(let d): "The sync server sent data Bluebox couldn't read (\(d))."
        case .invalidUsername(let why), .weakPassword(let why): why
        case .wrongPassword: "Wrong username or password."
        case .usernameTaken: "That username is taken. Sign in instead, or pick another."
        case .confirmEmailRequired:
            "Your server asks new accounts to confirm an email, which Bluebox doesn't use. In Supabase, open Authentication › Sign In / Providers › Email, turn off Confirm email, save, and try again."
        case .accountNotConfirmed:
            "This account was made while your server still asked for email confirmation. In Supabase, open Authentication › Users, delete it, then create it again here."
        case .signupsDisabled: "Your server doesn't allow new accounts. Sign in with the account you already have."
        case .emailSignInDisabled: "Username sign-in needs Supabase's Email provider. Turn on Authentication › Sign In / Providers › Email."
        case .accountChanged: "This device has another account's library. Choose what to do with it to start syncing."
        }
    }
}

/// A signed-in Supabase session. Stored in the Keychain, never in defaults.
public struct AuthSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var userID: String
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userID: String, email: String?) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.userID = userID; self.email = email
    }
}

extension SecretAccount {
    public static let supabaseSession = "supabase.session"
    /// A project entered in Settings: URL and publishable key, as JSON.
    public static let supabaseServer = "supabase.server"
}

/// Supabase Auth (GoTrue) over REST: username and password, token refresh, sign-out.
public actor SupabaseAuth {
    let config: SupabaseConfig
    let http: any HTTPClient
    let secrets: any SecretStore
    let now: @Sendable () -> Date
    private var session: AuthSession?
    private var refreshing: Task<AuthSession, Error>?
    private var observers: [UUID: @Sendable (AuthSession?) -> Void] = [:]
    private let retiredFlag = Flag()

    /// A one-way switch readable from any thread.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Refresh this long before the access token expires.
    static let refreshMargin: TimeInterval = 60

    public init(config: SupabaseConfig, http: any HTTPClient, secrets: any SecretStore,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config; self.http = http; self.secrets = secrets; self.now = now
        session = (try? secrets.read(SecretAccount.supabaseSession))
            .flatMap { $0 }
            .flatMap { try? JSONDecoder().decode(AuthSession.self, from: Data($0.utf8)) }
    }

    public var currentSession: AuthSession? { session }

    /// Called whenever the session changes (sign-in, refresh, sign-out).
    public func observe(_ handler: @escaping @Sendable (AuthSession?) -> Void) {
        observers[UUID()] = handler
    }

    /// Signs in with a username and password (`grant_type=password`).
    @discardableResult
    public func signIn(username: String, password: String) async throws -> AuthSession {
        let email = try Self.email(for: username)
        guard !password.isEmpty else { throw SyncError.wrongPassword }
        var req = request("auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "password")])
        req.httpBody = try JSONEncoder().encode(["email": email, "password": password])
        do {
            let s = try decodeSession(try await sendAuth(req))
            try setSession(s)
            return s
        } catch let f as AuthFailure {
            throw Self.signInError(f)
        }
    }

    /// Creates an account and signs straight in. Needs the project's
    /// "Confirm email" off (`mailer_autoconfirm`), which automatic setup turns off.
    @discardableResult
    public func signUp(username: String, password: String) async throws -> AuthSession {
        let email = try Self.email(for: username)
        if let why = BlueboxUsername.checkPassword(password) { throw SyncError.weakPassword(why) }
        var req = request("auth/v1/signup")
        req.httpBody = try JSONEncoder().encode(["email": email, "password": password])
        let data: Data
        do {
            data = try await sendAuth(req)
        } catch let f as AuthFailure {
            throw Self.signUpError(f)
        }
        // With confirmation on, Supabase answers with the new user but no session.
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard obj?["access_token"] != nil else { throw SyncError.confirmEmailRequired }
        let s = try decodeSession(data)
        try setSession(s)
        return s
    }

    /// Signs in with an Apple identity token (Sign in with Apple). `nonce` is
    /// the raw nonce whose SHA-256 was put in the Apple request.
    @discardableResult
    public func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        var req = request("auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "id_token")])
        req.httpBody = try JSONEncoder().encode(["provider": "apple", "id_token": idToken, "nonce": nonce])
        do {
            let s = try decodeSession(try await send(req))
            try setSession(s)
            return s
        } catch SyncError.server(let status, let message) where [400, 401, 403, 422].contains(status) {
            throw SyncError.server(status: status, message: message ?? "Apple sign-in was rejected. Check that the Apple provider is enabled in Supabase.")
        }
    }

    /// A valid access token, refreshing first if it is about to expire.
    public func accessToken() async throws -> String {
        guard let s = session else { throw SyncError.signedOut }
        if s.expiresAt.timeIntervalSince(now()) > Self.refreshMargin { return s.accessToken }
        return try await refresh().accessToken
    }

    /// Refreshes the session. Concurrent callers share one request, because
    /// Supabase rotates refresh tokens and a second use would be rejected.
    @discardableResult
    public func refresh() async throws -> AuthSession {
        if let refreshing { return try await refreshing.value }
        guard let current = session else { throw SyncError.signedOut }
        let task = Task { try await performRefresh(current) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func performRefresh(_ current: AuthSession) async throws -> AuthSession {
        do {
            var req = request("auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")])
            req.httpBody = try JSONEncoder().encode(["refresh_token": current.refreshToken])
            let data = try await send(req)
            let s = try decodeSession(data, fallbackEmail: current.email)
            // Signed out (or into another account) while the request was out:
            // don't bring the old session back.
            guard session?.refreshToken == current.refreshToken else { throw SyncError.signedOut }
            try setSession(s)
            return s
        } catch SyncError.server(let status, _) where (400...403).contains(status) {
            // The refresh token is no longer valid: the user has to sign in again,
            // unless they already did while this request was out.
            if session?.refreshToken == current.refreshToken { try? setSession(nil) }
            throw SyncError.signedOut
        }
    }

    /// Signs out locally, and on the server when reachable.
    public func signOut() async {
        if let token = session?.accessToken {
            var req = request("auth/v1/logout", query: [URLQueryItem(name: "scope", value: "local")])
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await send(req)
        }
        try? setSession(nil)
    }

    /// Drops the session after the server rejected it outright.
    func invalidate() {
        try? setSession(nil)
    }

    // MARK: Plumbing

    /// Stops this client touching the shared Keychain entry or notifying observers,
    /// once the app has switched to another project. Requests still in flight
    /// finish against their own project without signing the new one in or out.
    /// Synchronous, so the caller can switch projects without a window in which
    /// a request finishing on this client still writes the Keychain.
    public nonisolated func retire() {
        retiredFlag.set()
    }

    private func setSession(_ s: AuthSession?) throws {
        guard !retiredFlag.isSet else { session = s; observers = [:]; return }
        if let s {
            try secrets.write(String(decoding: try JSONEncoder().encode(s), as: UTF8.self), for: SecretAccount.supabaseSession)
        } else {
            try secrets.write(nil, for: SecretAccount.supabaseSession)
        }
        session = s
        for o in observers.values { o(s) }
    }

    private struct SessionDTO: Decodable {
        struct User: Decodable { let id: String; let email: String? }
        let access_token: String
        let refresh_token: String
        let expires_in: Double?
        let expires_at: Double?
        let user: User
    }

    private func decodeSession(_ data: Data, fallbackEmail: String? = nil) throws -> AuthSession {
        guard let dto = try? JSONDecoder().decode(SessionDTO.self, from: data) else {
            throw SyncError.decoding("auth session")
        }
        let expires = dto.expires_at.map { Date(timeIntervalSince1970: $0) }
            ?? now().addingTimeInterval(dto.expires_in ?? 3600)
        return AuthSession(accessToken: dto.access_token, refreshToken: dto.refresh_token, expiresAt: expires,
                           userID: dto.user.id, email: dto.user.email ?? fallbackEmail)
    }

    private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var c = URLComponents(url: config.endpoint(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        try await SupabaseTransport.send(req, http: http)
    }

    /// A GoTrue error with its machine-readable code, mapped to a `SyncError` per endpoint.
    struct AuthFailure: Error {
        let status: Int
        let code: String?
        let message: String?

        var syncError: SyncError { status == 429 ? .rateLimited : .server(status: status, message: message) }
    }

    /// Like `send`, but keeps GoTrue's `error_code` so each call can explain itself.
    private func sendAuth(_ req: URLRequest) async throws -> Data {
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.send(req)
        } catch let e as URLError {
            throw SupabaseTransport.map(e)
        }
        guard !(200..<300).contains(response.statusCode) else { return data }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        throw AuthFailure(status: response.statusCode, code: (obj?["error_code"] as? String) ?? (obj?["code"] as? String),
                          message: SupabaseTransport.errorMessage(data))
    }

    static func email(for username: String) throws -> String {
        do {
            return try BlueboxUsername.email(for: username)
        } catch let p as BlueboxUsername.Problem {
            throw SyncError.invalidUsername(p.errorDescription ?? "Check the username.")
        }
    }

    /// GoTrue's answers to `grant_type=password`, as `SyncError`s.
    static func signInError(_ f: AuthFailure) -> SyncError {
        switch f.code ?? "" {
        case "invalid_credentials": return .wrongPassword
        case "email_not_confirmed": return .accountNotConfirmed
        case "email_provider_disabled": return .emailSignInDisabled
        case "over_request_rate_limit": return .rateLimited
        default: break
        }
        let msg = (f.message ?? "").lowercased()
        if msg.contains("invalid login credentials") { return .wrongPassword }
        if msg.contains("not confirmed") { return .accountNotConfirmed }
        if msg.contains("logins are disabled") || msg.contains("provider is disabled") { return .emailSignInDisabled }
        return f.syncError
    }

    /// GoTrue's answers to `/signup`, as `SyncError`s.
    static func signUpError(_ f: AuthFailure) -> SyncError {
        switch f.code ?? "" {
        case "user_already_exists", "email_exists": return .usernameTaken
        case "weak_password": return .weakPassword(f.message ?? "Choose a longer password.")
        case "signup_disabled": return .signupsDisabled
        case "email_provider_disabled": return .emailSignInDisabled
        // Supabase tried to send a confirmation email, so confirmation is on.
        case "email_address_not_authorized", "email_address_invalid", "over_email_send_rate_limit": return .confirmEmailRequired
        case "over_request_rate_limit": return .rateLimited
        default: break
        }
        let msg = (f.message ?? "").lowercased()
        if msg.contains("already registered") || msg.contains("already exists") { return .usernameTaken }
        if msg.contains("signups not allowed") || msg.contains("signup") && msg.contains("disabled") { return .signupsDisabled }
        if msg.contains("logins are disabled") || msg.contains("provider is disabled") { return .emailSignInDisabled }
        if msg.contains("sending") && msg.contains("email") { return .confirmEmailRequired }
        return f.syncError
    }
}

/// Shared status mapping for Auth and REST calls.
enum SupabaseTransport {
    static func send(_ req: URLRequest, http: any HTTPClient) async throws -> Data {
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.send(req)
        } catch let e as URLError {
            throw map(e)
        }
        switch response.statusCode {
        case 200..<300: return data
        case 429: throw SyncError.rateLimited
        default: throw SyncError.server(status: response.statusCode, message: errorMessage(data))
        }
    }

    static func map(_ e: URLError) -> SyncError {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        default:
            return .server(status: 0, message: e.localizedDescription)
        }
    }

    /// Pulls a human-readable message out of a GoTrue or PostgREST error body.
    static func errorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for k in ["msg", "message", "error_description", "error"] {
            if let m = obj[k] as? String, !m.isEmpty { return m }
        }
        return nil
    }
}
