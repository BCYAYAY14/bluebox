import Addons
import DesignSystem
import Domain
import Downloads
import Foundation
import Persistence

/// Sizes for the season menu ("Download Remaining · about 7.2 GB"). A real
/// size wins (a download already started knows its file); otherwise the
/// episode's runtime times a rate taken from the best release the add-ons
/// found for one episode, or a typical rate for the preferred quality.
struct SeasonSizeEstimate: Sendable, Equatable {
    /// Bytes per minute of video, from a release whose size and runtime are known.
    var bytesPerMinute: Double?
    /// Used when no release has been seen: the preferred quality's usual rate.
    var fallbackBytesPerMinute: Double

    /// Typical sizes per minute of WEB-DL releases by quality.
    static func typicalBytesPerMinute(resolution: String?) -> Double {
        switch resolution?.lowercased() {
        case "2160p", "4k": 110_000_000
        case "720p": 15_000_000
        case "480p", "sd": 7_000_000
        default: 30_000_000  // 1080p: about 1.4 GB for 45 minutes
        }
    }

    /// Minutes assumed for an episode whose runtime isn't known.
    static let defaultRuntime = 45

    func bytes(for episode: Episode, knownSize: Int64?) -> Int64 {
        if let knownSize, knownSize > 0 { return knownSize }
        let minutes = Double(episode.runtimeMinutes ?? Self.defaultRuntime)
        return Int64(minutes * (bytesPerMinute ?? fallbackBytesPerMinute))
    }

    func bytes(for episodes: [Episode], knownSizes: [MediaKey: Int64]) -> Int64 {
        episodes.reduce(0) { $0 + bytes(for: $1, knownSize: knownSizes[$1.key]) }
    }

    /// Rate from one release of an episode with a known runtime.
    static func rate(releaseBytes: Int64?, runtimeMinutes: Int?) -> Double? {
        guard let releaseBytes, releaseBytes > 0 else { return nil }
        return Double(releaseBytes) / Double(max(runtimeMinutes ?? defaultRuntime, 1))
    }
}

/// What the season ⋯ menu offers, worked out from the season's episodes,
/// progress and downloads.
struct SeasonActionPlan: Equatable {
    /// Unwatched episodes with no download yet.
    var remaining: [Episode]
    /// Every episode with no download yet.
    var notDownloaded: [Episode]
    /// Downloads of this season in any state.
    var downloads: [DownloadRecord]
    var allWatched: Bool
    var anyWatched: Bool

    init(episodes: [Episode], progress: [MediaKey: WatchProgress], downloads: (MediaKey) -> DownloadRecord?,
         downloadable: Set<MediaKey>) {
        var remaining: [Episode] = [], notDownloaded: [Episode] = [], records: [DownloadRecord] = []
        for ep in episodes {
            if let r = downloads(ep.key), !r.isFailed {
                records.append(r)
                continue
            }
            guard downloadable.contains(ep.key) else { continue }
            notDownloaded.append(ep)
            if progress[ep.key]?.isCompleted != true { remaining.append(ep) }
        }
        self.remaining = remaining
        self.notDownloaded = notDownloaded
        self.downloads = records
        allWatched = !episodes.isEmpty && episodes.allSatisfy { progress[$0.key]?.isCompleted == true }
        anyWatched = episodes.contains { progress[$0.key].map { $0.isCompleted || $0.position > 0 } ?? false }
    }

    var downloadedBytes: Int64 {
        downloads.reduce(0) { $0 + ($1.state == .completed ? ($1.expectedBytes ?? $1.receivedBytes) : $1.receivedBytes) }
    }

    /// "about 6 GB", "about 11 GB", "about 850 MB": an estimate shouldn't look precise.
    static func sizeLabel(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 10 { return "about \(Int(gb.rounded())) GB" }
        if gb >= 1 {
            let tenth = (gb * 10).rounded() / 10
            return tenth == tenth.rounded() ? "about \(Int(tenth)) GB" : "about \(String(format: "%.1f", tenth)) GB"
        }
        let mb = max(Int((Double(bytes) / 1_000_000 / 10).rounded()) * 10, 10)
        return "about \(mb) MB"
    }
}

extension AppModel {
    /// Marks episodes watched (finished at their full length) or unwatched
    /// (progress reset, which syncs as a newer record, like removing from
    /// Continue Watching).
    func setWatched(_ episodes: [Episode], watched: Bool, current: [MediaKey: WatchProgress]) async throws {
        let now = Date.now
        for ep in episodes {
            let old = current[ep.key]
            if watched {
                guard old?.isCompleted != true else { continue }
                let duration = old?.duration ?? ep.runtimeMinutes.map { TimeInterval($0 * 60) }
                let record = WatchProgress(key: ep.key, position: duration ?? 0, duration: duration, isCompleted: true,
                                           updatedAt: now, deviceID: prefs.deviceID)
                _ = try await store.save(record)
            } else {
                guard let old, old.isCompleted || old.position > 0 else { continue }
                let reset = WatchProgress(key: ep.key, position: 0, duration: old.duration, updatedAt: now, deviceID: prefs.deviceID)
                _ = try await store.save(reset)
            }
        }
        noteLibraryChanged()
        reportWatchedToServers(episodes.map(\.key), watched: watched)  // Jellyfin and Emby
        if watched { downloadsFollowProgress(episodes.map(\.key), fromOtherDevice: false) }  // Smart Downloads
    }

    /// What the episodes' progress looks like once marked watched or
    /// unwatched, drawn before the save finishes (`setWatched` does the saving).
    static func progressAfterMarking(_ episodes: [Episode], watched: Bool, current: [MediaKey: WatchProgress],
                                     deviceID: String, now: Date = .now) -> [MediaKey: WatchProgress] {
        var out = current
        for ep in episodes {
            let old = current[ep.key]
            if watched {
                let duration = old?.duration ?? ep.runtimeMinutes.map { TimeInterval($0 * 60) }
                out[ep.key] = WatchProgress(key: ep.key, position: duration ?? 0, duration: duration, isCompleted: true,
                                            updatedAt: now, deviceID: deviceID)
            } else if let old {
                out[ep.key] = WatchProgress(key: ep.key, position: 0, duration: old.duration, updatedAt: now, deviceID: deviceID)
            }
        }
        return out
    }

    // Whole seasons download through `downloadSeason` (SeasonDownloads.swift).

    /// Best release's size for an episode, from the add-ons (cached for a while
    /// and shared with Play, so this also warms the release list).
    func bestReleaseBytes(for key: MediaKey) async -> Int64? {
        guard addonSettings.isEnabled else { return nil }
        return (try? await releases(for: key))?.first?.sizeBytes
    }
}
