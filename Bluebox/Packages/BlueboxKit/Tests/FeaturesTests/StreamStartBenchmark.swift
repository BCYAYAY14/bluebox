import Addons
import Domain
import Darwin
import Foundation
import Playback
import Testing
import TorrentStreaming
import VLCPlayback

/// Time from pressing Play to the first frame for an add-on release, over the
/// real network (add-on query, libtorrent, local stream server, AVPlayer/VLC).
/// Opt in on macOS:
///
///     BLUEBOX_LIVE_STREAM=1 BLUEBOX_BENCH_IMDB=tt1727587 swift test --filter StreamStartBenchmark
///
/// or on an iOS simulator:
///
///     TEST_RUNNER_BLUEBOX_LIVE_STREAM=1 TEST_RUNNER_BLUEBOX_BENCH_IMDB=tt1727587 \
///       xcodebuild test -scheme BlueboxKit-Package -destination 'id=<sim>' \
///       -only-testing:FeaturesTests/StreamStartBenchmark
///
/// The process used to crash on exit after this test (libtorrent's threads
/// outlived its static data); a clean exit is part of what this checks.
///
/// Uses openly licensed films only (Sintel tt1727587, Tears of Steel tt2285752).
/// The title's stream cache is cleared first so every run downloads from scratch.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_LIVE_STREAM"] == "1"))
@MainActor
struct StreamStartBenchmark {
    @Test(.timeLimit(.minutes(5))) func timeToFirstFrame() async throws {
        let env = ProcessInfo.processInfo.environment
        let imdb = env["BLUEBOX_BENCH_IMDB"] ?? "tt1727587"
        let key = MediaKey.movie(tmdbID: 1)
        StreamCache.clear()

        let clock = ContinuousClock()
        let start = clock.now
        let marks = MarkLog(start: start)
        var settings = AddonSettings()
        if let resolution = env["BLUEBOX_BENCH_RES"] { settings.preferredResolution = resolution }
        if let width = env["BLUEBOX_BENCH_RACE"].flatMap(Int.init) { settings.raceWidth = width }
        let source = StremioSource(settings: settings, debridKey: "", imdbID: { _ in imdb })
        await source.setStatusHandler { status in marks.note(status) }

        let variant = MediaVariant(id: StremioSource.bestReleaseID, sourceID: source.id, mediaKey: key,
                                   displayName: "Best release", location: .remote)
        let resource = try await source.resolve(variant)
        let resolved = clock.now - start
        print("BENCH resolved \(resolved) → \(resource.variant.displayName) [\(resource.variant.container ?? "?")]")

        let engine = PlaybackEngines.make(for: resource, streams: nil)
        try await engine.load(resource, startAt: nil)
        let loaded = clock.now - start
        engine.play()
        while engine.snapshot.position < 0.05 {
            if case .failed(let e) = engine.snapshot.status { throw e }
            try await Task.sleep(for: .milliseconds(20))
        }
        let firstFrame = clock.now - start
        TorrentStreamer.noteFirstFrame()
        let stats = await source.streamStats()
        print("BENCH imdb=\(imdb) resolved=\(Self.s(resolved)) loaded=\(Self.s(loaded)) firstFrame=\(Self.s(firstFrame)) "
              + "peers=\(stats.connectedPeers) rate=\(Int(stats.downloadRate / 1024))KB/s")
        print("BENCH marks \(marks.summary)")
        engine.stop()
        await source.stopStreaming()
    }

