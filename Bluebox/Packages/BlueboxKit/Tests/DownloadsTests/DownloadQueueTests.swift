import Domain
@testable import Downloads
import Foundation
import Testing

/// Records what the manager asks the torrent runner to do.
final class FakeRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    var log: [String] { lock.withLock { _log } }
    func record(_ s: String) { lock.withLock { _log.append(s) } }
    func clear() { lock.withLock { _log = [] } }

    var runner: ExternalDownloadRunner {
        ExternalDownloadRunner(start: { [self] r in record("start \(r.id)") },
                               stop: { [self] id in record("stop \(id)") },
                               delete: { [self] id in record("delete \(id)") })
    }
}

@Suite(.serialized) struct DownloadQueueTests {
    static let hashA = String(repeating: "a", count: 40)
    static let hashB = String(repeating: "b", count: 40)
    static let hashC = String(repeating: "c", count: 40)

    func torrent(_ hash: String, key: MediaKey = .movie(tmdbID: 1), size: Int64? = 1_000) -> MediaVariant {
        MediaVariant(id: "\(hash):0", sourceID: SourceID("addons"), mediaKey: key, displayName: "Release.\(hash.prefix(4)).1080p.mkv",
                     container: "mkv", resolution: "1080p", sizeBytes: size, location: .remote, isDownloadable: true)
    }

    func manager(_ dir: URL = DownloadsTests.tempDir(), settings: DownloadSettings = DownloadSettings(wifiOnly: true),
                 free: Int64 = 100_000_000_000, runner: FakeRunner) -> DownloadManager {
        let m = DownloadManager(directory: dir, configuration: .ephemeral, settings: settings, startsQueue: false,
                                monitorsNetwork: false, freeSpace: { _ in free })
        m.external = runner.runner
        m.activate()
        return m
    }

