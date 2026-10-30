import Foundation
import Metadata
import Persistence
@testable import Sync
import Testing
import TestingSupport

/// Records the steps automatic setup reports.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [SupabaseAutoSetup.Step] = []
    var steps: [SupabaseAutoSetup.Step] { lock.withLock { _steps } }
    func add(_ s: SupabaseAutoSetup.Step) { lock.withLock { if _steps.last != s { _steps.append(s) } } }
}

@Suite struct SupabaseManagementAPITests {
    let token = FakeSupabaseManagement.goodToken

    @Test func decodesTheDocumentedShapes() async throws {
        let http = FixtureHTTPClient()
        http.on("/v1/organizations", .fixture("supabase_mgmt_organizations"))
        http.on("/v1/projects", .fixture("supabase_mgmt_projects"))
        http.on("/v1/projects/blueboxprojectrefaaa/api-keys", .fixture("supabase_mgmt_api_keys"))
        http.on("/v1/projects/blueboxprojectrefaaa/health", .fixture("supabase_mgmt_health"))
        http.on("/v1/projects/available-regions", .fixture("supabase_mgmt_regions"))
        http.on("/v1/organizations/tsrqponmlkjihgfedcba", .fixture("supabase_mgmt_organization"))
        let api = SupabaseManagementAPI(token: token, http: http)

        #expect(try await api.organizations() == [ManagedOrganization(slug: "tsrqponmlkjihgfedcba", name: "brian's Org")])
        #expect(try await api.organizationPlan("tsrqponmlkjihgfedcba") == "free")
        let projects = try await api.projects()
        #expect(projects.map(\.ref) == ["qwertyuiopasdfghjklz", "zxcvbnmlkjhgfdsapoiu"])
        #expect(projects[0].isHealthy && projects[1].isPaused)
        #expect(projects[0].url.absoluteString == "https://qwertyuiopasdfghjklz.supabase.co")
        #expect(try await api.servicesHealthy("blueboxprojectrefaaa"))
        // London is at capacity in the fixture, so the next recommendation.
        #expect(try await api.recommendedRegion(organizationSlug: "tsrqponmlkjihgfedcba", continent: "EU") == "eu-west-1")
        // The publishable key, never the service_role or secret key in the same reply.
        #expect(try await api.clientKey("blueboxprojectrefaaa") == FakeSupabaseManagement.publishableKey)
    }