    /// Two minutes of playback with two seeks: counts stalls (time the
    /// playhead doesn't move after the first frame, outside seeks), times each
    /// seek, and samples the process's memory. Opt in with BLUEBOX_BENCH_PLAY=1
    /// (BLUEBOX_BENCH_SECONDS changes the length).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_BENCH_PLAY"] == "1"), .timeLimit(.minutes(10)))
    func playbackWithSeeks() async throws {
        let env = ProcessInfo.processInfo.environment
        let imdb = env["BLUEBOX_BENCH_IMDB"] ?? "tt1727587"
        let length = env["BLUEBOX_BENCH_SECONDS"].flatMap(Double.init) ?? 120
        StreamCache.clear()
        let clock = ContinuousClock()
        let start = clock.now
        var settings = AddonSettings()
        if let resolution = env["BLUEBOX_BENCH_RES"] { settings.preferredResolution = resolution }
        let source = StremioSource(settings: settings, debridKey: "", imdbID: { _ in imdb })
        let variant = MediaVariant(id: StremioSource.bestReleaseID, sourceID: source.id, mediaKey: .movie(tmdbID: 1),
                                   displayName: "Best release", location: .remote)
        let resource = try await source.resolve(variant)
        let engine = PlaybackEngines.make(for: resource, streams: nil)
        try await engine.load(resource, startAt: nil)
        engine.play()
        while engine.snapshot.position < 0.05 {
            if case .failed(let e) = engine.snapshot.status { throw e }
            try await Task.sleep(for: .milliseconds(20))
        }
        let firstFrame = clock.now - start
        TorrentStreamer.noteFirstFrame()
        let duration = engine.snapshot.duration ?? 888
        // Seek at a third and two thirds of the run, to 45% and 75% of the film.
        let seeks: [(at: Double, to: Double)] = [(length / 3, duration * 0.45), (2 * length / 3, duration * 0.75)]
        var nextSeek = 0
        var stalls = 0, stalledSeconds = 0.0
        var seekWaits: [Double] = []
        var stalling = false
        var streak = 0.0
        var peakMemory: UInt64 = 0
        var played = 0.0
        var lastPosition = engine.snapshot.position
        var seekStarted: ContinuousClock.Instant?
        let tick = 0.1
        while played < length {
            try await Task.sleep(for: .milliseconds(Int(tick * 1000)))
            let snap = engine.snapshot
            if case .failed(let e) = snap.status { throw e }
            peakMemory = max(peakMemory, Self.footprint())
            let moving = snap.position > lastPosition + 0.01
            lastPosition = snap.position
            if let began = seekStarted {
                if moving {
                    seekWaits.append(Self.secs(clock.now - began))
                    seekStarted = nil
                } else if Self.secs(clock.now - began) > 120 {
                    throw TorrentStreamError.stalled
                }
                continue
            }
            if moving {
                played += tick + (stalling ? 0 : streak)
                streak = 0
                stalling = false
            } else {
                streak += tick
                // Under a second still is the player's clock granularity, not a stall.
                if stalling {
                    stalledSeconds += tick
                } else if streak >= 1 {
                    stalling = true
                    stalls += 1
                    stalledSeconds += streak
                }
            }
            if nextSeek < seeks.count, played >= seeks[nextSeek].at {
                seekStarted = clock.now
                stalling = false
                await engine.seek(to: seeks[nextSeek].to)
                lastPosition = engine.snapshot.position
                nextSeek += 1
            }
        }
        print("BENCH-PLAY imdb=\(imdb) firstFrame=\(Self.s(firstFrame)) played=\(Int(played))s stalls=\(stalls) "
              + "stalled=\(String(format: "%.1f", stalledSeconds))s "
              + "seekWaits=\(seekWaits.map { String(format: "%.1fs", $0) }.joined(separator: ",")) "
              + "peakMemory=\(peakMemory / 1_048_576)MB")
        engine.stop()
        await source.stopStreaming()
    }

    nonisolated static func secs(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// The process's physical footprint (what Xcode's memory gauge shows).
    nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    nonisolated static func s(_ d: Duration) -> String {
        String(format: "%.2fs", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }
}

private final class MarkLog: @unchecked Sendable {
    private let lock = NSLock()
    private let start: ContinuousClock.Instant
    private var marks: [String] = []
    private var last = ""

    init(start: ContinuousClock.Instant) { self.start = start }

    func note(_ status: AddonPlaybackStatus) {
        let label: String = switch status {
        case .searching: "searching"
        case .trying(let r): "trying(\(r))"
        case .torrent(let t, _): "\(t)".components(separatedBy: "(").first ?? "torrent"
        }
        lock.withLock {
            guard label != last else { return }
            last = label
            marks.append("\(label)@\(StreamStartBenchmark.s(ContinuousClock.now - start))")
        }
    }

    var summary: String { lock.withLock { marks.joined(separator: " ") } }
}
