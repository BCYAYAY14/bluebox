import Domain
@testable import Features
import Foundation
import Metadata
import Persistence
import Sync
import Testing
import TestingSupport

/// A tiny Supabase stand-in: Auth settings, table probes, links and empty sync answers.
final class AccountStubServer: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    var paths: [String] { lock.withLock { _paths } }
    var missingTables: Set<String> = []
    var goodAccessToken = "good-access"
    /// Held `/auth/v1/user` calls, to act while a link sign-in is in flight.
    var holdUser = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        lock.withLock { _paths.append(path) }
        if path == "/auth/v1/user", lock.withLock({ holdUser }) {
            await withCheckedContinuation { c in lock.withLock { held.append(c) } }
        }
        let (status, body) = respond(request, path)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func release() { lock.withLock { held.forEach { $0.resume() }; held = []; holdUser = false } }
    func waitUntilHeld() async { while lock.withLock({ held.isEmpty }) { await Task.yield() } }

    /// Username → password, for `/signup` and `grant_type=password`.
    private var accounts: [String: String] = [:]

    private func session(_ email: String) -> String {
        #"{"access_token":"good-access","refresh_token":"r-\#(UUID().uuidString)","expires_in":3600,"user":{"id":"u-\#(email)","email":"\#(email)"}}"#
    }

    private func respond(_ req: URLRequest, _ path: String) -> (Int, String) {
        let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String] ?? [:]
        switch path {
        case "/auth/v1/settings": return (200, #"{"external":{"email":true},"disable_signup":false,"mailer_autoconfirm":true}"#)
        case "/auth/v1/signup":
            guard let email = body["email"], let password = body["password"] else { return (400, "{}") }
            if lock.withLock({ accounts[email] }) != nil {
                return (422, #"{"code":422,"error_code":"user_already_exists","msg":"User already registered"}"#)
            }
            lock.withLock { accounts[email] = password }
            return (200, session(email))
        case "/auth/v1/token" where req.url?.query == "grant_type=password":
            guard let email = body["email"], let password = body["password"], lock.withLock({ accounts[email] }) == password else {
                return (400, #"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#)
            }
            return (200, session(email))
        case "/auth/v1/user":
            return req.value(forHTTPHeaderField: "Authorization") == "Bearer \(goodAccessToken)"
                ? (200, #"{"id":"u1","email":"link@example.com"}"#) : (401, #"{"msg":"invalid JWT"}"#)
        case "/auth/v1/logout": return (204, "")
        default: break
        }
        if path.hasPrefix("/rest/v1/rpc/") { return (200, "[]") }
        if path.hasPrefix("/rest/v1/") {
            let table = String(path.dropFirst("/rest/v1/".count))
            if req.value(forHTTPHeaderField: "Authorization") == nil {
                return lock.withLock({ missingTables.contains(table) })
                    ? (404, #"{"code":"PGRST205","message":"Could not find the table"}"#)
                    : (401, #"{"code":"42501","message":"permission denied"}"#)
            }
            return (200, "[]")
        }
        return (404, "{}")
    }
}

@MainActor
@Suite struct AccountFlowTests {
    static let url = "https://abcdefghijklmnopqrst.supabase.co"
    static let key = "sb_publishable_abcdefghijklmnop"

    func app(_ http: AccountStubServer, secrets: MemorySecretStore = MemorySecretStore()) throws -> AppModel {
        AppModel(store: try LibraryStore.make(inMemory: true), secrets: secrets,
                 prefs: PreferencesStore(defaults: UserDefaults(suiteName: "account.\(UUID().uuidString)")!),
                 http: http, forceSample: true)
    }

    @Test func connectingChecksTheProjectThenStoresIt() async throws {
        let http = AccountStubServer(), secrets = MemorySecretStore()
        let app = try app(http, secrets: secrets)
        #expect(!app.account.isConfigured)
        try await app.connectSupabase(url: "abcdefghijklmnopqrst.supabase.co/", key: Self.key)
        #expect(app.account.isConfigured)
        #expect(app.account.server == URL(string: Self.url))
        #expect(app.account.setupCheck == .ok(warnings: []))
        #expect(try secrets.read(SecretAccount.supabaseServer) != nil)
        #expect(http.paths.contains("/rest/v1/watch_progress"))
    }

    @Test func aServiceRoleKeyIsRefusedBeforeAnythingIsSent() async throws {
        let http = AccountStubServer(), secrets = MemorySecretStore()
        let app = try app(http, secrets: secrets)
        await #expect(throws: SupabaseSetupError.privilegedKey) {
            try await app.connectSupabase(url: Self.url, key: "sb_secret_abcdefghijklmnop")
        }
        #expect(http.paths.isEmpty)
        #expect(try secrets.read(SecretAccount.supabaseServer) == nil)
        #expect(!app.account.isConfigured)
    }

    @Test func missingTablesAreNotSaved() async throws {
        let http = AccountStubServer(), secrets = MemorySecretStore()
        http.missingTables = ["watch_progress", "profiles"]
        let app = try app(http, secrets: secrets)
        await #expect(throws: SupabaseSetupError.tablesMissing) { try await app.connectSupabase(url: Self.url, key: Self.key) }
        #expect(try secrets.read(SecretAccount.supabaseServer) == nil)
        #expect(!app.account.isConfigured)
    }

    /// Bluebox no longer sends sign-in emails, but a link still in an inbox works.
    @Test func anOldEmailLinkStillSignsIn() async throws {
        let http = AccountStubServer()
        let app = try app(http)
        try await app.connectSupabase(url: Self.url, key: Self.key)
        #expect(app.account.handleOpenURL(URL(string: "bluebox://title/1")!) == false)
        let link = AuthCallback(url: URL(string: "bluebox://auth-callback#access_token=good-access&refresh_token=r&expires_in=3600&type=magiclink")!)!
        await app.account.completeSignIn(link)
        #expect(app.account.email == "link@example.com")
        #expect(app.account.linkEvent == .signedIn("link@example.com"))
        #expect(http.paths.contains { $0.hasPrefix("/rest/v1/rpc/") })
        #expect(app.account.lastSynced != nil)
    }

    @Test func expiredLinkExplainsItself() async throws {
        let app = try app(AccountStubServer())
        try await app.connectSupabase(url: Self.url, key: Self.key)
        let link = AuthCallback(url: URL(string: "bluebox://auth-callback#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")!)!
        await app.account.completeSignIn(link)
        #expect(app.account.linkEvent == .failed(SyncError.linkExpired.localizedDescription))
        #expect(!app.account.isSignedIn)
    }

    @Test func linkWithoutAProjectSaysConnectFirst() async throws {
        let app = try app(AccountStubServer())
        #expect(app.account.handleOpenURL(URL(string: "bluebox://auth-callback#access_token=a&refresh_token=r")!))
        await app.account.completeSignIn(AuthCallback(url: URL(string: "bluebox://auth-callback#access_token=a&refresh_token=r")!)!)
        guard case .failed(let why) = app.account.linkEvent else { Issue.record("no event"); return }
        #expect(why.contains("Connect your server"))
    }

    @Test func switchingServersWhileALinkIsFinishingIgnoresIt() async throws {
        let http = AccountStubServer(), secrets = MemorySecretStore()
        let app = try app(http, secrets: secrets)
        try await app.connectSupabase(url: Self.url, key: Self.key)
        http.holdUser = true
        let link = AuthCallback(url: URL(string: "bluebox://auth-callback#access_token=good-access&refresh_token=r")!)!
        let finishing = Task { await app.account.completeSignIn(link) }
        await http.waitUntilHeld()
        app.disconnectSupabase()
        http.release()
        await finishing.value
        #expect(!app.account.isSignedIn)
        #expect(try secrets.read(SecretAccount.supabaseSession) == nil)
    }

    // MARK: Username and password

    @Test func createAccountThenSignInElsewhere() async throws {
        let http = AccountStubServer()
        let first = try app(http)
        try await first.connectSupabase(url: Self.url, key: Self.key)
        try await first.account.createAccount(username: "Brian", password: "a long password")
        #expect(first.account.isSignedIn)
        #expect(first.account.email == "brian@bluebox.invalid")
        #expect(first.account.accountName == "brian")
        #expect(http.paths.contains { $0.hasPrefix("/rest/v1/rpc/") })  // synced straight away

        let second = try app(http)
        try await second.connectSupabase(url: Self.url, key: Self.key)
        await #expect(throws: SyncError.wrongPassword) { try await second.account.signIn(username: "brian", password: "nope nope") }
        #expect(!second.account.isSignedIn)
        try await second.account.signIn(username: "BRIAN", password: "a long password")
        #expect(second.account.accountName == "brian")
        await #expect(throws: SyncError.usernameTaken) {
            try await second.account.createAccount(username: "brian", password: "another password")
        }
    }

    // MARK: Connect links

    @Test func aConnectLinkConnectsAndOpensSignIn() async throws {
        let http = AccountStubServer(), secrets = MemorySecretStore()
        let app = try app(http, secrets: secrets)
        let link = try #require(SupabaseConfig(url: Self.url, publishableKey: Self.key)).connectLinkURL
        await app.connect(fromLink: link)
        #expect(app.account.isConfigured && !app.account.isSignedIn)
        #expect(app.account.server == URL(string: Self.url))
        #expect(app.account.openRequest != nil)
        #expect(app.account.linkEvent == .connected("abcdefghijklmnopqrst.supabase.co"))
        #expect(try secrets.read(SecretAccount.supabaseServer) != nil)
        // The signed-in device shows the same link.
        #expect(app.account.connectLink == link)
    }

    @Test func aConnectLinkNeverSwitchesASignedInDevice() async throws {
        let http = AccountStubServer()
        let app = try app(http)
        try await app.connectSupabase(url: Self.url, key: Self.key)
        try await app.account.createAccount(username: "brian", password: "a long password")
        let other = try #require(SupabaseConfig(url: "https://zzzzzzzzzzzzzzzzzzzz.supabase.co", publishableKey: Self.key)).connectLinkURL
        await app.connect(fromLink: other)
        #expect(app.account.server == URL(string: Self.url))
        #expect(app.account.isSignedIn)
        guard case .failed(let why) = app.account.linkEvent else { Issue.record("no message"); return }
        #expect(why.contains("signed in to another server"))
    }

    @Test func aBrokenConnectLinkSaysSo() async throws {
        let app = try app(AccountStubServer())
        await app.connect(fromLink: URL(string: "bluebox://connect?url=https%3A%2F%2Fabcdefghijklmnopqrst.supabase.co&key=sb_secret_abcdefghijklmnop")!)
        #expect(!app.account.isConfigured)
        #expect(app.account.linkEvent == .failed(SupabaseSetupError.privilegedKey.errorDescription!))
    }

    // MARK: Automatic setup

    @Test(.timeLimit(.minutes(1))) func automaticSetupConnectsCreatesTheAccountAndClosesSignups() async throws {
        let management = FakeSupabaseManagement(projects: [])
        management.pollsUntilHealthy = 0
        let project = AccountStubServer()
        let secrets = RecordingSecrets()
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: secrets,
                           prefs: PreferencesStore(defaults: UserDefaults(suiteName: "account.\(UUID().uuidString)")!),
                           http: Router(management: management, project: project), forceSample: true)

        // A pasted project key is caught before anything is sent.
        #expect(app.serverSetup.start(token: "sb_publishable_abcdefghijklmnop") != nil)
        #expect(management.requests.isEmpty)

        #expect(app.serverSetup.start(token: FakeSupabaseManagement.goodToken) == nil)
        try await waitUntil { !app.serverSetup.isRunning }
        #expect(app.account.isConfigured)
        #expect(app.account.server == URL(string: "https://blueboxprojectrefaaa.supabase.co"))
        #expect(app.serverSetup.needsFirstAccount)

        try await app.account.createAccount(username: "brian", password: "a long password")
        #expect(app.account.isSignedIn)
        try await waitUntil { management.authPatches(FakeSupabaseManagement.createdRef).count == 2 }
        #expect(management.authPatches(FakeSupabaseManagement.createdRef)[1]["disable_signup"] as? Bool == true)
        #expect(!app.serverSetup.needsFirstAccount)

        // The token never reached storage, and only ever went to api.supabase.com.
        #expect(!secrets.everWritten.contains { $0.contains(FakeSupabaseManagement.goodToken) })
        #expect(!project.paths.isEmpty)
        #expect(management.requests.allSatisfy { $0.url?.host() == "api.supabase.com" })
    }

    @Test(.timeLimit(.minutes(1))) func setupFailuresCanBeRetriedOrCancelled() async throws {
        let management = FakeSupabaseManagement()
        management.projectLimitReached = true
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                           prefs: PreferencesStore(defaults: UserDefaults(suiteName: "account.\(UUID().uuidString)")!),
                           http: Router(management: management, project: AccountStubServer()), forceSample: true)
        app.serverSetup.start(token: FakeSupabaseManagement.goodToken)
        try await waitUntil { if case .choosingProject = app.serverSetup.phase { true } else { false } }
        guard case .choosingProject(_, let projects) = app.serverSetup.phase else { return }
        #expect(projects.map(\.name) == ["Recipes"])

        // Picking one carries on with the same token.
        app.serverSetup.use(projects[0])
        try await waitUntil { !app.serverSetup.isRunning }
        #expect(app.account.server == URL(string: "https://qwertyuiopasdfghjklz.supabase.co"))

        // Cancel forgets the token: Try Again has nothing to run with.
        app.disconnectSupabase()
        app.serverSetup.retry()
        #expect(app.serverSetup.phase == .idle)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > 20 { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// api.supabase.com to the Management API stand-in, everything else to the project.
final class Router: HTTPClient, @unchecked Sendable {
    let management: FakeSupabaseManagement
    let project: AccountStubServer
    init(management: FakeSupabaseManagement, project: AccountStubServer) { self.management = management; self.project = project }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        request.url?.host() == "api.supabase.com" ? try await management.send(request) : try await project.send(request)
    }
}

/// A Keychain stand-in that remembers every value ever written.
final class RecordingSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var written: [String] = []
    var everWritten: [String] { lock.withLock { written } }
    func read(_ account: String) throws -> String? { lock.withLock { values[account] } }
    func write(_ value: String?, for account: String) throws {
        lock.withLock { values[account] = value; if let value { written.append(value) } }
    }
}

extension SupabaseConfig {
    var connectLinkURL: URL { ConnectLink(config: self).url }
}
