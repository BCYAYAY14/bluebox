import Foundation

/// Decides which episode "Play" means for a series.
public enum SeriesCursor {
    public struct Target: Equatable, Sendable {
        public let key: MediaKey
        public let season: Int
        public let episode: Int
        /// True when there is a saved position to resume.
        public let isResume: Bool
        public init(key: MediaKey, season: Int, episode: Int, isResume: Bool) {
            self.key = key; self.season = season; self.episode = episode; self.isResume = isResume
        }
    }

    /// Episode after `(season, episode)`, crossing into the next regular season.
    /// Specials (season 0) are never chosen automatically.
    public static func next(after season: Int, _ episode: Int, seasons: [SeasonSummary]) -> (season: Int, episode: Int)? {
        let regular = seasons.filter { $0.number > 0 && $0.episodeCount > 0 }.sorted { $0.number < $1.number }
        if let current = regular.first(where: { $0.number == season }), episode < current.episodeCount {
            return (season, episode + 1)
        }
        if let following = regular.first(where: { $0.number > season }) {
            return (following.number, 1)
        }
        return nil
    }

    /// - The most recently touched episode, if it's resumable.
    /// - Otherwise the episode after the most recently finished one.
    /// - Otherwise the first episode of the first regular season.
    /// Returns nil when the series has no episodes or the user finished the last one
    /// (callers then offer "Watch again" from S1E1).
    public static func target(seriesID: Int, progress: [WatchProgress], seasons: [SeasonSummary],
                              policy: ProgressPolicy = .standard) -> Target? {
        target(series: .series(tmdbID: seriesID), progress: progress, seasons: seasons, policy: policy)
    }

    /// The same, for any series key: TMDB (`tmdb:tv:…`) or Cinemeta (`imdb:tv:tt…`).
    public static func target(series: MediaKey, progress: [WatchProgress], seasons: [SeasonSummary],
                              policy: ProgressPolicy = .standard) -> Target? {
        guard series.isSeries else { return nil }
        func episode(_ s: Int, _ e: Int) -> MediaKey { series.episode(season: s, episode: e) ?? series }
        let latest = progress
            .filter { $0.key.seriesKey == series }
            .max { $0.updatedAt < $1.updatedAt }
        if let latest, let (s, e) = latest.key.episodeNumbers {
            if policy.resumePosition(for: latest) != nil {
                return Target(key: latest.key, season: s, episode: e, isResume: true)
            }
            let finished = latest.isCompleted || (latest.duration.map { policy.isComplete(position: latest.position, duration: $0) } ?? false)
            if finished {
                guard let (ns, ne) = next(after: s, e, seasons: seasons) else { return nil }
                return Target(key: episode(ns, ne), season: ns, episode: ne, isResume: false)
            }
            // Barely started: restart that same episode.
            return Target(key: latest.key, season: s, episode: e, isResume: false)
        }
        guard let first = seasons.filter({ $0.number > 0 && $0.episodeCount > 0 }).min(by: { $0.number < $1.number }) else {
            return nil
        }
        return Target(key: episode(first.number, 1), season: first.number, episode: 1, isResume: false)
    }
}
