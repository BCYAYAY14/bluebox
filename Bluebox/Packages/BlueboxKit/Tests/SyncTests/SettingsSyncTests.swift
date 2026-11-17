import Domain
import Foundation
@testable import Persistence
@testable import Sync
import Testing

/// API keys, add-ons and settings following the account between devices.
@Suite struct SettingsSyncTests {
    struct Device {
        let prefs: PreferencesStore
        let base: MemorySecretStore
        let secrets: RecordingSecretStore
        let settings: SettingsSync
        let engine: SyncEngine
    }

    static let brian = "user-brian@bluebox.invalid"

    /// A device signed in as `username`, with Sync API Keys on unless `keys` is false.
    func device(_ server: FakeSupabase, username: String = "brian", keys: Bool = true,
                clock: @escaping @Sendable () -> Date = { Date() }) async throws -> Device {
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "settings.test.\(UUID().uuidString)")!)
        let base = MemorySecretStore()
        let settings = SettingsSync(prefs: prefs, secrets: base, preferenceKeys: ["bluebox.addons", "bluebox.playback.skipBack"],
                                    profileKeySuffixes: [".subtitleStyle"], secretAccounts: ["tmdb.credential"],
                                    secretAccountPrefixes: ["addon."], now: clock)
        prefs.onSet = { settings.preferenceChanged($0) }
        let auth = SupabaseAuth(config: FakeSupabase.config, http: server, secrets: MemorySecretStore())
        let session = try await auth.signIn(username: username, password: FakeSupabase.password)
        if keys { settings.setKeysEnabled(true, for: session.userID) }
        let store = try LibraryStore.make(inMemory: true)
        let engine = SyncEngine(auth: auth, config: FakeSupabase.config, http: server, store: store, prefs: prefs, settings: settings)
        return Device(prefs: prefs, base: base, secrets: RecordingSecretStore(base, sync: settings), settings: settings, engine: engine)
    }

    @Test func keysAndSettingsReachANewDevice() async throws {
        let server = FakeSupabase()
        let a = try await device(server)
        try a.secrets.write("tmdb-key", for: "tmdb.credential")
        a.prefs.set(15, for: "bluebox.playback.skipBack")
        a.prefs.set("only here", for: "bluebox.lastTab")  // not a synced key
        try await a.engine.sync()

        let b = try await device(server)
        let report = try await b.engine.sync()
        #expect(try b.base.read("tmdb.credential") == "tmdb-key")
        #expect(b.prefs.value(Int.self, for: "bluebox.playback.skipBack") == 15)
        #expect(b.prefs.value(String.self, for: "bluebox.lastTab") == nil)
        #expect(Set(report.settingsChanged) == ["secret.tmdb.credential", "bluebox.playback.skipBack"])
        // Applying them didn't mark them as B's own changes.
        #expect(b.settings.pending().isEmpty)
    }

    @Test func newestChangeWinsAndRemovalsSync() async throws {
        let server = FakeSupabase()
        let a = try await device(server), b = try await device(server)
        a.prefs.set(10, for: "bluebox.playback.skipBack")
        try await a.engine.sync()
        try await b.engine.sync()
        try await Task.sleep(for: .milliseconds(5))
        b.prefs.set(30, for: "bluebox.playback.skipBack")
        try await b.engine.sync()
        try await a.engine.sync()
        #expect(a.prefs.value(Int.self, for: "bluebox.playback.skipBack") == 30)

        try a.secrets.write("k", for: "tmdb.credential")
        try await a.engine.sync(); try await b.engine.sync()
        #expect(try b.base.read("tmdb.credential") == "k")
        try await Task.sleep(for: .milliseconds(5))
        try a.secrets.write(nil, for: "tmdb.credential")
        try await a.engine.sync(); try await b.engine.sync()
        #expect(try b.base.read("tmdb.credential") == nil)
    }

    @Test func aFreshDeviceTakesTheAccountsSettingsOverItsOwn() async throws {
        let server = FakeSupabase()
        let a = try await device(server)
        a.prefs.set(20, for: "bluebox.playback.skipBack")
        try await a.engine.sync()
        // B had a value before it ever synced (written without stamping, like before this feature).
        let b = try await device(server)
        b.prefs.setRawData(try JSONEncoder().encode(5), for: "bluebox.playback.skipBack")
        try await b.engine.sync()
        #expect(b.prefs.value(Int.self, for: "bluebox.playback.skipBack") == 20)
        try await a.engine.sync()
        #expect(a.prefs.value(Int.self, for: "bluebox.playback.skipBack") == 20)
    }

    @Test func aDevicesExistingKeysReachAnEmptyAccount() async throws {
        let server = FakeSupabase()
        let a = try await device(server)
        try a.base.write("from-before", for: "tmdb.credential")  // saved before settings synced
        try await a.engine.sync()
        let b = try await device(server)
        try await b.engine.sync()
        #expect(try b.base.read("tmdb.credential") == "from-before")
    }

    @Test func perProfileSettingsSyncButOtherProfileKeysDont() {
        let s = SettingsSync(prefs: PreferencesStore(defaults: UserDefaults(suiteName: "settings.keys.\(UUID().uuidString)")!),
                             secrets: MemorySecretStore(), preferenceKeys: ["bluebox.addons"],
                             profileKeySuffixes: [".subtitleStyle"], secretAccounts: ["tmdb.credential"])
        #expect(s.syncsPreference("bluebox.profile.kids.subtitleStyle"))
        #expect(!s.syncsPreference("bluebox.profile.kids.pin"))
        #expect(!s.syncsPreference("bluebox.profileSettings.migrated"))
        #expect(s.remoteKey(secret: "supabase.session") == nil)
    }

    @Test func aProjectWithoutTheTableStillSyncsTheLibrary() async throws {
        let server = FakeSupabase()
        server.settingsTableMissing = true
        let a = try await device(server)
        a.prefs.set(15, for: "bluebox.playback.skipBack")
        try await a.engine.sync()  // doesn't throw
        #expect(!a.settings.pending().isEmpty)  // kept for when the table exists
    }

    @Test func unchangedSavesDontRestamp() {
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "settings.restamp.\(UUID().uuidString)")!)
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        prefs.onSet = { _ in counter.n += 1 }
        prefs.set(["b": 1, "a": 2], for: "k")
        prefs.set(["a": 2, "b": 1], for: "k")
        #expect(counter.n == 1)
    }

    // MARK: Sync API Keys (security review BB-05)

    @Test func keysStayOnTheDeviceUntilSyncAPIKeysIsOn() async throws {
        let server = FakeSupabase()
        let a = try await device(server, keys: false)
        try a.secrets.write("tmdb-key", for: "tmdb.credential")
        a.prefs.set(15, for: "bluebox.playback.skipBack")
        try await a.engine.sync()
        #expect(server.settingKeys(user: Self.brian) == ["bluebox.playback.skipBack"])

        // Another device with it on doesn't receive what was never uploaded,
        // and its own key doesn't come down to a device with it off.
        let b = try await device(server)
        try b.secrets.write("b-key", for: "tmdb.credential")
        try await b.engine.sync()
        try await a.engine.sync()
        #expect(try a.base.read("tmdb.credential") == "tmdb-key")

        // Turned on: the newest local key goes up.
        a.settings.setKeysEnabled(true, for: Self.brian)
        try await Task.sleep(for: .milliseconds(5))
        try a.secrets.write("tmdb-key-2", for: "tmdb.credential")
        try await a.engine.sync()
        try await b.engine.sync()
        #expect(try b.base.read("tmdb.credential") == "tmdb-key-2")
    }

    /// Security review BB-01 with BB-05: signing in to another account with a
    /// key waiting to upload sends nothing to it, before or after the choice.
    @Test func anAccountChangeWithPendingSecretsSendsNoKeys() async throws {
        let server = FakeSupabase()
        let a = try await device(server)
        try a.secrets.write("tmdb-key", for: "tmdb.credential")
        a.prefs.set(15, for: "bluebox.playback.skipBack")
        try await a.engine.sync()
        try a.secrets.write("tmdb-key-2", for: "tmdb.credential")  // waiting to upload

        await a.engine.auth.signOut()
        let other = try await a.engine.auth.signIn(username: "other", password: FakeSupabase.password)
        await #expect(throws: SyncError.accountChanged(previous: Self.brian)) { try await a.engine.sync() }
        #expect(server.settingKeys(user: other.userID).isEmpty)

        SyncEngine.approve(user: other.userID, prefs: a.prefs)
        try await a.engine.sync()
        #expect(!server.settingKeys(user: other.userID).contains { $0.hasPrefix("secret.") })
        #expect(try a.base.read("tmdb.credential") == "tmdb-key-2")
    }

    @Test func theSwitchIsPerAccount() async throws {
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "settings.test.\(UUID().uuidString)")!)
        let settings = SettingsSync(prefs: prefs, secrets: MemorySecretStore(), preferenceKeys: [], profileKeySuffixes: [],
                                    secretAccounts: ["tmdb.credential"])
        settings.setKeysEnabled(true, for: "user-a")
        #expect(settings.keysEnabled(for: "USER-A"))
        #expect(!settings.keysEnabled(for: "user-b"))
    }

    @Test func addonLinksSyncUnderTheirPrefix() async throws {
        let server = FakeSupabase()
        let a = try await device(server)
        a.settings.currentPrefixedSecretAccounts = { ["addon.custom.1"] }
        try a.base.write("https://comet.example/secret-config", for: "addon.custom.1")
        try a.secrets.write("x", for: "unrelated.account")
        try await a.engine.sync()
        #expect(server.settingKeys(user: Self.brian) == ["secret.addon.custom.1"])
        let b = try await device(server)
        try await b.engine.sync()
        #expect(try b.base.read("addon.custom.1") == "https://comet.example/secret-config")
    }

    @Test func removingKeysFromTheServerLeavesEveryKeychainAlone() async throws {
        let server = FakeSupabase()
        let a = try await device(server), b = try await device(server)
        try a.secrets.write("tmdb-key", for: "tmdb.credential")
        a.prefs.set(15, for: "bluebox.playback.skipBack")
        try await a.engine.sync()
        try await b.engine.sync()
        try await a.engine.removeSecretsFromServer()
        #expect(server.settingKeys(user: Self.brian) == ["bluebox.playback.skipBack"])
        try await b.engine.sync()
        try await a.engine.sync()
        #expect(try a.base.read("tmdb.credential") == "tmdb-key")
        #expect(try b.base.read("tmdb.credential") == "tmdb-key")
        // Still on: the device's stamps were forgotten, so the key goes up again.
        try await a.engine.sync()
        #expect(server.settingKeys(user: Self.brian).contains("secret.tmdb.credential"))
    }
}

