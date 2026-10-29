import Domain
import Foundation

/// How downloads are queued and kept. Stored as JSON under
/// `PreferenceKey.downloadSettings` (and synced with the account); fields
/// missing from older saves take their defaults.
public struct DownloadSettings: Codable, Sendable, Equatable {
    /// Downloads that transfer at once; the rest wait in order.
    public var maxConcurrent: Int
    /// Only download on Wi‑Fi or Ethernet (not cellular or a personal hotspot).
    /// Applies to HTTP and torrent downloads.
    public var wifiOnly: Bool
    /// Delete a downloaded movie or episode once you finish watching it.
    public var deleteAfterWatching: Bool
    /// Finishing a downloaded episode queues the next one of the series.
    public var downloadNextEpisode: Bool
    /// Keep the screen on while the Downloads page is open and torrents are
    /// downloading (with `keepDownloadingInBackground` off they only run
    /// while Bluebox is open).
    public var keepScreenAwake: Bool
    /// iOS: keep torrents downloading after you leave Bluebox (a silent audio
    /// session keeps the app running; uses more battery), and resume them
    /// while the device charges.
    public var keepDownloadingInBackground: Bool

    // MARK: Smart Downloads

    /// Netflix's Smart Downloads: finish a downloaded episode and it's
    /// deleted (with Undo) while the next ones download on Wi‑Fi. Supersedes
    /// `deleteAfterWatching` / `downloadNextEpisode`, which older saves map onto.
    public var smartDownloads: Bool
    /// How many episodes after the one you're watching stay downloaded.
    public var keepNextEpisodes: Int
    /// Days after you finish a downloaded film before it's deleted; 0 deletes
    /// it right away, nil keeps it.
    public var deleteWatchedFilmsAfterDays: Int?
    /// Smart Downloads keeps downloads under this much, making room by
    /// deleting watched ones; nil: no limit.
    public var storageLimitBytes: Int64?
    /// Shows (series keys) with Smart Downloads turned off. Older saves; new
    /// per-show choices go in `showRules`.
    public var smartDownloadsOff: Set<String>

    // Added with the UI review (29 October 2026). Missing keys take their defaults.

    /// Highest resolution a download fetches when Bluebox picks the release
    /// (Smart Downloads, the Download buttons), separate from streaming's.
    public var downloadQuality: DownloadQuality
    /// Releases bigger than this per episode are passed over; nil: any size.
    public var maxEpisodeBytes: Int64?
    /// Audio language downloads prefer (ISO 639-1); nil follows the profile's.
    public var audioLanguage: String?
    /// Smart Downloads deletes a downloaded episode once you've watched it.
    public var deleteWatchedEpisodes: Bool
    /// The master switch for anything Smart Downloads deletes on its own:
    /// watched episodes, watched films, and making room under the storage
    /// limit. Off, it only ever adds downloads.
    public var allowsDeleting: Bool
    /// Watching on another device (synced progress or Trakt) tops up and
    /// cleans up here too, not only watching on this device.
    public var followOtherDevices: Bool
    /// When downloads Bluebox starts on its own may run.
    public var window: DownloadWindow
    /// Fetch subtitles in the profile's language with each download, for offline use.
    public var fetchSubtitles: Bool
    /// Per-show overrides (series key raw value → rule). A show without one uses the defaults above.
    public var showRules: [String: ShowDownloadRule]

    public static let concurrencyChoices = [1, 2, 3, 4, 6]
    public static let keepNextChoices = [1, 2, 3, 5]
    public static let filmDayChoices: [Int?] = [0, 1, 7, 30, nil]
    public static let storageLimitChoices: [Int64?] = [nil, 10_000_000_000, 20_000_000_000, 50_000_000_000, 100_000_000_000]
    public static let episodeSizeChoices: [Int64?] = [nil, 1_000_000_000, 2_000_000_000, 3_000_000_000, 5_000_000_000]

    /// Smart Downloads is on for this show (its series key, or an episode's).
    /// A show's own rule wins; otherwise the switch, less the shows older saves turned off.
    public func smartDownloads(for key: MediaKey) -> Bool {
        let raw = (key.seriesKey ?? key).rawValue
        if let own = showRules[raw]?.smartDownloads { return own }
        return smartDownloads && !smartDownloadsOff.contains(raw)
    }

