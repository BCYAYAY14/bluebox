import Domain
import Foundation
import Metadata
@testable import Persistence
@testable import Sync
import Testing
import TestingSupport

@Suite struct SyncTimestampTests {
    @Test(arguments: [
        ("2026-10-27T01:02:03.123456+00:00", "2026-10-27T01:02:03.123456Z"),
        ("2026-10-27T01:02:03Z", "2026-10-27T01:02:03.000000Z"),
        ("2026-10-27 12:02:03.5+11", "2026-10-27T01:02:03.500000Z"),
        ("2026-10-27T12:02:03.1234567+11:00", "2026-10-27T01:02:03.123456Z"),
        ("2024-02-29T23:59:59.999999-05:30", "2024-03-01T05:29:59.999999Z"),
        ("1970-01-01T00:00:00Z", "1970-01-01T00:00:00.000000Z"),
    ])
    func parsesAndFormats(input: String, expected: String) throws {
        let ts = try #require(SyncTimestamp(iso: input))
        #expect(ts.iso == expected)
        #expect(SyncTimestamp(iso: ts.iso) == ts)
    }

    @Test(arguments: ["", "2026-10-27", "2026-13-01T00:00:00Z", "2026-10-27T01:02:03.Z", "2026-10-27T01:02:03 junk"])
    func rejectsMalformed(_ s: String) { #expect(SyncTimestamp(iso: s) == nil) }

    @Test func agreesWithFoundation() throws {
        let date = Date(timeIntervalSince1970: 1_793_000_123.456)
        let ts = SyncTimestamp(date)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(f.date(from: ts.iso)?.millisecondsSince1970 == date.millisecondsSince1970)
        #expect(ts.date == date.millisecondRounded)
    }
}

@Suite struct SupabaseConfigTests {
    @Test func rejectsPlaceholdersAndEmpty() {
        #expect(SupabaseConfig(url: "", publishableKey: "") == nil)
        #expect(SupabaseConfig(url: "https://YOUR-PROJECT.supabase.co", publishableKey: "x") == nil)
        #expect(SupabaseConfig(url: "https://abc.supabase.co", publishableKey: "YOUR_PUBLISHABLE_KEY") == nil)
        #expect(SupabaseConfig(url: "http://abc.supabase.co", publishableKey: "k") == nil)
        #expect(SupabaseConfig(url: "https://abc.supabase.co", publishableKey: "sb_publishable_x") != nil)
    }
}

@Suite struct SupabaseAuthTests {
    @Test func signInStoresSessionInSecretStore() async throws {
        let server = FakeSupabase(), secrets = MemorySecretStore()
        let auth = SupabaseAuth(config: FakeSupabase.config, http: server, secrets: secrets)
        let s = try await auth.signIn(username: " Brian ", password: FakeSupabase.password)
        #expect(s.email == "brian@bluebox.invalid")
        #expect(try secrets.read(SecretAccount.supabaseSession) != nil)
        // A new instance restores the session from the Keychain stand-in.
        let again = SupabaseAuth(config: FakeSupabase.config, http: server, secrets: secrets)
        #expect(await again.currentSession == s)
    }

    @Test func wrongPasswordAndBadUsername() async throws {
        let server = FakeSupabase()
        let auth = SupabaseAuth(config: FakeSupabase.config, http: server, secrets: MemorySecretStore())
        await #expect(throws: SyncError.wrongPassword) { try await auth.signIn(username: "brian", password: "not it") }
        // A username that can't exist is refused before anything is sent.
        await #expect(throws: SyncError.invalidUsername(BlueboxUsername.Problem.length.errorDescription!)) {
            try await auth.signIn(username: "me", password: "")  // "me" is too short
        }
        #expect(server.count("POST /auth/v1/token") == 1)
        #expect(await auth.currentSession == nil)
    }

    @Test func refreshesNearExpiryAndSharesOneRequest() async throws {
        let server = FakeSupabase()
        let clock = Clock()
        let auth = SupabaseAuth(config: FakeSupabase.config, http: server, secrets: MemorySecretStore(), now: { clock.now })
        let first = try await auth.signIn(username: "brian", password: FakeSupabase.password)
        #expect(try await auth.accessToken() == first.accessToken)
        clock.now = first.expiresAt.addingTimeInterval(-30)
        async let a = auth.accessToken()
        async let b = auth.accessToken()
        let (ta, tb) = try await (a, b)
        #expect(ta == tb && ta != first.accessToken)
        #expect(server.count("POST /auth/v1/token") == 2)  // the sign-in, then one shared refresh
    }

    @Test func rejectedRefreshSignsOut() async throws {
        let server = FakeSupabase()
        let auth = SupabaseAuth(config: FakeSupabase.config, http: server, secrets: MemorySecretStore())
        _ = try await auth.signIn(username: "brian", password: FakeSupabase.password)
        server.rejectRefresh = true
        await #expect(throws: SyncError.signedOut) { try await auth.refresh() }
        #expect(await auth.currentSession == nil)
    }
}

