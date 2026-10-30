import Domain
import Downloads
import Foundation
import Observation
import Persistence
import Playback
import SkipSegments
import VLCPlayback

/// Settings added with the Settings redesign: playback, subtitle and network
/// defaults. Each value lives under its own `PreferenceKey`, so adding one
/// never disturbs another. The older settings (`subtitleStyle`, `defaultSpeed`,
/// `addonSettings`) stay on `AppModel` under their original keys.
@Observable
@MainActor
public final class AppSettings {
    public enum EnginePreference: String, Codable, CaseIterable, Identifiable, Sendable {
        /// AVPlayer when it can open the file (PiP, AirPlay), VLC for the rest.
        case automatic
        /// VLC for everything it can play.
        case preferVLC
        /// AVPlayer only; MKV, AVI and WebM won't play.
        case avPlayerOnly
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .automatic: "Automatic"
            case .preferVLC: "Prefer VLC"
            case .avPlayerOnly: "AVPlayer Only"
            }
        }
    }

    public enum ResumeBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
        case always, never
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .always: "Where I Left Off"
            case .never: "From the Beginning"
            }
        }
    }

    public static let skipIntervals = [5, 10, 15, 30, 45, 60]
    public static let countdowns = [5, 10, 15, 20, 30]

    public var enginePreference: EnginePreference { didSet { save(enginePreference, PreferenceKey.playbackEngine) } }
    public var resumeBehavior: ResumeBehavior { didSet { save(resumeBehavior, PreferenceKey.resumeBehavior) } }
    public var skipBackSeconds: Int { didSet { save(skipBackSeconds, PreferenceKey.skipBackSeconds) } }
    public var skipForwardSeconds: Int { didSet { save(skipForwardSeconds, PreferenceKey.skipForwardSeconds) } }
    /// Per profile (`ProfileSettingKey`): follows `profileID`.
    public var autoplayNextEpisode: Bool { didSet { save(autoplayNextEpisode, ProfileSettingKey.autoplayNextEpisode(profileID)) } }
    public var upNextCountdown: Int { didSet { save(upNextCountdown, PreferenceKey.upNextCountdown) } }
    /// nil plays the file's default audio track. Per profile, like Autoplay.
    public var preferredAudioLanguage: String? { didSet { save(preferredAudioLanguage, ProfileSettingKey.audioLanguage(profileID)) } }
    public var defaultSubtitleDelay: Double { didSet { save(defaultSubtitleDelay, PreferenceKey.defaultSubtitleDelay) } }
    public var autoSearchSubtitles: Bool { didSet { save(autoSearchSubtitles, PreferenceKey.autoSearchSubtitles) } }
    /// Search Online sites turned off in Settings › Subtitles (`SubtitleSite` raw values).
    public var subtitleSitesOff: [String] { didSet { save(subtitleSitesOff, PreferenceKey.subtitleSitesOff) } }
    /// The older on/off switch for streaming on cellular. Kept (and its key) in step
    /// with `mobileData.streaming`: off is the same as Never.
    public var allowCellularStreaming: Bool {
        didSet {
            save(allowCellularStreaming, PreferenceKey.allowCellularStreaming)
            if !allowCellularStreaming, mobileData.streaming != .never { mobileData.streaming = .never }
            if allowCellularStreaming, mobileData.streaming == .never { mobileData.streaming = .askFirst }
        }
    }
    public var playLaunchIntro: Bool { didSet { save(playLaunchIntro, PreferenceKey.launchIntro) } }
    /// Settings › Mobile Data (iPhone and iPad).
    public var mobileData: MobileDataSettings {
        didSet {
            save(mobileData, PreferenceKey.mobileData)
            let allow = mobileData.streaming != .never
            if allowCellularStreaming != allow { allowCellularStreaming = allow }
            onMobileDataChange?()
        }
    }
    /// Settings › Picture: applied to each video as it starts.
    public var pictureDefaults: PictureDefaults { didSet { save(pictureDefaults, PreferenceKey.pictureDefaults) } }

    /// The network right now. Updated on every path change.
    public private(set) var network = NetworkPathInfo()
    /// Bytes used on mobile data this month (Settings › Mobile Data).
    public internal(set) var dataUsage: MobileDataUsage { didSet { save(dataUsage, PreferenceKey.mobileDataUsage) } }
    /// True when Wi‑Fi dropped to mobile data while a stream was playing. The
    /// player shows "Now using mobile data" while it's set; Continue, Lower
    /// Quality and Pause clear it (`AppModel.dismissMobileDataBanner()`).
    public internal(set) var networkSwitchedToCellularDuringPlayback = false
    /// The "You're on mobile data" question waiting for an answer.
    public internal(set) var mobileDataPrompt: MobileDataPrompt?
    /// "Don't ask again for this session".
    @ObservationIgnored var skipsMobileDataPrompt = false
    /// "Play in Data Saver" for the stream that's starting or playing.
    @ObservationIgnored var dataSaverForThisPlayback = false
    /// What the player is streaming, for the counter and the network-switch banner.
    @ObservationIgnored var streamingVariant: MediaVariant?
    @ObservationIgnored var promptAnswer: CheckedContinuation<MobileDataChoice, Never>?
    @ObservationIgnored var onNetworkChange: (@MainActor (_ old: NetworkPathInfo, _ new: NetworkPathInfo) -> Void)?
    @ObservationIgnored var onMobileDataChange: (@MainActor () -> Void)?

    // Player features (Skip Intro, preview thumbnails, audio, Handoff). Keys live
    // here rather than in PreferenceKey so this file owns them; see `PlayerFeatureKey`.
    /// Skip Intro and Skip Recap: Off, Show Button or Automatic.
    public var skipIntroMode: SkipSegmentPlanner.Mode { didSet { save(skipIntroMode, PlayerFeatureKey.skipIntro) } }
    /// Skip Recap ("Previously on…"): its own mode, so a show can always skip
    /// its recap without its intro. Starts as whatever Skip Intro was.
    public var skipRecapMode: SkipSegmentPlanner.Mode { didSet { save(skipRecapMode, PlayerFeatureKey.skipRecap) } }
    /// At the credits: Off, Show Button ("Next Episode" / "Watch Credits") or Automatic.
    public var skipCreditsMode: SkipSegmentPlanner.Mode { didSet { save(skipCreditsMode, PlayerFeatureKey.skipCredits) } }
    /// "Always skip the intro (recap, credits) for this show". Per profile, like Autoplay.
    public var showSkipRules: ShowSkipRules { didSet { save(showSkipRules, ProfileSettingKey.showSkipRules(profileID)) } }
    /// Series (or film) keys the viewer asked never to skip for ("Don't skip for this show").
    public var skipDisabledShows: Set<String> { didSet { save(skipDisabledShows, PlayerFeatureKey.skipDisabledShows) } }
    /// Series keys whose crowd timestamps (TheIntroDB, IntroDB) were wrong ("Wrong time?").
    public var crowdSkipDisabledShows: Set<String> { didSet { save(crowdSkipDisabledShows, PlayerFeatureKey.crowdSkipDisabledShows) } }
    /// Frames above the time bubble while scrubbing.
    public var scrubThumbnails: Bool { didSet { save(scrubThumbnails, PlayerFeatureKey.scrubThumbnails) } }
    /// Default for Dialogue Boost (centre channel and speech frequencies up).
    public var dialogueBoost: Bool { didSet { save(dialogueBoost, PlayerFeatureKey.dialogueBoost) } }
    /// Default for Night Mode (compressor and limiter: quiet and loud scenes even out).
    public var nightMode: Bool { didSet { save(nightMode, PlayerFeatureKey.nightMode) } }
    /// Offer what's playing to your other devices (Handoff).
    public var handoff: Bool { didSet { save(handoff, PlayerFeatureKey.handoff) } }
    /// Hand every video Infuse can reach to Infuse (this device only: Infuse may not be on the others).
    public var alwaysOpenInInfuse: Bool { didSet { save(alwaysOpenInInfuse, PlayerFeatureKey.alwaysOpenInInfuse) } }

    @ObservationIgnored private let prefs: PreferencesStore
    @ObservationIgnored private let monitor = NetworkMonitor()
    /// Whose per-profile settings these are (`loadProfile`).
    @ObservationIgnored public private(set) var profileID = Profile.defaultID

    public init(prefs: PreferencesStore, profileID: String = Profile.defaultID) {
        self.prefs = prefs
        self.profileID = profileID
        ProfileSettingsMigration.runIfNeeded(prefs: prefs, profileIDs: ProfileSettingsMigration.storedProfileIDs(prefs))
        enginePreference = prefs.value(EnginePreference.self, for: PreferenceKey.playbackEngine) ?? .automatic
        resumeBehavior = prefs.value(ResumeBehavior.self, for: PreferenceKey.resumeBehavior) ?? .always
        skipBackSeconds = prefs.value(Int.self, for: PreferenceKey.skipBackSeconds) ?? 10
        skipForwardSeconds = prefs.value(Int.self, for: PreferenceKey.skipForwardSeconds) ?? 10
        autoplayNextEpisode = prefs.value(Bool.self, for: ProfileSettingKey.autoplayNextEpisode(profileID)) ?? true
        upNextCountdown = prefs.value(Int.self, for: PreferenceKey.upNextCountdown) ?? 10
        preferredAudioLanguage = prefs.value(String.self, for: ProfileSettingKey.audioLanguage(profileID))
        defaultSubtitleDelay = prefs.value(Double.self, for: PreferenceKey.defaultSubtitleDelay) ?? 0
        autoSearchSubtitles = prefs.value(Bool.self, for: PreferenceKey.autoSearchSubtitles) ?? false
        subtitleSitesOff = prefs.value([String].self, for: PreferenceKey.subtitleSitesOff) ?? []
        let allowCellular = prefs.value(Bool.self, for: PreferenceKey.allowCellularStreaming) ?? true
        allowCellularStreaming = allowCellular
        playLaunchIntro = prefs.value(Bool.self, for: PreferenceKey.launchIntro) ?? true
        let introMode = prefs.value(SkipSegmentPlanner.Mode.self, for: PlayerFeatureKey.skipIntro) ?? .button
        skipIntroMode = introMode
        skipRecapMode = prefs.value(SkipSegmentPlanner.Mode.self, for: PlayerFeatureKey.skipRecap) ?? introMode
        skipCreditsMode = prefs.value(SkipSegmentPlanner.Mode.self, for: PlayerFeatureKey.skipCredits) ?? .button
        showSkipRules = prefs.value(ShowSkipRules.self, for: ProfileSettingKey.showSkipRules(profileID)) ?? ShowSkipRules()
        skipDisabledShows = prefs.value(Set<String>.self, for: PlayerFeatureKey.skipDisabledShows) ?? []
        crowdSkipDisabledShows = prefs.value(Set<String>.self, for: PlayerFeatureKey.crowdSkipDisabledShows) ?? []
        scrubThumbnails = prefs.value(Bool.self, for: PlayerFeatureKey.scrubThumbnails) ?? true
        dialogueBoost = prefs.value(Bool.self, for: PlayerFeatureKey.dialogueBoost) ?? false
        nightMode = prefs.value(Bool.self, for: PlayerFeatureKey.nightMode) ?? false
        handoff = prefs.value(Bool.self, for: PlayerFeatureKey.handoff) ?? true
        alwaysOpenInInfuse = prefs.value(Bool.self, for: PlayerFeatureKey.alwaysOpenInInfuse) ?? false
        var mobile = prefs.value(MobileDataSettings.self, for: PreferenceKey.mobileData) ?? MobileDataSettings()
        if !allowCellular { mobile.streaming = .never }  // turned off before Mobile Data existed
        mobileData = mobile
        pictureDefaults = prefs.value(PictureDefaults.self, for: PreferenceKey.pictureDefaults) ?? PictureDefaults()
        dataUsage = (prefs.value(MobileDataUsage.self, for: PreferenceKey.mobileDataUsage) ?? MobileDataUsage()).current()
        monitor.start { [weak self] path in
            Task { @MainActor in if self?.simulatedNetwork == false { self?.networkChanged(path) } }
        }
    }

    /// Re-reads every stored setting: another device changed some (settings sync).
    func reloadFromPreferences() {
        func load<T: Codable & Equatable>(_ key: String, _ fallback: T, into path: ReferenceWritableKeyPath<AppSettings, T>) {
            let v = prefs.value(T.self, for: key) ?? fallback
            if self[keyPath: path] != v { self[keyPath: path] = v }
        }
        load(PreferenceKey.playbackEngine, EnginePreference.automatic, into: \.enginePreference)
        load(PreferenceKey.resumeBehavior, ResumeBehavior.always, into: \.resumeBehavior)
        load(PreferenceKey.skipBackSeconds, 10, into: \.skipBackSeconds)
        load(PreferenceKey.skipForwardSeconds, 10, into: \.skipForwardSeconds)
        load(PreferenceKey.upNextCountdown, 10, into: \.upNextCountdown)
        load(PreferenceKey.defaultSubtitleDelay, 0.0, into: \.defaultSubtitleDelay)
        load(PreferenceKey.autoSearchSubtitles, false, into: \.autoSearchSubtitles)
        load(PreferenceKey.subtitleSitesOff, [String](), into: \.subtitleSitesOff)
        load(PreferenceKey.allowCellularStreaming, true, into: \.allowCellularStreaming)
        load(PreferenceKey.launchIntro, true, into: \.playLaunchIntro)
        load(PlayerFeatureKey.skipIntro, SkipSegmentPlanner.Mode.button, into: \.skipIntroMode)
        load(PlayerFeatureKey.skipRecap, skipIntroMode, into: \.skipRecapMode)
        load(PlayerFeatureKey.skipCredits, SkipSegmentPlanner.Mode.button, into: \.skipCreditsMode)
        load(PlayerFeatureKey.skipDisabledShows, Set<String>(), into: \.skipDisabledShows)
        load(PlayerFeatureKey.crowdSkipDisabledShows, Set<String>(), into: \.crowdSkipDisabledShows)
        load(PlayerFeatureKey.scrubThumbnails, true, into: \.scrubThumbnails)
        load(PlayerFeatureKey.dialogueBoost, false, into: \.dialogueBoost)
        load(PlayerFeatureKey.nightMode, false, into: \.nightMode)
        load(PlayerFeatureKey.handoff, true, into: \.handoff)
        load(PlayerFeatureKey.alwaysOpenInInfuse, false, into: \.alwaysOpenInInfuse)
        load(PreferenceKey.mobileData, MobileDataSettings(), into: \.mobileData)
        load(PreferenceKey.pictureDefaults, PictureDefaults(), into: \.pictureDefaults)
        loadProfile(profileID)
    }

    /// Switches the per-profile values to another profile's.
    func loadProfile(_ id: String) {
        profileID = id
        let autoplay = prefs.value(Bool.self, for: ProfileSettingKey.autoplayNextEpisode(id)) ?? true
        if autoplay != autoplayNextEpisode { autoplayNextEpisode = autoplay }
        let audio = prefs.value(String.self, for: ProfileSettingKey.audioLanguage(id))
        if audio != preferredAudioLanguage { preferredAudioLanguage = audio }
        let rules = prefs.value(ShowSkipRules.self, for: ProfileSettingKey.showSkipRules(id)) ?? ShowSkipRules()
        if rules != showSkipRules { showSkipRules = rules }
    }

    private func networkChanged(_ path: NetworkPathInfo) {
        guard path != network else { return }
        let old = network
        network = path
        onNetworkChange?(old, path)
    }

    /// Test seam: pretend the network changed.
    func simulateNetwork(_ path: NetworkPathInfo) { simulatedNetwork = true; networkChanged(path) }
    @ObservationIgnored private var simulatedNetwork = false

    /// On mobile data as Settings › Mobile Data counts it (iPhone and iPad only;
    /// Low Data Mode and hotspots count too).
    public var isOnMobileData: Bool { mobileDataApplies && network.isMobileData }

    /// Mobile data rules apply on iPhone and iPad. Tests turn them on elsewhere.
    #if os(iOS)
    @ObservationIgnored var mobileDataApplies = true
    #else
    @ObservationIgnored var mobileDataApplies = false
    #endif

    /// Read before the app model exists, for the launch ident.
    nonisolated static var launchIntroEnabled: Bool {
        PreferencesStore().value(Bool.self, for: PreferenceKey.launchIntro) ?? true
    }

    private func save<T: Codable>(_ value: T?, _ key: String) { prefs.set(value, for: key) }

    /// Puts every setting on this object back to its default.
    public func resetToDefaults() {
        enginePreference = .automatic
        resumeBehavior = .always
        skipBackSeconds = 10
        skipForwardSeconds = 10
        autoplayNextEpisode = true
        upNextCountdown = 10
        preferredAudioLanguage = nil
        defaultSubtitleDelay = 0
        autoSearchSubtitles = false
        subtitleSitesOff = []
        allowCellularStreaming = true
        playLaunchIntro = true
        skipIntroMode = .button
        skipRecapMode = .button
        skipCreditsMode = .button
        skipDisabledShows = []
        crowdSkipDisabledShows = []
        showSkipRules = ShowSkipRules()
        scrubThumbnails = true
        dialogueBoost = false
        nightMode = false
        handoff = true
        alwaysOpenInInfuse = false
        mobileData = MobileDataSettings()
        pictureDefaults = PictureDefaults()
    }

    // MARK: Skipping, per show

    /// The key skip choices are remembered under: the series for episodes, the film itself otherwise.
    nonisolated static func showKey(for key: MediaKey) -> String { (key.seriesKey ?? key).rawValue }

    func skipsAllowed(for key: MediaKey) -> Bool { !skipDisabledShows.contains(Self.showKey(for: key)) }
    func setSkipsAllowed(_ allowed: Bool, for key: MediaKey) {
        if allowed { skipDisabledShows.remove(Self.showKey(for: key)) } else { skipDisabledShows.insert(Self.showKey(for: key)) }
    }

    /// The skip modes for what's playing: the global ones, with this show's
    /// "always skip" parts made Automatic.
    func skipModes(for key: MediaKey) -> SkipSegmentPlanner.Modes {
        showSkipRules.modes(show: Self.showKey(for: key),
                            defaults: .init(intro: skipIntroMode, recap: skipRecapMode, credits: skipCreditsMode))
    }

    func alwaysSkips(_ part: ShowSkipRules.Part, for key: MediaKey) -> Bool {
        showSkipRules.alwaysSkips(part, show: Self.showKey(for: key))
    }

    func setAlwaysSkip(_ on: Bool, _ part: ShowSkipRules.Part, for key: MediaKey) {
        showSkipRules.setAlways(on, part, show: Self.showKey(for: key))
        // Asking to always skip something means skipping is wanted for this show.
        if on { setSkipsAllowed(true, for: key) }
    }

    /// True the first time a part comes up for a show (the pill's "Always for this show").
    func offersAlwaysSkip(_ part: ShowSkipRules.Part, for key: MediaKey) -> Bool {
        showSkipRules.shouldOffer(part, show: Self.showKey(for: key))
    }

    func markAlwaysSkipOffered(_ part: ShowSkipRules.Part, for key: MediaKey) {
        showSkipRules.markOffered(part, show: Self.showKey(for: key))
    }

    func crowdSkipsAllowed(for key: MediaKey) -> Bool { !crowdSkipDisabledShows.contains(Self.showKey(for: key)) }
    func setCrowdSkipsAllowed(_ allowed: Bool, for key: MediaKey) {
        if allowed { crowdSkipDisabledShows.remove(Self.showKey(for: key)) } else { crowdSkipDisabledShows.insert(Self.showKey(for: key)) }
    }

    // MARK: Engine choice

    /// The engine for a resource, honouring Playback › Player.
    func makeEngine(for resource: PlaybackResource, streams: (any StreamDataProvider)?) -> any PlaybackEngine {
        switch kind(for: resource) {
        case .vlc: VLCEngine()
        case .avFoundation: AVPlayerEngine(streams: streams)
        }
    }

    /// A different engine when the next item needs one; nil keeps `current`.
    func replacementEngine(for resource: PlaybackResource, current: any PlaybackEngine,
                           streams: (any StreamDataProvider)?) -> (any PlaybackEngine)? {
        let currentKind: PlaybackEngineKind = current is VLCEngine ? .vlc : .avFoundation
        return kind(for: resource) == currentKind ? nil : makeEngine(for: resource, streams: streams)
    }

    func kind(for resource: PlaybackResource) -> PlaybackEngineKind {
        let automatic = PlaybackEngines.kind(for: resource)
        switch enginePreference {
        case .automatic:
            return automatic
        case .avPlayerOnly:
            return .avFoundation
        case .preferVLC:
            // bluebox-torrent:// is read through AVAssetResourceLoader, which VLC can't use.
            if let scheme = resource.url.scheme?.lowercased(), PlaybackEngineRouting.avOnlySchemes.contains(scheme) {
                return .avFoundation
            }
            return .vlc
        }
    }

    // MARK: Network

    /// Why streaming `variant` isn't allowed right now, or nil when it is.
    /// Files on this device always play.
    func streamingBlockedReason(for variant: MediaVariant) -> String? {
        guard mobileData.streaming == .never, variant.location == .remote, isOnMobileData else { return nil }
        return "Streaming on mobile data is off. Connect to Wi‑Fi, or change Settings › Mobile Data › Streaming."
    }

    /// True when the device has no network at all (not merely no internet).
    var isOffline: Bool { !network.isOnline }
}