    @Test func theTokenGoesOnlyInTheHeaderToSupabase() async throws {
        let http = FakeSupabaseManagement()
        _ = try await SupabaseManagementAPI(token: " \(token)\n", http: http).projects()
        let req = try #require(http.requests.first)
        #expect(req.url?.host() == "api.supabase.com")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(!(req.url?.absoluteString.contains(token) ?? true))
        #expect(req.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    @Test func errorsInPlainWords() async {
        await #expect(throws: ManagementAPIError.badToken) {
            try await SupabaseManagementAPI(token: "sbp_wrong", http: FakeSupabaseManagement()).projects()
        }
        let offline = StubHTTP { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: ManagementAPIError.offline) { try await SupabaseManagementAPI(token: token, http: offline).projects() }
        let limited = StubHTTP { _ in (429, #"{"message":"Too many requests"}"#) }
        await #expect(throws: ManagementAPIError.rateLimited) { try await SupabaseManagementAPI(token: token, http: limited).projects() }
        let scoped = StubHTTP { _ in (403, #"{"message":"Your token is missing the projects:read scope."}"#) }
        await #expect(throws: ManagementAPIError.forbidden("Your token is missing the projects:read scope.")) {
            try await SupabaseManagementAPI(token: token, http: scoped).projects()
        }
        #expect(ManagementAPIError.badToken.errorDescription?.contains("didn't accept that token") == true)
    }

    @Test func clientKeyNeverPicksAPrivilegedKey() {
        let anon = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJsdWVib3hwcm9qZWN0cmVmYWFhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE2MDAwMDAsImV4cCI6MjA3NzE3NjAwMH0.c2lnbmF0dXJlLW5vdC1jaGVja2Vk"
        let service = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJsdWVib3hwcm9qZWN0cmVmYWFhIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc2MTYwMDAwMCwiZXhwIjoyMDc3MTc2MDAwfQ.c2lnbmF0dXJlLW5vdC1jaGVja2Vk"
        // Old projects: only legacy keys. The anon one, by what it is rather than what it's called.
        #expect(SupabaseManagementAPI.pickClientKey([("legacy", "service_role", service), ("legacy", "anon", anon)]) == anon)
        #expect(SupabaseManagementAPI.pickClientKey([("legacy", "anon", service)]) == nil)
        #expect(SupabaseManagementAPI.pickClientKey([("publishable", "default", "sb_secret_abcdefghijklmnop")]) == nil)
        #expect(SupabaseManagementAPI.pickClientKey([("publishable", "default", nil)]) == nil)
    }

    @Test func revealsKeysOnlyWhenTheyAreHidden() async throws {
        let http = FakeSupabaseManagement()
        http.keysNeedReveal = true
        let key = try await SupabaseManagementAPI(token: token, http: http).clientKey("blueboxprojectrefaaa")
        #expect(key == FakeSupabaseManagement.publishableKey)
        let queries = http.requests.map { $0.url?.query ?? "" }
        #expect(queries == ["", "reveal=true"])
    }
}

@Suite struct SupabaseAutoSetupTests {
    func setup(_ http: FakeSupabaseManagement, zone: String = "Europe/London", token: String = FakeSupabaseManagement.goodToken,
               timeout: TimeInterval = 600) -> SupabaseAutoSetup {
        var s = SupabaseAutoSetup(token: token, http: http, timeZone: TimeZone(identifier: zone)!, sleep: { _ in },
                                  makePassword: { "generated-database-password-0001" })
        s.startTimeout = timeout
        return s
    }

    @Test func createsAFreeProjectNearbyAndSetsItUp() async throws {
        let http = FakeSupabaseManagement()
        let log = StepLog()
        let outcome = try await setup(http).run(.automatic) { log.add($0) }

        #expect(outcome.config.url.absoluteString == "https://blueboxprojectrefaaa.supabase.co")
        #expect(outcome.config.publishableKey == FakeSupabaseManagement.publishableKey)
        #expect(outcome.ownsProject && !outcome.hasAccounts)
        #expect(log.steps == [.checkingToken, .creatingServer, .creatingTables, .configuringSignIn, .connecting])

        let create = try #require(http.requests.first { $0.httpMethod == "POST" && $0.url?.path == "/v1/projects" })
        let body = try #require(try JSONSerialization.jsonObject(with: create.httpBody!) as? [String: Any])
        #expect(body["name"] as? String == "Bluebox")
        #expect(body["organization_slug"] as? String == "tsrqponmlkjihgfedcba")
        #expect(body["db_pass"] as? String == "generated-database-password-0001")
        #expect(body["region_selection"] as? [String: String] == ["type": "specific", "code": "eu-west-1"])
        #expect(body["organization_id"] == nil && body["region"] == nil && body["plan"] == nil)

        let project = try #require(http.projects.first { $0.ref == FakeSupabaseManagement.createdRef })
        #expect(project.tables && project.status == "ACTIVE_HEALTHY")

        let patch = try #require(http.authPatches(FakeSupabaseManagement.createdRef).first)
        #expect(patch["external_email_enabled"] as? Bool == true)
        #expect(patch["mailer_autoconfirm"] as? Bool == true)
        #expect(patch["site_url"] as? String == "bluebox://auth-callback")
        #expect(patch["uri_allow_list"] as? String == "bluebox://auth-callback")
        #expect(patch["password_min_length"] as? Int == 8)
        #expect(patch["disable_signup"] as? Bool == false)
    }

    @Test func reusesTheBlueboxProjectAndLeavesItsTablesAlone() async throws {
        var bluebox = FakeSupabaseManagement.Project(ref: "existingblueboxaaaaa", name: "bluebox", status: "ACTIVE_HEALTHY")
        bluebox.tables = true; bluebox.users = 1
        let http = FakeSupabaseManagement(projects: [bluebox])
        let log = StepLog()
        let outcome = try await setup(http).run(.automatic) { log.add($0) }

        #expect(outcome.ref == "existingblueboxaaaaa" && outcome.hasAccounts)
        #expect(log.steps == [.checkingToken, .creatingTables, .configuringSignIn, .connecting])
        #expect(!http.log.contains("POST /v1/projects"))
        let sql = http.requests.compactMap { $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } }
        #expect(!sql.contains { $0.contains("create table") })
        // Sign-ups stay as they are: the account already exists.
        #expect(http.authPatches("existingblueboxaaaaa").first?["disable_signup"] == nil)
    }

    @Test func runningAgainAfterATimeoutPicksUpWhereItStopped() async throws {
        let http = FakeSupabaseManagement()
        http.pollsUntilHealthy = 1_000
        await #expect(throws: SupabaseAutoSetup.Failure.stillStarting) {
            try await setup(http, timeout: 0).run(.automatic) { _ in }
        }
        http.pollsUntilHealthy = 0
        let log = StepLog()
        let outcome = try await setup(http).run(.automatic) { log.add($0) }
        #expect(outcome.ref == FakeSupabaseManagement.createdRef)
        #expect(http.log.filter { $0 == "POST /v1/projects" }.count == 1)  // created once, then reused
        #expect(log.steps.contains(.startingServer))
        #expect(SupabaseAutoSetup.Failure.stillStarting.errorDescription?.contains("Try again") == true)

        // And once more, with everything in place: nothing is created or re-run.
        _ = try await setup(http).run(.automatic) { _ in }
        #expect(http.log.filter { $0 == "POST /v1/projects" }.count == 1)
    }