    /// The show's own rule, if it has one (nil for films).
    public func showRule(for key: MediaKey) -> ShowDownloadRule? {
        guard !key.isMovie else { return nil }
        return showRules[(key.seriesKey ?? key).rawValue]
    }

    /// The rule for `key` (a film, a show or an episode): the show's
    /// overrides over the defaults. Deleting needs both the rule and
    /// `allowsDeleting`.
    public func rule(for key: MediaKey) -> DownloadRule {
        let own = showRule(for: key)
        return DownloadRule(
            smartDownloads: key.isMovie ? smartDownloads : smartDownloads(for: key),
            keepNext: max(own?.keepNext ?? keepNextEpisodes, 1),
            quality: own?.quality ?? downloadQuality,
            maxEpisodeBytes: key.isMovie ? nil : maxEpisodeBytes,
            audioLanguage: own?.audioLanguage ?? audioLanguage,
            deleteAfterWatching: allowsDeleting && (own?.deleteAfterWatching ?? deleteWatchedEpisodes),
            isCustom: own.map { !$0.isEmpty } ?? false)
    }

    public init(maxConcurrent: Int = 2, wifiOnly: Bool = true, deleteAfterWatching: Bool = false,
                downloadNextEpisode: Bool = false, keepScreenAwake: Bool = true,
                keepDownloadingInBackground: Bool = true, smartDownloads: Bool = true, keepNextEpisodes: Int = 1,
                deleteWatchedFilmsAfterDays: Int? = 7, storageLimitBytes: Int64? = nil, smartDownloadsOff: Set<String> = [],
                downloadQuality: DownloadQuality = .best, maxEpisodeBytes: Int64? = nil, audioLanguage: String? = nil,
                deleteWatchedEpisodes: Bool = true, allowsDeleting: Bool = true, followOtherDevices: Bool = true,
                window: DownloadWindow = .anyTime, fetchSubtitles: Bool = true, showRules: [String: ShowDownloadRule] = [:]) {
        self.maxConcurrent = maxConcurrent
        self.wifiOnly = wifiOnly
        self.deleteAfterWatching = deleteAfterWatching
        self.downloadNextEpisode = downloadNextEpisode
        self.keepScreenAwake = keepScreenAwake
        self.keepDownloadingInBackground = keepDownloadingInBackground
        self.smartDownloads = smartDownloads
        self.keepNextEpisodes = keepNextEpisodes
        self.deleteWatchedFilmsAfterDays = deleteWatchedFilmsAfterDays
        self.storageLimitBytes = storageLimitBytes
        self.smartDownloadsOff = smartDownloadsOff
        self.downloadQuality = downloadQuality
        self.maxEpisodeBytes = maxEpisodeBytes
        self.audioLanguage = audioLanguage
        self.deleteWatchedEpisodes = deleteWatchedEpisodes
        self.allowsDeleting = allowsDeleting
        self.followOtherDevices = followOtherDevices
        self.window = window
        self.fetchSubtitles = fetchSubtitles
        self.showRules = showRules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DownloadSettings()
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? d.maxConcurrent
        wifiOnly = try c.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? d.wifiOnly
        deleteAfterWatching = try c.decodeIfPresent(Bool.self, forKey: .deleteAfterWatching) ?? d.deleteAfterWatching
        downloadNextEpisode = try c.decodeIfPresent(Bool.self, forKey: .downloadNextEpisode) ?? d.downloadNextEpisode
        keepScreenAwake = try c.decodeIfPresent(Bool.self, forKey: .keepScreenAwake) ?? d.keepScreenAwake
        keepDownloadingInBackground = try c.decodeIfPresent(Bool.self, forKey: .keepDownloadingInBackground)
            ?? d.keepDownloadingInBackground
        // Saves from before Smart Downloads: on unless both old switches were off on purpose.
        if let smart = try c.decodeIfPresent(Bool.self, forKey: .smartDownloads) {
            smartDownloads = smart
        } else if c.contains(.deleteAfterWatching) || c.contains(.downloadNextEpisode) {
            smartDownloads = deleteAfterWatching || downloadNextEpisode
        } else {
            smartDownloads = d.smartDownloads
        }
        keepNextEpisodes = try c.decodeIfPresent(Int.self, forKey: .keepNextEpisodes) ?? d.keepNextEpisodes
        if c.contains(.deleteWatchedFilmsAfterDays) {
            deleteWatchedFilmsAfterDays = try c.decodeIfPresent(Int.self, forKey: .deleteWatchedFilmsAfterDays)
        } else {
            deleteWatchedFilmsAfterDays = d.deleteWatchedFilmsAfterDays
        }
        storageLimitBytes = try c.decodeIfPresent(Int64.self, forKey: .storageLimitBytes)
        smartDownloadsOff = try c.decodeIfPresent(Set<String>.self, forKey: .smartDownloadsOff) ?? []
        // A value written by a newer build falls back to the default instead of failing the whole decode.
        downloadQuality = (try? c.decodeIfPresent(DownloadQuality.self, forKey: .downloadQuality)) ?? d.downloadQuality
        maxEpisodeBytes = (try? c.decodeIfPresent(Int64.self, forKey: .maxEpisodeBytes)) ?? nil
        audioLanguage = (try? c.decodeIfPresent(String.self, forKey: .audioLanguage)) ?? nil
        deleteWatchedEpisodes = (try? c.decodeIfPresent(Bool.self, forKey: .deleteWatchedEpisodes)) ?? d.deleteWatchedEpisodes
        allowsDeleting = (try? c.decodeIfPresent(Bool.self, forKey: .allowsDeleting)) ?? d.allowsDeleting
        followOtherDevices = (try? c.decodeIfPresent(Bool.self, forKey: .followOtherDevices)) ?? d.followOtherDevices
        window = (try? c.decodeIfPresent(DownloadWindow.self, forKey: .window)) ?? d.window
        fetchSubtitles = (try? c.decodeIfPresent(Bool.self, forKey: .fetchSubtitles)) ?? d.fetchSubtitles
        showRules = (try? c.decodeIfPresent([String: ShowDownloadRule].self, forKey: .showRules)) ?? [:]
    }

