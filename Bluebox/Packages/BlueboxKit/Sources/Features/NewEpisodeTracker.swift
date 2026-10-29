import Domain
import Downloads
import Foundation
import Metadata

// New episodes: Coming Soon, New Episodes, "Remind Me", alerts and
// auto-download. Shows are followed when they're on My List, have recent
// progress, or have a reminder. TMDB's show details give each one's last
// and next episode; a check compares the last aired episode with the one
// seen before.

/// Settings › Notifications (and the per-show auto-download switch).
public struct NewEpisodeSettings: Codable, Equatable, Sendable {
    /// Alert when a followed show has a new episode.
    public var notify = true
    /// Download new episodes on Wi‑Fi, for shows without their own choice.
    public var autoDownloadByDefault = false
    /// Per-show choice (series key raw value → on/off), overriding the default.
    public var autoDownloadShows: [String: Bool] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notify = (try? c.decodeIfPresent(Bool.self, forKey: .notify)) ?? true
        autoDownloadByDefault = (try? c.decodeIfPresent(Bool.self, forKey: .autoDownloadByDefault)) ?? false
        autoDownloadShows = (try? c.decodeIfPresent([String: Bool].self, forKey: .autoDownloadShows)) ?? [:]
    }

    public func autoDownloads(_ series: MediaKey) -> Bool {
        autoDownloadShows[series.rawValue] ?? autoDownloadByDefault
    }
}

/// What the new-episode check remembers between runs.
struct EpisodeTrackerState: Codable, Equatable, Sendable {
    /// Series key → the last aired episode seen.
    var lastSeen: [String: String] = [:]
    /// Episode and movie keys already announced.
    var notified: Set<String> = []
    /// Titles with "Remind Me" on.
    var reminders: Set<String> = []
    /// Episodes to download once on Wi‑Fi.
    var pendingDownloads: [String] = []
    var lastCheck: Date?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSeen = (try? c.decodeIfPresent([String: String].self, forKey: .lastSeen)) ?? [:]
        notified = (try? c.decodeIfPresent(Set<String>.self, forKey: .notified)) ?? []
        reminders = (try? c.decodeIfPresent(Set<String>.self, forKey: .reminders)) ?? []
        pendingDownloads = (try? c.decodeIfPresent([String].self, forKey: .pendingDownloads)) ?? []
        lastCheck = try? c.decodeIfPresent(Date.self, forKey: .lastCheck)
    }
}

/// One row of Coming Soon.
public struct ComingSoonItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case episode(Episode)
        case movie
    }
    public let title: Title
    public let kind: Kind
    public let date: Date
    /// On My List, followed, or reminded (as opposed to a general upcoming film).
    public let isYours: Bool

    public var id: String {
        switch kind {
        case .episode(let e): e.key.rawValue
        case .movie: title.key.rawValue
        }
    }

    /// "S2·E5 · Name" for episodes, nil for films.
    public var episodeLine: String? {
        guard case .episode(let e) = kind else { return nil }
        return "\(e.code) · \(e.name)"
    }
}

/// One row of New Episodes.
public struct NewEpisodeItem: Identifiable, Hashable, Sendable {
    public let series: Title
    public let episode: Episode
    public var id: MediaKey { episode.key }
}

/// The pure part of the check, for tests.
public enum NewEpisodeRules {
    /// Announce episodes that aired at most this long ago (older ones are catch-up, not news).
    public static let newWindow: TimeInterval = 7 * 86_400

    /// The newly aired episode to announce, if any.
    /// - Parameter lastSeen: the last aired episode seen at the previous check; nil
    ///   the first time a show is checked (nothing is announced, it's a baseline).
    public static func newEpisode(airing: AiringInfo, lastSeen: MediaKey?, isFirstCheck: Bool, now: Date) -> Episode? {
        guard !isFirstCheck, let last = airing.lastEpisode, let aired = last.airDate,
              aired <= now, now.timeIntervalSince(aired) <= newWindow + 86_400, last.key != lastSeen else { return nil }
        // An older episode reappearing (data corrected) isn't news.
        if let lastSeen, let seen = lastSeen.episodeNumbers,
           (last.seasonNumber, last.number) <= (seen.season, seen.episode) { return nil }
        return last
    }

    /// Episodes to auto-download after `lastSeen` up to `latest`: within the same
    /// season, the ones in between; in a new season, from its first episode.
    /// At most `limit`.
    public static func episodesToDownload(series: MediaKey, latest: Episode, lastSeen: MediaKey?, limit: Int = 10) -> [MediaKey] {
        let start: Int
        if let seen = lastSeen?.episodeNumbers, seen.season == latest.seasonNumber {
            start = seen.episode + 1
        } else {
            start = 1
        }
        guard start <= latest.number else { return [] }
        let numbers = Array(start...latest.number).suffix(limit)
        return numbers.compactMap { series.episode(season: latest.seasonNumber, episode: $0) }
    }

    /// Coming Soon order: soonest first, yours before general films on the same day.
    public static func sortComingSoon(_ items: [ComingSoonItem]) -> [ComingSoonItem] {
        items.sorted { a, b in
            let da = Calendar.current.startOfDay(for: a.date), db = Calendar.current.startOfDay(for: b.date)
            if da != db { return da < db }
            if a.isYours != b.isYours { return a.isYours }
            return a.title.name < b.title.name
        }
    }
}
