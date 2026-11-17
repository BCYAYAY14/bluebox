#if DEBUG
import Domain
import Downloads
import Foundation
import MediaSources
import Metadata

extension AppModel {
    /// For the README and docs-site graphics (`-ui-testing -showcase`, and
    /// `PromoSnapshotTests`): the showcase catalog (Blender Studio's Creative
    /// Commons films with their TMDB artwork), a few films part watched, My
    /// List, finished downloads and two still coming in. Every film plays from
    /// a placeholder link, so title pages offer Play. `family` adds the
    /// profiles Who's Watching shows. Debug builds only; the download queue is
    /// frozen so nothing transfers.
    public func seedShowcaseForReview(family: Bool = false) async {
        SampleMetadataProvider.showcase = true
        let now = Date()
        let titles = SampleMetadataProvider.titles
        try? await store.store(titles)
        let watching: [(Int, Double, Double, Double)] = [   // id, position, duration, hours ago
            (358332, 410, 730, 1), (133701, 260, 734, 5), (457784, 120, 231, 26), (891761, 300, 629, 50),
        ]
        for (id, position, duration, hours) in watching {
            _ = try? await store.save(WatchProgress(key: .movie(tmdbID: id), position: position, duration: duration,
                                                    updatedAt: now.addingTimeInterval(-hours * 3_600)))
        }
        for t in titles {
            try? await directLinks.add(.init(url: URL(string: "https://media.example.com/\(t.key.tmdbID ?? 0).mp4")!,
                                             title: t.name, mediaKey: t.key))
        }
        for id in [45745, 406956, 1177628, 10378] {
            if let t = titles.first(where: { $0.key == .movie(tmdbID: id) }) { try? await store.setWatchlisted(t, true) }
        }

        func record(_ id: Int, _ name: String, state: DownloadRecord.State, fraction: Double, bytes: Int64, hours: Double) -> DownloadRecord {
            let key = MediaKey.movie(tmdbID: id)
            let variant = MediaVariant(id: "showcase-\(id)", sourceID: SourceID("direct-urls"), mediaKey: key, displayName: name,
                                       container: "mp4", resolution: "1080p", sizeBytes: bytes, location: .remote, isDownloadable: true)
            let created = now.addingTimeInterval(-hours * 3_600)
            let art = titles.first { $0.key == key }?.backdrop.flatMap { URL(string: $0.path) }
            return DownloadRecord(id: DownloadRecord.id(for: variant), mediaKey: key, title: name, subtitle: nil, origin: variant,
                                  state: state, receivedBytes: Int64(Double(bytes) * fraction), expectedBytes: bytes,
                                  createdAt: created, fileName: state == .completed ? "showcase-\(id).mp4" : nil, subtitleFiles: [],
                                  artworkURL: art, order: created.timeIntervalSince1970, completedAt: state == .completed ? created : nil)
        }
        let records = [
            record(9761, "Elephants Dream", state: .downloading, fraction: 0.62, bytes: 820_000_000, hours: 0.5),
            record(717986, "Coffee Run", state: .downloading, fraction: 0.21, bytes: 310_000_000, hours: 0.4),
            record(45745, "Sintel", state: .completed, fraction: 1, bytes: 2_400_000_000, hours: 50),
            record(10378, "Big Buck Bunny", state: .completed, fraction: 1, bytes: 1_100_000_000, hours: 70),
            record(406956, "Caminandes: Llamigos", state: .completed, fraction: 1, bytes: 380_000_000, hours: 80),
            record(1177628, "Wing It!", state: .completed, fraction: 1, bytes: 450_000_000, hours: 90),
        ]
        downloads.debugSeed(records, live: [records[0].id: DownloadLiveStats(bytesPerSecond: 4_200_000, peers: 31),
                                            records[1].id: DownloadLiveStats(bytesPerSecond: 2_600_000, peers: 12)])

        var me = currentProfile
        me.name = "Alex"
        updateProfile(me)
        // Several profiles open on Who's Watching, so only shots of it have them.
        if family {
            addProfile(name: "Sam", symbol: "star.fill", color: 2, maturity: .age16)
            addProfile(name: "Mia", symbol: "heart.fill", color: 13)
            addProfile(name: "Kids", symbol: "pawprint.fill", color: 8, maturity: .age7, isKids: true)
        }
        noteLibraryChanged()
    }
}
#endif
