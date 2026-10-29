import Domain
import Foundation
import MediaSources
import Network
import Observation
import Persistence
import UserNotifications

/// State for trailers, new episodes, the debrid library and Trakt
/// scrobbling, held by `AppModel.features`. The public API is on `AppModel`
/// (AppModel+Features.swift); views observe the revisions here.
@Observable
@MainActor
public final class FeatureServices {
    // MARK: Network (Low Data Mode and expensive networks count as mobile data)

    /// Cellular, a personal hotspot, or any network the system marks expensive.
    public private(set) var isOnMobileData = false
    /// Low Data Mode is on for the current network.
    public private(set) var isLowDataMode = false
    public private(set) var isOffline = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    // MARK: Trailers

    /// Settings › Playback › Autoplay Previews: Home's hero plays a muted trailer.
    public var autoplayPreviews: Bool { didSet { prefs.set(autoplayPreviews, for: Keys.autoplayPreviews) } }

    // MARK: New episodes

    public var newEpisodeSettings: NewEpisodeSettings {
        didSet { prefs.set(newEpisodeSettings, for: Keys.newEpisodeSettings) }
    }
    /// Bumped when reminders, Coming Soon or New Episodes change.
    public private(set) var episodesRevision = 0
    /// Set when a notification is opened: the root view shows this title (and episode).
    public var openRequest: OpenRequest?
    @ObservationIgnored var tracker: EpisodeTrackerState {
        didSet { prefs.set(tracker, for: Keys.tracker) }
    }
    @ObservationIgnored var checkTimer: Task<Void, Never>?
    @ObservationIgnored var checking: Task<Int, Never>?

    // MARK: Debrid library

    @ObservationIgnored public let debridLibrary: DebridLibrarySource
    /// Bumped when the debrid library reloads or its service changes.
    public private(set) var debridRevision = 0

    // MARK: Scrobbling

    @ObservationIgnored let scrobbler = ScrobbleObserver()

    @ObservationIgnored let prefs: PreferencesStore

    enum Keys {
        static let autoplayPreviews = "bluebox.previews.autoplay"
        static let newEpisodeSettings = "bluebox.newEpisodes.settings"
        static let tracker = "bluebox.newEpisodes.state"
    }

    /// Re-reads the settings another device can change (settings sync).
    func reloadFromPreferences() {
        let previews = prefs.value(Bool.self, for: Keys.autoplayPreviews) ?? true
        if previews != autoplayPreviews { autoplayPreviews = previews }
        let episodes = prefs.value(NewEpisodeSettings.self, for: Keys.newEpisodeSettings) ?? NewEpisodeSettings()
        if episodes != newEpisodeSettings { newEpisodeSettings = episodes }
    }

    init(prefs: PreferencesStore, debridLibrary: DebridLibrarySource) {
        self.prefs = prefs
        self.debridLibrary = debridLibrary
        autoplayPreviews = prefs.value(Bool.self, for: Keys.autoplayPreviews) ?? true
        newEpisodeSettings = prefs.value(NewEpisodeSettings.self, for: Keys.newEpisodeSettings) ?? NewEpisodeSettings()
        tracker = prefs.value(EpisodeTrackerState.self, for: Keys.tracker) ?? EpisodeTrackerState()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive, constrained = path.isConstrained, offline = path.status != .satisfied
            Task { @MainActor in
                self?.isOnMobileData = expensive
                self?.isLowDataMode = constrained
                self?.isOffline = offline
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.bluebox.features.network"))
    }

    deinit { pathMonitor.cancel() }

    func noteEpisodesChanged() { episodesRevision += 1 }
    func noteDebridChanged() { debridRevision += 1 }

    /// Muted autoplay is for Wi‑Fi: not on mobile data or in Low Data Mode
    /// (DECISIONS.md › Mobile data), and not when previews are off.
    public var canAutoplayPreviews: Bool {
        autoplayPreviews && !isOffline && !isLowDataMode && !isOnMobileData
    }

    /// Wi‑Fi or wired, not Low Data Mode: what auto-downloads wait for.
    public var isOnUnmeteredNetwork: Bool { !isOffline && !isOnMobileData && !isLowDataMode }
}

/// A title (and optionally one of its episodes) to show, e.g. from a notification.
public struct OpenRequest: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let title: Title
    /// The episode to scroll to on the title page.
    public let episode: MediaKey?
}

// MARK: - Local notifications

/// Asks for permission on first use and posts new-episode alerts.
enum EpisodeNotifications {
    static let category = "bluebox.newEpisode"
    /// Release alerts (ReleaseAlerts.swift). While Bluebox is open these go to
    /// the list only: the in-app notice already says it.
    static let releaseCategory = "bluebox.releaseAlert"
    static let mediaKeyField = "mediaKey"
    static let seriesKeyField = "seriesKey"

    /// Asks once; later calls return the current answer.
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default: return true  // ephemeral (App Clips)
        }
    }

    static func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status != .denied && status != .notDetermined
    }

    /// Also used for download alerts (DownloadLifecycle): `key` nil posts one
    /// that opens Bluebox without a title; `thread` groups them.
    static func post(id: String, title: String, body: String, key: MediaKey?, series: MediaKey?,
                     category: String = EpisodeNotifications.category, thread: String? = nil, sound: Bool = true) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        content.categoryIdentifier = category
        if let thread = thread ?? (series ?? key)?.rawValue { content.threadIdentifier = thread }
        var info: [String: String] = [:]
        if let key { info[mediaKeyField] = key.rawValue }
        if let series { info[seriesKeyField] = series.rawValue }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Routes notification taps to the app. Set as the notification center's
/// delegate at launch (BlueboxApp).
public final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = NotificationRouter()

    /// Show alerts while Bluebox is open, too.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        if notification.request.content.categoryIdentifier == EpisodeNotifications.releaseCategory { return [.list] }
        return [.banner, .list, .sound]
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info[EpisodeNotifications.mediaKeyField] as? String else { return }
        let series = (info[EpisodeNotifications.seriesKeyField] as? String).map(MediaKey.init(rawValue:))
        let key = MediaKey(rawValue: raw)
        await MainActor.run {
            AppModel.pendingNotificationKey = (key, series)
            AppModel.current?.openFromNotification()
        }
    }
}