/// UserDefaults keys for the player features' settings.
public enum PlayerFeatureKey {
    /// String: "off", "button" or "automatic".
    public static let skipIntro = "bluebox.playback.skipIntro"
    /// String: "off", "button" or "automatic".
    public static let skipRecap = "bluebox.playback.skipRecap"
    /// String: "off", "button" or "automatic".
    public static let skipCredits = "bluebox.playback.skipCredits"
    /// [String]: series/film media keys with skipping turned off.
    public static let skipDisabledShows = "bluebox.playback.skipDisabledShows"
    /// [String]: series/film media keys that ignore TheIntroDB and IntroDB.
    public static let crowdSkipDisabledShows = "bluebox.playback.crowdSkipDisabledShows"
    /// Bool: preview frames while scrubbing.
    public static let scrubThumbnails = "bluebox.playback.scrubThumbnails"
    /// Bool: Dialogue Boost on for new videos.
    public static let dialogueBoost = "bluebox.audio.dialogueBoost"
    /// Bool: Night Mode on for new videos.
    public static let nightMode = "bluebox.audio.nightMode"
    /// Bool: advertise what's playing for Handoff.
    public static let handoff = "bluebox.playback.handoff"
    /// Bool: hand videos to Infuse. Not synced.
    public static let alwaysOpenInInfuse = "bluebox.playback.alwaysInfuse"
}