    @Test func aPausedBlueboxProjectIsWokenUp() async throws {
        let http = FakeSupabaseManagement(projects: [.init(ref: "pausedblueboxaaaaaaa", name: "Bluebox", status: "INACTIVE")])
        let outcome = try await setup(http).run(.automatic) { _ in }
        #expect(outcome.ref == "pausedblueboxaaaaaaa")
        #expect(http.log.contains("POST /v1/projects/pausedblueboxaaaaaaa/restore"))
    }

    @Test func aFullFreePlanOffersTheRunningProjects() async throws {
        let http = FakeSupabaseManagement()
        http.projectLimitReached = true
        do {
            _ = try await setup(http).run(.automatic) { _ in }
            Issue.record("expected the project limit")
        } catch let failure as SupabaseAutoSetup.Failure {
            #expect(failure.alternatives?.map(\.name) == ["Recipes"])  // the paused one can't be used as it is
            #expect(failure.errorDescription?.contains("two active projects") == true)
        }

        // The user picks Recipes: Bluebox sets up there, but leaves that project's other settings alone.
        let outcome = try await setup(http).run(.existing(ref: "qwertyuiopasdfghjklz")) { _ in }
        #expect(!outcome.ownsProject)
        let patch = try #require(http.authPatches("qwertyuiopasdfghjklz").first)
        #expect(patch.keys.sorted() == ["external_email_enabled", "mailer_autoconfirm"])
    }

    @Test func accountsWithoutAnOrganizationGetOne() async throws {
        let http = FakeSupabaseManagement(projects: [])
        http.organizationsJSON = "[]"
        _ = try await setup(http).run(.automatic) { _ in }
        #expect(http.log.contains("POST /v1/organizations"))
        let create = try #require(http.requests.first { $0.url?.path == "/v1/projects" && $0.httpMethod == "POST" })
        let body = try JSONSerialization.jsonObject(with: create.httpBody!) as? [String: Any]
        #expect(body?["organization_slug"] as? String == "neworgslugaaaaaaaaaa")
    }

