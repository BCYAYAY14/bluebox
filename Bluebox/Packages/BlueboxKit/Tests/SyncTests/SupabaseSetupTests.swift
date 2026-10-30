import Foundation
import Metadata
@testable import Sync
import Testing

/// A legacy Supabase JWT with the given claims (signature irrelevant: only the server checks it).
func fakeJWT(_ claims: [String: String]) -> String {
    func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = b64(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
    let payload = b64(try! JSONSerialization.data(withJSONObject: claims))
    return "\(header).\(payload).signature"
}

/// Answers each request from a closure and records what was sent.
final class StubHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    let respond: @Sendable (URLRequest) throws -> (Int, String)

    init(_ respond: @escaping @Sendable (URLRequest) throws -> (Int, String)) { self.respond = respond }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, body) = try respond(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    /// A healthy project: Auth answers, tables exist (and refuse the anon role, as setup.sql does).
    static func healthy(email: Bool = true, missing: Set<String> = []) -> StubHTTP {
        StubHTTP { req in
            let path = req.url!.path
            if path == "/auth/v1/settings" { return (200, #"{"external":{"email":\#(email)},"disable_signup":false}"#) }
            if path.hasPrefix("/rest/v1/") {
                let table = String(path.dropFirst("/rest/v1/".count))
                if missing.contains(table) {
                    return (404, #"{"code":"PGRST205","message":"Could not find the table 'public.\#(table)' in the schema cache"}"#)
                }
                return (401, #"{"code":"42501","message":"permission denied for table \#(table)"}"#)
            }
            return (404, "{}")
        }
    }
}

@Suite struct SupabaseKeyTests {
    @Test func classifiesKeys() {
        #expect(SupabaseKeyKind("sb_publishable_abcdefghijklmnop") == .publishable)
        #expect(SupabaseKeyKind("  sb_secret_abcdefghijklmnop ") == .secret)
        #expect(SupabaseKeyKind(fakeJWT(["role": "anon", "ref": "abcdefghijklmnopqrst"])) == .anon(ref: "abcdefghijklmnopqrst"))
        #expect(SupabaseKeyKind(fakeJWT(["role": "service_role"])) == .serviceRole)
        #expect(SupabaseKeyKind(fakeJWT(["role": "authenticated"])) == .otherJWT(role: "authenticated"))
        #expect(SupabaseKeyKind("hello") == .unrecognized)
        #expect(SupabaseKeyKind("") == .empty)
        #expect(SupabaseKeyKind(fakeJWT(["role": "service_role"])).isPrivileged)
        #expect(!SupabaseKeyKind("sb_secret_x").isClientSafe)
    }

    @Test func configNeverHoldsAPrivilegedKey() {
        #expect(SupabaseConfig(url: "https://x.supabase.co", publishableKey: "sb_secret_abcdefghijklmnop") == nil)
        #expect(SupabaseConfig(url: "https://x.supabase.co", publishableKey: fakeJWT(["role": "service_role"])) == nil)
        #expect(SupabaseConfig(url: "https://x.supabase.co", publishableKey: "sb_publishable_abcdefghijklmnop") != nil)
    }

    @Test func keyCheckExplainsWhatIsWrong() {
        guard case .privileged(let why) = SupabaseSetupInput.checkKey(fakeJWT(["role": "service_role"])) else {
            Issue.record("service role accepted"); return
        }
        #expect(why.contains("service-role"))
        #expect(SupabaseSetupInput.checkKey("sb_publishable_abcdefghijklmnop") == .valid(.publishable))
        if case .invalid = SupabaseSetupInput.checkKey("nope") {} else { Issue.record("garbage accepted") }
        if case .invalid = SupabaseSetupInput.checkKey(fakeJWT(["role": "authenticated"])) {} else { Issue.record("user JWT accepted") }
    }
}

@Suite struct SupabaseURLInputTests {
    let ref = "abcdefghijklmnopqrst"

    @Test func acceptsTheShapesPeoplePaste() {
        let expected = URL(string: "https://\(ref).supabase.co")!
        for text in ["https://\(ref).supabase.co", "\(ref).supabase.co", " https://\(ref).supabase.co/ ",
                     "https://\(ref).supabase.co/rest/v1/", ref,
                     "https://supabase.com/dashboard/project/\(ref)/settings/api-keys"] {
            #expect(SupabaseSetupInput.checkURL(text) == .valid(expected, ref: ref), "\(text)")
        }
    }

    @Test func selfHostedAndLocal() {
        #expect(SupabaseSetupInput.checkURL("https://db.example.com").url == URL(string: "https://db.example.com"))
        #expect(SupabaseSetupInput.checkURL("https://db.example.com").ref == nil)
        #expect(SupabaseSetupInput.checkURL("http://127.0.0.1:54321").url == URL(string: "http://127.0.0.1:54321"))
    }

    @Test func rejectsWhatWontWork() {
        for text in ["http://db.example.com", "https://supabase.com", "https://short.supabase.co", "sb_publishable_abc", "intranet"] {
            if case .invalid = SupabaseSetupInput.checkURL(text) {} else { Issue.record("accepted \(text)") }
        }
        #expect(SupabaseSetupInput.checkURL("   ") == .empty)
    }

    @Test func refusesAKeyFromAnotherProject() {
        let key = fakeJWT(["role": "anon", "ref": "zzzzzzzzzzzzzzzzzzzz"])
        #expect(throws: SupabaseSetupError.keyForAnotherProject) {
            try SupabaseSetupInput.config(url: "https://\(ref).supabase.co", key: key)
        }
        #expect(throws: SupabaseSetupError.privilegedKey) {
            try SupabaseSetupInput.config(url: "https://\(ref).supabase.co", key: "sb_secret_abcdefghijklmnop")
        }
    }

    @Test func dashboardLinksUseTheProjectRef() {
        #expect(SupabaseDashboard.url(.sqlEditor, ref: ref).absoluteString == "https://supabase.com/dashboard/project/\(ref)/sql/new")
        #expect(SupabaseDashboard.url(.providers, ref: nil).absoluteString == "https://supabase.com/dashboard/project/_/auth/providers")
        #expect(SupabaseDashboard.ref(for: URL(string: "https://\(ref).supabase.co")) == ref)
        #expect(SupabaseDashboard.ref(for: URL(string: "https://db.example.com")) == nil)
    }
}

@Suite struct SupabaseProbeTests {
    let config = SupabaseConfig(url: "https://abcdefghijklmnopqrst.supabase.co", publishableKey: "sb_publishable_abcdefghijklmnop")!

    @Test func healthyProjectPasses() async throws {
        let http = StubHTTP.healthy()
        let report = try await SupabaseProjectProbe.check(config, http: http)
        #expect(report.warnings.isEmpty)
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "apikey") == config.publishableKey })
        #expect(http.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func reportsEmailSignInOff() async throws {
        let report = try await SupabaseProjectProbe.check(config, http: StubHTTP.healthy(email: false))
        #expect(report.warnings.first?.contains("Email provider, which is off") == true)
    }

    /// Set up before private Realtime channels (security review BB-03): say how to add the policies.
    @Test func reportsMissingRealtimePolicies() async throws {
        let old = try await SupabaseProjectProbe.check(config, http: StubHTTP.healthy(missing: ["rpc/bluebox_realtime_private"]))
        #expect(old.realtimePrivateMissing)
        #expect(old.warnings.count == 1 && old.warnings[0].contains("20261030000000_realtime_private.sql"))
        #expect(old.warnings[0].contains("Allow public access"))
        let current = try await SupabaseProjectProbe.check(config, http: StubHTTP.healthy())
        #expect(!current.realtimePrivateMissing)
    }

    @Test func missingTablesSayRunSetupSQL() async {
        await #expect(throws: SupabaseSetupError.tablesMissing) {
            try await SupabaseProjectProbe.check(config, http: StubHTTP.healthy(missing: ["watch_progress", "profiles"]))
        }
        await #expect(throws: SupabaseSetupError.tablesOutdated) {
            try await SupabaseProjectProbe.check(config, http: StubHTTP.healthy(missing: ["profiles"]))
        }
        #expect(SupabaseSetupError.tablesMissing.errorDescription?.contains("setup.sql") == true)
    }

    @Test func wrongKeyAndWrongServer() async {
        await #expect(throws: SupabaseSetupError.badKey) {
            try await SupabaseProjectProbe.check(config, http: StubHTTP { _ in (401, #"{"message":"Invalid API key"}"#) })
        }
        await #expect(throws: SupabaseSetupError.notSupabase) {
            try await SupabaseProjectProbe.check(config, http: StubHTTP { _ in (404, "<html>") })
        }
        await #expect(throws: SupabaseSetupError.notSupabase) {
            try await SupabaseProjectProbe.check(config, http: StubHTTP { _ in (200, "<html>not json</html>") })
        }
    }

    @Test func confirmEmailIsAWarningOnlyWhileSignupsAreOpen() async throws {
        func settings(_ json: String) -> StubHTTP {
            StubHTTP { req in
                if req.url!.path == "/auth/v1/settings" { return (200, json) }
                return (401, #"{"code":"42501","message":"permission denied"}"#)
            }
        }
        let open = try await SupabaseProjectProbe.check(config, http: settings(
            #"{"external":{"email":true},"disable_signup":false,"mailer_autoconfirm":false}"#))
        #expect(open.confirmEmailRequired)
        #expect(open.warnings.count == 1 && open.warnings[0].contains("Confirm email"))
        // Automatic setup closes sign-ups after the first account: nothing to warn about.
        let closed = try await SupabaseProjectProbe.check(config, http: settings(
            #"{"external":{"email":true},"disable_signup":true,"mailer_autoconfirm":true}"#))
        #expect(closed.signupsDisabled && closed.warnings.isEmpty)
    }

    @Test func networkFailuresAreSpecific() async {
        await #expect(throws: SupabaseSetupError.unreachable("no server has that name.")) {
            try await SupabaseProjectProbe.check(config, http: StubHTTP { _ in throw URLError(.cannotFindHost) })
        }
        await #expect(throws: SupabaseSetupError.offline) {
            try await SupabaseProjectProbe.check(config, http: StubHTTP { _ in throw URLError(.notConnectedToInternet) })
        }
    }

}

@Suite struct SupabaseSetupFilesTests {
    static let backend = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Backend/supabase")

    func file(_ path: String) throws -> String {
        var s = try String(contentsOf: Self.backend.appending(path: path), encoding: .utf8)
        if s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    /// Setup runs these: run Backend/supabase/embed-in-app.sh after editing the files.
    @Test func embeddedCopiesMatchBackend() throws {
        #expect(SupabaseSetupFiles.setupSQL == (try file("setup.sql")))
        #expect(SupabaseSetupFiles.profilesMigrationSQL == (try file("migrations/20261028000000_profiles.sql")))
        #expect(SupabaseSetupFiles.accountSettingsMigrationSQL == (try file("migrations/20261029000000_account_settings.sql")))
        #expect(SupabaseSetupFiles.listsMigrationSQL == (try file("migrations/20261029100000_lists.sql")))
        #expect(SupabaseSetupFiles.realtimePrivateMigrationSQL == (try file("migrations/20261030000000_realtime_private.sql")))
    }

    /// setup.sql is the five migrations in order, so a project with only the
    /// first ones gets exactly the rest from the later migrations.
    @Test func setupSQLIsTheMigrationsInOrder() throws {
        let setup = SupabaseSetupFiles.setupSQL
        #expect(setup.hasSuffix(SupabaseSetupFiles.realtimePrivateMigrationSQL))
        #expect(setup.contains(SupabaseSetupFiles.profilesMigrationSQL + "\n\n" + SupabaseSetupFiles.accountSettingsMigrationSQL
                               + "\n\n" + SupabaseSetupFiles.listsMigrationSQL + "\n\n" + SupabaseSetupFiles.realtimePrivateMigrationSQL))
        #expect(setup.contains(try file("migrations/20261027000000_library_sync.sql")))
    }
}
