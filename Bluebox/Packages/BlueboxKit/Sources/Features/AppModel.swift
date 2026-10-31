import Addons
import TorrentStreaming
import DesignSystem
import Domain
import Downloads
import Foundation
import MediaSources
import Metadata
import Observation
import Persistence
import Playback
import Subtitles
import Sync
import SystemSnapshot
import Torrent
import VLCPlayback

/// Composition root and app-wide state. Screens get services from here; the
/// services themselves stay independent and testable.
@Observable
@MainActor
public final class AppModel {
    /// `live` is TMDB; `cinemeta` is Stremio's keyless catalogue, used without a TMDB key.
    public enum CatalogMode: Equatable { case live, sample, cinemeta }

    public private(set) var metadata: any MetadataProvider
    public private(set) var catalogMode: CatalogMode
    /// Bumped whenever watchlist or progress changes so screens can refresh.
    public internal(set) var libraryRevision = 0 {
        didSet { scheduleSystemRefresh() }  // widgets, Spotlight and Siri (AppModel+System.swift)
    }
    @ObservationIgnored public let system = SystemSurfaces()
    /// Bumped when Settings clears recent searches, so Search reloads them.
    var searchHistoryRevision = 0
    /// Bumped when sources are added, removed, enabled, or rescanned.
    public internal(set) var sourcesRevision = 0
    public private(set) var sourceConfigurations: [SourceConfiguration] = []
    /// Fix Match choices for local and debrid files (`AppModel+FixMatch`).
    @ObservationIgnored let matchOverrides: MatchOverrides
    public private(set) var activePlayer: PlayerSession?
    @ObservationIgnored private var activeVariant: MediaVariant?
    /// The Jellyfin or Emby item last reported as playing, so it can be
    /// reported stopped when the player closes or Up Next moves on.
    @ObservationIgnored var serverPlayback: (source: JellyfinSource, itemID: String, position: TimeInterval)?
    public var alert: AppAlert?
    /// The release picker opened from outside a title's page (an alert's "Releases…").
    var releasePickerRequest: TitleDetailView.ReleaseRequest?
    /// A magnet, .torrent or video opened from outside (dropped on the Mac
    /// window, or a link opened in Bluebox): what the open sheet shows.
    public var externalOpen: ExternalOpenState?
    /// File › Open… on the Mac: shows the picker for videos, folders and .torrent files.
    public var pickingFiles = false
    /// A short non-blocking message (`ToastHost` draws it).
    public var toast: AppToast?
    /// The current profile's subtitle look and languages (`ProfileSettingKey`).
    public var subtitleStyle: SubtitleStyle {
        didSet { prefs.set(subtitleStyle, for: ProfileSettingKey.subtitleStyle(currentProfileID)) }
    }
    /// The current profile's equaliser, for every video (`ProfileSettingKey.equalizer`).
    public var equalizer = EqualizerSettings() {
        didSet { prefs.set(equalizer, for: ProfileSettingKey.equalizer(currentProfileID)) }
    }
    public var defaultSpeed: Float { didSet { prefs.set(defaultSpeed, for: PreferenceKey.playbackSpeed) } }
    /// Playback, subtitle, network and advanced settings (Settings › …).
    public let settings: AppSettings
    /// Trailers, new episodes, the debrid library, scrobbling (AppModel+Features.swift).
    public let features: FeatureServices
    /// Settings › Privacy & Features: a switch for each feature that could feel invasive.
    public let featureSwitches: FeatureSwitches
    /// My Bluebox statistics and release alerts (Statistics/, ReleaseAlerts.swift).
    public let insights: InsightsModel

    /// Sign-in and cloud sync. Inert when the build has no Supabase configuration.
    public let account: AccountModel
    /// Setting up a Supabase project from an access token (Settings › Account & Sync).
    public let serverSetup: ServerSetupModel
    /// Trakt watchlist and history sync. Inert without Trakt app credentials.
    public let trakt: TraktModel
    /// The current profile's library.
    @ObservationIgnored public private(set) var store: LibraryStore
    /// The default profile's library (Trakt syncs this one).
    @ObservationIgnored let defaultStore: LibraryStore
    @ObservationIgnored let profileStore: ProfileStore
    @ObservationIgnored private let libraryDirectory: URL?
    @ObservationIgnored private var openStores: [String: LibraryStore] = [:]
    /// Each profile's Not Interested titles (Settings › Hidden Titles; AppModel+Home.swift).
    @ObservationIgnored let hiddenTitles: HiddenTitlesStore
    /// Bumped when a title is hidden or un-hidden.
    public internal(set) var hiddenRevision = 0
    /// Home's personal rows, one small file per profile (HomePersonalization.swift).
    @ObservationIgnored var personalHome: PersonalHomeStore
    public private(set) var profiles: [Profile] = []
    public private(set) var currentProfileID = Profile.defaultID
    public var currentProfile: Profile { profiles.first { $0.id == currentProfileID } ?? .makeDefault() }
    /// Profiles with a PIN on this device (`ProfileLockStore`, in the Keychain).
    public private(set) var lockedProfileIDs: Set<String> = []
    @ObservationIgnored let locks: ProfileLockStore
    /// A switch asked for from a shortcut, the menu bar or the profile menu;
    /// RootView runs it (asking for the PIN first when the profile is locked).
    public var profileSwitchRequest: ProfileSwitchRequest?
    /// Bumped to open "Who's watching?" (Profiles › Who's Watching? in the Mac menu bar).
    public var profilePickerRequest = 0
    @ObservationIgnored public let registry: MediaSourceRegistry
    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored let prefs: PreferencesStore
    @ObservationIgnored let http: any HTTPClient
    @ObservationIgnored let directLinks: DirectURLSource
    /// Saved copies for offline playback.
    @ObservationIgnored public let downloads: DownloadManager
    /// Bumped when any download changes, so download buttons and the list refresh.
    public private(set) var downloadsRevision = 0
    /// Keys with a finished download. Only reassigned when the set changes, so the "Downloaded"
    /// badge doesn't re-render every screen on each progress tick.
    public private(set) var completedDownloadKeys: Set<MediaKey> = []
    /// Downloading or queued, for the tab badge. Only reassigned when it changes.
    public private(set) var activeDownloadCount = 0
    /// Downloads asked for that aren't queued yet (a release is being found),
    /// so their buttons answer at once (SeasonDownloads.swift).
    public internal(set) var preparingDownloads: Set<MediaKey> = []
    /// Seasons Download Season is still queueing (`SeasonDownloadRequest.jobID`).
    var seasonJobs: Set<String> = []
    @ObservationIgnored var seasonDownloadTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Queue size, Wi‑Fi only, delete after watching… (`setDownloadSettings`).
    public internal(set) var downloadSettings: DownloadSettings
    /// Info hashes / download IDs held back while the same release streams.
    @ObservationIgnored var streamHolds: [String] = []
    /// Download states last seen, so finishing and failing can be announced.
    @ObservationIgnored var lastDownloadStates: [String: DownloadRecord.State]?
    @ObservationIgnored let downloadLifecycle = DownloadLifecycle()
    /// What an external player is reading from Bluebox's stream server (`AppModel+ExternalPlayer`).
    @ObservationIgnored var externalHandoff: ExternalHandoff?
    @ObservationIgnored var madeKeyBridge: CatalogKeyBridge?
    /// Reads add-ons' catalogs and metas (tests pass a fake transport).
    @ObservationIgnored var addonCatalogClient = AddonClient()
    @ObservationIgnored var externalWatch: Task<Void, Never>?
    /// Sound goes to an AirPlay receiver: releases rank MP4 first (`AppModel+Addons`).
    @ObservationIgnored let airPlayRoute = AirPlayRoute()
    /// AVPlayer is showing the video over AirPlay (the player reports it).
    @ObservationIgnored var airPlayingVideo = false
    /// The Live Activity (iPhone) and Dock badge (Mac) for the queue.
    @ObservationIgnored let downloadsPresence = DownloadsPresence()
    /// Shows "Playing on Mac" (iPhone) or publishes this Mac's player (RemoteControl.swift).
    public let remote = RemoteControl()
    /// The Watch Party you're in (AppModel+WatchParty.swift).
    public internal(set) var party: WatchParty?
    /// Join the Party: the invitation for a link that was opened, or Join a Party… asking for a code or link.
    public var partyJoin: PartyJoinRequest?
    /// Why joining failed while the invitation was up (it shows there instead of in an alert).
    public var partyJoinProblem: String?
    /// The party is opening its next title: closing the old player doesn't leave it.
    @ObservationIgnored var partyIsSwitching = false
    /// The Mac's highlight for the remote's touch pad and taps (RemoteFocus.swift).
    @ObservationIgnored public let remoteFocus = RemoteFocus()
    /// Where the remote asked the Mac to go; RootView goes there and clears it.
    public var remoteNavigation: RemoteNavigation?
    /// What the player's skip button offers now ("Skip Intro"), and taking it:
    /// the phone shows the same button (PlayerView keeps it up to date).
    @ObservationIgnored var remoteSkip: (title: String, accept: @MainActor () -> Void)?
    /// Text the remote typed for Search; SearchView takes it and clears it.
    public var remoteSearchText: String?
    /// Bumped by the Mac menu bar's Open Downloads; RootView shows the Downloads tab.
    public var downloadsOpenRequest = 0
    @ObservationIgnored private var bootstrapped = false
    /// Torrents the user added (magnet links / .torrent files). Never searched for.
    @ObservationIgnored public let torrents: TorrentSource
    /// Releases from Stremio add-ons: torrents (via libtorrent) and debrid links.
    @ObservationIgnored public let addons: StremioSource
    public private(set) var addonSettings: AddonSettings
    public private(set) var debridKey: String
    /// What Play is doing while an add-on release is found and buffered.
    public private(set) var addonStatus: AddonPlaybackStatus?
    /// What Play is opening, for the preparing overlay's title and art.
    public private(set) var preparingItem: NowPlayingItem?
    /// Bumped by every `play`: only the newest one opens the player (a double
    /// click, or Play pressed twice, never leaves two videos playing).
    @ObservationIgnored private var playRequest = 0
    public nonisolated var addonsCanStreamTorrents: Bool { addons.canStreamTorrents }
    @ObservationIgnored private var preparing: Task<PlaybackResource, Error>?
    /// The episode Up Next resolved, so the countdown and the play that
    /// follows share one resolve (an add-on torrent is buffered only once).
    @ObservationIgnored private var resolvedNext: (after: MediaKey, item: NowPlayingItem, resource: PlaybackResource, at: Date)?
    /// The next episode's release, picked in the background near the end of
    /// this one (`prepareNextEpisode`) but not started: resolving an add-on
    /// torrent would replace the stream that's still playing.
    @ObservationIgnored private var pickedNext: PickedEpisode?
    /// A list's Play All or Shuffle, in play order (LibraryLists.swift). Cleared when the player closes.
    @ObservationIgnored var listQueue: [Title]?
    /// New List or Edit List, drawn by `listEditorHost()` (ListViews.swift).
    public var listEditor: ListEditorRequest?
    /// Whole-torrent downloads (libtorrent). Their records live in `downloads`.
    @ObservationIgnored let torrentDownloads: TorrentDownloader
    @ObservationIgnored let nowPlaying = NowPlayingBridge()
    /// IMDb / Rotten Tomatoes / Metacritic lookups; nil without an OMDb key.
    @ObservationIgnored public private(set) var ratingsProvider: (any RatingsProvider)?
    public private(set) var hasOMDbKey = false
    /// True when the Supabase project was entered in Settings (not built in).
    public private(set) var hasCustomServer = false
    /// A connect link waiting for the user's yes.
    public private(set) var pendingConnect: PendingConnect?
    /// Online subtitle search; nil without an OpenSubtitles API key.
    @ObservationIgnored private(set) var subtitleSearch: OpenSubtitlesService?
    public private(set) var hasOpenSubtitlesKey = false
    /// Subdl search (Search Online); nil without a Subdl API key.
    @ObservationIgnored var subdl: SubdlService?
    public internal(set) var hasSubdlKey = false
    public private(set) var openSubtitlesSignedIn = false
    @ObservationIgnored private let sample = SampleMetadataProvider()

