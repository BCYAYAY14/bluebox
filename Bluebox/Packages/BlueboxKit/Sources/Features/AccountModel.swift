import Domain
import Foundation
import Metadata
import Observation
import Persistence
import Sync

/// Sign-in state and sync status for Settings, plus the triggers that keep the
/// library in sync. Inert when no Supabase project is configured.
@Observable
@MainActor
public final class AccountModel {
    public enum Status: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)
    }

    /// The outcome of opening a `bluebox://connect` link (or a refused
    /// `bluebox://auth-callback` sign-in link), for the banner and the account page.
    public enum LinkEvent: Equatable {
        /// Connecting to the server in a link from another device.
        case connecting
        /// Connected from a link: sign in next. The server's host.
        case connected(String)
        case failed(String)
    }

    /// A device that last synced with another account, waiting for the user
    /// to say what happens to its library (security review BB-01). Nothing
    /// syncs meanwhile.
    public struct AccountChange: Equatable {
        /// The account this device last synced with ("another account" if unknown).
        public var previousName: String
        public var newName: String
        public var myList: Int
        public var continueWatching: Int
        public var profiles: Int
    }

    public enum AccountChangeChoice {
        /// Remove this device's copy of the old library; the new account's comes down.
        case useAccountLibrary
        /// Upload this device's library into the new account.
        case addDeviceLibrary
        case signOut
    }

    /// Checking the connected project for its tables and email settings.
    public enum SetupCheck: Equatable {
        case idle
        case checking
        case ok(warnings: [String])
        case failed(String, needsSetupSQL: Bool)
    }

    /// The signed-in account's address: `<username>@bluebox.invalid`, or a real
    /// email for accounts from before usernames and Sign in with Apple.
    public private(set) var email: String?
    public private(set) var status: Status = .idle
    public private(set) var linkEvent: LinkEvent?
    public private(set) var accountChange: AccountChange?
    /// Changed when something outside Settings (a connect link) wants
    /// Settings › Account shown. RootView opens it.
    public internal(set) var openRequest: UUID?
    public private(set) var setupCheck: SetupCheck = .idle
    /// The last successful sync with this project, kept across launches.
    public private(set) var lastSynced: Date?
    /// Reads the observed `server` (set together with `auth`), so views update on connect and disconnect.
    public var isConfigured: Bool { server != nil }
    public var isSignedIn: Bool { email != nil }
    /// The signed-in account's user ID.
    public private(set) var userID: String?
    /// Sync API Keys for the signed-in account (`SettingsSync.keysEnabled(for:)`).
    public private(set) var syncsKeys = false

    @ObservationIgnored private var auth: SupabaseAuth?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var config: SupabaseConfig?
    @ObservationIgnored private let http: any HTTPClient
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private var store: LibraryStore
    @ObservationIgnored private var profileID: String?
    /// The server in use, for Settings. Changing it is `configure(_:)`.
    public private(set) var server: URL?
    @ObservationIgnored private let prefs: PreferencesStore
    @ObservationIgnored private let profiles: ProfileStore
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var linkEventDismissal: Task<Void, Never>?
    @ObservationIgnored let now: () -> Date
    /// Set by `signOut()`, so a sync it interrupts ends quietly instead of reporting an error.
    @ObservationIgnored private var signedOutOnPurpose = false
    /// Called after a sync changed local records, so screens can refresh.
    @ObservationIgnored var onRemoteChanges: @MainActor () -> Void = {}
    /// Called once a new account exists, so automatic setup can close sign-ups.
    @ObservationIgnored var onAccountCreated: @MainActor () -> Void = {}
    /// Called after any sign-in, so automatic setup can forget its token.
    @ObservationIgnored var onSignedIn: @MainActor () -> Void = {}
    /// Erases this device's library and profiles, for `.useAccountLibrary`.
    @ObservationIgnored var onUseAccountLibrary: @MainActor () async -> Void = {}
    /// Called with the settings keys another device changed, after they're written here.
    @ObservationIgnored var onSettingsChanged: @MainActor ([String]) -> Void = { _ in }
    /// API keys, add-ons and settings that follow the account.
    @ObservationIgnored let settingsSync: SettingsSync?
    /// While the app is in front: pull every `pollInterval` (or `realtimePollInterval`
    /// while Realtime is listening), in case a change signal was missed.
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored var pollInterval: Duration = .seconds(60)
    @ObservationIgnored var realtimePollInterval: Duration = .seconds(600)
    /// Signals another device's changes while the app is in front.
    @ObservationIgnored private var realtime: RealtimeListener?
    public private(set) var realtimeState: RealtimeListener.State = .stopped
    @ObservationIgnored private var inForeground = false
    /// Off in tests that drive sync by hand.
    @ObservationIgnored var usesRealtime = true
    /// While a video plays, progress goes up at most this often (and right away on pause).
    @ObservationIgnored var playingSyncInterval: TimeInterval = 60
    @ObservationIgnored private var lastPlayingSync: Date?

    init(config: SupabaseConfig?, http: any HTTPClient, secrets: any SecretStore, store: LibraryStore, prefs: PreferencesStore,
         profiles: ProfileStore, settingsSync: SettingsSync? = nil, now: @escaping () -> Date = { Date() }) {
        self.http = http; self.prefs = prefs; self.profiles = profiles; self.secrets = secrets; self.store = store
        self.settingsSync = settingsSync
        self.now = now
        configure(config)
    }

    /// The project ref, for links into the Supabase dashboard.
    public var projectRef: String? { SupabaseDashboard.ref(for: server) }

    /// The name to show for the signed-in account: the username, or the
    /// email for an account from before usernames.
    public var accountName: String? {
        guard let email else { return nil }
        return BlueboxUsername.username(fromEmail: email) ?? email
    }

    /// `bluebox://connect?…` for this server, for "Add Another Device". Holds only
    /// the URL and the publishable key, which are public by design.
    public var connectLink: URL? {
        _ = server  // observed, so the link follows the connected server
        return config.map { ConnectLink(config: $0).url }
    }

    /// Points sign-in and sync at a Supabase project, or turns sync off with nil.
    /// Changing projects signs out of the old one.
    func configure(_ config: SupabaseConfig?) {
        pending?.cancel(); pending = nil
        stopRealtime()
        // A sync or refresh still running on the old client must not write its
        // session into the Keychain or report it as this project's sign-in.
        auth?.retire()
        // A session belongs to one project: drop it before the new client reads the Keychain.
        if self.config != nil, config != self.config { try? secrets.write(nil, for: SecretAccount.supabaseSession) }
        self.config = config
        server = config?.url
        email = nil
        accountChange = nil
        setUser(nil)
        status = .idle
        setupCheck = .idle
        lastSynced = config.flatMap { prefs.value(Date.self, for: Self.lastSyncedKey($0)) }
        guard let config else { auth = nil; engine = nil; return }
        let auth = SupabaseAuth(config: config, http: http, secrets: secrets)
        self.auth = auth
        if let profileID {
            engine = SyncEngine(auth: auth, config: config, http: http, store: store, prefs: prefs,
                                profileID: profileID, profiles: profiles, settings: settingsSync)
        } else {
            engine = SyncEngine(auth: auth, config: config, http: http, store: store, prefs: prefs, profiles: profiles,
                                settings: settingsSync)
        }
        Task { [weak self] in
            await auth.observe { [weak self] session in
                Task { @MainActor in
                    guard let self, self.auth === auth else { return }
                    self.email = session.map { $0.email ?? "Signed in" }
                    self.setUser(session?.userID)
                }
            }
            let session = await auth.currentSession
            guard let self, self.auth === auth else { return }
            self.email = session.map { $0.email ?? "Signed in" }
            self.setUser(session?.userID)
        }
    }

    /// Points sync at another profile's library.
    func switchLibrary(to store: LibraryStore, profileID: String) {
        // A change made just before switching (My List, progress saved as the
        // player closed) is waiting on the debounce: push it with the old
        // profile's engine instead of leaving it until that profile is used again.
        if pending != nil, let old = engine, isSignedIn { Task { _ = try? await old.sync() } }
        pending?.cancel(); pending = nil
        self.store = store
        self.profileID = profileID
        guard let auth, let config else { return }
        engine = SyncEngine(auth: auth, config: config, http: http, store: store, prefs: prefs,
                            profileID: profileID, profiles: profiles, settings: settingsSync)
    }

    // MARK: Sign-in

    /// Signs in with a username and password, then syncs.
    public func signIn(username: String, password: String) async throws {
        guard let auth else { throw SyncError.notConfigured }
        let session = try await auth.signIn(username: username, password: password)
        guard self.auth === auth else { return }
        didSignIn(session.email ?? username)
        await syncNow()
    }

    /// Creates an account (Supabase signs it straight in), then syncs: this
    /// device's library becomes the account's.
    public func createAccount(username: String, password: String) async throws {
        guard let auth else { throw SyncError.notConfigured }
        let session = try await auth.signUp(username: username, password: password)
        guard self.auth === auth else { return }
        onAccountCreated()  // before didSignIn, which lets automatic setup forget its token
        didSignIn(session.email ?? username)
        await syncNow()
    }

    public func signInWithApple(idToken: String, nonce: String) async throws {
        guard let auth else { throw SyncError.notConfigured }
        let session = try await auth.signInWithApple(idToken: idToken, nonce: nonce)
        guard self.auth === auth else { return }
        didSignIn(session.email ?? "Apple ID")
        await syncNow()
    }

    private func didSignIn(_ address: String) {
        signedOutOnPurpose = false
        email = address
        onSignedIn()
        if inForeground { setInForeground(true) }
    }

    /// Whether this build has the Sign in with Apple capability (see SETUP.md).
    public var appleSignInAvailable: Bool {
        isConfigured && (Bundle.main.object(forInfoDictionaryKey: "AppleSignInEnabled") as? String)?.uppercased() == "YES"
    }

    // MARK: Changing accounts

    /// What the user chose for a device that last synced with another account.
    public func resolveAccountChange(_ choice: AccountChangeChoice) async {
        guard accountChange != nil, let userID else { return }
        accountChange = nil
        switch choice {
        case .addDeviceLibrary:
            SyncEngine.approve(user: userID, prefs: prefs)
            await syncNow()
        case .useAccountLibrary:
            await onUseAccountLibrary()
            SyncEngine.adopt(user: userID, profileIDs: profiles.allIDs(), prefs: prefs)
            await syncNow()
        case .signOut:
            await signOut()
        }
    }

    private func makeAccountChange(previous: String) async -> AccountChange {
        let names = prefs.value([String: String].self, for: Self.accountNamesKey) ?? [:]
        let store = store
        let myList = (try? await store.watchlist().count) ?? 0
        let watching = (try? await store.continueWatching(limit: 1000).count) ?? 0
        return AccountChange(previousName: names[previous.lowercased()] ?? "another account", newName: accountName ?? "this account",
                             myList: myList, continueWatching: watching, profiles: profiles.active().count)
    }

    /// User ID → account name, so the question can say whose library this is.
    static let accountNamesKey = "bluebox.sync.accountNames"

    private func rememberAccountName() {
        guard let userID, let accountName else { return }
        var names = prefs.value([String: String].self, for: Self.accountNamesKey) ?? [:]
        guard names[userID.lowercased()] != accountName else { return }
        names[userID.lowercased()] = accountName
        prefs.set(names, for: Self.accountNamesKey)
    }

    // MARK: Sync API Keys

    private func setUser(_ id: String?) {
        if userID != id { userID = id }
        let keys = id.map { settingsSync?.keysEnabled(for: $0) ?? false } ?? false
        if syncsKeys != keys { syncsKeys = keys }
    }

    /// Turns Sync API Keys on or off for the signed-in account (Settings asks
    /// first, listing what leaves the Keychain). Off is the default, and each
    /// account has its own switch.
    public func setSyncsKeys(_ on: Bool) {
        guard let userID, let settingsSync else { return }
        settingsSync.setKeysEnabled(on, for: userID)
        syncsKeys = on
        if on { scheduleSync(after: .milliseconds(200)) }
    }

    /// Deletes the keys and add-on links this account has on the server
    /// (uploaded by earlier versions, or before the switch was turned off).
    /// No device's Keychain changes. Sync API Keys turns off first, so a sync
    /// running meanwhile can't put them back.
    public func removeKeysFromServer() async throws {
        guard let engine else { throw SyncError.notConfigured }
        setSyncsKeys(false)
        try await engine.removeSecretsFromServer()
    }

    // MARK: Sign-in links

    /// Refuses a `bluebox://auth-callback` URL with a message. Bluebox never
    /// asks for sign-in emails, so such a link, with tokens or without, wasn't
    /// started here and mustn't change who's signed in (security review BB-01).
    /// Returns false for URLs that aren't sign-in links.
    @discardableResult
    public func handleOpenURL(_ url: URL) -> Bool {
        guard AuthCallback.matches(url) else { return false }
        showLinkEvent(.failed(AuthCallback.refusal))
        return true
    }

    public func dismissLinkEvent() {
        linkEventDismissal?.cancel()
        linkEvent = nil
    }

    func showLinkEvent(_ event: LinkEvent) {
        linkEventDismissal?.cancel()
        linkEvent = event
        guard event != .connecting else { return }
        // Success fades on its own; errors stay a while longer so they can be read.
        let delay: Duration = switch event {
        case .connected: .seconds(4)
        default: .seconds(10)
        }
        linkEventDismissal = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.linkEvent = nil
        }
    }

    // MARK: Project health

    /// Re-checks the connected project: reachable, key accepted, tables present.
    public func checkSetup() async {
        guard let config else { return }
        setupCheck = .checking
        do {
            let report = try await SupabaseProjectProbe.check(config, http: http)
            guard self.config == config else { return }
            setupCheck = .ok(warnings: report.warnings)
        } catch {
            guard self.config == config else { return }
            setupCheck = .failed(Self.describe(error), needsSetupSQL: (error as? SupabaseSetupError)?.needsSetupSQL ?? false)
        }
    }

    /// Records a check made while connecting, so its warnings show straight away.
    func recordSetupCheck(_ report: SupabaseProjectReport) {
        setupCheck = .ok(warnings: report.warnings)
    }

    // MARK: Sync

    /// Pushes anything waiting first (up to 8 seconds), so nothing made on
    /// this account is left behind if another account's library replaces it.
    public func signOut() async {
        pending?.cancel()
        stopRealtime()
        if let engine, isSignedIn, accountChange == nil {
            let push = Task { _ = try? await engine.sync() }
            let deadline = Task { try? await Task.sleep(for: .seconds(8)); push.cancel() }
            await push.value
            deadline.cancel()
        }
        signedOutOnPurpose = true
        await auth?.signOut()
        email = nil
        setUser(nil)
        accountChange = nil
        status = .idle
    }

    /// Syncs right away (launch, foreground, Sync Now).
    public func syncNow() async {
        pending?.cancel()
        pending = nil
        await run()
    }

    /// Syncs shortly after a local change, coalescing bursts of edits.
    public func scheduleSync(after delay: Duration = .seconds(2)) {
        guard engine != nil, isSignedIn else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    /// The player saved its position. While playing, sync at most every
    /// minute; on pause or at the end, soon, so another device can pick up there.
    func progressSaved(playing: Bool) {
        let date = now()
        if playing, let last = lastPlayingSync, date.timeIntervalSince(last) < playingSyncInterval { return }
        lastPlayingSync = playing ? date : nil
        scheduleSync()
    }

    /// The app came to the front (true) or went away (false). In front, it
    /// pulls every minute; the foreground sync itself is `syncNow`.
    func setInForeground(_ inFront: Bool) {
        inForeground = inFront
        polling?.cancel(); polling = nil
        guard inFront else { stopRealtime(); return }
        startRealtime()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self.map({ $0.realtimeState == .listening ? $0.realtimePollInterval : $0.pollInterval }) else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                // A change waiting on the debounce syncs by itself.
                if self.pending == nil, self.isSignedIn { await self.run() }
            }
        }
    }

    private func startRealtime() {
        guard usesRealtime, realtime == nil, let auth, let config, isSignedIn else { return }
        let listener = RealtimeListener(config: config, auth: auth, onChange: { [weak self] in
            Task { @MainActor in self?.scheduleSync(after: .seconds(1)) }
        }, onState: { [weak self] state in
            Task { @MainActor in
                guard let self, self.realtime != nil || state == .stopped else { return }
                self.realtimeState = state
            }
        })
        realtime = listener
        Task { await listener.start() }
    }

    /// The remote-control channel on this account (RemoteControl.swift); nil while signed out.
    func makeRemoteChannel(onMessage: @escaping @Sendable (RemoteMessage) -> Void,
                           onState: @escaping @Sendable (RemoteChannel.State) -> Void) -> RemoteChannel? {
        guard let auth, let config, isSignedIn else { return nil }
        return RemoteChannel(config: config, auth: auth, onMessage: onMessage, onState: onState)
    }

    private func stopRealtime() {
        guard let listener = realtime else { return }
        realtime = nil
        realtimeState = .stopped
        Task { await listener.stop() }
    }

    private func run() async {
        guard let engine, let auth, let config, await auth.currentSession != nil else { return }
        status = .syncing
        do {
            let report = try await engine.sync()
            if !report.settingsChanged.isEmpty { onSettingsChanged(report.settingsChanged) }
            if report.applied > 0 { onRemoteChanges() }
            guard self.auth === auth else { return }  // switched projects meanwhile
            rememberAccountName()
            let date = now()
            status = .synced(date)
            lastSynced = date
            prefs.set(date, for: Self.lastSyncedKey(config))
        } catch SyncError.accountChanged(let previous) {
            guard self.auth === auth else { return }
            status = .idle
            let change = await makeAccountChange(previous: previous)
            if accountChange != change { accountChange = change }
        } catch SyncError.signedOut {
            guard self.auth === auth else { return }
            // Signing out on purpose while a sync was running isn't an error.
            status = signedOutOnPurpose ? .idle : .failed(SyncError.signedOut.localizedDescription)
            email = nil
        } catch {
            guard self.auth === auth else { return }
            status = .failed(Self.describe(error))
        }
    }

    static func lastSyncedKey(_ config: SupabaseConfig) -> String {
        "bluebox.sync.lastSynced.\(config.url.host() ?? config.url.absoluteString)"
    }

    /// A user-facing sentence for any account error.
    public static func describe(_ error: any Error) -> String {
        if let e = error as? LocalizedError, let text = e.errorDescription { return text }
        if let e = error as? URLError, e.code == .notConnectedToInternet { return SyncError.offline.localizedDescription }
        return error.localizedDescription
    }
}