@Suite struct RealtimeProtocolTests {
    let config = SupabaseConfig(url: "https://abc.supabase.co", publishableKey: "sb_publishable_x")!

    @Test func socketURLAndJoin() throws {
        let url = RealtimeListener.socketURL(config)
        #expect(url.absoluteString == "wss://abc.supabase.co/realtime/v1/websocket?apikey=sb_publishable_x&vsn=1.0.0")
        #expect(RealtimeListener.topic(userID: "ABC-1") == "realtime:bluebox-sync:abc-1")
        let join = RealtimeListener.joinMessage(topic: "realtime:bluebox-sync:u", token: "jwt", ref: "1")
        #expect(join["event"] as? String == "phx_join")
        #expect(join["topic"] as? String == "realtime:bluebox-sync:u")
        let payload = try #require(join["payload"] as? [String: Any])
        #expect(payload["access_token"] as? String == "jwt")
        // Private: Realtime checks the realtime.messages policies (security review BB-03).
        #expect((payload["config"] as? [String: Any])?["private"] as? Bool == true)
        let changes = try #require((payload["config"] as? [String: Any])?["postgres_changes"] as? [[String: String]])
        #expect(changes.map { $0["table"] } == RealtimeListener.tables)
        // Custom lists arrive live too.
        #expect(changes.contains { $0["table"] == "lists" } && changes.contains { $0["table"] == "list_entries" })
        // It must serialise as JSON.
        _ = try JSONSerialization.data(withJSONObject: join)
    }

