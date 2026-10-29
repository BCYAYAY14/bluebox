import CoreGraphics
import Domain
import Foundation
@testable import Playback
import Subtitles
import Testing
import TestingSupport

// MARK: - Mock engine

@MainActor
class MockEngine: PlaybackEngine {
    static let supportedContainers: Set<String> = ["mp4"]
    var snapshot = PlaybackSnapshot() { didSet { onChange?(snapshot) } }
    var onChange: ((PlaybackSnapshot) -> Void)?
    var loadedStart: TimeInterval?
    var loads = 0
    var embeddedSelection: String?
    var failLoad: PlaybackError?

    func load(_ resource: PlaybackResource, startAt: TimeInterval?) async throws {
        loads += 1
        loadedStart = startAt
        if let failLoad { snapshot.status = .failed(failLoad); throw failLoad }
        var s = PlaybackSnapshot()
        s.status = .paused
        s.duration = 3600
        s.position = startAt ?? 0
        s.embeddedSubtitles = [MediaTrack(id: "s0", kind: .subtitle, label: "English", languageCode: "en")]
        snapshot = s
    }
    func play() { snapshot.status = .playing }
    func pause() { snapshot.status = .paused }
    var seeks: [TimeInterval] = []
    var scrubs: [TimeInterval] = []
    func seek(to seconds: TimeInterval) async { seeks.append(seconds); snapshot.position = seconds }
    func scrub(to seconds: TimeInterval) { scrubs.append(seconds) }
    func setRate(_ rate: Float) { snapshot.rate = rate }
    func selectAudio(_ trackID: String?) { snapshot.selectedAudioID = trackID }
    func selectEmbeddedSubtitle(_ trackID: String?) { embeddedSelection = trackID }
    func stop() { snapshot.status = .idle }
    func setVideoAdjustments(_ adjustments: VideoAdjustments) {}
    var volume: Float = 1
    var muted = false
    var audioDelay: TimeInterval = 0
    func setVolume(_ volume: Float, muted: Bool) { self.volume = volume; self.muted = muted }
    func setAudioDelay(_ seconds: TimeInterval) { audioDelay = seconds }
    var supportsAudioDelay: Bool { true }

    /// Simulates playback reaching a position.
    func advance(to t: TimeInterval) { snapshot.position = t }
    func finish() { snapshot.position = snapshot.duration ?? 0; snapshot.status = .ended }
}

final class MemoryProgress: ProgressRepository, @unchecked Sendable {
    let lock = NSLock()
    var store: [MediaKey: WatchProgress] = [:]
    var saves = 0
    func progress(for key: MediaKey) async throws -> WatchProgress? { lock.withLock { store[key] } }
    func progress(forSeries seriesKey: MediaKey) async throws -> [WatchProgress] { [] }
    func continueWatching(limit: Int) async throws -> [WatchProgress] { [] }
    func recent(limit: Int) async throws -> [WatchProgress] { [] }
    func save(_ p: WatchProgress) async throws -> WatchProgress {
        lock.withLock {
            saves += 1
            let (w, _) = ProgressMerge.apply(incoming: p, to: store[p.key])
            store[p.key] = w
            return w
        }
    }
    func delete(_ key: MediaKey) async throws { lock.withLock { store[key] = nil } }
}

func resource(_ id: String = "v", subs: [ExternalSubtitle] = []) -> PlaybackResource {
    PlaybackResource(
        variant: MediaVariant(id: id, sourceID: SourceID("s"), mediaKey: nil, displayName: id, container: "mp4", location: .remote),
        url: URL(string: "https://example.invalid/\(id).mp4")!, externalSubtitles: subs
    )
}

/// Monotonic fake clock so merge ordering is deterministic.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1_000
    func now() -> Date { lock.withLock { t += 1; return Date(timeIntervalSince1970: t) } }
}