    // Writes nil optionals as explicit nulls, so "Never" survives a reload.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxConcurrent, forKey: .maxConcurrent)
        try c.encode(wifiOnly, forKey: .wifiOnly)
        try c.encode(deleteAfterWatching, forKey: .deleteAfterWatching)
        try c.encode(downloadNextEpisode, forKey: .downloadNextEpisode)
        try c.encode(keepScreenAwake, forKey: .keepScreenAwake)
        try c.encode(keepDownloadingInBackground, forKey: .keepDownloadingInBackground)
        try c.encode(smartDownloads, forKey: .smartDownloads)
        try c.encode(keepNextEpisodes, forKey: .keepNextEpisodes)
        try c.encode(deleteWatchedFilmsAfterDays, forKey: .deleteWatchedFilmsAfterDays)
        try c.encode(storageLimitBytes, forKey: .storageLimitBytes)
        try c.encode(smartDownloadsOff, forKey: .smartDownloadsOff)
        try c.encode(downloadQuality, forKey: .downloadQuality)
        try c.encode(maxEpisodeBytes, forKey: .maxEpisodeBytes)
        try c.encode(audioLanguage, forKey: .audioLanguage)
        try c.encode(deleteWatchedEpisodes, forKey: .deleteWatchedEpisodes)
        try c.encode(allowsDeleting, forKey: .allowsDeleting)
        try c.encode(followOtherDevices, forKey: .followOtherDevices)
        try c.encode(window, forKey: .window)
        try c.encode(fetchSubtitles, forKey: .fetchSubtitles)
        try c.encode(showRules, forKey: .showRules)
    }

    private enum CodingKeys: String, CodingKey {
        case maxConcurrent, wifiOnly, deleteAfterWatching, downloadNextEpisode, keepScreenAwake, keepDownloadingInBackground
        case smartDownloads, keepNextEpisodes, deleteWatchedFilmsAfterDays, storageLimitBytes, smartDownloadsOff
        case downloadQuality, maxEpisodeBytes, audioLanguage, deleteWatchedEpisodes, allowsDeleting, followOtherDevices
        case window, fetchSubtitles, showRules
    }

    /// `maxConcurrent` clamped to something sane.
    public var concurrencyLimit: Int { min(max(maxConcurrent, 1), 8) }
}