/// Two devices syncing through one fake project.
@Suite struct SyncEngineTests {
    struct Device {
        let store: LibraryStore
        let engine: SyncEngine
        let auth: SupabaseAuth
    }

    func device(_ server: FakeSupabase, username: String = "brian") async throws -> Device {
        let store = try LibraryStore.make(inMemory: true)
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "sync.test.\(UUID().uuidString)")!)
        let auth = SupabaseAuth(config: FakeSupabase.config, http: server, secrets: MemorySecretStore())
        _ = try await auth.signIn(username: username, password: FakeSupabase.password)
        return Device(store: store, engine: SyncEngine(auth: auth, config: FakeSupabase.config, http: server, store: store, prefs: prefs), auth: auth)
    }

    let movie = Title(key: .movie(tmdbID: 1), kind: .movie, name: "One")
    let show = Title(key: .series(tmdbID: 2), kind: .series, name: "Two")

    @Test func profilesSyncAndKeepSeparateLibraries() async throws {
        let server = FakeSupabase()
        func setup() async throws -> (SupabaseAuth, PreferencesStore, ProfileStore) {
            let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "sync.test.\(UUID().uuidString)")!)
            let auth = SupabaseAuth(config: FakeSupabase.config, http: server, secrets: MemorySecretStore())
            _ = try await auth.signIn(username: "brian", password: FakeSupabase.password)
            return (auth, prefs, ProfileStore(prefs: prefs))
        }
        let (authA, prefsA, profilesA) = try await setup()
        let (authB, prefsB, profilesB) = try await setup()
        profilesA.save(Profile(id: "kids", name: "Kids", symbol: "star.fill", color: 3, updatedAt: .now))

        // Device A: default profile watched the movie; Kids added the show to its list.
        let defaultA = try LibraryStore.make(inMemory: true), kidsA = try LibraryStore.make(inMemory: true)
        try await defaultA.save(WatchProgress(key: movie.key, position: 600, duration: 3600, updatedAt: .now))
        try await kidsA.setWatchlisted(show, true)
        try await SyncEngine(auth: authA, config: FakeSupabase.config, http: server, store: defaultA, prefs: prefsA, profiles: profilesA).sync()
        try await SyncEngine(auth: authA, config: FakeSupabase.config, http: server, store: kidsA, prefs: prefsA,
                             profileID: "kids", profiles: profilesA).sync()

        // Device B learns the profile list, and each library stays separate.
        let defaultB = try LibraryStore.make(inMemory: true), kidsB = try LibraryStore.make(inMemory: true)
        try await SyncEngine(auth: authB, config: FakeSupabase.config, http: server, store: defaultB, prefs: prefsB, profiles: profilesB).sync()
        #expect(profilesB.active().map(\.name) == ["Me", "Kids"])
        #expect(profilesB.profile("kids")?.color == 3)
        try await SyncEngine(auth: authB, config: FakeSupabase.config, http: server, store: kidsB, prefs: prefsB,
                             profileID: "kids", profiles: profilesB).sync()
        #expect(try await defaultB.progress(for: movie.key)?.position == 600)
        #expect(try await defaultB.watchlist().isEmpty)
        #expect(try await kidsB.watchlist().map(\.key) == [show.key])
        #expect(try await kidsB.progress(for: movie.key) == nil)

        // Removing a profile reaches the other device.
        profilesB.remove("kids")
        try await SyncEngine(auth: authB, config: FakeSupabase.config, http: server, store: defaultB, prefs: prefsB, profiles: profilesB).sync()
        try await SyncEngine(auth: authA, config: FakeSupabase.config, http: server, store: defaultA, prefs: prefsA, profiles: profilesA).sync()
        #expect(profilesA.active().map(\.id) == ["default"])
    }

    @Test func progressAndWatchlistReachTheOtherDevice() async throws {
        let server = FakeSupabase()
        let a = try await device(server), b = try await device(server)
        try await a.store.save(.fixture(movie.key, 600, at: 1_000, device: "A"))
        try await a.store.setWatchlisted(show, true)

        let pushed = try await a.engine.sync()
        #expect(pushed.uploaded == 2)
        #expect(try await a.store.pendingUploads().isEmpty)
        #expect(try await a.store.pendingWatchlistUploads().isEmpty)

        let pulled = try await b.engine.sync()
        #expect(pulled.applied == 2)
        #expect(try await b.store.progress(for: movie.key)?.position == 600)
        #expect(try await b.store.watchlist().map(\.key) == [show.key])
        #expect(try await b.store.title(for: show.key)?.name == "Two")
        // Pulled records aren't re-uploaded.
        #expect(try await b.store.pendingUploads().isEmpty)
    }

    @Test func removalPropagatesAndNewestProgressWins() async throws {
        let server = FakeSupabase()
        let a = try await device(server), b = try await device(server)
        try await a.store.setWatchlisted(show, true)
        try await a.store.save(.fixture(movie.key, 600, at: 1_000, device: "A"))
        try await a.engine.sync(); try await b.engine.sync()

        try await Task.sleep(for: .milliseconds(5))
        try await b.store.setWatchlisted(show, false)
        try await b.store.save(.fixture(movie.key, 1_200, at: 2_000, device: "B"))
        try await a.store.save(.fixture(movie.key, 900, at: 1_500, device: "A"))  // older than B's

        try await b.engine.sync()
        let r = try await a.engine.sync()   // A's push loses; server returns B's row
        #expect(r.applied >= 2)
        #expect(try await a.store.watchlist().isEmpty)
        #expect(try await a.store.progress(for: movie.key)?.position == 1_200)
        try await b.engine.sync()
        #expect(try await b.store.progress(for: movie.key)?.position == 1_200)
    }

    @Test func pagesThroughLargePulls() async throws {
        let server = FakeSupabase()
        server.pageSize = 500
        let a = try await device(server), b = try await device(server)
        for i in 1...1_150 { try await a.store.save(.fixture(.movie(tmdbID: i), 100, at: Double(i), device: "A")) }
        #expect(try await a.engine.sync().uploaded == 1_150)
        #expect(server.count("POST /rest/v1/rpc/sync_progress") == 6)  // batches of 200
        #expect(try await b.engine.sync().applied == 1_150)
        #expect(try await b.store.recent(limit: 2_000).count == 1_150)
        #expect(server.count("GET /rest/v1/watch_progress") >= 4)  // 3 pages for B (+ A's own pull)
    }

    @Test func expiredTokenIsRefreshedOnce() async throws {
        let server = FakeSupabase()
        let a = try await device(server)
        try await a.store.save(.fixture(movie.key, 600, at: 1_000))
        server.rejectNextWithUnauthorized = true
        #expect(try await a.engine.sync().uploaded == 1)
        #expect(server.count("POST /auth/v1/token") == 2)  // the sign-in, then one refresh
    }

    @Test func newAccountUploadsWholeLocalLibrary() async throws {
        let server = FakeSupabase()
        let a = try await device(server)
        try await a.store.save(.fixture(movie.key, 600, at: 1_000))
        try await a.engine.sync()
        #expect(try await a.store.pendingUploads().isEmpty)

        await a.auth.signOut()
        _ = try await a.auth.signIn(username: "other", password: FakeSupabase.password)
        #expect(try await a.engine.sync().uploaded == 1)

        let other = try await device(server, username: "other")
        try await other.engine.sync()
        #expect(try await other.store.progress(for: movie.key)?.position == 600)
    }

    @Test func pullQueryQuotesCursorValues() async throws {
        let server = FakeSupabase()
        let a = try await device(server)
        let cursor = SyncCursor(timestamp: SyncTimestamp(iso: "2026-01-01T00:00:00.5Z")!, mediaKey: "tmdb:tv:1:s1e2")
        let req = try await a.engine.selectRequest("watch_progress", columns: "media_key", after: cursor, token: "t")
        let or = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "or" }!.value!
        #expect(or == #"(server_updated_at.gt."2026-01-01T00:00:00.500000Z",and(server_updated_at.eq."2026-01-01T00:00:00.500000Z",media_key.gt."tmdb:tv:1:s1e2"))"#)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(req.value(forHTTPHeaderField: "apikey") == FakeSupabase.config.publishableKey)
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date()
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}