    @Test func paidOrganizationsAreNotUsed() async throws {
        let http = FakeSupabaseManagement()
        http.organizationPlan = "pro"
        await #expect(throws: SupabaseAutoSetup.Failure.noFreeOrganization([
            ManagedProject(ref: "qwertyuiopasdfghjklz", name: "Recipes", organizationSlug: "tsrqponmlkjihgfedcba",
                           region: "eu-west-2", status: "ACTIVE_HEALTHY"),
        ])) {
            try await setup(http).run(.automatic) { _ in }
        }
        #expect(!http.log.contains("POST /v1/projects"))
    }

    @Test func aProjectFromBeforeProfilesGetsOnlyTheLaterMigrations() async throws {
        var old = FakeSupabaseManagement.Project(ref: "olderblueboxaaaaaaaa", name: "Bluebox", status: "ACTIVE_HEALTHY")
        old.tables = true; old.profilesOnlyMissing = true
        let http = FakeSupabaseManagement(projects: [old])
        _ = try await setup(http).run(.automatic) { _ in }
        let sql = queries(http)
        #expect(sql.contains(SupabaseSetupFiles.profilesMigrationSQL + "\n" + SupabaseSetupFiles.accountSettingsMigrationSQL
                             + "\n" + SupabaseSetupFiles.listsMigrationSQL))
        #expect(!sql.contains(SupabaseSetupFiles.setupSQL))
        #expect(http.projects[0].tables && !http.projects[0].profilesOnlyMissing && !http.projects[0].settingsMissing)
    }

    /// The private-channel policies (security review BB-03) are safe to run
    /// again, so a project that's otherwise up to date gets them too.
    @Test func anUpToDateProjectGetsTheRealtimePolicies() async throws {
        var old = FakeSupabaseManagement.Project(ref: "olderblueboxaaaaaaaa", name: "Bluebox", status: "ACTIVE_HEALTHY")
        old.tables = true
        let http = FakeSupabaseManagement(projects: [old])
        _ = try await setup(http).run(.automatic) { _ in }
        let sql = queries(http)
        #expect(sql.contains(SupabaseSetupFiles.realtimePrivateMigrationSQL))
        #expect(!sql.contains(SupabaseSetupFiles.setupSQL) && !sql.contains(SupabaseSetupFiles.listsMigrationSQL))
        #expect(http.projects[0].realtimePrivate)
    }

    @Test func aProjectFromBeforeListsGetsOnlyTheFourthMigration() async throws {
        var old = FakeSupabaseManagement.Project(ref: "olderblueboxaaaaaaaa", name: "Bluebox", status: "ACTIVE_HEALTHY")
        old.tables = true; old.listsMissing = true
        let http = FakeSupabaseManagement(projects: [old])
        _ = try await setup(http).run(.automatic) { _ in }
        let sql = queries(http)
        #expect(sql.contains(SupabaseSetupFiles.listsMigrationSQL))
        #expect(!sql.contains(SupabaseSetupFiles.accountSettingsMigrationSQL) && !sql.contains(SupabaseSetupFiles.setupSQL))
        #expect(!http.projects[0].listsMissing)
    }

    @Test func aProjectFromBeforeAccountSettingsGetsTheThirdAndFourthMigrations() async throws {
        var old = FakeSupabaseManagement.Project(ref: "olderblueboxaaaaaaaa", name: "Bluebox", status: "ACTIVE_HEALTHY")
        old.tables = true; old.settingsMissing = true
        let http = FakeSupabaseManagement(projects: [old])
        _ = try await setup(http).run(.automatic) { _ in }
        let sql = queries(http)
        #expect(sql.contains(SupabaseSetupFiles.accountSettingsMigrationSQL + "\n" + SupabaseSetupFiles.listsMigrationSQL))
        #expect(!sql.contains(SupabaseSetupFiles.setupSQL) && !sql.contains(SupabaseSetupFiles.profilesMigrationSQL))
        #expect(!http.projects[0].settingsMissing)
    }

    private func queries(_ http: FakeSupabaseManagement) -> [String] {
        http.requests.compactMap { req -> String? in
            (req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["query"] as? String
        }
    }

    @Test func tablePlanRefusesSomeoneElsesProfilesTable() throws {
        typealias S = SupabaseAutoSetup
        #expect(try S.tablePlan(.init()) == .everything)
        #expect(try S.tablePlan(.init(progress: true, watchlist: true, profiles: true, syncProfiles: true, settings: true, lists: true)) == .nothing)
        #expect(try S.tablePlan(.init(progress: true, watchlist: true, profiles: true, syncProfiles: true, settings: true)) == .listsOnly)
        #expect(try S.tablePlan(.init(progress: true, watchlist: true, profiles: true, syncProfiles: true)) == .settingsOnly)
        #expect(try S.tablePlan(.init(progress: true, watchlist: true)) == .profilesOnly)
        #expect(throws: S.Failure.foreignProfilesTable) { try S.tablePlan(.init(profiles: true)) }
        #expect(throws: S.Failure.tablesHalfSetUp) { try S.tablePlan(.init(progress: true)) }
        // pg-meta's row values, however they come.
        let row: [String: Any] = ["progress": true, "watchlist": NSNumber(value: true), "profiles": "t", "sync_profiles": "true", "settings": 1,
                                  "lists": "t", "users": "3"]
        #expect(S.DatabaseState(row: row) == .init(progress: true, watchlist: true, profiles: true, syncProfiles: true,
                                                    settings: true, lists: true, users: 3))
    }

    @Test func badTokensAndKeysAreCaughtEarly() async throws {
        #expect(SupabaseAutoSetup.checkToken("  ") != nil)
        #expect(SupabaseAutoSetup.checkToken("sb_publishable_abc")?.contains("project key") == true)
        #expect(SupabaseAutoSetup.checkToken("eyJhbGciOi.x.y")?.contains("project key") == true)
        #expect(SupabaseAutoSetup.checkToken("sbp_abc def") != nil)
        #expect(SupabaseAutoSetup.checkToken(" \(FakeSupabaseManagement.goodToken)\n") == nil)

        let http = FakeSupabaseManagement()
        await #expect(throws: SupabaseAutoSetup.Failure.api(.badToken)) {
            try await setup(http, token: "sbp_revoked").run(.automatic) { _ in }
        }
    }

    @Test func turningOffSignupsIsOnePatch() async throws {
        let http = FakeSupabaseManagement()
        try await setup(http).turnOffSignups(ref: "qwertyuiopasdfghjklz")
        #expect(http.authPatches("qwertyuiopasdfghjklz").count == 1)
        #expect(http.authPatches("qwertyuiopasdfghjklz")[0]["disable_signup"] as? Bool == true)
    }

    @Test func regionsFollowTheTimeZone() {
        func region(_ id: String) -> String { SupabaseRegions.fallbackRegion(for: TimeZone(identifier: id)!) }
        #expect(SupabaseRegions.continent(for: TimeZone(identifier: "America/Sao_Paulo")!) == "SA")
        #expect(SupabaseRegions.continent(for: TimeZone(identifier: "Australia/Sydney")!) == "OC")
        #expect(region("America/New_York") == "us-east-1")
        #expect(region("America/Los_Angeles") == "us-west-1")
        #expect(region("America/Toronto") == "ca-central-1")
        #expect(region("Europe/London") == "eu-west-2")
        #expect(region("Europe/Berlin") == "eu-central-1")
        #expect(region("Asia/Tokyo") == "ap-northeast-1")
        #expect(region("Asia/Kolkata") == "ap-south-1")
        #expect(region("Asia/Singapore") == "ap-southeast-1")
        #expect(region("Pacific/Auckland") == "ap-southeast-2")
    }

    @Test func databasePasswordsAreStrongAndRandom() {
        let a = SupabaseAutoSetup.databasePassword(), b = SupabaseAutoSetup.databasePassword()
        #expect(a.count == 32 && a != b)
        #expect(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }
}