    public init(store: LibraryStore, secrets: any SecretStore, prefs: PreferencesStore,
                http: any HTTPClient = URLSessionHTTPClient(), forceSample: Bool = false, supabase: SupabaseConfig? = nil,
                trakt traktConfig: TraktConfig? = nil, torrentDirectory: URL? = nil, downloadsDirectory: URL? = nil,
                libraryDirectory: URL? = nil) {
        // The subtitle fonts Bluebox brings, before anything draws a subtitle.
        SubtitleFontCatalog.prepare()
        // API keys, add-ons and settings follow the account (not in previews and tests' sample mode).
        let settingsSync = forceSample ? nil : SettingsSync(prefs: prefs, secrets: secrets, preferenceKeys: Self.syncedPreferenceKeys,
                                                            profileKeySuffixes: Self.syncedProfileKeySuffixes,
                                                            secretAccounts: Self.syncedSecretAccounts,
                                                            secretAccountPrefixes: [SecretAccount.addonLinkPrefix])
        // Add-on links are Keychain accounts named after the add-on; the list says which exist.
        settingsSync?.currentPrefixedSecretAccounts = { [prefs] in
            (prefs.value(AddonSettings.self, for: PreferenceKey.addons)?.addons ?? []).compactMap {
                if case .custom = $0.kind { return SecretAccount.addonLink($0.id) }
                return nil
            }
        }
        let secrets: any SecretStore = settingsSync.map { RecordingSecretStore(secrets, sync: $0) } ?? secrets
        if let settingsSync { prefs.onSet = { key in settingsSync.preferenceChanged(key) } }
        self.store = store; self.defaultStore = store; self.secrets = secrets; self.prefs = prefs; self.http = http
        self.libraryDirectory = libraryDirectory
        hiddenTitles = HiddenTitlesStore(prefs: prefs)
        personalHome = PersonalHomeStore(directory: libraryDirectory == nil
            ? FileManager.default.temporaryDirectory.appending(path: "bluebox-home-\(UUID().uuidString)", directoryHint: .isDirectory)
            : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Bluebox/Home", directoryHint: .isDirectory))
        let profileStore = ProfileStore(prefs: prefs)
        self.profileStore = profileStore
        locks = ProfileLockStore(secrets: secrets)
        openStores[Profile.defaultID] = store
        // A project entered in Settings wins over one built in through Secrets.xcconfig.
        let server = forceSample ? nil : Self.storedServer(secrets)
        hasCustomServer = server != nil
        account = AccountModel(config: server ?? supabase, http: http, secrets: secrets, store: store, prefs: prefs, profiles: profileStore,
                               settingsSync: settingsSync)
        // The access token's requests use their own session: no disk cache, no cookies.
        serverSetup = ServerSetupModel(http: http is URLSessionHTTPClient
                                       ? URLSessionHTTPClient(session: URLSession(configuration: .ephemeral)) : http)
        let resolver = TitleResolver()
        trakt = TraktModel(config: traktConfig, http: http, secrets: secrets, store: store, prefs: prefs,
                           resolveTitle: { key in await resolver.title(for: key) })
        let credential = forceSample ? nil : (try? secrets.read(SecretAccount.tmdb)).flatMap { $0.flatMap(TMDBCredential.init) }
        if let credential {
            metadata = CachedMetadataProvider(TMDBService(credential: credential, http: http))
            catalogMode = .live
        } else if forceSample {
            // Cached like the others, so the profile's maturity filter applies to it too.
            metadata = CachedMetadataProvider(sample)
            catalogMode = .sample
        } else {
            // No TMDB key: browse Stremio's public Cinemeta catalogue instead.
            metadata = CachedMetadataProvider(CinemetaMetadataProvider(http: http))
            catalogMode = .cinemeta
        }
        if !forceSample, let key = (try? secrets.read(SecretAccount.omdb)).flatMap({ $0 }), !key.isEmpty {
            ratingsProvider = OMDbService(apiKey: key, http: http)
            hasOMDbKey = true
        }
        if !forceSample, let key = (try? secrets.read(SecretAccount.openSubtitles)).flatMap({ $0 }), !key.isEmpty {
            let session = (try? secrets.read(SecretAccount.openSubtitlesSession)).flatMap { $0 }
                .flatMap { try? JSONDecoder().decode(OpenSubtitlesService.Session.self, from: Data($0.utf8)) }
            subtitleSearch = OpenSubtitlesService(apiKey: key, http: http, session: session)
            hasOpenSubtitlesKey = true
            openSubtitlesSignedIn = session != nil
        }
        if !forceSample, let key = (try? secrets.read(SecretAccount.subdl)).flatMap({ $0 }), !key.isEmpty {
            subdl = SubdlService(apiKey: key, http: http)
            hasSubdlKey = true
        }
        // AppSettings first: it copies the shared settings into each profile once.
        settings = AppSettings(prefs: prefs)
        subtitleStyle = prefs.value(SubtitleStyle.self, for: ProfileSettingKey.subtitleStyle(Profile.defaultID)) ?? SubtitleStyle()
        equalizer = prefs.value(EqualizerSettings.self, for: ProfileSettingKey.equalizer(Profile.defaultID)) ?? EqualizerSettings()
        defaultSpeed = prefs.value(Float.self, for: PreferenceKey.playbackSpeed) ?? 1
        matchOverrides = MatchOverrides(prefs.value([String: MatchOverride].self, for: PreferenceKey.matchOverrides) ?? [:])
        features = FeatureServices(prefs: prefs, debridLibrary: DebridLibrarySource(api: nil, matcher: nil, overrides: matchOverrides))
        featureSwitches = FeatureSwitches(prefs: prefs)
        insights = InsightsModel(prefs: prefs)
        let links = prefs.value([DirectURLSource.Item].self, for: PreferenceKey.directURLs) ?? []
        directLinks = DirectURLSource(items: links)
        let downloadSettings = prefs.value(DownloadSettings.self, for: PreferenceKey.downloadSettings) ?? DownloadSettings()
        self.downloadSettings = downloadSettings
        if let downloadsDirectory {
            // The queue starts in `bootstrap`, once sources can resolve links.
            downloads = DownloadManager(directory: downloadsDirectory, settings: downloadSettings, startsQueue: false)
        } else {
            // Previews and UI tests: a throwaway folder and no shared background session.
            downloads = DownloadManager(directory: FileManager.default.temporaryDirectory.appending(path: "bluebox-downloads-\(UUID().uuidString)"),
                                        configuration: .ephemeral, settings: downloadSettings, startsQueue: false)
        }
        let torrentDir = torrentDirectory ?? FileManager.default.temporaryDirectory.appending(path: "bluebox-torrents-\(UUID().uuidString)")
        torrents = TorrentSource(client: TorrentClient(directory: torrentDir),
                                 items: prefs.value([TorrentSource.Item].self, for: PreferenceKey.torrents) ?? [])
        let addonSettings = Self.loadAddonSettings(prefs: prefs, secrets: secrets)
        let debridKey = (try? secrets.read(SecretAccount.debrid)).flatMap { $0 } ?? ""
        self.addonSettings = addonSettings
        self.debridKey = debridKey
        torrentDownloads = TorrentDownloader(root: downloads.directory.appending(path: "torrents", directoryHint: .isDirectory),
                                             settings: addonSettings.streamSettings)
        let imdb = IMDbLookup(resolver: resolver)
        addons = StremioSource(settings: addonSettings, debridKey: debridKey,
                               imdbID: { key in await imdb.imdbID(for: key) })
        registry = MediaSourceRegistry()
        sourceConfigurations = prefs.value([SourceConfiguration].self, for: PreferenceKey.sourceConfigurations)
            ?? [SourceConfiguration(id: SourceID("public-catalog"), kind: .publicCatalog, name: "Open Movies")]
        settingsSync?.onLocalChange = { [weak self] in
            Task { @MainActor in self?.account.scheduleSync() }
        }
        account.onSettingsChanged = { [weak self] keys in self?.applySyncedSettings(keys) }
        account.onRemoteChanges = { [weak self] in
            guard let self else { return }
            self.libraryRevision += 1
            self.reloadProfiles()
            self.downloadsFollowProgress(fromOtherDevice: true)  // Smart Downloads follow other devices' watching
        }
        account.onAccountCreated = { [weak self] in self?.serverSetup.firstAccountCreated() }
        account.onSignedIn = { [weak self] in self?.serverSetup.forget() }
        account.onSignOutBlocked = { [weak self] waiting in self?.askToSignOut(leaving: waiting) }
        account.onUseAccountLibrary = { [weak self] in await self?.eraseLibraryForAccountChange() }
        serverSetup.connect = { [weak self] config in
            try await self?.connectSupabase(url: config.url.absoluteString, key: config.publishableKey)
        }
        profiles = profileStore.active()
        lockedProfileIDs = Set(profiles.map(\.id).filter { locks.hasPIN($0) })
        applyContentFilter()
        trakt.onRemoteChanges = { [weak self] in
            self?.libraryRevision += 1
            self?.account.scheduleSync()  // carry what came from Trakt to other devices
            self?.downloadsFollowProgress(fromOtherDevice: true)  // and let Smart Downloads follow it
        }
        resolver.app = self
        downloads.onChange = { [weak self] in
            self?.downloadsRevision += 1
            self?.refreshDownloadSummary()
            self?.announceDownloadChanges()
            self?.downloadLifecycle.downloadsChanged()
            self?.downloadsPresence.downloadsChanged()
        }
        configureDownloads()
        refreshDownloadSummary()
        startMobileData()
    }

    /// Registers configured sources. Call once at launch; later calls do
    /// nothing (a background launch for downloads may have run it already).
    public func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        if let saved = prefs.value(String.self, for: PreferenceKey.currentProfile), saved != Profile.defaultID,
           profileStore.profile(saved)?.isRemoved == false {
            await switchProfile(to: saved, sync: false)
        }
        await registry.register(DownloadsSource(manager: downloads))  // first: offline copies win
        await registry.register(PublicCatalogSource())
        await registry.register(directLinks)
        await registry.register(torrents)
        Task { await torrents.client.resumeAll() }
        await addons.setStatusHandler { [weak self] status in
            Task { @MainActor in
                // Only while Play waits on it: a late update, or one from Up Next
                // resolving the next episode, would leave the buffering overlay
                // up after the player closes.
                guard let self, self.preparing != nil else { return }
                self.addonStatus = status
            }
        }
        await configureAddonRanking()
        for config in sourceConfigurations {
            switch config.kind {
            case .localFolder:
                // A folder whose bookmark no longer resolves still registers: it shows in
                // Settings and My Sources saying what's wrong, rather than vanishing.
                if let source = try? LocalFolderSource.fromConfiguration(config, matcher: makeMatcher(), overrides: matchOverrides) {
                    if let renewed = source.refreshedBookmark { renewBookmark(renewed, for: config.id) }
                    await registry.register(source)
                }
            case .jellyfin, .emby:
                if let source = jellyfinSource(config) { await register(source) }
            case .webdav:
                if let source = webDAVSource(config) { await registry.register(source) }
            case .plex:
                if let source = plexSource(config) { await registry.register(source) }
            default: break
            }
        }
        // Last: your own files and servers win over releases from the internet.
        await registry.register(features.debridLibrary)  // your debrid cloud before new add-on searches
        await registry.register(addons)
        startDownloadQueue()
        startFeatureServices()
        for config in sourceConfigurations {
            await registry.setEnabled(config.isEnabled, for: config.id)
        }
        sourcesRevision += 1
        Task { await account.syncNow() }
        Task { await trakt.syncNow() }
        checkReleaseAlertsIfDue()
    }