@Suite struct AppleSignInTests {
    /// The id_token grant, answered by a tiny stub (FakeSupabase covers the rest of GoTrue).
    final class Stub: HTTPClient, @unchecked Sendable {
        var body: [String: String] = [:]
        var path = ""
        func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
            path = r.url!.path + "?" + (r.url!.query ?? "")
            body = (try? JSONDecoder().decode([String: String].self, from: r.httpBody ?? Data())) ?? [:]
            let ok = body["id_token"] == "apple.jwt"
            let json = ok ? #"{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"id":"u","email":"x@privaterelay.appleid.com"}}"#
                          : #"{"msg":"Bad ID token"}"#
            return (Data(json.utf8), HTTPURLResponse(url: r.url!, statusCode: ok ? 200 : 400, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func exchangesTheAppleTokenForASession() async throws {
        let stub = Stub(), secrets = MemorySecretStore()
        let auth = SupabaseAuth(config: FakeSupabase.config, http: stub, secrets: secrets)
        let s = try await auth.signInWithApple(idToken: "apple.jwt", nonce: "raw-nonce")
        #expect(stub.path == "/auth/v1/token?grant_type=id_token")
        #expect(stub.body == ["provider": "apple", "id_token": "apple.jwt", "nonce": "raw-nonce"])
        #expect(s.email == "x@privaterelay.appleid.com")
        #expect(try secrets.read(SecretAccount.supabaseSession) != nil)
        await #expect(throws: SyncError.self) { try await auth.signInWithApple(idToken: "bad", nonce: "n") }
    }
}
