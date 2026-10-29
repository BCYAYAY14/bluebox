import Foundation
import Metadata

// Supabase's Management API (https://api.supabase.com/v1), used once to set up a
// project from a personal access token (https://supabase.com/dashboard/account/tokens).
// Shapes follow the published OpenAPI document, https://api.supabase.com/api/v1-json.
//
// The token lives only in this value: it goes in the Authorization header of
// requests to api.supabase.com and nowhere else. It is never written to the
// Keychain, defaults or a log, and never put in a URL.

/// Why a Management API call failed, in words the user can act on.
public enum ManagementAPIError: Error, Equatable, Sendable, LocalizedError {
    /// 401: the token is wrong, revoked or expired.
    case badToken
    /// 403: the token isn't allowed to do this (a token with limited permissions).
    case forbidden(String?)
    case rateLimited
    case offline
    case timedOut
    case notFound
    case server(status: Int, message: String?)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .badToken:
            "Supabase didn't accept that token. Copy it again from Access Tokens, or generate a new one."
        case .forbidden(let message):
            (message.map { "Supabase refused: \($0.trimmingCharacters(in: CharacterSet(charactersIn: "."))). " } ?? "Supabase refused. ")
                + "If you limited the token's permissions, generate a new token without limits."
        case .rateLimited: "Supabase is limiting requests right now. Wait a minute, then try again."
        case .offline: "You're offline. Connect to the internet, then try again."
        case .timedOut: "Supabase didn't answer in time. Try again."
        case .notFound: "Supabase couldn't find that project. It may have been deleted."
        case .server(let status, let message):
            message.map { "Supabase returned an error (\(status)): \($0)" } ?? "Supabase returned an error (\(status)). Try again in a minute."
        case .decoding(let what): "Supabase sent a reply Bluebox couldn't read (\(what))."
        }
    }

    /// Worth retrying on its own while waiting for a project to start.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .offline, .timedOut: true
        case .server(let status, _): status >= 500
        default: false
        }
    }
}

/// An organization the token's account belongs to.
public struct ManagedOrganization: Decodable, Equatable, Sendable {
    public let slug: String
    public let name: String

    public init(slug: String, name: String) { self.slug = slug; self.name = name }

    enum CodingKeys: String, CodingKey { case slug, name, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `slug` replaced `id`; accept either.
        guard let slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? c.decodeIfPresent(String.self, forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.slug, .init(codingPath: c.codingPath, debugDescription: "slug"))
        }
        self.slug = slug
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? slug
    }
}

/// A project as the Management API lists it.
public struct ManagedProject: Decodable, Equatable, Sendable, Identifiable {
    public let ref: String
    public let name: String
    public let organizationSlug: String?
    public let region: String?
    /// `ACTIVE_HEALTHY`, `COMING_UP`, `INACTIVE` (paused), …
    public let status: String?

    public var id: String { ref }
    public var isHealthy: Bool { status == "ACTIVE_HEALTHY" }
    public var isPaused: Bool { status == "INACTIVE" }
    /// The project's API address, as the dashboard shows it.
    public var url: URL { URL(string: "https://\(ref)\(SupabaseSetupInput.hostedSuffix)")! }

    public init(ref: String, name: String, organizationSlug: String? = nil, region: String? = nil, status: String? = nil) {
        self.ref = ref; self.name = name; self.organizationSlug = organizationSlug; self.region = region; self.status = status
    }

    enum CodingKeys: String, CodingKey { case ref, id, name, region, status, organization_slug }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `ref` replaced `id`; accept either.
        guard let ref = try c.decodeIfPresent(String.self, forKey: .ref) ?? c.decodeIfPresent(String.self, forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.ref, .init(codingPath: c.codingPath, debugDescription: "ref"))
        }
        self.ref = ref
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ref
        organizationSlug = try c.decodeIfPresent(String.self, forKey: .organization_slug)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }
}

/// The fields of `PATCH /v1/projects/{ref}/config/auth` Bluebox sets. Nil fields are left out.
public struct AuthConfigUpdate: Encodable, Equatable, Sendable {
    /// Authentication › Sign In / Providers › Email.
    public var externalEmailEnabled: Bool?
    /// True turns off "Confirm email": new accounts are signed in at once, and no email is sent.
    public var mailerAutoconfirm: Bool?
    public var siteURL: String?
    /// Comma-separated redirect URLs.
    public var uriAllowList: String?
    public var disableSignup: Bool?
    public var passwordMinLength: Int?

