import Foundation
import Metadata

/// An in-memory stand-in for Supabase's Management API (api.supabase.com),
/// answering from the `supabase_mgmt_*` fixtures (shaped like the published
/// OpenAPI document) and keeping just enough state to walk a project from
/// "created" to "healthy" and its tables from "missing" to "there".
public final class FakeSupabaseManagement: HTTPClient, @unchecked Sendable {
    /// Not shaped like a real token (40 hex digits), so secret scanners leave it alone.
    public static let goodToken = "sbp_fake-token-for-tests"
    public static let createdRef = "blueboxprojectrefaaa"
    public static let publishableKey = "sb_publishable_FixturePublishableKey123"

    public struct Project {
        public var ref: String, name: String, status: String, region: String
        public var tables = false, profilesOnlyMissing = false, settingsMissing = false, listsMissing = false, users = 0
        public init(ref: String, name: String, status: String, region: String = "eu-west-1") {
            self.ref = ref; self.name = name; self.status = status; self.region = region
        }
    }

    private let lock = NSLock()
    private var _projects: [Project]
    private var _requests: [URLRequest] = []
    private var _authPatches: [String: [[String: Any]]] = [:]
    private var polls: [String: Int] = [:]

    /// GETs of a starting project before it reports healthy.
    public var pollsUntilHealthy = 2
    /// POST /v1/projects answers that the free plan is full.
    public var projectLimitReached = false
    /// Organizations returned; nil uses the fixture.
    public var organizationsJSON: String?
    public var organizationPlan = "free"
    /// The project's key list shows values only with `reveal=true`.
    public var keysNeedReveal = false
    /// Every database query fails with this status.
    public var queryFailure: Int?

    public init(projects: [Project]? = nil) {
        _projects = projects ?? [
            Project(ref: "qwertyuiopasdfghjklz", name: "Recipes", status: "ACTIVE_HEALTHY", region: "eu-west-2"),
            Project(ref: "zxcvbnmlkjhgfdsapoiu", name: "Old experiment", status: "INACTIVE", region: "us-east-1"),
        ]
    }

