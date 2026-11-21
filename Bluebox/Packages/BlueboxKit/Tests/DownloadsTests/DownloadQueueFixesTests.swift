import Domain
@testable import Downloads
import Foundation
import Testing

/// Free space a test can change while the manager runs.
final class FreeSpace: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64
    init(_ bytes: Int64) { self.bytes = bytes }
    var value: Int64 { get { lock.withLock { bytes } } set { lock.withLock { bytes = newValue } } }
}

/// Download First on a stopped download, space coming back, and what a relaunch remembers.
@Suite(.serialized) struct DownloadQueueFixesTests {
    static let hashA = String(repeating: "a", count: 40)
    static let hashB = String(repeating: "b", count: 40)

    func torrent(_ hash: String, size: Int64? = 1_000) -> MediaVariant {
        MediaVariant(id: "\(hash):0", sourceID: SourceID("addons"), mediaKey: .movie(tmdbID: 1), displayName: "Release.\(hash.prefix(4)).mkv",
                     container: "mkv", sizeBytes: size, location: .remote, isDownloadable: true)
    }

    func id(_ hash: String) -> String { "addons/\(hash):0" }

    func manager(_ dir: URL = DownloadsTests.tempDir(), free: FreeSpace = FreeSpace(100_000_000_000), maxConcurrent: Int = 1,
                 runner: FakeRunner) -> DownloadManager {
        let m = DownloadManager(directory: dir, configuration: .ephemeral, settings: DownloadSettings(maxConcurrent: maxConcurrent, wifiOnly: false),
                                startsQueue: false, monitorsNetwork: false, freeSpace: { _ in free.value })
        m.external = runner.runner
        m.activate()
        return m
    }