    /// Quitting: saves the playing position, stops the stream and torrent
    /// downloads (libtorrent writes their resume data), then stops libtorrent's
    /// threads so the process exits cleanly. Gives up waiting after `timeout`.
    public func prepareForTermination(timeout: Duration = .seconds(6)) async {
        let work = Task { @MainActor in
            preparing?.cancel()
            if activePlayer != nil { await closePlayer() }
            await addons.stopStreaming(waitForTeardown: true)
            await downloads.setTorrentsSuspended(true)
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work.value }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
        await Task.detached { TorrentStreamer.shutdownEngine() }.value
    }

    /// Syncs everything connected (launch, foreground).
    public func syncAll() async {
        checkReleaseAlertsIfDue()  // throttled to every 12 hours
        async let a: Void = account.syncNow()
        async let t: Void = trakt.syncNow()
        _ = await (a, t)
    }

    /// The live app: on-disk store, Keychain, standard defaults. Pass the
    /// Keychain already read (`KeychainStore().cachedBundle()`) so nothing here
    /// waits on the Keychain on the main thread.
    public static func live(secrets: any SecretStore) throws -> AppModel {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Bluebox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try LibraryStore.make(url: dir.appending(path: "Library.store"))
        return AppModel(store: store, secrets: secrets, prefs: PreferencesStore(),
                        supabase: SupabaseConfig(bundle: .main), trakt: TraktConfig(bundle: .main),
                        torrentDirectory: dir.appending(path: "Torrents", directoryHint: .isDirectory),
                        downloadsDirectory: dir.appending(path: "Downloads", directoryHint: .isDirectory),
                        libraryDirectory: dir)
    }

    /// The live app, with the Keychain read off the main thread first. Use at
    /// launch: a Keychain prompt then can't hold up the first window.
    public static func liveReadingSecrets() async throws -> AppModel {
        try live(secrets: await KeychainStore().cachedBundle())
    }

    /// Deterministic in-memory app for previews and UI tests: sample catalog,
    /// a few progress records, one watchlisted title.
    public static func demo(seed: Bool = true) -> AppModel {
        let suite = "bluebox.demo.\(UUID().uuidString)"
        let model = AppModel(store: try! LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                             prefs: PreferencesStore(defaults: UserDefaults(suiteName: suite)!), forceSample: true)
        if seed {
            Task {
                let now = Date()
                _ = try? await model.store.save(WatchProgress(key: .movie(tmdbID: 133701), position: 260, duration: 734,
                                                          updatedAt: now.addingTimeInterval(-3600)))
                _ = try? await model.store.save(WatchProgress(key: .episode(seriesID: 9_100_001, season: 1, episode: 3),
                                                          position: 1500, duration: 2880, updatedAt: now.addingTimeInterval(-600)))
                _ = try? await model.store.save(WatchProgress(key: .episode(seriesID: 9_100_001, season: 1, episode: 2),
                                                          position: 2880, duration: 2880, isCompleted: true,
                                                          updatedAt: now.addingTimeInterval(-7200)))
                let titles = SampleMetadataProvider.titles
                try? await model.store.store(titles)
                if let t = titles.first(where: { $0.key == .series(tmdbID: 9_100_002) }) {
                    try? await model.store.setWatchlisted(t, true)
                }
                model.libraryRevision += 1
            }
        }
        return model
    }

    // MARK: Catalog

    public func imageURL(_ artwork: Artwork?, width: CGFloat) -> URL? {
        artwork.flatMap { metadata.imageURL(for: $0, width: Int(width * 2)) }
    }

    public var hasTMDBCredential: Bool { catalogMode == .live }

    /// Validates a TMDB credential against the API, then stores it in the Keychain.
    public func saveTMDBCredential(_ raw: String) async throws {
        guard let credential = TMDBCredential(raw) else { throw MetadataError.missingCredentials }
        let service = TMDBService(credential: credential, http: http)
        _ = try await service.genres()
        let stored: String = switch credential { case .apiKey(let k): k; case .readAccessToken(let t): t }
        try secrets.write(stored, for: SecretAccount.tmdb)
        metadata = CachedMetadataProvider(service)
        catalogMode = .live
        applyContentFilter()
    }

    public func removeTMDBCredential() {
        try? secrets.write(nil, for: SecretAccount.tmdb)
        metadata = CachedMetadataProvider(CinemetaMetadataProvider(http: http))
        catalogMode = .cinemeta
        applyContentFilter()
    }

