import Domain
@testable import Downloads
import Foundation
import Testing

/// The queue's side of the UI review: automatic downloads keep to the
/// download window and Wi‑Fi, drag to reorder, stall reasons, and subtitles
/// saved beside a download.
@Suite(.serialized) struct SmartQueueTests {
    static let hash = String(repeating: "d", count: 40)

    func record(_ id: String, automatic: Bool = false, order: Double, torrent: Bool = false) -> DownloadRecord {
        let variantID = torrent ? "\(Self.hash):\(Int(order))" : "https://example.com/\(id).mp4"
        let v = MediaVariant(id: variantID, sourceID: SourceID("addons"), mediaKey: nil, displayName: id, location: .remote,
                             isDownloadable: true)
        var r = DownloadRecord(id: id, mediaKey: nil, title: id, subtitle: nil, origin: v, state: .queued, receivedBytes: 0,
                               expectedBytes: nil, createdAt: Date(timeIntervalSince1970: order), fileName: nil, subtitleFiles: [],
                               order: order)
        if automatic { r.isAutomatic = true }
        return r
    }

    @Test func automaticDownloadsWaitForTheWindowAndWiFi() {
        let records = [record("mine", order: 1), record("auto", automatic: true, order: 2)]
        let settings = DownloadSettings(maxConcurrent: 4, wifiOnly: false, window: .overnight)
        let closed = DownloadScheduler.plan(records: records, running: [], settings: settings,
                                            conditions: DownloadConditions(automaticWindowOpen: false))
        #expect(closed.start == ["mine"])
        #expect(closed.waits["auto"] == .window(.overnight))
        #expect(DownloadWait.window(.overnight).message == "Waiting for overnight (1–6 am)")
        let open = DownloadScheduler.plan(records: records, running: [], settings: settings, conditions: DownloadConditions())
        #expect(Set(open.start) == ["mine", "auto"])
        // On mobile data with Wi‑Fi Only off, yours may go; automatic ones wait for Wi‑Fi.
        let mobile = DownloadScheduler.plan(records: records, running: [], settings: settings,
                                            conditions: DownloadConditions(isExpensive: true))
        #expect(mobile.start == ["mine"] && mobile.waits["auto"] == .wifi)
    }

    @Test func stallReasonsNameTheCause() {
        var r = record("t", order: 1, torrent: true)
        r.state = .downloading
        #expect(DownloadStall.reason(r, stats: DownloadLiveStats(peers: 0), idle: 30) == nil)
        #expect(DownloadStall.reason(r, stats: DownloadLiveStats(peers: 0), idle: 130) == "No peers for 2 min")
        #expect(DownloadStall.reason(r, stats: DownloadLiveStats(peers: 4), idle: 90) == "Peers aren't sending for 1 min")
        let http = { () -> DownloadRecord in var h = record("h", order: 2); h.state = .downloading; return h }()
        #expect(DownloadStall.reason(http, stats: nil, idle: 600) == "No data for 10 min")
        r.state = .paused
        #expect(DownloadStall.reason(r, stats: nil, idle: 600) == nil)
    }

    func manager() -> DownloadManager {
        let m = DownloadManager(directory: DownloadsTests.tempDir(), configuration: .ephemeral, settings: DownloadSettings(maxConcurrent: 1),
                                startsQueue: false, monitorsNetwork: false, freeSpace: { _ in 100_000_000_000 })
        return m
    }

    func variant(_ n: Int) -> MediaVariant {
        MediaVariant(id: "https://example.com/\(n).mp4", sourceID: SourceID("addons"), mediaKey: .movie(tmdbID: n),
                     displayName: "Film \(n)", location: .remote, isDownloadable: true)
    }

    @Test func dragToReorderKeepsTheQueuesSlots() throws {
        let m = manager()
        let ids = try (1...4).map { try m.enqueue(variant($0), key: .movie(tmdbID: $0), title: "F\($0)").id }
        // Move the last to the top of the first three.
        m.reorder([ids[3], ids[0], ids[1], ids[2]])
        #expect(m.queue().map(\.id) == [ids[3], ids[0], ids[1], ids[2]])
        // Reordering a subset leaves the others where they were.
        m.reorder([ids[2], ids[0]])
        #expect(m.queue().map(\.id) == [ids[3], ids[2], ids[1], ids[0]])
    }

    @Test func downloadFirstStopsAnAutomaticDownloadWaiting() throws {
        let m = manager()
        let r = try m.enqueue(variant(1), key: .movie(tmdbID: 1), title: "F", automatic: true, replaces: "old")
        #expect(m.record(id: r.id)?.isAutomatic == true && m.record(id: r.id)?.replaces == "old")
        m.prioritize(r.id)
        #expect(m.record(id: r.id)?.isAutomatic == nil)
    }

    @Test func subtitlesAreSavedBesideADownload() throws {
        let m = manager()
        let r = try m.enqueue(variant(1), key: .movie(tmdbID: 1), title: "F")
        try m.addSubtitle(Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8), languageCode: "en", label: "English", format: "srt", to: r.id)
        let files = try #require(m.record(id: r.id)?.subtitleFiles)
        #expect(files.count == 1 && files[0].languageCode == "en")
        #expect(FileManager.default.fileExists(atPath: m.subtitleURL(files[0]).path))
    }
}