    @Test func joinWithoutListTablesForOlderProjects() throws {
        let join = RealtimeListener.joinMessage(topic: "t", token: "jwt", ref: "1", tables: RealtimeListener.tablesBeforeLists)
        let config = try #require((join["payload"] as? [String: Any])?["config"] as? [String: Any])
        let changes = try #require(config["postgres_changes"] as? [[String: String]])
        #expect(changes.map { $0["table"] } == ["watch_progress", "watchlist_entries", "profiles", "account_settings"])
        // A refusal about the tables falls back; one about the sign-in doesn't.
        #expect(!RealtimeListener.isAuthProblem("Unable to subscribe to changes with given parameters: [table: lists]"))
        #expect(RealtimeListener.isAuthProblem("Invalid token"))
        #expect(RealtimeListener.isAuthProblem("You do not have permissions to read from this Channel topic"))
    }

    @Test func classifiesMessages() {
        func c(_ s: String) -> RealtimeListener.Incoming { RealtimeListener.classify(Data(s.utf8), topic: "realtime:bluebox-sync") }
        #expect(c(#"{"topic":"realtime:bluebox-sync","event":"phx_reply","ref":"1","payload":{"status":"ok","response":{"postgres_changes":[{"id":1}]}}}"#) == .joined)
        #expect(c(#"{"topic":"phoenix","event":"phx_reply","ref":"2","payload":{"status":"ok","response":{}}}"#) == .other)
        #expect(c(#"{"topic":"realtime:bluebox-sync","event":"postgres_changes","payload":{"data":{"table":"watch_progress"}}}"#) == .change)
        #expect(c(#"{"topic":"realtime:bluebox-sync","event":"phx_reply","payload":{"status":"error","response":{"reason":"Invalid token"}}}"#) == .refused("Invalid token"))
        #expect(c(#"{"topic":"realtime:bluebox-sync","event":"system","payload":{"status":"error","message":"no publication"}}"#) == .refused("no publication"))
        #expect(c(#"{"topic":"realtime:bluebox-sync","event":"system","payload":{"status":"ok"}}"#) == .other)
        #expect(c(#"{"topic":"realtime:bluebox-sync","event":"phx_close","payload":{}}"#) == .closed("phx_close"))
        #expect(c("not json") == .other)
    }
}