    /// Validates an OMDb key with a known title, then stores it in the Keychain.
    public func saveOMDbKey(_ raw: String) async throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MetadataError.missingCredentials }
        let service = OMDbService(apiKey: key, http: http)
        guard try await service.ratings(imdbID: "tt0133093") != nil else { throw MetadataError.unauthorized }
        try secrets.write(key, for: SecretAccount.omdb)
        ratingsProvider = service
        hasOMDbKey = true
    }

    public func removeOMDbKey() {
        try? secrets.write(nil, for: SecretAccount.omdb)
        ratingsProvider = nil
        hasOMDbKey = false
    }

    /// External ratings for a title, or nil (no key, no IMDb ID, or lookup failed).
    public func externalRatings(for detail: TitleDetail) async -> ExternalRatings? {
        guard let provider = ratingsProvider, let id = detail.imdbID else { return nil }
        return try? await provider.ratings(imdbID: id)
    }

    // MARK: Profiles

    /// Switches whose My List, progress and Continue Watching are shown.
    public func switchProfile(to id: String, sync: Bool = true) async {
        guard id != currentProfileID, let profile = profileStore.profile(id), !profile.isRemoved else { return }
        do {
            let s = try libraryStore(for: id)
            if activePlayer != nil { await closePlayer() }
            store = s
            currentProfileID = id
            settingsUnlocked = false
            prefs.set(id, for: PreferenceKey.currentProfile)
            account.switchLibrary(to: s, profileID: id)
            loadProfileSettings(id)
            applyContentFilter()
            libraryRevision += 1
            if sync { Task { await account.syncNow() } }
        } catch {
            alert = AppAlert(title: "Couldn't open that profile", message: UserFacingError.message(for: error))
        }
    }

    @discardableResult
    public func addProfile(name: String, symbol: String, color: Int, maturity: MaturityRating = .all, isKids: Bool = false,
                           allowsUnrated: Bool? = nil) -> Profile {
        let p = Profile(id: UUID().uuidString.lowercased(), name: String(name.trimmingCharacters(in: .whitespaces).prefix(40)),
                        symbol: symbol, color: color, updatedAt: .now, maturity: maturity, isKids: isKids, allowsUnrated: allowsUnrated)
        profileStore.save(p)
        reloadProfiles()
        account.scheduleSync()
        return p
    }

    public func updateProfile(_ p: Profile) {
        var p = p
        p.name = String(p.name.trimmingCharacters(in: .whitespaces).prefix(40))
        guard !p.name.isEmpty else { return }
        let old = profileStore.profile(p.id)
        let filterChanged = old?.contentFilter != p.contentFilter
        // Restricting the profile that's watching from inside Settings: whoever
        // did it is already in, so Settings stays open until the next lock.
        if p.id == currentProfileID, old?.isRestricted == false, p.isRestricted { settingsUnlocked = true }
        profileStore.save(p)
        reloadProfiles()
        if filterChanged, p.id == currentProfileID {
            applyContentFilter()
            libraryRevision += 1  // Home and Search load again under the new limit
        }
        account.scheduleSync()
    }

    /// Removes a profile everywhere. Its local library is deleted from this device.
    public func deleteProfile(_ id: String) async {
        guard id != Profile.defaultID else { return }
        if currentProfileID == id { await switchProfile(to: Profile.defaultID) }
        profileStore.remove(id)
        try? locks.setPIN(nil, for: id)
        lockedProfileIDs.remove(id)
        openStores[id] = nil
        hiddenTitles.removeAll(profileID: id)
        personalHome.remove(profileID: id)
        if let libraryDirectory {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: libraryDirectory.appending(path: "\(Self.libraryFileName(id))\(suffix)"))
            }
        }
        reloadProfiles()
        account.scheduleSync()
    }

    /// The user chose the newly signed-in account's library over this
    /// device's (which came from another account and stays in it): every
    /// profile's library, lists, hidden titles and Home tweaks go, and the
    /// profiles go back to the default one alone, so the account's come down.
    /// Nothing here is marked for upload. Downloads, sources and settings stay.
    func eraseLibraryForAccountChange() async {
        await switchProfile(to: Profile.defaultID, sync: false)
        for id in profileStore.allIDs() {
            hiddenTitles.removeAll(profileID: id)
            personalHome.remove(profileID: id)
            guard id != Profile.defaultID else { continue }
            try? locks.setPIN(nil, for: id)
            openStores[id] = nil
            if let libraryDirectory {
                for suffix in ["", "-shm", "-wal"] {
                    try? FileManager.default.removeItem(at: libraryDirectory.appending(path: "\(Self.libraryFileName(id))\(suffix)"))
                }
            }
        }
        lockedProfileIDs = []
        profileStore.resetToDefault()
        try? await store.eraseLibrary()
        reloadProfiles()
        libraryRevision += 1
    }

    private func reloadProfiles() {
        profiles = profileStore.active()
        lockedProfileIDs = Set(profiles.map(\.id).filter { locks.hasPIN($0) })
        if !profiles.contains(where: { $0.id == currentProfileID }) {
            Task { await switchProfile(to: Profile.defaultID) }
        }
    }

    // MARK: Profile settings, locks and limits

    /// Languages, Autoplay and the subtitle style follow the profile.
    private func loadProfileSettings(_ id: String) {
        settings.loadProfile(id)
        featureSwitches.loadProfile(id)
        insights.profileChanged()
        let style = prefs.value(SubtitleStyle.self, for: ProfileSettingKey.subtitleStyle(id)) ?? SubtitleStyle()
        if style != subtitleStyle { subtitleStyle = style }
        let eq = prefs.value(EqualizerSettings.self, for: ProfileSettingKey.equalizer(id)) ?? EqualizerSettings()
        if eq != equalizer { equalizer = eq }
    }

    /// Hands the current profile's maturity limit to the catalogue.
    func applyContentFilter() {
        (metadata as? CachedMetadataProvider)?.contentFilter = currentProfile.contentFilter
        (metadata as? CachedMetadataProvider)?.keyBridge = catalogMode == .sample ? nil : keyBridge
    }

    /// Titles saved under the other catalog (TMDB or Cinemeta) still open (`CatalogKeyBridge`).
    var keyBridge: CatalogKeyBridge {
        if let made = madeKeyBridge { return made }
        let bridge = CatalogKeyBridge(http: http)
        let store = store
        bridge.savedTitle = { key in try? await store.title(for: key) }
        madeKeyBridge = bridge
        return bridge
    }

    /// Whether the current profile may open a title with this certification.
    public func allowsCertification(_ certification: String?) -> Bool {
        currentProfile.contentFilter?.allows(certification: certification) ?? true
    }

    public func isLocked(_ profileID: String) -> Bool { lockedProfileIDs.contains(profileID) }

    /// Why the current profile can't play `key`: its known certification is
    /// above the profile's limit, or it has none and the profile doesn't allow
    /// unrated titles. nil when it may. Says nothing about how to change it.
    func maturityBlock(for key: MediaKey) -> String? {
        guard let filter = currentProfile.contentFilter else { return nil }
        let cert = (metadata as? CachedMetadataProvider)?.certification(for: key.seriesKey ?? key)
        guard !filter.allows(certification: cert) else { return nil }
        let name = currentProfile.name
        if let cert, MaturityRating.minimumAge(forCertification: cert) != nil {
            return "It\u{2019}s rated \(cert), which is above what \(name)\u{2019}s profile allows."
        }
        return "It doesn\u{2019}t have a rating, so it isn\u{2019}t on \(name)\u{2019}s profile."
    }

    /// Before Play on a profile that refuses unrated titles: learn the
    /// title's certification from its page, so a rated title picked from a
    /// row isn't mistaken for an unrated one.
    func learnCertificationIfNeeded(for key: MediaKey) async {
        guard currentProfile.contentFilter?.blocksUnrated == true, let cache = metadata as? CachedMetadataProvider else { return }
        let titleKey = key.seriesKey ?? key
        guard cache.certification(for: titleKey) == nil else { return }
        _ = try? await cache.detail(for: titleKey)
    }

    // MARK: Settings lock

    /// The profiles whose PIN opens Settings (and the watching profile's own
    /// editor) while a restricted profile is watching: its own PIN when it has
    /// one; on a Kids profile without one, any grown-up profile's. Empty:
    /// Settings opens without asking.
    public var settingsPINProfiles: [Profile] {
        let me = currentProfile
        guard me.isRestricted else { return [] }
        if isLocked(me.id) { return [me] }
        guard me.isKids else { return [] }
        return profiles.filter { !$0.isRemoved && !$0.isKids && isLocked($0.id) }
    }

    /// Settings has been unlocked for the watching profile. Cleared when the
    /// profile changes or the app goes to the background.
    public private(set) var settingsUnlocked = false

    /// Settings shows the PIN pad instead of its pages.
    public var settingsNeedsPIN: Bool { !settingsUnlocked && !settingsPINProfiles.isEmpty }

    /// Unlocks Settings with one of `settingsPINProfiles`' PINs.
    public func unlockSettings(pin: String) -> Bool {
        guard settingsPINProfiles.contains(where: { locks.verify(pin, for: $0.id) }) else { return false }
        settingsUnlocked = true
        return true
    }

    /// Forgot PIN: the device owner (Touch ID, Face ID or the device password) opens Settings.
    func unlockSettingsAsDeviceOwner() { settingsUnlocked = true }

    /// The app went to the background.
    public func lockSettings() { settingsUnlocked = false }

    /// Checks a PIN (true when the profile has none).
    public func verifyPIN(_ pin: String, for profileID: String) -> Bool { locks.verify(pin, for: profileID) }

    /// Sets, or with nil removes, a profile's 4-digit PIN.
    public func setPIN(_ pin: String?, for profileID: String) throws {
        try locks.setPIN(pin, for: profileID)
        if pin != nil, profileID == currentProfileID { settingsUnlocked = true }  // just chose it, inside Settings
        if pin == nil { lockedProfileIDs.remove(profileID) } else { lockedProfileIDs.insert(profileID) }
    }

    /// Asks RootView to switch, with the PIN first if the profile is locked.
    /// Used by ⌃⌘1–4, the Profiles menu and the profile menu's avatars.
    public func requestProfileSwitch(to id: String) {
        guard id != currentProfileID, profiles.contains(where: { $0.id == id }) else { return }
        profileSwitchRequest = ProfileSwitchRequest(profileID: id)
    }

    /// ⌃⌘1–4.
    public func requestProfileSwitch(digit: Int) {
        guard let p = ProfileShortcuts.profile(forDigit: digit, in: profiles) else { return }
        requestProfileSwitch(to: p.id)
    }

    /// Row titles that say whose library a row comes from (`HomeRowTitles`).
    public var continueWatchingTitle: String { HomeRowTitles.continueWatching(currentProfile, profiles: profiles.count) }
    public var myListTitle: String { HomeRowTitles.myList(currentProfile, profiles: profiles.count) }
    /// Shared things (Downloads) say so once there's more than one profile.
    public var showsSharedTags: Bool { profiles.count > 1 }

    private func libraryStore(for id: String) throws -> LibraryStore {
        if let s = openStores[id] { return s }
        let s = try libraryDirectory.map { try LibraryStore.make(url: $0.appending(path: Self.libraryFileName(id))) }
            ?? LibraryStore.make(inMemory: true)
        openStores[id] = s
        return s
    }

    /// A profile's store file. Opening and deleting must agree on it.
    static func libraryFileName(_ profileID: String) -> String {
        "Library-\(profileID.filter { $0.isLetter || $0.isNumber || $0 == "-" }).store"
    }

    // MARK: Subtitle search

    /// Checks an OpenSubtitles key with a search, then stores it in the Keychain.
    public func saveOpenSubtitlesKey(_ raw: String) async throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SubtitleSearchError.missingKey }
        let service = OpenSubtitlesService(apiKey: key, http: http)
        _ = try await service.search(.movie(tmdbID: 603), languages: ["en"])
        try secrets.write(key, for: SecretAccount.openSubtitles)
        subtitleSearch = service
        hasOpenSubtitlesKey = true
        openSubtitlesSignedIn = false
    }

    public func removeOpenSubtitlesKey() {
        try? secrets.write(nil, for: SecretAccount.openSubtitles)
        try? secrets.write(nil, for: SecretAccount.openSubtitlesSession)
        subtitleSearch = nil
        hasOpenSubtitlesKey = false
        openSubtitlesSignedIn = false
    }

    /// Optional account sign-in for a higher download quota. Only the session token is stored.
    public func signInToOpenSubtitles(username: String, password: String) async throws {
        guard let subtitleSearch else { throw SubtitleSearchError.missingKey }
        let session = try await subtitleSearch.signIn(username: username, password: password)
        try secrets.write(String(decoding: try JSONEncoder().encode(session), as: UTF8.self), for: SecretAccount.openSubtitlesSession)
        openSubtitlesSignedIn = true
    }

    public func signOutOfOpenSubtitles() async {
        await subtitleSearch?.signOut()
        try? secrets.write(nil, for: SecretAccount.openSubtitlesSession)
        openSubtitlesSignedIn = false
    }

    /// Languages to search: the preferred subtitle language, then the device's languages.
    var subtitleSearchLanguages: [String] {
        var langs: [String] = []
        if let p = subtitleStyle.preferredLanguage { langs.append(p) }
        for l in Locale.preferredLanguages.prefix(3) {
            if let code = Locale(identifier: l).language.languageCode?.identifier, !langs.contains(code) { langs.append(code) }
        }
        return langs
    }

    public func searchSubtitles(for key: MediaKey) async throws -> [SubtitleSearchResult] {
        guard let subtitleSearch else { throw SubtitleSearchError.missingKey }
        return try await subtitleSearch.search(key, languages: subtitleSearchLanguages)
    }

    /// Downloads a found subtitle to the caches folder and returns its file URL.
    public func downloadSubtitle(_ result: SubtitleSearchResult) async throws -> URL {
        guard let subtitleSearch else { throw SubtitleSearchError.missingKey }
        let data = try await subtitleSearch.download(result)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Subtitles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = result.release.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined().prefix(80)
        // The result's id too: several files often share a release name and language (SDH and plain).
        let url = dir.appending(path: "\(safe)-\(result.id).\(result.language ?? "und").srt")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Library

    public func toggleWatchlist(_ title: Title) async {
        do {
            let on = try await store.isOnWatchlist(title.key)
            try await store.setWatchlisted(title, !on)
            libraryRevision += 1
            account.scheduleSync()
            trakt.scheduleSync()
        } catch {
            alert = AppAlert(title: "Couldn't update My List", message: UserFacingError.message(for: error))
        }
    }

    /// Looks up a title for a key, preferring the local cache (works offline).
    public func title(for key: MediaKey) async -> Title? {
        if let cached = try? await store.title(for: key) { return cached }
        guard let detail = try? await metadata.detail(for: key) else { return nil }
        try? await store.store([detail.title])
        return detail.title
    }

    func noteLibraryChanged() {
        libraryRevision += 1
        account.scheduleSync()
        trakt.scheduleSync()
    }

    /// Takes an item out of Continue Watching on every device by resetting its
    /// progress (a newer record that syncs), rather than deleting it locally.
    /// Shows a toast with Undo, which puts the position back (again as a newer record).
    public func removeFromContinueWatching(_ progress: WatchProgress) async {
        let reset = WatchProgress(key: progress.key, position: 0, duration: progress.duration,
                                  updatedAt: .now, deviceID: prefs.deviceID)
        _ = try? await store.save(reset)
        noteLibraryChanged()
        showToast(AppToast("Removed from Continue Watching", actionTitle: "Undo") { [weak self] in
            guard let self else { return }
            var restored = progress
            restored.updatedAt = .now
            restored.deviceID = self.prefs.deviceID
            Task {
                _ = try? await self.store.save(restored)
                self.noteLibraryChanged()
            }
        })
    }

    // MARK: Sources

    public func availability(for key: MediaKey) async -> Availability {
        let found = await registry.availability(for: key)
        noteQuality(found, for: key)
        return found
    }

    public func setSourceEnabled(_ id: SourceID, _ enabled: Bool) async {
        await registry.setEnabled(enabled, for: id)
        if let i = sourceConfigurations.firstIndex(where: { $0.id == id }) {
            sourceConfigurations[i].isEnabled = enabled
        } else if id == directLinks.id || id == SourceID("public-catalog") {
            let kind: SourceKind = id == directLinks.id ? .directURL : .publicCatalog
            sourceConfigurations.append(SourceConfiguration(id: id, kind: kind, name: id.rawValue, isEnabled: enabled))
        }
        persistSources()
    }

    /// Adds a folder the user picked (Settings › Sources, dropped on the window,
    /// opened with Bluebox). Throws, with a message for the user, when it can't
    /// be read or is already a source. Returns how many videos it has.
    @discardableResult
    public func addLocalFolder(_ url: URL) async throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        // Read it now, while the picker's permission is certain: a folder that
        // can't be read fails here with a reason instead of showing up empty.
        let count = try LocalFolderSource.videoFiles(in: url, name: name).count
        let path = url.standardizedFileURL.path
        if let existing = sourceConfigurations.first(where: { $0.kind == .localFolder && $0.settings["path"] == path }) {
            throw LocalFolderAddError.alreadyAdded(existing.name)
        }
        let bookmark: Data
        do { bookmark = try LocalFolderSource.makeBookmark(for: url) } catch {
            throw LocalFolderAddError.noBookmark(name)
        }
        let config = SourceConfiguration(id: SourceID("local-\(UUID().uuidString.prefix(8))"), kind: .localFolder, name: name,
                                         settings: ["bookmark": bookmark.base64EncodedString(), "path": path])
        let source = try LocalFolderSource.fromConfiguration(config, matcher: makeMatcher(), overrides: matchOverrides)
        // The bookmark has to give the folder back, or it would be unreadable after a relaunch.
        guard await source.testConnection().ok else { throw LocalFolderAddError.noBookmark(name) }
        sourceConfigurations.append(config)
        persistSources()
        await registry.register(source)
        sourcesRevision += 1
        libraryRevision += 1
        return count
    }

    /// Saves a renewed bookmark for a folder whose old one was stale.
    private func renewBookmark(_ data: Data, for id: SourceID) {
        guard let i = sourceConfigurations.firstIndex(where: { $0.id == id }) else { return }
        sourceConfigurations[i].settings["bookmark"] = data.base64EncodedString()
        persistSources()
    }

    /// Signs in to a Jellyfin or Emby server and adds it as a source. Only the
    /// access token is kept (in the Keychain); the password is not stored. The
    /// server's own answer decides which it is; `flavour` is what the user picked.
    public func addMediaServer(_ flavour: JellyfinSource.Flavour, server: String, username: String, password: String) async throws {
        let (creds, serverName) = try await JellyfinSource.signIn(server: server, username: username, password: password,
                                                                  http: http, deviceID: prefs.deviceID, expecting: flavour)
        let id = SourceID("\(creds.flavour.rawValue)-\(UUID().uuidString.prefix(8))")
        try secrets.write(creds.accessToken, for: SecretAccount.source(id.rawValue))
        let config = SourceConfiguration(id: id, kind: creds.flavour == .emby ? .emby : .jellyfin, name: serverName, settings: [
            "server": creds.server.absoluteString, "userID": creds.userID, "username": creds.username,
        ])
        sourceConfigurations.append(config)
        persistSources()
        if let source = jellyfinSource(config) { await register(source) }
        sourcesRevision += 1
        libraryRevision += 1
    }

    /// Adds a signed-in network source (WebDAV, Plex: `AppModel+NetworkSources`).
    func addNetworkSource(_ config: SourceConfiguration, _ source: (any MediaSource)?) async {
        sourceConfigurations.append(config)
        persistSources()
        if let source { await registry.register(source) }
        sourcesRevision += 1
        libraryRevision += 1
    }

    private func jellyfinSource(_ config: SourceConfiguration) -> JellyfinSource? {
        guard let server = config.settings["server"].flatMap(URL.init(string:)), let userID = config.settings["userID"],
              let token = (try? secrets.read(SecretAccount.source(config.id.rawValue))).flatMap({ $0 }) else { return nil }
        let creds = JellyfinSource.Credentials(server: server, userID: userID, accessToken: token,
                                               username: config.settings["username"] ?? "",
                                               flavour: config.kind == .emby ? .emby : .jellyfin)
        return JellyfinSource(id: config.id, name: config.name, credentials: creds, http: http,
                              deviceID: prefs.deviceID, matcher: makeMatcher())
    }

    /// Registers a server and takes in its watched state each time its library loads.
    func register(_ source: JellyfinSource) async {
        await source.setProgressHandler { [weak self] records in await self?.applyServerProgress(records) }
        await registry.register(source)
    }

    public func removeSource(_ id: SourceID) async {
        sourceConfigurations.removeAll { $0.id == id }
        persistSources()
        await registry.unregister(id)
        try? secrets.write(nil, for: SecretAccount.source(id.rawValue))
        sourcesRevision += 1
    }

    public func addDirectLink(url: URL, title: String, matching key: MediaKey?) async throws {
        try await directLinks.add(.init(url: url, title: title, mediaKey: key))
        prefs.set(await directLinks.allItems(), for: PreferenceKey.directURLs)
        sourcesRevision += 1
    }

    public func removeDirectLink(_ url: URL) async {
        await directLinks.remove(url)
        prefs.set(await directLinks.allItems(), for: PreferenceKey.directURLs)
        sourcesRevision += 1
    }

    public func directLinkItems() async -> [DirectURLSource.Item] { await directLinks.allItems() }

    // MARK: Downloads (see the "Downloads" extension at the end of this file)

    /// For the iOS app delegate: returns false if the session isn't Bluebox's downloads.
    public nonisolated static func handleBackgroundDownloadEvents(identifier: String, completion: @escaping @Sendable () -> Void) -> Bool {
        guard DownloadManager.backgroundIdentifiers.contains(identifier) else { return false }
        DownloadManager.setBackgroundCompletion(completion, for: identifier)
        return true
    }

    public func deleteDownload(_ r: DownloadRecord) { deleteDownloads([r]) }

    public func deleteDownloads(_ records: [DownloadRecord]) {
        downloads.delete(records.map(\.id))
        libraryRevision += 1  // "My Sources" lists downloads
    }

    // MARK: Torrents

    /// Adds a magnet link the user pasted. Waits for the file list, then
    /// matches video files to the catalog.
    public func addTorrent(magnet: String) async throws -> TorrentSource.Item {
        try await addTorrent(try TorrentDescriptor(magnet: magnet))
    }

    /// Adds a .torrent file the user picked.
    public func addTorrent(file url: URL) async throws -> TorrentSource.Item {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count < 20 * 1024 * 1024 else { throw TorrentError.invalidTorrent("file too large") }
        return try await addTorrent(try TorrentDescriptor(torrentFile: data))
    }

    private func addTorrent(_ d: TorrentDescriptor) async throws -> TorrentSource.Item {
        let item = try await torrents.add(d, matcher: makeMatcher())
        prefs.set(await torrents.allItems(), for: PreferenceKey.torrents)
        sourcesRevision += 1
        libraryRevision += 1
        return item
    }

    public func removeTorrent(_ hash: InfoHash) async {
        await torrents.remove(hash)
        prefs.set(await torrents.allItems(), for: PreferenceKey.torrents)
        sourcesRevision += 1
        libraryRevision += 1
    }

    public func torrentItems() async -> [TorrentSource.Item] { await torrents.allItems() }

    public func torrentStatus(_ hash: InfoHash) async -> TorrentStatus? { await torrents.client.status(hash) }

    public func rescanSources() async {
        for case let local as LocalFolderSource in await registry.all() {
            _ = try? await local.rescan()
        }
        sourcesRevision += 1
    }

    private func persistSources() {
        prefs.set(sourceConfigurations, for: PreferenceKey.sourceConfigurations)
    }

    /// Matches a parsed filename to the catalog using search + normalized title + year.
    func makeMatcher() -> MediaMatcher {
        { [weak self] parsed in
            guard let provider = await self?.metadata else { return nil }
            guard let results = try? await provider.search(parsed.title, page: 1).items else { return nil }
            let want = MediaNameParser.normalized(parsed.title)
            switch parsed.kind {
            case .movie:
                let movies = results.filter { $0.kind == .movie && MediaNameParser.normalized($0.name) == want }
                let best = movies.first { parsed.year == nil || $0.year == parsed.year } ?? movies.first
                return best?.key
            case .episode(let s, let e):
                let shows = results.filter { $0.kind == .series && MediaNameParser.normalized($0.name) == want }
                // "The.Office.2005.S01E01": the year picks the right one of same-named shows.
                guard let show = shows.first(where: { parsed.year == nil || $0.year == parsed.year }) ?? shows.first
                else { return nil }
                return show.key.episode(season: s, episode: e)  // TMDB or Cinemeta (IMDb) keys
            }
        }
    }

    // MARK: Playback

    /// Resolves a playable variant for `key` and presents the player.
    /// - Parameter startAt: start at this second whatever the saved progress and
    ///   Settings › Playback › Start Playing say (Handoff).
    /// - Parameter external: hand the stream to this app instead (Open In…).
    ///   Settings › Playback › Open Videos In does the same for every video
    ///   the chosen app can reach; the rest play here.
    /// - Parameter autoplay: false opens it paused (a Watch Party's lobby, or joining one).
    public func play(_ item: NowPlayingItem, variant preferred: MediaVariant? = nil, resume: Bool = true,
                     startAt: TimeInterval? = nil, in external: ExternalPlayer? = nil, autoplay: Bool = true) async {
        // "Play on" another device (the remote): it plays there. A file chosen here, and a
        // party's title (opened paused), stay here.
        if preferred == nil, startAt == nil, external == nil, autoplay,
           remote.playOnTarget(RemotePlay(key: item.key, title: item.title, subtitle: item.subtitle, resume: resume)) { return }
        // A maturity limit: titles rated above it, or unrated ones on Kids, don't play on this profile.
        await learnCertificationIfNeeded(for: item.key)
        if let reason = maturityBlock(for: item.key) {
            alert = AppAlert(title: "Not available on this profile", message: reason)
            return
        }
        let variant: MediaVariant
        if let preferred {
            variant = downloadedCopy(of: preferred) ?? preferred
        } else if let saved = downloadedVariant(for: item.key) {
            variant = saved  // offline copies play at once, without asking other sources
        } else {
            let availability = await registry.availability(for: item.key)
            guard let first = chooseVariant(availability.variants, for: item.key) else {
                if settings.isOffline {
                    alert = AppAlert(title: "You're offline",
                                     message: "“\(item.title)” isn't downloaded. Connect to the internet to stream it.")
                } else {
                    alert = AppAlert(title: "Not available to play",
                                     message: "None of your sources has “\(item.title)”. Add a folder, a direct link, or a media server in Settings.")
                }
                return
            }
            variant = first
        }
        if let reason = settings.streamingBlockedReason(for: variant) { alert = AppAlert(title: "Not on Wi‑Fi", message: reason); return }
        // Settings › Mobile Data: torrent rules and "You're on mobile data" (MobileData.swift).
        guard await mobileDataAllowsPlaying(item, variant: variant) else { return }
        // Add-on releases need the internet; say so now rather than after the searches time out.
        if variant.sourceID == addons.id, settings.isOffline {
            alert = AppAlert(title: "You're offline", message: "Connect to the internet to stream “\(item.title)”. Downloaded titles still play.")
            return
        }
        playRequest &+= 1
        let request = playRequest
        // One video at a time: what's playing ends (and saves its place) before the next opens.
        if activePlayer != nil { await closePlayer() }
        await endExternalHandoff()
        guard request == playRequest else { return }
        resolvedNext = nil
        pickedNext = nil
        await holdTorrentDownloads(before: variant, key: item.key)
        preparingItem = item
        defer { if preparingItem == item { preparingItem = nil } }
        do {
            let resource = try await resolveCancellably(variant)
            // Cancelled, or another Play came after this one: it opens nothing.
            guard request == playRequest else { return }
            await holdTorrentDownloads(streaming: resource.variant)
            rememberSource(variant, for: item.key)
            noteStreaming(resource.variant)  // the mobile data counter
            // A party's title (opened paused) stays here, where the party can keep it in step.
            if let player = external ?? (autoplay ? settings.openVideosIn : nil), ExternalPlayer.canOpen(resource) {
                if await openExternally(resource, variant: variant, in: player) {
                    // The app plays it from here; a torrent or a download keeps being served (`AppModel+ExternalPlayer`).
                    addonStatus = nil
                    return
                }
                if external != nil {
                    addonStatus = nil
                    releaseTorrentDownloadHolds()
                    if variant.sourceID == addons.id { await addons.stopStreaming() }
                    alert = AppAlert(title: "Couldn't open \(player.name)",
                                     message: player.isInstalled ? "\(player.name) didn't open “\(item.title)”."
                                         : "\(player.name) isn't installed on this device. Get it from the App Store, or play “\(item.title)” in Bluebox.")
                    return
                }
                // Open Videos In, but that app isn't here: it plays in Bluebox.
            }
            activeVariant = variant
            let session = makeSession(for: resource)
            // From the preparing overlay (black, like the player), the player
            // takes its place at once rather than sliding up as a second step.
            PlayerPresentation.change(instantly: variant.sourceID == addons.id) {
                activePlayer = session
                addonStatus = nil
            }
            nowPlaying.attach(session)
            await session.start(item, resource: resource, resume: resume && settings.resumeBehavior == .always, startAt: startAt,
                                autoplay: autoplay)
        } catch is CancellationError {
            addonStatus = nil
            releaseTorrentDownloadHolds()
        } catch let error as DebridLinkError {
            addonStatus = nil
            releaseTorrentDownloadHolds()
            Log.playback.error("Debrid link is a notice clip: \(error.problem.rawValue, privacy: .public)")
            alert = debridAlert(error, title: "Couldn't play “\(item.title)”", item: item)
        } catch {
            addonStatus = nil
            releaseTorrentDownloadHolds()
            report(error, title: "Couldn't play “\(item.title)”",
                   context: variant.sourceID == addons.id ? .addons : .playback) { [weak self] in
                await self?.play(item, variant: preferred, resume: resume, startAt: startAt, autoplay: autoplay)
            }
        }
    }


    /// Plays a video file from outside the library (dropped on the window or
    /// opened with Bluebox). It's matched to the catalog by its name, so
    /// progress lands on the right title when there is one.
    public func playFile(at url: URL) async {
        // A dropped or opened file comes with access for this session; keep it while it plays.
        _ = url.startAccessingSecurityScopedResource()
        let parsed = MediaNameParser.parse(filename: url.lastPathComponent)
        let matched = await makeMatcher()(parsed)
        let key = matched ?? MediaKey(rawValue: "url:" + url.absoluteString)
        var name: String?
        if let matched { name = await title(for: matched.seriesKey ?? matched)?.name }
        let variant = MediaVariant(id: url.absoluteString, sourceID: SourceID("opened-files"), mediaKey: matched,
                                   displayName: url.lastPathComponent, container: url.pathExtension.lowercased(),
                                   location: .downloaded)
        guard PlaybackEngines.canAttempt(container: variant.container) else {
            alert = AppAlert(title: "Can't play this file", message: "Bluebox can't play “\(url.lastPathComponent)” on this device.")
            return
        }
        if activePlayer != nil { await closePlayer() }
        let resource = PlaybackResource(variant: variant, url: url)
        let item = NowPlayingItem(key: key, title: name ?? url.deletingPathExtension().lastPathComponent,
                                  subtitle: key.episodeNumbers.map { "S\($0.season)·E\($0.episode)" })
        activeVariant = variant
        let session = makeSession(for: resource)
        PlayerPresentation.change(instantly: false) { activePlayer = session }
        nowPlaying.attach(session)
        await session.start(item, resource: resource, resume: settings.resumeBehavior == .always, startAt: nil)
    }

    /// Resolves through the registry in a task Cancel can stop. Add-on releases
    /// can take a while (finding peers, buffering), so the overlay offers Cancel.
    private func resolveCancellably(_ variant: MediaVariant) async throws -> PlaybackResource {
        let task = Task { try await registry.resolve(variant) }
        preparing = task
        // `addonStatus` (the overlay) stays until `play` has put the player in
        // its place, so the library doesn't flash between the two.
        defer { preparing = nil }
        let resource = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        // A source that finished anyway after Cancel: the player still doesn't open.
        if task.isCancelled { throw CancellationError() }
        return resource
    }

    /// Prefers the source that last played this item (or its series).
    func chooseVariant(_ variants: [MediaVariant], for key: MediaKey) -> MediaVariant? {
        let memory = prefs.value([String: LastPlayedSource].self, for: PreferenceKey.lastPlayedSources) ?? [:]
        return VariantChooser.choose(from: variants, item: memory[key.rawValue],
                                     series: key.seriesKey.flatMap { memory[$0.rawValue] },
                                     canAttempt: { PlaybackEngines.canAttempt(container: $0.container) })
    }

    func rememberSource(_ variant: MediaVariant, for key: MediaKey) {
        var memory = prefs.value([String: LastPlayedSource].self, for: PreferenceKey.lastPlayedSources) ?? [:]
        let entry = LastPlayedSource(sourceID: variant.sourceID, variantID: variant.id, playedAt: .now)
        memory[key.rawValue] = entry
        if let series = key.seriesKey { memory[series.rawValue] = entry }
        if memory.count > 500 {
            // Keep the most recent entries; this is a convenience, not history.
            memory = Dictionary(uniqueKeysWithValues: memory.sorted { $0.value.playedAt > $1.value.playedAt }.prefix(400).map { ($0.key, $0.value) })
        }
        prefs.set(memory, for: PreferenceKey.lastPlayedSources)
    }

    public func closePlayer() async {
        guard let session = activePlayer else { return }
        // Closing the player leaves the party, unless the party itself is changing what plays.
        if party != nil, !partyIsSwitching { await leaveParty() }
        // Quiet straight away, and a video still opening stands down: the steps
        // below can take a moment, and the player is already leaving.
        session.beginClosing()
        await reportServerPlayback(session, stopped: true)
        if let v = activeVariant, let plex = await registry.source(v.sourceID) as? PlexSource {
            let position = session.snapshot.position, duration = session.snapshot.duration
            Task { await plex.reportProgress(ratingKey: v.id, position: position, duration: duration, isPaused: true, stopped: true) }
        }
        let wasStreaming = activeVariant?.sourceID == addons.id || resolvedNext?.resource.variant.sourceID == addons.id
        let watched = session.item?.key
        activeVariant = nil
        resolvedNext = nil
        pickedNext = nil
        // Save the final position before the torrent stream goes away underneath the player.
        await session.end()
        if wasStreaming { await addons.stopStreaming() }
        releaseTorrentDownloadHolds()
        if let watched { Task { await downloadsAfterWatching(watched) } }
        nowPlaying.detach()
        activePlayer = nil
        listQueue = nil
        // Every live screen reloads on this. Wait for the player to finish
        // animating away, so the reloads don't land mid-dismissal.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.libraryRevision += 1
        }
        account.scheduleSync(after: .zero)
        trakt.scheduleSync()
    }

    public func updateNowPlaying() { nowPlaying.update() }

    /// AVPlayer when it can attempt the resolved container (PiP, AirPlay), VLC otherwise.
    private func makeSession(for resource: PlaybackResource) -> PlayerSession {
        let streams = torrents.client
        let session = PlayerSession(
            engine: settings.makeEngine(for: resource, streams: streams), progress: store, deviceID: prefs.deviceID,
            nextProvider: { [weak self] key in
                if let next = await self?.nextEpisode(after: key) { return next }
                return await self?.nextInListQueue(after: key)
            }, upNextCountdown: settings.upNextCountdown
        )
        session.autoplayNext = settings.autoplayNextEpisode
        session.onProgressSaved = { [weak self, weak session] playing in
            self?.account.progressSaved(playing: playing)
            guard let self, let session else { return }
            Task { await self.reportServerPlayback(session, stopped: false) }
        }
        session.onNearEnd = { [weak self] key in self?.prepareNextEpisode(after: key) }
        session.subtitleStyle = subtitleStyle
        session.setAudioEffects(AudioEffects(dialogueBoost: settings.dialogueBoost, nightMode: settings.nightMode, equalizer: equalizer))
        // Defaults for every item the session starts, Up Next and Next Episode included.
        session.onItemStarted = { [weak self, weak session] _ in
            guard let self, let session else { return }
            // The first item takes Settings' speed; later ones (next episode) keep the one in use.
            session.setRate(session.chosenRate ?? self.defaultSpeed); self.applyPlaybackDefaults(to: session)
        }
        let settings = settings
        session.engineSwitcher = { resource, current in settings.replacementEngine(for: resource, current: current, streams: streams) }
        return session
    }

    /// The episode after `key`, resolved and ready to play, if any source has it.
    func nextEpisode(after key: MediaKey) async -> (NowPlayingItem, PlaybackResource)? {
        if let hit = resolvedNext, hit.after == key, Date().timeIntervalSince(hit.at) < 600 {
            return (hit.item, hit.resource)
        }
        guard let picked = await pickNextEpisode(after: key),
              let resolved = await startEpisode(picked) else { return nil }
        resolvedNext = (key, resolved.0, resolved.1, Date())
        return resolved
    }

    /// About 85% through an episode (`PlayerSession.onNearEnd`): picks the next
    /// one's release in the background, so Up Next and Next Episode only have
    /// to start it. Nothing is resolved yet, so what's playing is untouched.
    func prepareNextEpisode(after key: MediaKey) {
        guard key.seriesKey != nil, key.episodeNumbers != nil else { return }
        Task { _ = await pickNextEpisode(after: key) }
    }

    /// The episode after `key` with its release chosen, from `pickedNext` while it's fresh.
    private func pickNextEpisode(after key: MediaKey) async -> PickedEpisode? {
        if let hit = pickedNext, hit.after == key, hit.isFresh { return hit }
        guard let seriesKey = key.seriesKey, let (s, e) = key.episodeNumbers,
              let detail = try? await metadata.detail(for: seriesKey),
              let (ns, ne) = SeriesCursor.next(after: s, e, seasons: detail.seasons),
              let nextKey = seriesKey.episode(season: ns, episode: ne),
              var picked = await pickEpisode(nextKey, detail: detail) else { return nil }
        picked.after = key
        pickedNext = picked
        return picked
    }

    /// An episode resolved and ready to play in the open player (Next Episode,
    /// Previous Episode, the player's Episodes list).
    func resolveEpisode(_ nextKey: MediaKey, detail known: TitleDetail? = nil) async -> (NowPlayingItem, PlaybackResource)? {
        if let hit = resolvedNext, hit.item.key == nextKey, Date().timeIntervalSince(hit.at) < 600 {
            return (hit.item, hit.resource)
        }
        let early: PickedEpisode? = if let hit = pickedNext, hit.item.key == nextKey, hit.isFresh { hit } else { nil }
        let fetched: PickedEpisode? = if let early { early } else { await pickEpisode(nextKey, detail: known) }
        guard let picked = fetched else { return nil }
        return await startEpisode(picked)
    }

    /// The pick half: which release `nextKey` plays, and its title and still.
    /// Asks the sources (add-on searches, debrid cache checks), which is most
    /// of the wait, but starts nothing.
    private func pickEpisode(_ nextKey: MediaKey, detail known: TitleDetail?) async -> PickedEpisode? {
        guard let seriesKey = nextKey.seriesKey, let (ns, ne) = nextKey.episodeNumbers else { return nil }
        let fetched: TitleDetail? = if let known { known } else { try? await metadata.detail(for: seriesKey) }
        guard let detail = fetched else { return nil }
        // The player this is for; if it closes meanwhile, nothing is kept.
        let owner = activePlayer
        let availability = await registry.availability(for: nextKey)
        guard activePlayer === owner else { return nil }
        guard let variant = chooseVariant(availability.variants, for: nextKey),
              PlaybackEngines.canAttempt(container: variant.container) else { return nil }
        let episode = try? await metadata.season(ns, of: seriesKey).episodes.first { $0.number == ne }
        let item = NowPlayingItem(key: nextKey, title: detail.title.name,
                                  subtitle: "S\(ns)·E\(ne)" + (episode.map { " · \($0.name)" } ?? ""),
                                  artworkURL: imageURL(episode?.still ?? detail.title.backdrop, width: 640))
        return PickedEpisode(item: item, variant: variant)
    }

    /// The start half: resolves the picked release (for a torrent, this is
    /// where the stream changes over).
    private func startEpisode(_ picked: PickedEpisode) async -> (NowPlayingItem, PlaybackResource)? {
        let nextKey = picked.item.key, variant = picked.variant
        let owner = activePlayer
        await holdTorrentDownloads(before: variant, key: nextKey)
        let resource: PlaybackResource
        do {
            resource = try await registry.resolve(variant)
        } catch {
            Log.playback.error("Up Next couldn't resolve \(nextKey.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        guard activePlayer === owner else {
            // Closed while it was found: let its stream and the paused downloads go.
            if resource.variant.sourceID == addons.id { await addons.stopStreaming() }
            releaseTorrentDownloadHolds()
            return nil
        }
        await holdTorrentDownloads(streaming: resource.variant)
        rememberSource(variant, for: nextKey)
        if pickedNext?.item.key == nextKey { pickedNext = nil }  // used: a later pick asks the sources afresh
        return (picked.item, resource)
    }
}

