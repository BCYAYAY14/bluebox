import Domain
import Foundation
import Metadata
import Playback

/// Small per-profile UI memory: the last tab, the season picked on each show,
/// the My Library section. Kept in UserDefaults (it's only a convenience), under
/// keys that include the profile, so each person returns to their own place.
@MainActor
enum ViewMemory {
    private static func key(_ name: String, _ profile: String) -> String { "bluebox.memory.\(profile).\(name)" }

    static func string(_ name: String, profile: String) -> String? {
        UserDefaults.standard.string(forKey: key(name, profile))
    }

    static func set(_ value: String?, _ name: String, profile: String) {
        UserDefaults.standard.set(value, forKey: key(name, profile))
    }

    static func int(_ name: String, profile: String) -> Int? {
        UserDefaults.standard.object(forKey: key(name, profile)) as? Int
    }

    static func set(_ value: Int?, _ name: String, profile: String) {
        UserDefaults.standard.set(value, forKey: key(name, profile))
    }
}

extension AppTab {
    /// A stable string for `ViewMemory`.
    var memoryValue: String {
        switch self {
        case .home: "home"
        case .shows: "shows"
        case .movies: "movies"
        case .newHot: "newHot"
        case .search: "search"
        case .library: "library"
        case .myList: "myList"
        case .watching: "watching"
        case .downloads: "downloads"
        case .source(let id): "source:" + id.rawValue
        }
    }

    init?(memoryValue v: String) {
        switch v {
        case "home": self = .home
        case "shows": self = .shows
        case "movies": self = .movies
        case "newHot": self = .newHot
        case "search": self = .search
        case "library": self = .library
        case "myList": self = .myList
        case "watching": self = .watching
        case "downloads": self = .downloads
        default:
            guard v.hasPrefix("source:") else { return nil }
            self = .source(SourceID(String(v.dropFirst("source:".count))))
        }
    }
}

extension AppModel {
    /// For pull to refresh (and ⌘R on Mac): drops cached catalogue pages so the
    /// next load asks the service again.
    func refreshCatalog() async {
        if let cached = metadata as? CachedMetadataProvider { await cached.removeAll() }
    }

    /// Plays the episode after `key` (from Continue Watching, once an episode
    /// is done or nearly so). Says so if there isn't one.
    func playNextEpisode(after key: MediaKey, seriesName: String) async {
        // Works for TMDB and Cinemeta (IMDb) keys alike: the next key is built from the series key.
        guard let seriesKey = key.seriesKey, let (s, e) = key.episodeNumbers,
              let detail = try? await metadata.detail(for: seriesKey),
              let (ns, ne) = SeriesCursor.next(after: s, e, seasons: detail.seasons),
              let next = seriesKey.episode(season: ns, episode: ne) else {
            showToast(AppToast("No next episode", message: "That was the last episode of \(seriesName) Bluebox knows about."))
            return
        }
        await play(NowPlayingItem(key: next, title: seriesName, subtitle: "S\(ns)·E\(ne)",
                                  artworkURL: imageURL(detail.title.backdrop, width: 640)), resume: false)
    }
}

extension WatchProgress {
    /// Finished, or close enough that the next episode is what you'd want.
    var isNearlyFinished: Bool { isCompleted || (fraction ?? 0) >= 0.9 }
}
