import Addons
import Domain
import Foundation
import Playback
import Testing
import TorrentStreaming
import VLCPlayback

/// Live checks of the torrent engine against Sintel (tt1727587, CC BY 3.0),
/// over the real network. Opt in with BLUEBOX_LIVE_STREAM=1 and
/// BLUEBOX_LIVE_DOWNLOAD=1 (they download the whole film).
///
/// 1. Download Sintel with TorrentDownloader while streaming the same release
///    with TorrentStreamer, reading from the stream (start and a seek) as the
///    download runs: neither may break the other.
/// 2. Play the downloaded file for a few seconds.
/// 3. Shut the engine down (the process must then exit cleanly).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_LIVE_STREAM"] == "1"
                 && ProcessInfo.processInfo.environment["BLUEBOX_LIVE_DOWNLOAD"] == "1"),
       .serialized)
@MainActor
struct StreamAndDownloadLiveTests {
    @Test(.timeLimit(.minutes(20))) func streamWhileDownloadingThenPlayTheDownload() async throws {
        let imdb = ProcessInfo.processInfo.environment["BLUEBOX_BENCH_IMDB"] ?? "tt1727587"
        let source = StremioSource(settings: AddonSettings(), debridKey: "", imdbID: { _ in imdb })
        let releases = try await source.releases(for: .movie(tmdbID: 1))
        let release = try #require(releases.first { $0.magnet != nil && !$0.isDebrid })
        let magnet = try #require(release.magnet)
        print("LIVE release \(release.fileName) \(release.sizeText ?? "?")")

        let root = FileManager.default.temporaryDirectory.appending(path: "bb-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = TorrentDownloader(root: root, settings: TorrentStreamSettings())
        let log = EventLog()
        let clock = ContinuousClock()
        let began = clock.now

        // Download first, then stream the same release while it runs.
        await downloader.start(id: "live", magnet: magnet, fileIndex: release.fileIndex) { log.add($0) }
        let streamer = TorrentStreamer(settings: TorrentStreamSettings())
        let (url, _, _) = try await streamer.start(candidates: [TorrentCandidate(magnet: magnet, fileIndex: release.fileIndex)]) { _ in }
        print("LIVE stream ready after \(clock.now - began): \(url)")

        // Read the start and, after a seek, the middle, while the download continues.
        let head = try await Self.fetch(url, range: "bytes=0-1048575")
        #expect(head.count == 1_048_576)
        let ranges = try #require(TorrentStreamer.downloadedRanges(for: url))
        let middle = ranges.length / 2
        let seekBegan = clock.now
        let mid = try await Self.fetch(url, range: "bytes=\(middle)-\(middle + 1_048_575)")
        #expect(mid.count == 1_048_576)
        print("LIVE seek read took \(clock.now - seekBegan); downloaded ranges: \(TorrentStreamer.downloadedRanges(for: url)?.ranges.count ?? 0)")

        // Wait for the download to finish (the stream stays up meanwhile).
        var lastPrint = clock.now
        while log.completed == nil && log.failed == nil {
            try await Task.sleep(for: .seconds(1))
            if clock.now - lastPrint > .seconds(15), let p = log.lastProgress {
                print("LIVE download \(p.receivedBytes / 1_048_576)/\((p.totalBytes ?? 0) / 1_048_576) MB at \(Int(p.bytesPerSecond / 1024)) KB/s, \(p.peers) peers")
                lastPrint = clock.now
            }
        }
        #expect(log.failed == nil, "download failed: \(log.failed ?? "")")
        let relative = try #require(log.completed)
        let file = downloader.folder(for: "live").appending(path: relative)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        print("LIVE download complete after \(clock.now - began): \(relative) (\(size) bytes)")
        #expect(size > 0)

        // The stream still serves after the download released its share.
        let tail = try await Self.fetch(url, range: "bytes=-65536")
        #expect(tail.count == 65536)
        // The downloaded bytes match what the stream served.
        let handle = try FileHandle(forReadingFrom: file)
        let onDisk = try handle.read(upToCount: 1_048_576) ?? Data()
        try handle.close()
        #expect(onDisk == head)
        await streamer.stop()

        // Play the downloaded file.
        let resource = PlaybackResource(variant: MediaVariant(id: "live", sourceID: SourceID("downloads"), mediaKey: .movie(tmdbID: 1),
                                                              displayName: relative, container: file.pathExtension,
                                                              location: .downloaded),
                                        url: file)
        let engine = PlaybackEngines.make(for: resource, streams: nil)
        try await engine.load(resource, startAt: 30)
        engine.play()
        let playStart = clock.now
        while engine.snapshot.position < 33 {
            if case .failed(let e) = engine.snapshot.status { throw e }
            if clock.now - playStart > .seconds(30) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("LIVE played the download to \(String(format: "%.1f", engine.snapshot.position)) s")
        #expect(engine.snapshot.position >= 33)
        engine.stop()
        await downloader.delete("live")

        TorrentStreamer.shutdownEngine()
        print("LIVE engine shut down")
    }

    nonisolated static func fetch(_ url: URL, range: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        return data
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _completed: String?
    private var _failed: String?
    private var _progress: TorrentDownloadProgress?

    func add(_ event: TorrentDownloadEvent) {
        lock.withLock {
            switch event {
            case .connecting: break
            case .progress(let p): _progress = p
            case .completed(let path): _completed = path
            case .failed(let message): _failed = message
            }
        }
    }

    var completed: String? { lock.withLock { _completed } }
    var failed: String? { lock.withLock { _failed } }
    var lastProgress: TorrentDownloadProgress? { lock.withLock { _progress } }
}