/// An episode whose release has been chosen but not started (`AppModel.pickEpisode`).
struct PickedEpisode {
    /// The episode it follows, when picked as "the next one".
    var after: MediaKey?
    let item: NowPlayingItem
    let variant: MediaVariant
    let at = Date()

    /// Debrid caches and swarms change: after ten minutes, ask again.
    var isFresh: Bool { Date().timeIntervalSince(at) < 600 }
}

public struct AppAlert: Identifiable, Equatable {
    public let id = UUID()
    public let title: String
    public let message: String
    /// Shown as a Try Again button beside OK when set.
    public let retry: (@MainActor () -> Void)?
    /// Ways forward shown above OK, the first in white ("Open Real-Debrid", "Releases…").
    /// When any has a `role`, the alert asks for a decision: just these
    /// buttons, styled by role, with no OK ("Sign Out Anyway", "Try Again", "Cancel").
    public let actions: [Action]

    public struct Action {
        public enum Role { case primary, secondary, cancel }
        public let title: String
        public let role: Role?
        public let perform: @MainActor () -> Void
        public init(_ title: String, role: Role? = nil, perform: @escaping @MainActor () -> Void = {}) {
            self.title = title; self.role = role; self.perform = perform
        }
    }

    public init(title: String, message: String, retry: (@MainActor () -> Void)? = nil, actions: [Action] = []) {
        self.title = title; self.message = message; self.retry = retry; self.actions = actions
    }