func waitUntil(_ timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

// MARK: - Session tests

@MainActor
@Suite struct PlayerSessionTests {
    let movie = NowPlayingItem(key: .movie(tmdbID: 1), title: "One")

    func make(_ progress: MemoryProgress = MemoryProgress(), next: NextItemProvider? = nil, countdown: Int = 0) -> (PlayerSession, MockEngine) {
        let engine = MockEngine()
        let clock = TestClock()
        let s = PlayerSession(engine: engine, progress: progress, deviceID: "test", nextProvider: next,
                              upNextCountdown: countdown, now: { clock.now() })
        return (s, engine)
    }

    @Test func resumesFromSavedProgress() async throws {
        let progress = MemoryProgress()
        _ = try await progress.save(.fixture(movie.key, 900, at: 1))
        let (s, engine) = make(progress)
        await s.start(movie, resource: resource())
        #expect(engine.loadedStart == 900)
        #expect(s.snapshot.status == .playing)
    }

    @Test func startsOverWhenCompletedOrTooEarlyOrResumeDisabled() async throws {
        let progress = MemoryProgress()
        _ = try await progress.save(.fixture(movie.key, 3600, completed: true, at: 1))
        let (s, engine) = make(progress)
        await s.start(movie, resource: resource())
        #expect(engine.loadedStart == nil)

        _ = try await progress.save(.fixture(movie.key, 1200, at: 2))
        await s.start(movie, resource: resource(), resume: false)
        #expect(engine.loadedStart == nil)
    }

    @Test func explicitStartWinsOverSavedProgressAndResumeOff() async throws {
        // Handoff: the handed-off second, even with resume off or under the resume threshold.
        let progress = MemoryProgress()
        _ = try await progress.save(.fixture(movie.key, 900, at: 1))
        let (s, engine) = make(progress)
        await s.start(movie, resource: resource(), resume: false, startAt: 12)
        #expect(engine.loadedStart == 12)
        await s.start(movie, resource: resource(), resume: true, startAt: 1500)
        #expect(engine.loadedStart == 1500)
    }

    @Test func savesOnPauseAndPeriodicallyAndOnEnd() async throws {
        let progress = MemoryProgress()
        let (s, engine) = make(progress)
        await s.start(movie, resource: resource())
        engine.advance(to: 5)            // under save interval
        await s.persistProgress()        // flush any in-flight
        let before = progress.saves
        engine.advance(to: 20)           // crosses 10 s interval
        #expect(await waitUntil { progress.saves > before })
        #expect(try await progress.progress(for: movie.key)?.position == 20)

        engine.advance(to: 25)
        engine.pause()
        #expect(await waitUntil { progress.store[movie.key]?.position == 25 })

        engine.play()
        engine.advance(to: 26)
        await s.end()
        #expect(progress.store[movie.key]?.position == 26)
        #expect(s.item == nil)
        #expect(engine.snapshot.status == .idle)
    }

    @Test func endingMarksCompleted() async throws {
        let progress = MemoryProgress()
        let (s, engine) = make(progress)
        await s.start(movie, resource: resource())
        engine.finish()
        #expect(await waitUntil { progress.store[movie.key]?.isCompleted == true })
        _ = s
    }

    @Test func openingAndClosingImmediatelyRecordsNothing() async {
        let progress = MemoryProgress()
        let (s, _) = make(progress)
        await s.start(movie, resource: resource())
        await s.end()
        #expect(progress.store.isEmpty)
    }

    @Test func loadFailureSurfacesError() async {
        let (s, engine) = make()
        engine.failLoad = .unsupportedFormat("mkv")
        await s.start(movie, resource: resource())
        #expect(s.error == .unsupportedFormat("mkv"))
        await s.end()
    }

    @Test func externalSubtitlesWithOffset() async throws {
        let sub = ExternalSubtitle(id: "en", url: Fixtures.testSubtitleURL, languageCode: "en", label: "English", format: "srt")
        let (s, engine) = make()
        await s.start(movie, resource: resource(subs: [sub]), resume: false)
        #expect(s.allSubtitleTracks.map(\.id) == ["s0", "en"])
        engine.advance(to: 2)
        s.selectSubtitle(.external("en"))
        #expect(engine.embeddedSelection == nil)
        #expect(s.canAdjustSubtitleTiming)
        #expect(await waitUntil { s.subtitleText == "Bluebox test pattern" })

        s.nudgeSubtitles(by: 1.5)   // cue now shows 2.5–4.5
        #expect(s.subtitleText == nil)
        engine.advance(to: 3)
        #expect(s.subtitleText == "Bluebox test pattern")
        #expect(s.subtitleOffset.label == "+1.5 s")
        s.resetSubtitleOffset()
        s.selectSubtitle(.embedded("s0"))
        #expect(engine.embeddedSelection == "s0")
        #expect(s.subtitleText == nil)
        #expect(!s.canAdjustSubtitleTiming)
        await s.end()
    }

    @Test func importedSubtitleIsAddedAndSelected() async {
        let (s, _) = make()
        await s.start(movie, resource: resource(), resume: false)
        s.importSubtitle(Fixtures.testSubtitleURL)
        #expect(s.externalSubtitles.count == 1)
        #expect(s.subtitleSelection == .external("import-en.srt"))
        await s.end()
    }

    @Test func badSubtitleFileReportsErrorAndTurnsOff() async {
        let bad = ExternalSubtitle(id: "x", url: URL(fileURLWithPath: "/nonexistent.srt"), languageCode: nil, label: "x", format: "srt")
        let (s, _) = make()
        await s.start(movie, resource: resource(subs: [bad]), resume: false)
        s.selectSubtitle(.external("x"))
        #expect(await waitUntil { s.subtitleError != nil })
        #expect(s.subtitleSelection == .off)
        await s.end()
    }

    @Test func upNextAutoplaysNextEpisode() async {
        let e1 = NowPlayingItem(key: .episode(seriesID: 5, season: 1, episode: 1), title: "Ep 1")
        let e2 = NowPlayingItem(key: .episode(seriesID: 5, season: 1, episode: 2), title: "Ep 2")
        let progress = MemoryProgress()
        let (s, engine) = make(progress, next: { key in key == e1.key ? (e2, resource("e2")) : nil }, countdown: 0)
        await s.start(e1, resource: resource("e1"))
        engine.finish()
        #expect(await waitUntil { s.item == e2 })
        #expect(engine.loads == 2)
        #expect(progress.store[e1.key]?.isCompleted == true)
        await s.end()
    }

    @Test func upNextCanBeCancelled() async {
        let e1 = NowPlayingItem(key: .episode(seriesID: 5, season: 1, episode: 1), title: "Ep 1")
        let e2 = NowPlayingItem(key: .episode(seriesID: 5, season: 1, episode: 2), title: "Ep 2")
        let (s, engine) = make(next: { _ in (e2, resource("e2")) }, countdown: 5)
        await s.start(e1, resource: resource("e1"))
        engine.finish()
        #expect(await waitUntil { s.upNext?.item == e2 })
        s.cancelUpNext()
        try? await Task.sleep(for: .milliseconds(1200))
        #expect(s.item == e1)
        #expect(engine.loads == 1)
        await s.end()
    }
}

// MARK: - Real AVFoundation playback

@MainActor
@Suite(.serialized) struct AVPlayerEngineTests {
    func testResource(container: String = "mp4") -> PlaybackResource {
        PlaybackResource(
            variant: MediaVariant(id: "test", sourceID: SourceID("t"), mediaKey: nil, displayName: "test",
                                  container: container, location: .localFile),
            url: Fixtures.testVideoURL
        )
    }

    @Test func playsSeeksAndReportsTracks() async throws {
        let engine = AVPlayerEngine()
        engine.player.isMuted = true
        try await engine.load(testResource(), startAt: 2)
        let d = try #require(engine.snapshot.duration)
        #expect(abs(d - 12) < 0.2)
        #expect(abs(engine.snapshot.position - 2) < 0.1)
        #expect(engine.snapshot.audioTracks.map(\.languageCode) == ["en", "es"])
        #expect(engine.snapshot.embeddedSubtitles.count == 1)
        #expect(engine.snapshot.selectedAudioID == "a0")

        engine.play()
        #expect(await waitUntil(.seconds(5)) { engine.snapshot.status == .playing })
        #expect(await waitUntil(.seconds(5)) { engine.snapshot.position > 2.6 })

        engine.selectAudio("a1")
        #expect(engine.snapshot.selectedAudioID == "a1")
        engine.selectEmbeddedSubtitle("s0")
        #expect(engine.snapshot.selectedEmbeddedSubtitleID == "s0")

        engine.setRate(1.5)
        #expect(engine.player.rate == 1.5)

        await engine.seek(to: 9)
        #expect(abs(engine.snapshot.position - 9) < 0.1)
        engine.pause()
        #expect(await waitUntil { engine.snapshot.status == .paused })
        engine.stop()
        #expect(engine.snapshot.status == .idle)
        #expect(engine.player.currentItem == nil)
    }

    /// Serves the fixture through `StreamDataProvider` with a delay, like a
    /// torrent that's still downloading.
    final class SlowProvider: StreamDataProvider {
        let data: Data
        init() throws { data = try Data(contentsOf: Fixtures.testVideoURL) }
        func canProvide(_ url: URL) -> Bool { url.scheme == "bluebox-test" }
        func contentLength(of url: URL) async throws -> Int64 { Int64(data.count) }
        func read(_ url: URL, offset: Int64, length: Int) async throws -> Data {
            try await Task.sleep(for: .milliseconds(5))
            let start = Int(offset), end = min(data.count, start + length)
            return data.subdata(in: start..<end)
        }
    }

    @Test func playsThroughAStreamProvider() async throws {
        let engine = AVPlayerEngine(streams: try SlowProvider())
        engine.player.isMuted = true
        let r = PlaybackResource(
            variant: MediaVariant(id: "s", sourceID: SourceID("t"), mediaKey: nil, displayName: "s", container: "mp4", location: .remote),
            url: URL(string: "bluebox-test://x/0.mp4")!)
        try await engine.load(r, startAt: 3)
        #expect(abs((engine.snapshot.duration ?? 0) - 12) < 0.2)
        #expect(engine.snapshot.audioTracks.count == 2)
        engine.play()
        #expect(await waitUntil(.seconds(5)) { engine.snapshot.position > 3.6 })
        engine.stop()
    }

    @Test func adjustsCapturesAndStepsFrames() async throws {
        let engine = AVPlayerEngine()
        engine.player.isMuted = true
        try await engine.load(testResource(), startAt: 4)
        #expect(engine.snapshot.supportsVideoAdjustments)
        var a = VideoAdjustments(); a.saturation = 0
        engine.setVideoAdjustments(a)
        try await Task.sleep(for: .milliseconds(300))
        let image = try #require(await engine.captureFrame())
        #expect(image.width == 320 && image.height == 180)
        // Black and white: every sampled pixel has r == g == b (within rounding).
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var maxSpread = 0
        for i in stride(from: 0, to: image.width * image.height * 4, by: 4 * 97) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            maxSpread = max(maxSpread, max(r, g, b) - min(r, g, b))
        }
        #expect(maxSpread <= 6)
        let before = engine.snapshot.position
        engine.stepFrame(by: 1)
        #expect(await waitUntil { engine.snapshot.position > before })
        engine.stop()
    }

    @Test func reachesEnd() async throws {
        let engine = AVPlayerEngine()
        engine.player.isMuted = true
        try await engine.load(testResource(), startAt: 10.5)
        engine.play()
        #expect(await waitUntil(.seconds(8)) { engine.snapshot.status == .ended })
        engine.stop()
    }

    @Test func rejectsUnsupportedContainerUpFront() async {
        let engine = AVPlayerEngine()
        await #expect(throws: PlaybackError.unsupportedFormat("mkv")) {
            try await engine.load(testResource(container: "mkv"), startAt: nil)
        }
        #expect(engine.snapshot.status == .failed(.unsupportedFormat("mkv")))
    }

    @Test func missingFileFails() async {
        let engine = AVPlayerEngine()
        let r = PlaybackResource(
            variant: MediaVariant(id: "x", sourceID: SourceID("t"), mediaKey: nil, displayName: "x", container: "mp4", location: .localFile),
            url: URL(fileURLWithPath: "/nonexistent-\(UUID()).mp4")
        )
        await #expect(throws: PlaybackError.self) { try await engine.load(r, startAt: nil) }
        if case .failed = engine.snapshot.status {} else { Issue.record("expected failed status") }
    }
}