@Suite struct UsernameTests {
    @Test func usernamesAreCheckedAndLowerCased() throws {
        #expect(try BlueboxUsername.check(" Brian.Chen ").get() == "brian.chen")
        #expect(try BlueboxUsername.check("a_b-c").get() == "a_b-c")
        #expect(BlueboxUsername.check("") == .failure(.empty))
        #expect(BlueboxUsername.check("ab") == .failure(.length))
        #expect(BlueboxUsername.check(String(repeating: "a", count: 33)) == .failure(.length))
        #expect(BlueboxUsername.check("brian chen") == .failure(.characters))
        #expect(BlueboxUsername.check("brïan") == .failure(.characters))
        #expect(BlueboxUsername.check("me@home") == .failure(.characters))
        #expect(BlueboxUsername.check(".brian") == .failure(.edges))
        #expect(BlueboxUsername.check("brian-") == .failure(.edges))
        #expect(BlueboxUsername.check("bri..an") == .failure(.edges))
    }

    @Test func aUsernameIsAnAddressThatCanNeverReceiveMail() throws {
        #expect(try BlueboxUsername.email(for: "Brian") == "brian@bluebox.invalid")
        #expect(BlueboxUsername.username(fromEmail: "brian@bluebox.invalid") == "brian")
        #expect(BlueboxUsername.username(fromEmail: "Brian@Bluebox.Invalid") == "brian")
        #expect(BlueboxUsername.username(fromEmail: "brian@example.com") == nil)
        #expect(BlueboxUsername.username(fromEmail: nil) == nil)
        // GoTrue's sign-up check (badoux/checkmail's format regex) accepts every allowed username.
        let checkmail = /^[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/
        for name in ["abc", "a.b-c_d", String(repeating: "z", count: 32), "007"] {
            #expect(try checkmail.wholeMatch(in: BlueboxUsername.email(for: name)) != nil)
        }
    }

    @Test func passwordRules() {
        #expect(BlueboxUsername.checkPassword("") != nil)
        #expect(BlueboxUsername.checkPassword("1234567") == "Use at least 8 characters.")
        #expect(BlueboxUsername.checkPassword("12345678") == nil)
        #expect(BlueboxUsername.checkPassword(String(repeating: "x", count: 73)) != nil)
    }
}

@Suite struct PasswordAuthTests {
    func auth(_ server: FakeSupabase, _ secrets: MemorySecretStore = MemorySecretStore()) -> SupabaseAuth {
        SupabaseAuth(config: FakeSupabase.config, http: server, secrets: secrets)
    }