    public init(externalEmailEnabled: Bool? = nil, mailerAutoconfirm: Bool? = nil, siteURL: String? = nil,
                uriAllowList: String? = nil, disableSignup: Bool? = nil, passwordMinLength: Int? = nil) {
        self.externalEmailEnabled = externalEmailEnabled; self.mailerAutoconfirm = mailerAutoconfirm
        self.siteURL = siteURL; self.uriAllowList = uriAllowList; self.disableSignup = disableSignup
        self.passwordMinLength = passwordMinLength
    }

    enum CodingKeys: String, CodingKey {
        case externalEmailEnabled = "external_email_enabled"
        case mailerAutoconfirm = "mailer_autoconfirm"
        case siteURL = "site_url"
        case uriAllowList = "uri_allow_list"
        case disableSignup = "disable_signup"
        case passwordMinLength = "password_min_length"
    }
}

/// Where a new project should live: one region, or a Smart Region Group.
public enum RegionChoice: Equatable, Sendable, Encodable {
    case specific(String)
    case smartGroup(String)

    public var code: String { switch self { case .specific(let c), .smartGroup(let c): c } }

    enum CodingKeys: String, CodingKey { case type, code }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .specific(let code): try c.encode("specific", forKey: .type); try c.encode(code, forKey: .code)
        case .smartGroup(let code): try c.encode("smartGroup", forKey: .type); try c.encode(code, forKey: .code)
        }
    }
}

/// A Management API client for one access token.
public struct SupabaseManagementAPI: Sendable {
    public static let baseURL = URL(string: "https://api.supabase.com")!

    private let token: String
    private let http: any HTTPClient

