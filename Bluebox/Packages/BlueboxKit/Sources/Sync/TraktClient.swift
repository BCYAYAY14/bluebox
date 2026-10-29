import Domain
import Foundation
import Metadata
import Persistence

/// Trakt API app credentials. The client secret ships in the app, as Trakt's
/// device flow expects for native apps; it identifies the app, not the user.
public struct TraktConfig: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String
    public let baseURL: URL

    public init?(clientID: String?, clientSecret: String?, baseURL: URL = URL(string: "https://api.trakt.tv")!) {
        guard let id = clientID?.trimmingCharacters(in: .whitespaces), let secret = clientSecret?.trimmingCharacters(in: .whitespaces),
              !id.isEmpty, !secret.isEmpty, !id.hasPrefix("YOUR_"), !secret.hasPrefix("YOUR_") else { return nil }
        self.clientID = id; self.clientSecret = secret; self.baseURL = baseURL
    }

    /// Reads `TraktClientID` / `TraktClientSecret` from an Info.plist, filled
    /// from `Config/Secrets.xcconfig`. Nil when unset.
    public init?(bundle: Bundle) {
        self.init(clientID: bundle.object(forInfoDictionaryKey: "TraktClientID") as? String,
                  clientSecret: bundle.object(forInfoDictionaryKey: "TraktClientSecret") as? String)
    }
}

public enum TraktError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured
    case notConnected
    case codeExpired
    case denied
    case rateLimited
    case listLimitReached
    case offline
    case server(status: Int)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Trakt isn't set up in this build."
        case .notConnected: "Trakt is disconnected. Connect it again in Settings."
        case .codeExpired: "The Trakt code expired. Start again to get a new one."
        case .denied: "Trakt access was declined."
        case .rateLimited: "Trakt is rate limiting requests. Bluebox will try again later."
        case .listLimitReached: "Your Trakt watchlist is full for your Trakt plan."
        case .offline: "You're offline. Trakt will sync when you reconnect."
        case .server(let s): "Trakt returned an error (\(s))."
        case .decoding(let d): "Trakt sent data Bluebox couldn't read (\(d))."
        }
    }
}

public struct TraktTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var username: String?
}

/// A pending device sign-in: show `userCode` and send the user to `verificationURL`.
public struct TraktDeviceCode: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    public let interval: TimeInterval
}

extension SecretAccount {
    public static let traktTokens = "trakt.tokens"
}