    @Test func signUpSignsStraightIn() async throws {
        let server = FakeSupabase(), secrets = MemorySecretStore()
        let s = try await auth(server, secrets).signUp(username: "Brian", password: "a long password")
        #expect(s.email == "brian@bluebox.invalid")
        #expect(try secrets.read(SecretAccount.supabaseSession) != nil)
        let body = try #require(try JSONSerialization.jsonObject(with: server.lastSignupRequest!.httpBody!) as? [String: String])
        #expect(body == ["email": "brian@bluebox.invalid", "password": "a long password"])

        // The same username and password sign in on another device.
        let other = try await auth(server).signIn(username: "BRIAN", password: "a long password")
        #expect(other.userID == s.userID)
        let query = server.lastPasswordRequest?.url?.query
        #expect(query == "grant_type=password")
        await #expect(throws: SyncError.wrongPassword) { try await auth(server).signIn(username: "brian", password: "wrong one") }
    }

    @Test func takenUsernamesAndShortPasswords() async throws {
        let server = FakeSupabase()
        try await auth(server).signUp(username: "brian", password: "a long password")
        await #expect(throws: SyncError.usernameTaken) { try await auth(server).signUp(username: "Brian", password: "another one") }
        await #expect(throws: SyncError.weakPassword("Use at least 8 characters.")) {
            try await auth(server).signUp(username: "newperson", password: "short")
        }
        #expect(SyncError.wrongPassword.errorDescription == "Wrong username or password.")
        #expect(SyncError.usernameTaken.errorDescription?.hasPrefix("That username is taken") == true)
    }