    public static func == (a: AppAlert, b: AppAlert) -> Bool { a.id == b.id }
}

/// Lets background sync look up full titles through the app's current
/// metadata provider without holding the app strongly.
@MainActor
final class TitleResolver {
    weak var app: AppModel?
    func title(for key: MediaKey) async -> Title? { await app?.title(for: key) }
    func imdbID(for key: MediaKey) async -> String? {
        guard let metadata = app?.metadata else { return nil }
        return try? await metadata.detail(for: key).imdbID
    }
}

// MARK: - Torrents & Debrid (Stremio add-ons)

extension AppModel {
    public func setAddonSettings(_ settings: AddonSettings) {
        saveAddonSettings(settings, reloading: true)
    }

    /// `reloading` false keeps the pages built from the sources as they are
    /// (Home saving the catalogs it just read).
    func saveAddonSettings(_ settings: AddonSettings, reloading: Bool) {
        addonSettings = settings
        prefs.set(settings, for: PreferenceKey.addons)
        Task { await addons.update(settings: settings, debridKey: debridKey) }
        Task { await torrentDownloads.update(settings: settings.streamSettings) }
        refreshDebridLibrarySource()
        if reloading { sourcesRevision += 1 }
    }

    public func setDebridKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        debridKey = trimmed
        try? secrets.write(trimmed.isEmpty ? nil : trimmed, for: SecretAccount.debrid)
        Task { await addons.update(settings: addonSettings, debridKey: trimmed) }
        refreshDebridLibrarySource()
        sourcesRevision += 1
    }

    public func testAddons() async -> SourceHealth {
        await addons.testConnection()
    }

    /// Every release the add-ons offer for a movie or episode, best first.
    public func releases(for key: MediaKey, refresh: Bool = false) async throws -> [AddonRelease] {
        try await addons.releases(for: key, refresh: refresh)
    }

    /// Plays one release the user picked.
    public func play(_ item: NowPlayingItem, release: AddonRelease, in external: ExternalPlayer? = nil,
                     resume: Bool = true, autoplay: Bool = true) async {
        if external == nil, autoplay, let data = try? JSONEncoder().encode(release),
           remote.playOnTarget(RemotePlay(key: item.key, title: item.title, subtitle: item.subtitle, release: data)) { return }
        let variant = await addons.variant(for: release, key: item.key)
        await play(item, variant: variant, resume: resume, in: external, autoplay: autoplay)
    }

    /// The apps a release's Open In… offers: links, and torrents, which
    /// Bluebox keeps serving behind the app. Empty when none is installed.
    public func externalPlayers(for release: AddonRelease) -> [ExternalPlayer] {
        if let url = release.url { guard ExternalPlayer.canOpen(url) else { return [] } }
        else if release.magnet == nil || !addonsCanStreamTorrents { return [] }
        return ExternalPlayer.installed
    }

    #if DEBUG
    /// Screenshots (`-show-preparing` on a title page): the overlay Play shows while it opens a release.
    func debugShowPreparing(_ item: NowPlayingItem) {
        preparingItem = item
        addonStatus = .trying(release: "Sintel.2010.1080p.WEB-DL.H264.AAC-NTb.mp4")
    }
    #endif

    /// Stops finding or buffering a release.
    public func cancelPreparing() {
        preparing?.cancel()
        addonStatus = nil
        Task { await addons.stopStreaming() }
    }
}