/// Trakt OAuth (device flow) and authorized requests.
public actor TraktClient {
    let config: TraktConfig
    let http: any HTTPClient
    let secrets: any SecretStore
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async throws -> Void
    private var tokens: TraktTokens?
    private var refreshing: Task<TraktTokens, Error>?
    private var lastWrite: Date?

    static let redirectURI = "urn:ietf:wg:oauth:2.0:oob"
    /// Trakt allows one write (POST/PUT/DELETE) per second per user.
    static let writeSpacing: TimeInterval = 1

    public init(config: TraktConfig, http: any HTTPClient, secrets: any SecretStore,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.config = config; self.http = http; self.secrets = secrets; self.now = now; self.sleep = sleep
        tokens = (try? secrets.read(SecretAccount.traktTokens)).flatMap { $0 }
            .flatMap { try? JSONDecoder().decode(TraktTokens.self, from: Data($0.utf8)) }
    }

    public var isConnected: Bool { tokens != nil }
    public var username: String? { tokens?.username }

    // MARK: Device flow

    public func startDeviceAuth() async throws -> TraktDeviceCode {
        struct DTO: Decodable {
            let device_code: String; let user_code: String; let verification_url: String
            let expires_in: Double; let interval: Double
        }
        let data = try await send(request("oauth/device/code", method: "POST", body: ["client_id": config.clientID]))
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data), let url = URL(string: dto.verification_url) else {
            throw TraktError.decoding("device code")
        }
        return TraktDeviceCode(deviceCode: dto.device_code, userCode: dto.user_code, verificationURL: url,
                               expiresAt: now().addingTimeInterval(dto.expires_in), interval: max(dto.interval, 1))
    }

    /// Polls until the user approves the code, it expires, or the task is cancelled.
    public func waitForAuthorization(_ code: TraktDeviceCode) async throws {
        var interval = code.interval
        while now() < code.expiresAt {
            try await sleep(interval)
            try Task.checkCancellation()
            let req = request("oauth/device/token", method: "POST", body: [
                "code": code.deviceCode, "client_id": config.clientID, "client_secret": config.clientSecret,
            ])
            let (data, response) = try await transport(req)
            switch response.statusCode {
            case 200:
                var t = try decodeTokens(data)
                t.username = try? await fetchUsername(token: t.accessToken)
                try store(t)
                return
            case 400: continue  // not approved yet
            case 429: interval += 1
            case 410: throw TraktError.codeExpired
            case 418: throw TraktError.denied
            case 404, 409: throw TraktError.codeExpired  // unknown or already used
            default: throw TraktError.server(status: response.statusCode)
            }
        }
        throw TraktError.codeExpired
    }

    public func disconnect() async {
        if let t = tokens {
            let req = request("oauth/revoke", method: "POST", body: [
                "token": t.accessToken, "client_id": config.clientID, "client_secret": config.clientSecret,
            ])
            _ = try? await transport(req)
        }
        try? store(nil)
    }

    // MARK: Authorized requests

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await authorized { self.request(path, method: "GET", query: query, token: $0) }
    }

    func post<T: Encodable>(_ path: String, _ body: T) async throws -> Data {
        if let last = lastWrite {
            let wait = Self.writeSpacing - now().timeIntervalSince(last)
            if wait > 0 { try await sleep(wait) }
        }
        defer { lastWrite = now() }
        let encoded = try JSONEncoder().encode(body)
        return try await authorized { token in
            var r = self.request(path, method: "POST", token: token)
            r.httpBody = encoded
            return r
        }
    }

    private func authorized(_ make: @Sendable (String) -> URLRequest) async throws -> Data {
        let token = try await accessToken()
        do {
            return try await sendRetryingRateLimit(make(token))
        } catch TraktError.server(status: 401) {
            let fresh = try await refresh()
            do {
                return try await sendRetryingRateLimit(make(fresh.accessToken))
            } catch TraktError.server(status: 401) {
                try? store(nil)
                throw TraktError.notConnected
            }
        }
    }

    /// Waits out rate limits (`Retry-After`, up to a minute in all) and
    /// retries Trakt's transient gateway errors twice with backoff.
    private func sendRetryingRateLimit(_ req: URLRequest) async throws -> Data {
        var waited: TimeInterval = 0
        var attempt = 0
        while true {
            let (data, response) = try await transport(req)
            let status = response.statusCode
            if status == 429 {
                let wait = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 2
                guard attempt < 3, waited + wait <= 60 else { throw TraktError.rateLimited }
                attempt += 1; waited += wait
                try await sleep(wait)
                continue
            }
            if Self.transientStatuses.contains(status), attempt < 2 {
                attempt += 1
                try await sleep(Double(attempt) * 2)
                continue
            }
            return try check(data, response)
        }
    }

    /// Trakt's Cloudflare and gateway errors: worth a retry.
    static let transientStatuses: Set<Int> = [500, 502, 503, 504, 520, 521, 522]

    /// Sends a scrobble. Trakt answers 409 when the same stop arrives twice in
    /// a few minutes, which counts as done.
    func scrobble<T: Encodable>(_ action: String, _ body: T) async throws {
        do {
            _ = try await post("scrobble/\(action)", body)
        } catch TraktError.server(status: 409) {
            // Already scrobbled in the last few minutes: fine.
        }
    }

    private func accessToken() async throws -> String {
        guard let t = tokens else { throw TraktError.notConnected }
        if t.expiresAt.timeIntervalSince(now()) > 300 { return t.accessToken }
        return try await refresh().accessToken
    }

    private func refresh() async throws -> TraktTokens {
        if let refreshing { return try await refreshing.value }
        guard let current = tokens else { throw TraktError.notConnected }
        let task = Task { try await performRefresh(current) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func performRefresh(_ current: TraktTokens) async throws -> TraktTokens {
        let req = request("oauth/token", method: "POST", body: [
            "refresh_token": current.refreshToken, "client_id": config.clientID, "client_secret": config.clientSecret,
            "redirect_uri": Self.redirectURI, "grant_type": "refresh_token",
        ])
        let (data, response) = try await transport(req)
        guard response.statusCode == 200 else {
            if (400...403).contains(response.statusCode) { try? store(nil); throw TraktError.notConnected }
            throw TraktError.server(status: response.statusCode)
        }
        var t = try decodeTokens(data)
        t.username = current.username
        try store(t)
        return t
    }

    private func fetchUsername(token: String) async throws -> String? {
        struct DTO: Decodable { struct User: Decodable { let username: String? }; let user: User }
        let (data, response) = try await transport(request("users/settings", method: "GET", token: token))
        guard response.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(DTO.self, from: data).user.username
    }

    // MARK: Plumbing

    private func store(_ t: TraktTokens?) throws {
        if let t {
            try secrets.write(String(decoding: try JSONEncoder().encode(t), as: UTF8.self), for: SecretAccount.traktTokens)
        } else {
            try secrets.write(nil, for: SecretAccount.traktTokens)
        }
        tokens = t
    }

    private func decodeTokens(_ data: Data) throws -> TraktTokens {
        struct DTO: Decodable {
            let access_token: String; let refresh_token: String
            let expires_in: Double; let created_at: Double?
        }
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data) else { throw TraktError.decoding("tokens") }
        let created = dto.created_at.map { Date(timeIntervalSince1970: $0) } ?? now()
        return TraktTokens(accessToken: dto.access_token, refreshToken: dto.refresh_token,
                           expiresAt: created.addingTimeInterval(dto.expires_in), username: nil)
    }

    private nonisolated func request(_ path: String, method: String, query: [URLQueryItem] = [], token: String? = nil,
                                     body: [String: String]? = nil) -> URLRequest {
        var c = URLComponents(url: config.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("2", forHTTPHeaderField: "trakt-api-version")
        r.setValue(config.clientID, forHTTPHeaderField: "trakt-api-key")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try? JSONEncoder().encode(body) }
        r.timeoutInterval = 30
        return r
    }

    private func transport(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await http.send(req)
        } catch let e as URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .dataNotAllowed:
                throw TraktError.offline
            default: throw TraktError.server(status: 0)
            }
        }
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await transport(req)
        return try check(data, response)
    }

    private func check(_ data: Data, _ response: HTTPURLResponse) throws -> Data {
        switch response.statusCode {
        case 200..<300: return data
        case 420: throw TraktError.listLimitReached
        case 429: throw TraktError.rateLimited
        default: throw TraktError.server(status: response.statusCode)
        }
    }
}