    @Test func confirmEmailOnIsExplained() async throws {
        let server = FakeSupabase()
        server.confirmEmail = true
        await #expect(throws: SyncError.confirmEmailRequired) { try await auth(server).signUp(username: "brian", password: "a long password") }
        #expect(SyncError.confirmEmailRequired.errorDescription?.contains("Confirm email") == true)
    }

    @Test func goTrueSignUpErrorsMapToPlainWords() async {
        let cases: [(Int, String, SyncError)] = [
            (422, #"{"code":422,"error_code":"signup_disabled","msg":"Signups not allowed for this instance"}"#, .signupsDisabled),
            (422, #"{"code":422,"error_code":"weak_password","msg":"Password should be at least 10 characters.","weak_password":{"reasons":["length"]}}"#,
             .weakPassword("Password should be at least 10 characters.")),
            (400, #"{"code":400,"error_code":"email_provider_disabled","msg":"Email signups are disabled"}"#, .emailSignInDisabled),
            (400, #"{"code":400,"error_code":"email_address_not_authorized","msg":"Email address not authorized"}"#, .confirmEmailRequired),
            (500, #"{"code":500,"msg":"Error sending confirmation email"}"#, .confirmEmailRequired),
            (429, #"{"code":429,"error_code":"over_request_rate_limit","msg":"Request rate limit reached"}"#, .rateLimited),
        ]
        for (status, body, expected) in cases {
            let server = FakeSupabase()
            server.signupFailure = (status, body)
            await #expect(throws: expected) { try await auth(server).signUp(username: "brian", password: "a long password") }
        }
    }

    @Test func goTrueSignInErrorsMapToPlainWords() {
        func f(_ status: Int, _ code: String?, _ msg: String) -> SupabaseAuth.AuthFailure { .init(status: status, code: code, message: msg) }
        #expect(SupabaseAuth.signInError(f(400, "invalid_credentials", "Invalid login credentials")) == .wrongPassword)
        #expect(SupabaseAuth.signInError(f(400, nil, "Invalid login credentials")) == .wrongPassword)
        #expect(SupabaseAuth.signInError(f(400, "email_not_confirmed", "Email not confirmed")) == .accountNotConfirmed)
        #expect(SupabaseAuth.signInError(f(429, nil, "slow down")) == .rateLimited)
    }
}

@Suite struct ConnectLinkTests {
    let config = SupabaseConfig(url: "https://abcdefghijklmnopqrst.supabase.co", publishableKey: "sb_publishable_abcdefghijklmnop")!

    @Test func roundTripsThroughTheLink() throws {
        let url = ConnectLink(config: config).url
        #expect(url.absoluteString == "bluebox://connect?url=https%3A%2F%2Fabcdefghijklmnopqrst.supabase.co&key=sb_publishable_abcdefghijklmnop")
        #expect(try ConnectLink.parse(url)?.config == config)
        // Pasted with words around it, as chat apps do.
        #expect(try ConnectLink.parse(text: "Open this: \(url.absoluteString) \n").config == config)
    }

    @Test func otherLinksAndBadOnes() throws {
        #expect(try ConnectLink.parse(URL(string: "bluebox://auth-callback#access_token=a")!) == nil)
        #expect(try ConnectLink.parse(URL(string: "https://example.com/connect")!) == nil)
        #expect(throws: SupabaseSetupError.self) { try ConnectLink.parse(URL(string: "bluebox://connect?url=https%3A%2F%2Fx.supabase.co")!) }
        #expect(throws: SupabaseSetupError.self) { try ConnectLink.parse(text: "hello") }
    }

    @Test func aPrivilegedKeyInALinkIsRefused() {
        let link = URL(string: "bluebox://connect?url=https%3A%2F%2Fabcdefghijklmnopqrst.supabase.co&key=sb_secret_abcdefghijklmnop")!
        #expect(throws: SupabaseSetupError.privilegedKey) { try ConnectLink.parse(link) }
    }
}