    public var requests: [URLRequest] { lock.withLock { _requests } }
    public var projects: [Project] { lock.withLock { _projects } }
    public func authPatches(_ ref: String) -> [[String: Any]] { lock.withLock { _authPatches[ref] ?? [] } }
    /// "METHOD /path" for each request, in order.
    public var log: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" } }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock { () -> (Int, Data) in
            _requests.append(request)
            return handle(request)
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Type": "application/json"])!)
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    private func handle(_ req: URLRequest) -> (Int, Data) {
        guard req.url?.host() == "api.supabase.com" else { return (404, json("{}")) }
        guard req.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.goodToken)" else {
            return (401, json(#"{"message":"Unauthorized"}"#))
        }
        let method = req.httpMethod ?? "GET"
        let parts = req.url!.path.split(separator: "/").map(String.init)  // ["v1", "projects", ref, …]
        let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []

        // "GET /v1/projects/*/health": the ref or slug as a wildcard.
        var shape = parts
        if shape.count > 2, shape[2] != "available-regions" { shape[2] = "*" }
        switch "\(method) /" + shape.joined(separator: "/") {
        case "GET /v1/organizations":
            return (200, organizationsJSON.map(json) ?? Fixtures.data("supabase_mgmt_organizations"))
        case "POST /v1/organizations":
            return (201, json(#"{"id":"neworgslugaaaaaaaaaa","slug":"neworgslugaaaaaaaaaa","name":"\#(body["name"] as? String ?? "")"}"#))
        case "GET /v1/organizations/*":
            return (200, json(#"{"id":"\#(parts[2])","name":"Org","plan":"\#(organizationPlan)","opt_in_tags":[]}"#))
        case "GET /v1/projects":
            return (200, projectsJSON())
        case "GET /v1/projects/available-regions":
            return (200, Fixtures.data("supabase_mgmt_regions"))
        case "POST /v1/projects":
            if projectLimitReached {
                return (400, json(#"{"message":"The following organization members have reached their maximum limits for the number of active free projects within organizations where they are an administrator or owner: brian (2 project limit)."}"#))
            }
            guard body["db_pass"] is String, body["organization_slug"] is String, body["region"] == nil,
                  let region = body["region_selection"] as? [String: Any], region["type"] as? String == "specific" else {
                return (400, json(#"{"message":"Invalid request body"}"#))
            }
            _projects.append(Project(ref: Self.createdRef, name: body["name"] as? String ?? "", status: "COMING_UP",
                                     region: region["code"] as? String ?? ""))
            return (201, Fixtures.data("supabase_mgmt_project_created"))
        case "GET /v1/projects/*":
            guard let i = _projects.firstIndex(where: { $0.ref == parts[2] }) else { return (404, json(#"{"message":"Project not found"}"#)) }
            if ["COMING_UP", "RESTORING"].contains(_projects[i].status) {
                polls[parts[2], default: 0] += 1
                if polls[parts[2]]! >= pollsUntilHealthy { _projects[i].status = "ACTIVE_HEALTHY" }
            }
            return (200, projectJSON(_projects[i]))
        case "POST /v1/projects/*/restore":
            guard let i = _projects.firstIndex(where: { $0.ref == parts[2] }) else { return (404, json("{}")) }
            _projects[i].status = "RESTORING"
            return (200, json("{}"))
        case "GET /v1/projects/*/health":
            guard query.first(where: { $0.name == "services" })?.value != nil else { return (400, json("{}")) }
            return (200, Fixtures.data("supabase_mgmt_health"))
        case "POST /v1/projects/*/database/query":
            if let queryFailure { return (queryFailure, json(#"{"message":"Failed to run sql query: connection refused"}"#)) }
            guard let i = _projects.firstIndex(where: { $0.ref == parts[2] }), let sql = body["query"] as? String else {
                return (404, json("{}"))
            }
            return runQuery(sql, &_projects[i])
        case "PATCH /v1/projects/*/config/auth":
            _authPatches[parts[2], default: []].append(body)
            return (200, json("{}"))
        case "GET /v1/projects/*/api-keys":
            let revealed = query.first { $0.name == "reveal" }?.value == "true"
            if keysNeedReveal && !revealed {
                return (200, json(#"[{"name":"default","api_key":null,"type":"publishable","id":"x"}]"#))
            }
            return (200, Fixtures.data("supabase_mgmt_api_keys"))
        default:
            return (404, json(#"{"message":"Not found"}"#))
        }
    }

    private func runQuery(_ sql: String, _ p: inout Project) -> (Int, Data) {
        if sql.contains("to_regclass") {
            let progress = p.tables
            let profiles = p.tables && !p.profilesOnlyMissing
            let settings = profiles && !p.settingsMissing
            let lists = settings && !p.listsMissing
            return (201, json(#"[{"progress":\#(progress),"watchlist":\#(progress),"profiles":\#(profiles),"sync_profiles":\#(profiles),"settings":\#(settings),"lists":\#(lists),"users":\#(p.users)}]"#))
        }
        if sql.contains("create table public.watch_progress") {
            // setup.sql isn't idempotent: running it twice fails like Postgres would.
            if p.tables { return (400, json(#"{"message":"Failed to run sql query: ERROR:  42P07: relation \"watch_progress\" already exists"}"#)) }
            p.tables = true; p.profilesOnlyMissing = false; p.settingsMissing = false; p.listsMissing = false
            return (201, json("[]"))
        }
        if sql.contains("create table public.profiles") {
            if !p.tables || !p.profilesOnlyMissing { return (400, json(#"{"message":"Failed to run sql query: ERROR:  42P07: relation \"profiles\" already exists"}"#)) }
            p.profilesOnlyMissing = false
            if sql.contains("create table public.account_settings") { p.settingsMissing = false }
            return (201, json("[]"))
        }
        if sql.contains("create table public.account_settings") {
            if !p.tables || p.profilesOnlyMissing || !p.settingsMissing {
                return (400, json(#"{"message":"Failed to run sql query: ERROR:  42P07: relation \"account_settings\" already exists"}"#))
            }
            p.settingsMissing = false
            return (201, json("[]"))
        }
        if sql.contains("create table public.lists") {
            if !p.tables || p.profilesOnlyMissing || p.settingsMissing || !p.listsMissing {
                return (400, json(#"{"message":"Failed to run sql query: ERROR:  42P07: relation \"lists\" already exists"}"#))
            }
            p.listsMissing = false
            return (201, json("[]"))
        }
        return (201, json("[]"))
    }

    private func projectJSON(_ p: Project) -> Data {
        json(#"{"id":"\#(p.ref)","ref":"\#(p.ref)","organization_id":"tsrqponmlkjihgfedcba","organization_slug":"tsrqponmlkjihgfedcba","name":"\#(p.name)","region":"\#(p.region)","created_at":"2026-10-28T21:40:00.000Z","status":"\#(p.status)","database":{"host":"db.\#(p.ref).supabase.co","version":"17.4.1.054","postgres_engine":"17","release_channel":"ga"}}"#)
    }

    private func projectsJSON() -> Data {
        let items = _projects.map { String(decoding: projectJSON($0), as: UTF8.self) }
        return json("[" + items.joined(separator: ",") + "]")
    }
}