@Suite struct RealtimeEchoFilterTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theJoinRightAfterAPassIsSkipped() {
        var f = RealtimeEchoFilter(window: 5)
        do { let answer = f.shouldSync(.joined, at: t0); #expect(answer) }  // nothing ran yet
        f.passStarted()
        do { let answer = f.shouldSync(.joined, at: t0); #expect(!answer) }  // the running pass reads everything
        do { let answer = f.passFinished(at: t0, pushed: false); #expect(!answer) }
        do { let answer = f.shouldSync(.joined, at: t0.addingTimeInterval(2)); #expect(!answer) }
        do { let answer = f.shouldSync(.joined, at: t0.addingTimeInterval(6)); #expect(answer) }
    }

    @Test func ourOwnPushEchoIsIgnored() {
        var f = RealtimeEchoFilter(window: 5)
        f.passStarted()
        do { let answer = f.shouldSync(.change, at: t0); #expect(!answer) }  // decided when the pass ends
        do { let answer = f.passFinished(at: t0, pushed: true); #expect(!answer) }  // it pushed: that was our echo
        do { let answer = f.shouldSync(.change, at: t0.addingTimeInterval(1)); #expect(!answer) }  // a late echo
        do { let answer = f.shouldSync(.change, at: t0.addingTimeInterval(6)); #expect(answer) }  // later: another device
    }

    @Test func aChangeDuringAPassThatPushedNothingIsFollowed() {
        var f = RealtimeEchoFilter(window: 5)
        f.passStarted()
        do { let answer = f.shouldSync(.change, at: t0); #expect(!answer) }
        do { let answer = f.passFinished(at: t0, pushed: false); #expect(answer) }
        // And right after a pass that pushed nothing, a change can't be our echo.
        do { let answer = f.shouldSync(.change, at: t0.addingTimeInterval(1)); #expect(answer) }
    }

    @Test func overlappingPassesDecideTogetherAndFailuresDecideNothing() {
        var f = RealtimeEchoFilter(window: 5)
        f.passStarted(); f.passStarted()
        do { let answer = f.shouldSync(.change, at: t0); #expect(!answer) }
        do { let answer = f.passFinished(at: t0, pushed: false); #expect(!answer) }  // the other is still running
        do { let answer = f.passFinished(at: t0, pushed: true); #expect(!answer) }
        f.passStarted()
        do { let answer = f.shouldSync(.change, at: t0.addingTimeInterval(10)); #expect(!answer) }
        do { let answer = f.passFinished(at: t0.addingTimeInterval(10), pushed: nil); #expect(!answer) }
        // A failed pass doesn't count as a fresh read: the join after it syncs.
        do { let answer = f.shouldSync(.joined, at: t0.addingTimeInterval(11)); #expect(answer) }
    }
}
