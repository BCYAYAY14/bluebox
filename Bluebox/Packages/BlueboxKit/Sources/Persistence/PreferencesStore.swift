import Domain
import Foundation

/// Non-secret preferences backed by `UserDefaults`, encoded as JSON values.
public final class PreferencesStore: @unchecked Sendable {
    let defaults: UserDefaults

    /// Called after `set` changes a key (settings sync records it). Not called by `setRawData`.
    public var onSet: (@Sendable (String) -> Void)?

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func value<T: Codable>(_ type: T.Type, for key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func set<T: Codable>(_ value: T?, for key: String) {
        let before = defaults.data(forKey: key)
        if let value {
            guard let data = try? Self.encoder.encode(value) else { return }
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        if defaults.data(forKey: key) != before { onSet?(key) }
    }

    /// Sorted keys, so saving an unchanged value writes the same bytes.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    /// The stored JSON for `key`, as written by `set`.
    public func rawData(for key: String) -> Data? { defaults.data(forKey: key) }

    /// Stores JSON for `key` (nil removes it) without calling `onSet`.
    public func setRawData(_ data: Data?, for key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// Keys stored so far that start with `prefix`.
    public func keys(withPrefix prefix: String) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
    }

    /// Stable per-install identifier used only for sync diagnostics.
    public var deviceID: String {
        if let id = defaults.string(forKey: "bluebox.deviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "bluebox.deviceID")
        return id
    }
}

public enum PreferenceKey {
    public static let subtitleStyle = "bluebox.subtitleStyle"
    public static let sourceConfigurations = "bluebox.sources"
    public static let directURLs = "bluebox.directURLs"
    /// [TorrentSource.Item]: torrents the user added and their catalog matches.
    public static let torrents = "bluebox.torrents"
    public static let addons = "bluebox.addons"
    public static let pausedTorrentDownloads = "bluebox.pausedTorrentDownloads"
    /// `DownloadSettings` (Downloads): concurrency, Wi‑Fi only, delete after watching…
    public static let downloadSettings = "bluebox.downloadSettings"
    /// Profile shown at launch.
    public static let currentProfile = "bluebox.currentProfile"
    public static let playbackSpeed = "bluebox.playbackSpeed"
    /// [media key raw value: LastPlayedSource] for movies, episodes and series.
    public static let lastPlayedSources = "bluebox.lastPlayedSources"
    /// Per-show subtitle language/offset, keyed by series or movie key.
    public static func subtitlePreference(_ key: MediaKey) -> String { "bluebox.subs.\(key.rawValue)" }

    // MARK: Settings › Playback
    /// String: "automatic", "preferVLC" or "avPlayerOnly".
    public static let playbackEngine = "bluebox.playback.engine"
    /// String: "always" (resume where you left off) or "never" (start from the beginning).
    public static let resumeBehavior = "bluebox.playback.resume"
    /// Int seconds for the skip-back button and the left arrow key.
    public static let skipBackSeconds = "bluebox.playback.skipBack"
    /// Int seconds for the skip-forward button and the right arrow key.
    public static let skipForwardSeconds = "bluebox.playback.skipForward"
    /// Bool: count down and play the next episode when one ends.
    public static let autoplayNextEpisode = "bluebox.playback.autoplayNext"
    /// Int seconds the Up Next countdown runs.
    public static let upNextCountdown = "bluebox.playback.upNextCountdown"
    /// String? ISO 639-1 code of the audio track to pick when a file has several.
    public static let preferredAudioLanguage = "bluebox.playback.audioLanguage"

    // MARK: Settings › Subtitles
    /// Double seconds applied to subtitle files when playback starts.
    public static let defaultSubtitleDelay = "bluebox.subtitles.defaultDelay"
    /// Bool: search OpenSubtitles when nothing in your language is available.
    public static let autoSearchSubtitles = "bluebox.subtitles.autoSearch"
    /// Search Online sites turned off (`SubtitleSite` raw values).
    public static let subtitleSitesOff = "bluebox.subtitles.sitesOff"

    // MARK: Settings › Network
    /// Bool: stream over cellular (iPhone and iPad). Off means Wi‑Fi or wired only.
    public static let allowCellularStreaming = "bluebox.network.cellularStreaming"

    // MARK: Settings › Mobile Data (iPhone and iPad)
    /// `MobileDataSettings` JSON: streaming (allow / ask first / never), quality on
    /// mobile data, torrents on mobile data, upload on mobile data.
    public static let mobileData = "bluebox.mobileData"
    /// `MobileDataUsage` JSON: bytes Bluebox used on mobile data this month.
    public static let mobileDataUsage = "bluebox.mobileData.usage"

    // MARK: Settings › Picture
    /// `PictureDefaults` JSON: brightness, contrast and saturation applied when a video starts.
    public static let pictureDefaults = "bluebox.picture.defaults"

    // MARK: Settings › Advanced
    /// Bool: play the launch ident when the app opens.
    public static let launchIntro = "bluebox.launchIntro"
}