    public init(token: String, http: any HTTPClient) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = http
    }

    // MARK: Organizations

    /// `GET /v1/organizations`
    public func organizations() async throws -> [ManagedOrganization] {
        try decode([ManagedOrganization].self, try await send("GET", "v1/organizations"), "organizations")
    }

    /// The organization's plan (`free`, `pro`, …) from `GET /v1/organizations/{slug}`.
    public func organizationPlan(_ slug: String) async throws -> String? {
        struct Detail: Decodable { let plan: String? }
        return try decode(Detail.self, try await send("GET", "v1/organizations/\(slug)"), "organization").plan
    }

    /// `POST /v1/organizations`, for an account that has none yet.
    public func createOrganization(name: String) async throws -> ManagedOrganization {
        try decode(ManagedOrganization.self, try await send("POST", "v1/organizations", body: ["name": name]), "organization")
    }

    // MARK: Projects

    /// `GET /v1/projects`: every project in every organization.
    public func projects() async throws -> [ManagedProject] {
        try decode([ManagedProject].self, try await send("GET", "v1/projects"), "projects")
    }

    /// `GET /v1/projects/{ref}`
    public func project(_ ref: String) async throws -> ManagedProject {
        try decode(ManagedProject.self, try await send("GET", "v1/projects/\(ref)"), "project")
    }

    /// `POST /v1/projects`. The plan is the organization's; the database
    /// password is required but Bluebox never needs it again.
    public func createProject(name: String, organizationSlug: String, databasePassword: String,
                              region: RegionChoice) async throws -> ManagedProject {
        struct Body: Encodable {
            let name: String
            let organization_slug: String
            let db_pass: String
            let region_selection: RegionChoice
        }
        let body = Body(name: name, organization_slug: organizationSlug, db_pass: databasePassword, region_selection: region)
        return try decode(ManagedProject.self, try await send("POST", "v1/projects", body: body, timeout: 60), "project")
    }

    /// `POST /v1/projects/{ref}/restore`: wakes a paused free project.
    public func restoreProject(_ ref: String) async throws {
        _ = try await send("POST", "v1/projects/\(ref)/restore")
    }

    /// The first recommended region for a continent, from the (beta)
    /// `GET /v1/projects/available-regions`. Nil when it has no recommendation.
    public func recommendedRegion(organizationSlug: String, continent: String) async throws -> String? {
        struct Info: Decodable {
            struct Region: Decodable { let code: String; let status: String? }
            struct Recommendations: Decodable { let specific: [Region]? }
            let recommendations: Recommendations?
        }
        let data = try await send("GET", "v1/projects/available-regions",
                                  query: [URLQueryItem(name: "organization_slug", value: organizationSlug),
                                          URLQueryItem(name: "continent", value: continent)])
        let info = try decode(Info.self, data, "regions")
        let regions = info.recommendations?.specific ?? []
        // `capacity` marks a region that's full right now.
        return (regions.first { $0.status != "capacity" } ?? regions.first)?.code
    }

    /// True when the project's Auth, database and API all report healthy
    /// (`GET /v1/projects/{ref}/health`).
    public func servicesHealthy(_ ref: String) async throws -> Bool {
        struct Service: Decodable { let name: String?; let status: String?; let healthy: Bool? }
        let data = try await send("GET", "v1/projects/\(ref)/health",
                                  query: [URLQueryItem(name: "services", value: "auth,db,rest")])
        let services = try decode([Service].self, data, "health")
        return !services.isEmpty && services.allSatisfy { ($0.status.map { $0 == "ACTIVE_HEALTHY" }) ?? ($0.healthy ?? false) }
    }

    // MARK: Database, Auth, keys

    /// `POST /v1/projects/{ref}/database/query`. Returns the rows as JSON objects.
    public func runQuery(_ ref: String, _ sql: String) async throws -> [[String: Any]] {
        let data = try await send("POST", "v1/projects/\(ref)/database/query", body: ["query": sql], timeout: 90)
        if data.isEmpty { return [] }
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            // DDL can answer with something other than rows; only a row query needs them.
            return []
        }
        return rows
    }

    /// `PATCH /v1/projects/{ref}/config/auth`
    public func updateAuthConfig(_ ref: String, _ update: AuthConfigUpdate) async throws {
        _ = try await send("PATCH", "v1/projects/\(ref)/config/auth", body: update)
    }

    /// The project's client-safe key: the publishable key (`sb_publishable_…`),
    /// or on older projects the legacy anon key, from `GET /v1/projects/{ref}/api-keys`.
    /// Other keys in the reply (secret, service_role) are dropped unread.
    public func clientKey(_ ref: String) async throws -> String? {
        if let key = try await clientKey(ref, reveal: false) { return key }
        // Some projects only show key values when asked to.
        return try await clientKey(ref, reveal: true)
    }

    private func clientKey(_ ref: String, reveal: Bool) async throws -> String? {
        struct Key: Decodable { let api_key: String?; let type: String?; let name: String? }
        let data = try await send("GET", "v1/projects/\(ref)/api-keys",
                                  query: reveal ? [URLQueryItem(name: "reveal", value: "true")] : [])
        let keys = try decode([Key].self, data, "API keys")
        return Self.pickClientKey(keys.map { ($0.type, $0.name, $0.api_key) })
    }

    /// Publishable first, then the legacy anon key. Only values that really
    /// are client-safe keys are returned, whatever the reply calls them.
    static func pickClientKey(_ keys: [(type: String?, name: String?, value: String?)]) -> String? {
        let publishable = keys.lazy.filter { $0.type == "publishable" }.compactMap(\.value)
            .first { SupabaseKeyKind($0) == .publishable }
        if let publishable { return publishable }
        return keys.lazy.filter { $0.type == "legacy" || $0.type == nil }.filter { $0.name == "anon" }.compactMap(\.value)
            .first { if case .anon = SupabaseKeyKind($0) { true } else { false } }
    }

    // MARK: Plumbing

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      timeout: TimeInterval = 30) async throws -> Data {
        try await send(method, path, query: query, body: Optional<[String: String]>.none, timeout: timeout)
    }

    private func send<Body: Encodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Body?,
                                       timeout: TimeInterval = 30) async throws -> Data {
        var c = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        // Replies carry keys: never from or into a cache.
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.send(req)
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw ManagementAPIError.timedOut
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                throw ManagementAPIError.offline
            default: throw ManagementAPIError.server(status: 0, message: e.localizedDescription)
            }
        }
        let message = SupabaseTransport.errorMessage(data)
        switch response.statusCode {
        case 200..<300: return data
        case 401: throw ManagementAPIError.badToken
        case 403: throw ManagementAPIError.forbidden(message)
        case 404: throw ManagementAPIError.notFound
        case 429: throw ManagementAPIError.rateLimited
        default: throw ManagementAPIError.server(status: response.statusCode, message: message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ what: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw ManagementAPIError.decoding(what) }
    }
}