    func wait(_ m: DownloadManager, until: (DownloadManager) -> Bool) async throws {
        for _ in 0..<300 {
            await m.settle()
            if until(m) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out")
    }

    @Test func downloadFirstResumesAPausedOrFailedDownload() async throws {
        let runner = FakeRunner()
        let m = manager(runner: runner)
        try m.enqueue(torrent(Self.hashA), key: .movie(tmdbID: 1), title: "A")
        try m.enqueue(torrent(Self.hashB), key: .movie(tmdbID: 2), title: "B")
        try await wait(m) { _ in runner.log.contains("start \(id(Self.hashA))") }
        m.pause(id(Self.hashB))
        #expect(m.record(id: id(Self.hashB))?.state == .paused)

        // Download First on the paused one: it goes back in the queue, at the front, and takes the slot.
        m.prioritize(id(Self.hashB))
        try await wait(m) { $0.record(id: id(Self.hashB))?.state == .downloading }
        #expect(runner.log.contains("start \(id(Self.hashB))"))
        #expect(m.record(id: id(Self.hashA))?.state == .queued)

        // A failed one too.
        m.externalFailed(id(Self.hashB), message: "Gone")
        try await wait(m) { $0.record(id: id(Self.hashB))?.isFailed == true }
        m.prioritize(id(Self.hashB))
        try await wait(m) { $0.record(id: id(Self.hashB))?.state == .downloading }
    }

    @Test func spaceFailuresGoBackOnceThereIsRoom() async throws {
        let runner = FakeRunner()
        let free = FreeSpace(100_000_000)  // under the 200 MB the queue keeps free
        let m = manager(free: free, runner: runner)
        // A torrent's size is only known once its file list arrives; then it doesn't fit.
        try m.enqueue(torrent(Self.hashA, size: nil), key: .movie(tmdbID: 1), title: "A")
        try await wait(m) { _ in runner.log.contains("start \(id(Self.hashA))") }
        m.externalProgress(id(Self.hashA), receivedBytes: 0, totalBytes: 1_000, bytesPerSecond: 0, peers: 3)
        try await wait(m) { $0.record(id: id(Self.hashA))?.isFailed == true }
        #expect(m.record(id: id(Self.hashA))?.failedForSpace == true)
        runner.clear()

        // Still no room: nothing happens.
        #expect(m.resumeWhenSpaceReturns().isEmpty)

        // Room again: it goes back in the queue by itself and starts.
        free.value = 10_000_000_000
        #expect(m.resumeWhenSpaceReturns() == [id(Self.hashA)])
        try await wait(m) { _ in runner.log.contains("start \(id(Self.hashA))") }
        #expect(m.record(id: id(Self.hashA))?.failedForSpace == nil)
    }

    @Test func fittingTakesWhatFitsInOrder() {
        let sizes: [(id: String, bytes: Int64)] = [("a", 3), ("b", 5), ("c", 2), ("d", 1)]
        #expect(DownloadManager.fitting(sizes, free: 6) == ["a", "c", "d"])
        #expect(DownloadManager.fitting(sizes, free: 0) == [])
        #expect(DownloadManager.fitting(sizes, free: -5) == [])
    }

    @Test func aRelaunchRemembersTheStatesItFound() async throws {
        let dir = DownloadsTests.tempDir()
        let runner = FakeRunner()
        let first = manager(dir, runner: runner)
        try first.enqueue(torrent(Self.hashA), key: .movie(tmdbID: 1), title: "A")
        try await wait(first) { $0.record(id: id(Self.hashA))?.state == .downloading }
        first.saveNow()

        // The next launch reads the index (running ones go back to queued) before anything moves.
        let second = DownloadManager(directory: dir, configuration: .ephemeral, startsQueue: false, monitorsNetwork: false,
                                     freeSpace: { _ in 100_000_000_000 })
        #expect(second.launchStates[id(Self.hashA)] == .queued)
    }

    /// Try Another Release comes from the downloader giving up, never from a
    /// message's wording: a connection timeout says "or try another release"
    /// but still gets Retry.
    @Test func onlyAGiveUpSuggestsAnotherRelease() async throws {
        let runner = FakeRunner()
        let m = manager(maxConcurrent: 2, runner: runner)
        try m.enqueue(torrent(Self.hashA), key: .movie(tmdbID: 1), title: "A")
        try m.enqueue(torrent(Self.hashB), key: .movie(tmdbID: 2), title: "B")
        try await wait(m) { _ in runner.log.contains("start \(id(Self.hashA))") && runner.log.contains("start \(id(Self.hashB))") }

        m.externalFailed(id(Self.hashA), message: "Couldn't reach anyone sharing this release. Tap Retry, or try another release.")
        m.externalFailed(id(Self.hashB), message: "Nobody has shared this release for 15 minutes. Try another release.",
                         needsAnotherRelease: true)
        try await wait(m) { $0.record(id: id(Self.hashA))?.isFailed == true && $0.record(id: id(Self.hashB))?.isFailed == true }
        #expect(m.record(id: id(Self.hashA))?.suggestsAnotherRelease == false)
        #expect(m.record(id: id(Self.hashB))?.suggestsAnotherRelease == true)

        // Retrying clears it: a later failure of another kind offers Retry again.
        m.retry(id(Self.hashB))
        try await wait(m) { $0.record(id: id(Self.hashB))?.state == .downloading }
        #expect(m.record(id: id(Self.hashB))?.needsAnotherRelease == nil)
        m.externalFailed(id(Self.hashB), message: "The torrent stopped with a problem. Tap Retry, or try another release.")
        try await wait(m) { $0.record(id: id(Self.hashB))?.isFailed == true }
        #expect(m.record(id: id(Self.hashB))?.suggestsAnotherRelease == false)
    }

    @Test func aFlaggedDebridDownloadStillGetsRetry() {
        let v = MediaVariant(id: "https://cdn.example/x.mkv", sourceID: SourceID("addons"), mediaKey: nil, displayName: "x",
                             location: .remote, isDownloadable: true)
        var r = DownloadRecord(id: "x", mediaKey: nil, title: "A", subtitle: nil, origin: v, state: .failed("Try another release."),
                               receivedBytes: 0, expectedBytes: nil, createdAt: .now, fileName: nil, subtitleFiles: [])
        r.needsAnotherRelease = true
        // A debrid link that failed isn't a torrent: Retry gets a fresh link.
        #expect(!r.suggestsAnotherRelease)
    }
}
