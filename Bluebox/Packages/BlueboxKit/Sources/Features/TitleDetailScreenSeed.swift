#if DEBUG
import Domain
import Downloads
import Foundation
import MediaSources

extension AppModel {
    /// For screenshots and design review (`-ui-testing -seed-screens`): Harbor
    /// Lights partway through season 2 with playable episodes, some downloaded,
    /// one downloading and one queued; finished movies and a second show on
    /// the Downloads page. Debug builds only; the queue is frozen so nothing
    /// actually transfers.
    public func seedScreensForReview() async {
        let harbor = 9_100_001, orbit = 9_100_002
        let now = Date()
        let runtime: (Int) -> TimeInterval = { n in TimeInterval((44 + (n % 3) * 5) * 60) }

        // Progress: season 1 watched, S2E1–2 watched, S2E3 under half way.
        var progress: [WatchProgress] = (1...8).map { n in
            WatchProgress(key: .episode(seriesID: harbor, season: 1, episode: n), position: runtime(n), duration: runtime(n),
                          isCompleted: true, updatedAt: now.addingTimeInterval(Double(-60 * (10 - n))))
        }
        progress += [1, 2].map { n in
            WatchProgress(key: .episode(seriesID: harbor, season: 2, episode: n), position: runtime(n), duration: runtime(n),
                          isCompleted: true, updatedAt: now.addingTimeInterval(Double(-3_600 * (4 - n))))
        }
        progress.append(WatchProgress(key: .episode(seriesID: harbor, season: 2, episode: 3), position: runtime(3) * 0.45,
                                      duration: runtime(3), updatedAt: now))
        // Enough history for Home's personal rows: two finished films, The Long
        // Orbit up to S1E3 (its S1E4 just aired), and a thumbs-up.
        let day: TimeInterval = 86_400
        progress += [(45745, 3.0), (10378, 12.0)].map { id, days in
            WatchProgress(key: .movie(tmdbID: id), position: 5_000, duration: 5_000, isCompleted: true,
                          updatedAt: now.addingTimeInterval(-days * day))
        }
        progress += (1...3).map { n in
            WatchProgress(key: .episode(seriesID: orbit, season: 1, episode: n), position: 2_900, duration: 2_900,
                          isCompleted: true, updatedAt: now.addingTimeInterval(-Double(4 - n) * 3_600 - 1_800))
        }
        for p in progress { _ = try? await store.save(p) }
        trakt.setRating(RatingThumb.up.rating, for: .series(tmdbID: harbor))
        let orbitNext = MediaKey.episode(seriesID: orbit, season: 1, episode: 4)
        features.tracker.lastSeen[MediaKey.series(tmdbID: orbit).rawValue] = orbitNext.rawValue
        features.tracker.notified.insert(orbitNext.rawValue)

        // Every Harbor Lights episode plays (and downloads) from a link.
        for s in 1...2 {
            for n in 1...8 {
                let url = URL(string: "https://media.example.com/harbor-lights/s\(s)e\(n).mp4")!
                try? await directLinks.add(.init(url: url, title: "Harbor Lights S\(s)E\(n)",
                                                 mediaKey: .episode(seriesID: harbor, season: s, episode: n)))
            }
        }

        func record(_ key: MediaKey, title: String, subtitle: String?, state: DownloadRecord.State, fraction: Double,
                    bytes: Int64, ageHours: Double) -> DownloadRecord {
            let variant = MediaVariant(id: "review-\(key.rawValue)", sourceID: SourceID("direct-urls"), mediaKey: key,
                                       displayName: title, container: "mp4", resolution: "1080p", sizeBytes: bytes,
                                       location: .remote, isDownloadable: true)
            let created = now.addingTimeInterval(-ageHours * 3_600)
            return DownloadRecord(id: DownloadRecord.id(for: variant), mediaKey: key, title: title, subtitle: subtitle,
                                  origin: variant, state: state, receivedBytes: Int64(Double(bytes) * fraction),
                                  expectedBytes: bytes, createdAt: created,
                                  fileName: state == .completed ? "review-\(key.rawValue).mp4" : nil,
                                  subtitleFiles: [], artworkURL: nil, order: created.timeIntervalSince1970,
                                  completedAt: state == .completed ? created : nil)
        }
        let episode = { (series: Int, s: Int, e: Int) in MediaKey.episode(seriesID: series, season: s, episode: e) }
        let records: [DownloadRecord] = [
            record(episode(harbor, 2, 1), title: "Harbor Lights", subtitle: "S2·E1", state: .completed, fraction: 1,
                   bytes: 1_240_000_000, ageHours: 30),
            record(episode(harbor, 2, 3), title: "Harbor Lights", subtitle: "S2·E3", state: .downloading, fraction: 0.62,
                   bytes: 1_310_000_000, ageHours: 1),
            record(episode(harbor, 2, 4), title: "Harbor Lights", subtitle: "S2·E4", state: .queued, fraction: 0,
                   bytes: 1_180_000_000, ageHours: 0.9),
            record(.movie(tmdbID: 133701), title: "Tears of Steel", subtitle: nil, state: .downloading, fraction: 0.38,
                   bytes: 740_000_000, ageHours: 0.5),
            record(.movie(tmdbID: 9761), title: "Elephants Dream", subtitle: nil, state: .queued, fraction: 0,
                   bytes: 410_000_000, ageHours: 0.4),
            record(.movie(tmdbID: 45745), title: "Sintel", subtitle: nil, state: .completed, fraction: 1,
                   bytes: 2_400_000_000, ageHours: 50),
            record(.movie(tmdbID: 10378), title: "Big Buck Bunny", subtitle: nil, state: .completed, fraction: 1,
                   bytes: 1_100_000_000, ageHours: 70),
            record(.movie(tmdbID: 9_000_005), title: "Small Hours", subtitle: nil, state: .completed, fraction: 1,
                   bytes: 1_600_000_000, ageHours: 90),
            record(episode(orbit, 1, 1), title: "The Long Orbit", subtitle: "S1·E1 · Burn", state: .completed, fraction: 1,
                   bytes: 1_380_000_000, ageHours: 100),
            record(episode(orbit, 1, 2), title: "The Long Orbit", subtitle: "S1·E2 · Mass Budget", state: .completed,
                   fraction: 1, bytes: 1_350_000_000, ageHours: 99),
            record(episode(orbit, 1, 3), title: "The Long Orbit", subtitle: "S1·E3 · Coast Phase", state: .completed,
                   fraction: 1, bytes: 1_420_000_000, ageHours: 98),
        ]
        let id = { (k: MediaKey) in records.first { $0.mediaKey == k }!.id }
        downloads.debugSeed(
            records,
            live: [id(episode(harbor, 2, 3)): DownloadLiveStats(bytesPerSecond: 4_200_000, peers: 31),
                   id(.movie(tmdbID: 133701)): DownloadLiveStats(bytesPerSecond: 2_600_000, peers: 12)],
            waits: [id(episode(harbor, 2, 4)): .queued(position: 1), id(.movie(tmdbID: 9761)): .wifi])
        noteLibraryChanged()
    }
}
#endif