/// Finds a title's IMDb ID (what Stremio add-ons key on) through the app's
/// metadata provider, remembering answers.
final class IMDbLookup: @unchecked Sendable {
    private let resolver: TitleResolver
    private let lock = NSLock()
    private var known: [MediaKey: String] = [:]

    init(resolver: TitleResolver) { self.resolver = resolver }

    func imdbID(for key: MediaKey) async -> String? {
        if let id = key.imdbID { return id }  // Cinemeta keys carry it
        if let hit = lock.withLock({ known[key] }) { return hit }
        guard let id = await resolver.imdbID(for: key) else { return nil }
        lock.withLock { known[key] = id }
        return id
    }
}

// MARK: - Your own Supabase project

extension AppModel {
    private struct StoredServer: Codable { let url: String; let key: String }

    static func storedServer(_ secrets: any SecretStore) -> SupabaseConfig? {
        guard let json = (try? secrets.read(SecretAccount.supabaseServer)).flatMap({ $0 }),
              let saved = try? JSONDecoder().decode(StoredServer.self, from: Data(json.utf8)) else { return nil }
        return SupabaseConfig(url: saved.url, publishableKey: saved.key)
    }

    /// Checks the URL and key (refusing service-role and secret keys before
    /// anything is sent), checks the project answers and has Bluebox's tables,
    /// then uses it for sign-in and sync. Throws `SupabaseSetupError`.
    @discardableResult
    public func connectSupabase(url: String, key: String) async throws -> SupabaseProjectReport {
        let config = try SupabaseSetupInput.config(url: url, key: key)
        let report = try await SupabaseProjectProbe.check(config, http: http)
        let saved = StoredServer(url: config.url.absoluteString, key: config.publishableKey)
        try? secrets.write(String(decoding: try JSONEncoder().encode(saved), as: UTF8.self), for: SecretAccount.supabaseServer)
        hasCustomServer = true
        account.configure(config)
        account.recordSetupCheck(report)
        return report
    }

    public func cancelConnect() { pendingConnect = nil }

    /// Sign-out couldn't upload everything: sign out anyway (the changes stay
    /// here and upload the next time this account signs in), try again, or stay.
    func askToSignOut(leaving waiting: Int) {
        let title = waiting == 1 ? "1 change hasn't uploaded" : "\(waiting) changes haven't uploaded"
        alert = AppAlert(title: title,
                         message: "Bluebox couldn't reach your server. If you sign out now, they stay on this device and upload the next time you sign in to this account.",
                         actions: [
                             .init("Sign Out Anyway") { [weak self] in Task { await self?.account.signOut(force: true) } },
                             .init("Try Again", role: .primary) { [weak self] in Task { await self?.account.signOut() } },
                             .init("Cancel", role: .cancel),
                         ])
    }

    /// Forgets the project entered in Settings and signs out.
    public func disconnectSupabase() {
        try? secrets.write(nil, for: SecretAccount.supabaseServer)
        hasCustomServer = false
        serverSetup.cancel()
        account.configure(SupabaseConfig(bundle: .main))
    }