// MARK: - Applying playback defaults

extension AppModel {
    /// Applies Settings › Playback and Subtitles defaults to a session that just
    /// started: audio language, subtitle delay and the OpenSubtitles fallback.
    /// Tracks appear a moment after loading, so this waits briefly for them.
    func applyPlaybackDefaults(to session: PlayerSession) {
        let settings = self.settings
        let key = session.item?.key
        Task { @MainActor [weak self, weak session] in
            if settings.defaultSubtitleDelay != 0, let session, session.subtitleOffset.seconds == 0 {
                session.nudgeSubtitles(by: settings.defaultSubtitleDelay)
            }
            // Settings › Picture, unless this video was already adjusted.
            if !settings.pictureDefaults.isDefault, let session, session.videoAdjustments.isDefault {
                session.setVideoAdjustments(settings.pictureDefaults.adjustments)
            }
            // Audio language: wait up to 5 s for the file's tracks.
            // A language chosen earlier in this session (the last episode) wins over the setting.
            if let lang = settings.preferredAudioLanguage, session?.rememberedAudio == nil {
                for _ in 0..<20 {
                    guard let session, session.item?.key == key else { return }
                    let tracks = session.snapshot.audioTracks
                    if tracks.count > 1 {
                        // Already in that language: leave it. Else the plain track (not commentary or description).
                        let current = tracks.first { $0.id == session.snapshot.selectedAudioID }
                        let inLanguage = current.flatMap(\.languageCode).map { Self.sameLanguage($0, lang) } ?? false
                        if !inLanguage, let match = TrackChoice(languageCode: lang).best(in: tracks),
                           match.id != session.snapshot.selectedAudioID {
                            session.selectAudio(match.id, remember: false)
                        }
                        break
                    }
                    if !tracks.isEmpty { break }  // only one track: nothing to choose
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            // Subtitles: if nothing in your language was found, search OpenSubtitles.
            guard settings.autoSearchSubtitles, let self, self.hasOpenSubtitlesKey,
                  let lang = self.subtitleStyle.preferredLanguage, let key else { return }
            try? await Task.sleep(for: .seconds(3))  // let embedded tracks and the preferred-language pick settle
            guard let session, session.item?.key == key, session.subtitleSelection == .off, session.rememberedSubtitle == nil else { return }
            guard let results = try? await self.searchSubtitles(for: key),
                  let best = results.filter({ $0.language.map { Self.sameLanguage($0, lang) } ?? false })
                    .min(by: { ($0.machineTranslated ? 1 : 0) < ($1.machineTranslated ? 1 : 0) }),
                  let url = try? await self.downloadSubtitle(best),
                  session.item?.key == key, session.subtitleSelection == .off else { return }
            session.importSubtitle(url)
        }
    }

    /// True when two language codes name the same language ("en", "eng", "en-US").
    nonisolated static func sameLanguage(_ a: String, _ b: String) -> Bool {
        normalizedLanguage(a) == normalizedLanguage(b)
    }

    nonisolated static func normalizedLanguage(_ code: String) -> String {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? code.lowercased()
        return Locale.LanguageCode(base).identifier(.alpha2) ?? base
    }
}