/// The highest resolution a download fetches.
public enum DownloadQuality: String, Codable, Sendable, CaseIterable {
    case best, p2160 = "2160p", p1080 = "1080p", p720 = "720p", p480 = "480p"

    /// The cap as a release resolution ("1080p"); nil for no cap (the release order decides, as for streaming).
    public var maxResolution: String? { self == .best ? nil : rawValue }

    public var title: String {
        switch self {
        case .best: "No Limit"
        case .p2160: "4K"
        default: rawValue
        }
    }
}

/// When downloads Bluebox starts by itself (Smart Downloads, new episodes,
/// upgrades) may transfer. Downloads you start yourself ignore it.
public enum DownloadWindow: String, Codable, Sendable, CaseIterable {
    case anyTime, overnight, whileCharging

    /// 1 am up to 6 am, device time.
    public static let overnightHours = 1..<6

    public var title: String {
        switch self {
        case .anyTime: "Any Time"
        case .overnight: "Overnight (1–6 am)"
        case .whileCharging: "While Charging"
        }
    }

    /// Whether automatic downloads may run at `date`.
    public func isOpen(at date: Date, isCharging: Bool, calendar: Calendar = .current) -> Bool {
        switch self {
        case .anyTime: true
        case .overnight: Self.overnightHours.contains(calendar.component(.hour, from: date))
        case .whileCharging: isCharging
        }
    }
}

/// One show's own download rules. Every field left nil follows the defaults
/// in Settings › Downloads; "Use defaults" clears them all.
public struct ShowDownloadRule: Codable, Sendable, Equatable {
    public var smartDownloads: Bool?
    public var keepNext: Int?
    public var quality: DownloadQuality?
    public var audioLanguage: String?
    public var deleteAfterWatching: Bool?

    public init(smartDownloads: Bool? = nil, keepNext: Int? = nil, quality: DownloadQuality? = nil,
                audioLanguage: String? = nil, deleteAfterWatching: Bool? = nil) {
        self.smartDownloads = smartDownloads; self.keepNext = keepNext; self.quality = quality
        self.audioLanguage = audioLanguage; self.deleteAfterWatching = deleteAfterWatching
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smartDownloads = (try? c.decodeIfPresent(Bool.self, forKey: .smartDownloads)) ?? nil
        keepNext = (try? c.decodeIfPresent(Int.self, forKey: .keepNext)) ?? nil
        quality = (try? c.decodeIfPresent(DownloadQuality.self, forKey: .quality)) ?? nil
        audioLanguage = (try? c.decodeIfPresent(String.self, forKey: .audioLanguage)) ?? nil
        deleteAfterWatching = (try? c.decodeIfPresent(Bool.self, forKey: .deleteAfterWatching)) ?? nil
    }

    /// Nothing overridden.
    public var isEmpty: Bool {
        smartDownloads == nil && keepNext == nil && quality == nil && audioLanguage == nil && deleteAfterWatching == nil
    }
}

/// The rules in force for one title, after its show's overrides.
public struct DownloadRule: Sendable, Equatable {
    public var smartDownloads: Bool
    public var keepNext: Int
    public var quality: DownloadQuality
    /// Episodes only.
    public var maxEpisodeBytes: Int64?
    public var audioLanguage: String?
    /// Watched episodes go (only when Smart Downloads may delete at all).
    public var deleteAfterWatching: Bool
    /// The show has overrides of its own.
    public var isCustom: Bool

    public init(smartDownloads: Bool, keepNext: Int, quality: DownloadQuality, maxEpisodeBytes: Int64?,
                audioLanguage: String?, deleteAfterWatching: Bool, isCustom: Bool) {
        self.smartDownloads = smartDownloads; self.keepNext = keepNext; self.quality = quality
        self.maxEpisodeBytes = maxEpisodeBytes; self.audioLanguage = audioLanguage
        self.deleteAfterWatching = deleteAfterWatching; self.isCustom = isCustom
    }
}