    /// Links opened from outside: `bluebox://title…`, `play…`, `my-list` and
    /// `search…` from widgets, Spotlight and Siri (`SystemLink`), `bluebox://connect?…` from another device's
    /// "Add Another Device", `bluebox://auth-callback…` sign-in links (refused), and
    /// (Mac) `magnet:` links, .torrent and video files opened with Bluebox,
    /// which go the Settings › Sources way and then offer Play (`openExternal`).
    public func handleOpenURL(_ url: URL) {
        if let invite = TogetherInvite(url: url) {
            partyJoin = PartyJoinRequest(invite: invite)
        } else if let link = SystemLink(url: url) {
            Task { await open(link) }  // widgets, Spotlight and Siri
        } else if ConnectLink.matches(url) {
            Task { await connect(fromLink: url) }
        } else if let item = ExternalItem.classify(url) {
            Task { await openExternal(item) }
        } else {
            account.handleOpenURL(url)
        }
    }

    /// A server from a connect link, waiting for the user to confirm it
    /// (`ConnectLinkPrompt`): a link can come from anyone, and the username and
    /// password typed next go to that server.
    public struct PendingConnect: Equatable, Identifiable, Sendable {
        public let link: ConnectLink
        /// The server this device uses now, which connecting replaces.
        public let replacing: String?
        public var id: String { link.url.absoluteString }
        public var host: String { link.config.url.host() ?? link.config.url.absoluteString }
    }

    /// Asks before connecting to the server in a connect link, then shows
    /// Settings › Account to sign in. A device signed in elsewhere isn't
    /// switched: it says how to change servers first. Pasting a link in
    /// Settings connects straight away, since the user chose it there.
    func connect(fromLink url: URL) async {
        let link: ConnectLink
        do {
            guard let parsed = try ConnectLink.parse(url) else { return }
            link = parsed
        } catch {
            account.showLinkEvent(.failed(AccountModel.describe(error)))
            return
        }
        if account.server == link.config.url, account.isConfigured {
            account.openRequest = UUID()
            return
        }
        if account.isSignedIn {
            account.showLinkEvent(.failed("This device is signed in to another server. To switch, open Settings › Account, sign out and choose Change Server, then open the link again."))
            account.openRequest = UUID()
            return
        }
        pendingConnect = PendingConnect(link: link, replacing: account.isConfigured ? account.server.flatMap { $0.host() } : nil)
    }

    /// The user confirmed the server in a connect link.
    public func confirmConnect() async {
        guard let pending = pendingConnect else { return }
        pendingConnect = nil
        let link = pending.link, host = pending.host
        guard !account.isSignedIn else { return }  // signed in meanwhile
        account.showLinkEvent(.connecting)
        do {
            try await connectSupabase(url: link.config.url.absoluteString, key: link.config.publishableKey)
            serverSetup.cancel()
            account.showLinkEvent(.connected(host))
            account.openRequest = UUID()
        } catch {
            account.showLinkEvent(.failed(AccountModel.describe(error)))
        }
    }
}

// MARK: - UI data (Top 10, New & Hot, downloaded badge)

extension AppModel {
    /// Today's Top 10 for one kind, from TMDB's popular lists.
    public func topTen(_ kind: TitleKind) async throws -> [Title] {
        let page = try await metadata.list(kind == .movie ? .popularMovies : .popularSeries, page: 1)
        return Array(page.items.filter { $0.kind == kind }.prefix(10))
    }

    /// Recent releases across trending and popular lists, newest first, for
    /// New & Hot. Titles without a date go last.
    public func newReleases(limit: Int = 20) async throws -> [Title] {
        async let trending = metadata.list(.trending, page: 1)
        async let movies = metadata.list(.popularMovies, page: 1)
        async let series = metadata.list(.popularSeries, page: 1)
        let all = try await trending.items + movies.items + series.items
        var seen = Set<MediaKey>()
        let unique = all.filter { seen.insert($0.key).inserted }
        return Array(unique.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }.prefix(limit))
    }

    /// The best resolution any source offers for a key ("4K", "HD"), for the
    /// title page's metadata line. Nil when nothing is playable or unknown.
    func qualityLabel(_ availability: Availability?) -> String? {
        let res = (availability?.variants ?? []).compactMap { $0.resolution?.lowercased() }
        if res.contains(where: { $0.contains("2160") || $0.contains("4k") }) { return "4K" }
        if res.contains(where: { $0.contains("1080") || $0.contains("720") }) { return "HD" }
        return nil
    }

    /// Hook for the "Downloaded" badge on cards. Reads finished records from
    /// `DownloadManager`; the downloads work may replace this with its own API.
    func hasFinishedDownload(_ key: MediaKey) -> Bool {
        completedDownloadKeys.contains(key)
    }

    /// Recomputes `completedDownloadKeys` and `activeDownloadCount`, writing
    /// them only when they differ (an Observable write always notifies).
    func refreshDownloadSummary() {
        var done = Set<MediaKey>(), active = 0
        for r in downloads.all() {
            switch r.state {
            case .completed:
                if let k = r.mediaKey { done.insert(k) }
            case .downloading, .queued: active += 1
            default: break
            }
        }
        if done != completedDownloadKeys {
            completedDownloadKeys = done
            scheduleSystemRefresh()  // Spotlight lists downloads
        }
        if active != activeDownloadCount { activeDownloadCount = active }
    }
}

/// A profile switch waiting for RootView (and maybe a PIN).
public struct ProfileSwitchRequest: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let profileID: String
}

// MARK: - Settings sync

extension AppModel {
    /// Settings that follow the account. Device-only state (data usage, the
    /// last tab, sources and folders on this device) stays out.
    static let syncedPreferenceKeys = Set<String>([
        PreferenceKey.addons, PreferenceKey.downloadSettings, PreferenceKey.playbackSpeed,
        PreferenceKey.playbackEngine, PreferenceKey.resumeBehavior, PreferenceKey.skipBackSeconds,
        PreferenceKey.skipForwardSeconds, PreferenceKey.upNextCountdown, PreferenceKey.defaultSubtitleDelay,
        PreferenceKey.autoSearchSubtitles, PreferenceKey.allowCellularStreaming, PreferenceKey.mobileData,
        PreferenceKey.pictureDefaults, PreferenceKey.launchIntro,
        PlayerFeatureKey.skipIntro, PlayerFeatureKey.skipCredits, PlayerFeatureKey.skipDisabledShows,
        PlayerFeatureKey.crowdSkipDisabledShows, PlayerFeatureKey.scrubThumbnails, PlayerFeatureKey.dialogueBoost,
        PlayerFeatureKey.nightMode, PlayerFeatureKey.handoff, PlayerFeatureKey.skipRecap,
        FeatureServices.Keys.autoplayPreviews, FeatureServices.Keys.newEpisodeSettings,
    ]).union(FeatureSwitches.syncedKeys)
    /// Each profile's audio language, autoplay, subtitle style, shows it always
    /// skips (`ProfileSettingKey`) and its Privacy & Features switches.
    static let syncedProfileKeySuffixes = [".audioLanguage", ".autoplayNext", ".subtitleStyle", ".showSkipRules", ".equalizer"]
        + FeatureSwitches.syncedProfileSuffixes
    /// API keys, with Sync API Keys on (add-on links too, by prefix). Sign-ins
    /// that refresh themselves (Supabase, Trakt, OpenSubtitles) stay per device.
    static let syncedSecretAccounts: Set<String> = [
        SecretAccount.tmdb, SecretAccount.omdb, SecretAccount.openSubtitles, SecretAccount.debrid,
    ]

    /// Another device changed these settings and they're written here: load them.
    func applySyncedSettings(_ keys: [String]) {
        guard let sync = account.settingsSync else { return }
        let changed = Set(keys)
        sync.withoutRecording {
            settings.reloadFromPreferences()
            features.reloadFromPreferences()
            featureSwitches.reloadFromPreferences()
            let speed = prefs.value(Float.self, for: PreferenceKey.playbackSpeed) ?? 1
            if speed != defaultSpeed { defaultSpeed = speed }
            let style = prefs.value(SubtitleStyle.self, for: ProfileSettingKey.subtitleStyle(currentProfileID)) ?? SubtitleStyle()
            if style != subtitleStyle { subtitleStyle = style }
            let eq = prefs.value(EqualizerSettings.self, for: ProfileSettingKey.equalizer(currentProfileID)) ?? EqualizerSettings()
            if eq != equalizer { equalizer = eq }
            if changed.contains(PreferenceKey.downloadSettings) {
                setDownloadSettings(prefs.value(DownloadSettings.self, for: PreferenceKey.downloadSettings) ?? DownloadSettings())
            }
            if changed.contains(PreferenceKey.addons) || changed.contains(where: { $0.hasPrefix("secret." + SecretAccount.addonLinkPrefix) }) {
                setAddonSettings(Self.loadAddonSettings(prefs: prefs, secrets: secrets))
            }
            if changed.contains("secret." + SecretAccount.debrid) {
                setDebridKey((try? secrets.read(SecretAccount.debrid)).flatMap { $0 } ?? "")
            }
            if changed.contains("secret." + SecretAccount.tmdb) { reloadTMDBCredential() }
            if changed.contains("secret." + SecretAccount.omdb) { reloadOMDbKey() }
            if changed.contains("secret." + SecretAccount.openSubtitles) { reloadOpenSubtitlesKey() }
        }
        Log.persistence.notice("Settings sync: applied \(keys.count) change(s) from another device")
    }

    private func reloadTMDBCredential() {
        guard catalogMode != .sample else { return }
        if let credential = (try? secrets.read(SecretAccount.tmdb)).flatMap({ $0.flatMap(TMDBCredential.init) }) {
            metadata = CachedMetadataProvider(TMDBService(credential: credential, http: http))
            catalogMode = .live
        } else {
            guard catalogMode == .live else { return }
            metadata = CachedMetadataProvider(CinemetaMetadataProvider(http: http))
            catalogMode = .cinemeta
        }
        applyContentFilter()
        libraryRevision += 1
    }

    private func reloadOMDbKey() {
        if let key = (try? secrets.read(SecretAccount.omdb)).flatMap({ $0 }), !key.isEmpty {
            ratingsProvider = OMDbService(apiKey: key, http: http)
            hasOMDbKey = true
        } else {
            ratingsProvider = nil
            hasOMDbKey = false
        }
    }

    private func reloadOpenSubtitlesKey() {
        if let key = (try? secrets.read(SecretAccount.openSubtitles)).flatMap({ $0 }), !key.isEmpty {
            subtitleSearch = OpenSubtitlesService(apiKey: key, http: http)
            hasOpenSubtitlesKey = true
        } else {
            subtitleSearch = nil
            hasOpenSubtitlesKey = false
        }
        openSubtitlesSignedIn = false
    }
}

#if os(macOS)
import AppKit

extension NSApplication {
    /// Quits from inside a Swift task. Calling terminate there deadlocks:
    /// AppDelegate answers terminateLater and finishes on the main actor, which
    /// AppKit's wait can't reach while the calling task still holds it. So it's
    /// run from the run loop instead, once the task has let go.
    func quitFromTask() {
        RunLoop.main.perform { NSApp.terminate(nil) }
    }
}
#endif