    /// The manager reattaches its URLSession before the queue runs.
    func ready(_ m: DownloadManager, until: (DownloadManager) -> Bool) async throws {
        for _ in 0..<200 {
            await m.settle()
            if until(m) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out")
    }

    func id(_ hash: String) -> String { "addons/\(hash):0" }

    // MARK: Scheduler rules

    func record(_ hash: String, state: DownloadRecord.State = .queued, order: Double) -> DownloadRecord {
        DownloadRecord(id: id(hash), mediaKey: nil, title: hash, subtitle: nil, origin: torrent(hash), state: state,
                       receivedBytes: 0, expectedBytes: nil, createdAt: Date(timeIntervalSince1970: order), fileName: nil,
                       subtitleFiles: [], order: order)
    }

    @Test func schedulerRunsInOrderUpToTheLimit() {
        let records = [record(Self.hashC, order: 3), record(Self.hashA, order: 1), record(Self.hashB, order: 2)]
        let plan = DownloadScheduler.plan(records: records, running: [], settings: DownloadSettings(maxConcurrent: 2),
                                          conditions: DownloadConditions())
        #expect(plan.start == [id(Self.hashA), id(Self.hashB)])
        #expect(plan.waits[id(Self.hashC)] == .queued(position: 1))
    }

    @Test func schedulerStopsExtrasAndHonorsWifiHoldsAndBackground() {
        let records = [record(Self.hashA, state: .downloading, order: 1), record(Self.hashB, state: .downloading, order: 2),
                       record(Self.hashC, state: .paused, order: 0)]
        let running: Set = [id(Self.hashA), id(Self.hashB)]
        // Limit lowered to 1: the later one goes back to the queue; paused ones never run.
        var plan = DownloadScheduler.plan(records: records, running: running, settings: DownloadSettings(maxConcurrent: 1),
                                          conditions: DownloadConditions())
        #expect(plan.stop == [id(Self.hashB)] && plan.start.isEmpty)

        plan = DownloadScheduler.plan(records: records, running: running, settings: DownloadSettings(wifiOnly: true),
                                      conditions: DownloadConditions(isExpensive: true))
        #expect(Set(plan.stop) == running && plan.waits[id(Self.hashA)] == .wifi)

        plan = DownloadScheduler.plan(records: records, running: running, settings: DownloadSettings(wifiOnly: false),
                                      conditions: DownloadConditions(isExpensive: true))
        #expect(plan.stop.isEmpty)

        plan = DownloadScheduler.plan(records: records, running: running, settings: DownloadSettings(),
                                      conditions: DownloadConditions(torrentsSuspended: true))
        #expect(Set(plan.stop) == running && plan.waits[id(Self.hashB)] == .appInBackground)

        plan = DownloadScheduler.plan(records: records, running: running, settings: DownloadSettings(),
                                      conditions: DownloadConditions(isOnline: false))
        #expect(plan.waits[id(Self.hashA)] == .offline)

        plan = DownloadScheduler.plan(records: records, running: running, settings: DownloadSettings(),
                                      conditions: DownloadConditions(), holds: [id(Self.hashA): "streaming"])
        #expect(plan.stop == [id(Self.hashA)] && plan.waits[id(Self.hashA)] == .held("streaming"))
    }

    @Test func settingsDecodeOldSavesWithDefaults() throws {
        let decoded = try JSONDecoder().decode(DownloadSettings.self, from: Data(#"{"maxConcurrent":4}"#.utf8))
        #expect(decoded.maxConcurrent == 4)
        #expect(decoded.wifiOnly == DownloadSettings().wifiOnly)
        #expect(decoded.deleteAfterWatching == false)
        #expect(DownloadSettings(maxConcurrent: 0).concurrencyLimit == 1)
    }

    // MARK: Queue with torrents

    @Test func queuesTorrentsAndStartsTheNextWhenOneFinishes() async throws {
        let runner = FakeRunner()
        let m = manager(settings: DownloadSettings(maxConcurrent: 1), runner: runner)
        try m.enqueue(torrent(Self.hashA), key: .movie(tmdbID: 1), title: "A")
        try m.enqueue(torrent(Self.hashB, key: .movie(tmdbID: 2)), key: .movie(tmdbID: 2), title: "B")
        try await ready(m) { _ in runner.log == ["start \(id(Self.hashA))"] }
        #expect(m.wait(id(Self.hashB)) == .queued(position: 1))

        // Asking again for the same release doesn't add a second copy.
        #expect(throws: DownloadError.alreadyInQueue) { try m.enqueue(torrent(Self.hashA), key: .movie(tmdbID: 1), title: "A") }

        m.externalProgress(id(Self.hashA), receivedBytes: 500, totalBytes: 1_000, bytesPerSecond: 250_000, peers: 7)
        #expect(m.liveStats(id(Self.hashA))?.peers == 7)
        #expect(m.liveStats(id(Self.hashA))?.eta(remaining: 500_000) == 2)
        #expect(m.record(id: id(Self.hashA))?.fraction == 0.5)

        let file = "torrents/a/movie.mkv"
        try FileManager.default.createDirectory(at: m.directory.appending(path: "torrents/a"), withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: m.directory.appending(path: file))
        m.externalCompleted(id(Self.hashA), fileName: file)
        try await ready(m) { _ in runner.log.last == "start \(id(Self.hashB))" }
        #expect(m.record(id: id(Self.hashA))?.state == .completed)
        #expect(m.isDownloaded(.movie(tmdbID: 1)))
        #expect(!m.isDownloaded(.movie(tmdbID: 2)))
        #expect(throws: DownloadError.alreadyDownloaded) { try m.enqueue(torrent(Self.hashA), key: .movie(tmdbID: 1), title: "A") }

        // Plays offline from the downloads source, with the real file's container.
        let source = DownloadsSource(manager: m)
        let variants = try await source.variants(for: .movie(tmdbID: 1))
        #expect(variants.first?.container == "mkv")
        #expect(variants.first?.location == .downloaded)
        let resolved = try await source.resolve(variants[0])
        // Straight from disk: no torrent engine or local stream server in between.
        #expect(resolved.url.isFileURL)
        #expect(resolved.url.standardizedFileURL == m.directory.appending(path: file).standardizedFileURL)
    }

    @Test func pauseResumeAndDeleteWhileActive() async throws {
        let runner = FakeRunner()
        let m = manager(runner: runner)
        try m.enqueue(torrent(Self.hashA), key: .movie(tmdbID: 1), title: "A")
        try await ready(m) { _ in runner.log.count == 1 }
        m.pause(id(Self.hashA))
        try await ready(m) { _ in runner.log.last == "stop \(id(Self.hashA))" }
        #expect(m.record(id: id(Self.hashA))?.state == .paused)
        // Late progress from the stopped run is ignored.
        m.externalProgress(id(Self.hashA), receivedBytes: 900, totalBytes: 1_000, bytesPerSecond: 1, peers: 1)
        #expect(m.record(id: id(Self.hashA))?.receivedBytes == 0)

        m.resume(id(Self.hashA))
        try await ready(m) { _ in runner.log.last == "start \(id(Self.hashA))" }
        #expect(m.record(id: id(Self.hashA))?.state == .downloading)

        m.delete(id(Self.hashA))
        try await ready(m) { _ in runner.log.last == "delete \(id(Self.hashA))" }
        #expect(m.record(id: id(Self.hashA)) == nil)
    }

    @Test func holdsADownloadWhileItsReleaseStreams() async throws {
        let runner = FakeRunner()
        let m = manager(runner: runner)
        try m.enqueue(torrent(Self.hashA), key: .movie(tmdbID: 1), title: "A")
        try await ready(m) { _ in runner.log.count == 1 }
        await m.hold(Self.hashA.uppercased(), reason: "Streaming")
        #expect(runner.log.last == "stop \(id(Self.hashA))")
        #expect(m.record(id: id(Self.hashA))?.state == .queued)
        #expect(m.wait(id(Self.hashA)) == .held("Streaming"))

        m.releaseHold(Self.hashA)
        try await ready(m) { _ in runner.log.last == "start \(id(Self.hashA))" }
    }

    @Test func wifiOnlyAndBackgroundStopTorrentsUntilAllowed() async throws {
        let runner = FakeRunner()
        let m = manager(runner: runner)
        try m.enqueue(torrent(Self.hashA), key: .movie(tmdbID: 1), title: "A")
        try await ready(m) { _ in runner.log.count == 1 }
        m.networkChanged(online: true, expensive: true)
        try await ready(m) { _ in runner.log.last == "stop \(id(Self.hashA))" }
        #expect(m.wait(id(Self.hashA)) == .wifi)
        m.networkChanged(online: true, expensive: false)
        try await ready(m) { _ in runner.log.last == "start \(id(Self.hashA))" }

        await m.setTorrentsSuspended(true)
        #expect(runner.log.last == "stop \(id(Self.hashA))")
        #expect(m.wait(id(Self.hashA)) == .appInBackground)
        await m.setTorrentsSuspended(false)
        try await ready(m) { _ in runner.log.last == "start \(id(Self.hashA))" }
    }

    @Test func refusesOrStopsWhenSpaceRunsOut() async throws {
        let runner = FakeRunner()
        let m = manager(free: 600_000_000, runner: runner)
        #expect(throws: DownloadError.insufficientSpace(needed: nil, free: nil)) {
            try m.enqueue(torrent(Self.hashA, size: 2_000_000_000), key: .movie(tmdbID: 1), title: "A")
        }
        // Size unknown at first; once the torrent's file list says 5 GB, it stops with a clear reason.
        try m.enqueue(torrent(Self.hashB, size: nil), key: .movie(tmdbID: 2), title: "B")
        try await ready(m) { _ in runner.log.count == 1 }
        m.externalProgress(id(Self.hashB), receivedBytes: 0, totalBytes: 5_000_000_000, bytesPerSecond: 0, peers: 1)
        try await ready(m) { _ in runner.log.last == "stop \(id(Self.hashB))" }
        let failure = try #require(m.record(id: id(Self.hashB))?.failureMessage)
        #expect(failure.contains("Not enough free space"))
    }

    /// Two 3 GB downloads with 4 GB free: both used to start against the same
    /// free space and both failed later. The second is refused at once.
    @Test func spaceCheckCountsDownloadsStartedTogether() async throws {
        let runner = FakeRunner()
        let m = manager(settings: DownloadSettings(maxConcurrent: 2), free: 4_000_000_000, runner: runner)
        m.networkChanged(online: false, expensive: false)
        try m.enqueue(torrent(Self.hashA, size: 3_000_000_000), key: .movie(tmdbID: 1), title: "A")
        try m.enqueue(torrent(Self.hashB, key: .movie(tmdbID: 2), size: 3_000_000_000), key: .movie(tmdbID: 2), title: "B")
        m.networkChanged(online: true, expensive: false)
        try await ready(m) { _ in runner.log.count == 1 }
        #expect(runner.log == ["start \(id(Self.hashA))"])
        #expect(m.record(id: id(Self.hashB))?.failureMessage?.contains("Not enough free space") == true)
    }

    /// Saves from several threads used to write their snapshots out of order,
    /// so a delete could be undone on disk by an older progress save.
    @Test func concurrentSavesNeverResurrectADeletedDownload() async throws {
        let dir = DownloadsTests.tempDir()
        let runner = FakeRunner()
        let m = manager(dir, settings: DownloadSettings(maxConcurrent: 3), runner: runner)
        let hashes = (0..<3).map { String(repeating: "\($0 + 1)", count: 40) }
        for (i, h) in hashes.enumerated() {
            try m.enqueue(torrent(h, key: .movie(tmdbID: 10 + i)), key: .movie(tmdbID: 10 + i), title: h)
        }
        try await ready(m) { _ in runner.log.count == 3 }
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<200 {
                group.addTask {
                    for h in hashes.dropFirst() {
                        m.externalProgress(id(h), receivedBytes: Int64(n), totalBytes: 1_000, bytesPerSecond: 1, peers: 1)
                    }
                }
            }
            group.addTask { m.delete(id(hashes[0])) }
        }
        await m.settle()
        let reopened = DownloadManager(directory: dir, configuration: .ephemeral, settings: DownloadSettings(), startsQueue: false,
                                       monitorsNetwork: false, freeSpace: { _ in 100_000_000_000 })
        #expect(reopened.record(id: id(hashes[0])) == nil)
        #expect(reopened.all().count == 2)
    }

    @Test func resumesAfterRelaunchAndRepairsMissingFiles() async throws {
        let dir = DownloadsTests.tempDir()
        let runner = FakeRunner()
        do {
            let m = manager(dir, runner: runner)
            try m.enqueue(torrent(Self.hashA), key: .movie(tmdbID: 1), title: "A")
            try m.enqueue(torrent(Self.hashB, key: .movie(tmdbID: 2)), key: .movie(tmdbID: 2), title: "B")
            try m.enqueue(torrent(Self.hashC, key: .movie(tmdbID: 3)), key: .movie(tmdbID: 3), title: "C")
            try await ready(m) { _ in runner.log.count == 2 }
            m.pause(id(Self.hashB))
            let file = "torrents/c.mkv"
            try FileManager.default.createDirectory(at: dir.appending(path: "torrents"), withIntermediateDirectories: true)
            try Data(count: 10).write(to: dir.appending(path: file))
            m.prioritize(id(Self.hashC))
            try await ready(m) { _ in runner.log.contains("start \(id(Self.hashC))") }
            m.externalCompleted(id(Self.hashC), fileName: file)
            await m.settle()
        }
        // The completed file disappears and a stray partial file is left behind.
        try FileManager.default.removeItem(at: dir.appending(path: "torrents/c.mkv"))
        try Data(count: 5).write(to: dir.appending(path: "stray.mp4"))

        let runner2 = FakeRunner()
        let m2 = manager(dir, runner: runner2)
        try await ready(m2) { _ in runner2.log == ["start \(id(Self.hashA))"] }
        #expect(m2.record(id: id(Self.hashB))?.state == .paused)
        #expect(m2.record(id: id(Self.hashC))?.isFailed == true)
        #expect(!m2.isDownloaded(.movie(tmdbID: 3)))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "stray.mp4").path))
    }

    @Test func seriesKeysCountDownloadedEpisodes() async throws {
        let runner = FakeRunner()
        let m = manager(runner: runner)
        let ep = MediaKey.episode(seriesID: 9, season: 1, episode: 2)
        try m.enqueue(torrent(Self.hashA, key: ep), key: ep, title: "Show", subtitle: "S1·E2")
        try await ready(m) { _ in runner.log.count == 1 }
        try Data(count: 10).write(to: m.directory.appending(path: "ep.mkv"))
        m.externalCompleted(id(Self.hashA), fileName: "ep.mkv")
        #expect(m.isDownloaded(ep))
        #expect(m.isDownloaded(try #require(ep.seriesKey)))
        #expect(!m.isDownloaded(.episode(seriesID: 9, season: 1, episode: 3)))
    }

    @Test func withoutARunnerTorrentsFailClearly() async throws {
        let m = DownloadManager(directory: DownloadsTests.tempDir(), configuration: .ephemeral, monitorsNetwork: false)
        try m.enqueue(torrent(Self.hashA), key: .movie(tmdbID: 1), title: "A")
        for _ in 0..<100 where m.record(id: id(Self.hashA))?.isFailed != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.record(id: id(Self.hashA))?.isFailed == true)
    }
}
