import CoreGraphics
import Domain
import Foundation
@testable import Playback
import Subtitles
import Testing

@Suite struct VideoLayoutTests {
    let screen = CGSize(width: 1600, height: 900)
    let hd = CGSize(width: 1920, height: 1080)

    func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    @Test func defaultFitsWithoutCropping() {
        let l = VideoLayout(container: screen, natural: hd, framing: VideoFraming())
        #expect(close(l.videoFrame, CGRect(x: 0, y: 0, width: 1600, height: 900)))
        #expect(close(l.visibleRect, CGRect(x: 0, y: 0, width: 1600, height: 900)))
    }

    @Test func aspectOverrideLetterboxes() {
        var f = VideoFraming(); f.aspect = .r2_35
        let l = VideoLayout(container: screen, natural: hd, framing: f)
        #expect(abs(l.visibleRect.width - 1600) < 0.5)
        #expect(abs(l.visibleRect.height - 1600 / 2.35) < 0.5)
        #expect(abs(l.visibleRect.midY - 450) < 0.5)
    }

    @Test func cropRemovesBakedInBarsAndFills() {
        // A 4:3 file with a 16:9 picture inside: crop to 16:9 and it fills a 16:9 screen.
        var f = VideoFraming(); f.crop = .r16x9
        let l = VideoLayout(container: screen, natural: CGSize(width: 1440, height: 1080), framing: f)
        #expect(close(l.visibleRect, CGRect(x: 0, y: 0, width: 1600, height: 900)))
        // The full layer is taller than the screen; the box clips the bars.
        #expect(l.videoFrame.height > 900 && l.videoFrame.minY < 0)
    }

    @Test func zoomAndPanMoveThePicture() {
        var f = VideoFraming(); f.setZoom(2); f.setPan(x: 1, y: 0)
        let l = VideoLayout(container: screen, natural: hd, framing: f)
        #expect(abs(l.videoFrame.width - 3200) < 0.5)
        #expect(abs(l.videoFrame.minX - (-1600)) < 0.5)   // panned fully right shows the right half
        #expect(close(l.visibleRect, CGRect(origin: .zero, size: screen)))
        f.setZoom(1)
        #expect(f.panX == 0)
    }

    @Test func quarterTurnSwapsTheBox() {
        var f = VideoFraming(); f.rotate()
        let l = VideoLayout(container: screen, natural: hd, framing: f)
        #expect(l.box == CGSize(width: 900, height: 1600))
        #expect(l.rotationDegrees == 90)
        // 16:9 fitted into a 900-wide box, then turned: a tall picture centered on screen.
        #expect(abs(l.visibleRect.height - 900) < 0.5 && abs(l.visibleRect.width - 506.25) < 0.5)
        #expect(abs(l.visibleRect.midX - 800) < 0.5)
    }

    @Test func manualCropTrimsEdges() {
        var f = VideoFraming(); f.cropTop = 0.1; f.cropBottom = 0.1
        let r = f.cropRect(sourceAspect: 16.0 / 9)
        #expect(abs(r.minY - 0.1) < 1e-9 && abs(r.height - 0.8) < 1e-9)
        f.cropLeft = 0.9  // clamped to 0.45
        #expect(f.cropRect(sourceAspect: 16.0 / 9).minX == 0.45)
    }
}

@MainActor
@Suite struct PlayerToolsSessionTests {
    let movie = NowPlayingItem(key: .movie(tmdbID: 1), title: "One")

    func session(_ engine: MockEngine, subs: [ExternalSubtitle] = [], loader: SubtitleLoader = SubtitleLoader()) -> PlayerSession {
        PlayerSession(engine: engine, progress: MemoryProgress(), subtitleLoader: loader)
    }

    @Test func abLoopJumpsBack() async throws {
        let engine = MockEngine()
        let s = session(engine)
        await s.start(movie, resource: resource())
        engine.advance(to: 100); s.cycleLoop()
        engine.advance(to: 110); s.cycleLoop()
        #expect(s.loopStart == 100 && s.loopEnd == 110)
        engine.advance(to: 110.2)
        #expect(await waitUntil { engine.snapshot.position == 100 })
        s.cycleLoop()
        #expect(s.loopStart == nil && s.loopEnd == nil)
    }

    @Test func sleepAtEndOfItemStopsAutoplay() async throws {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), nextProvider: { _ in
            (NowPlayingItem(key: .movie(tmdbID: 2), title: "Two"), resource("two"))
        })
        await s.start(movie, resource: resource())
        s.setSleepTimer(.endOfItem)
        engine.finish()
        try await Task.sleep(for: .milliseconds(100))
        #expect(s.upNext == nil)
        #expect(s.sleepTimer == .off)
    }

    @Test func chapterNavigation() async throws {
        let engine = MockEngine()
        let s = session(engine)
        await s.start(movie, resource: resource())
        engine.snapshot.chapters = [Chapter(title: "A", start: 0), Chapter(title: "B", start: 300), Chapter(title: "C", start: 900)]
        engine.advance(to: 310)
        #expect(s.currentChapterIndex == 1)
        await s.jumpToChapter(offset: 1)
        #expect(engine.snapshot.position == 900)
        engine.advance(to: 950)
        await s.jumpToChapter(offset: -1)   // more than 3 s in: back to the chapter's start
        #expect(engine.snapshot.position == 900)
        await s.jumpToChapter(offset: -1)
        #expect(engine.snapshot.position == 300)
    }

    @Test func syncThisLineThenFixDrift() async throws {
        let srt = """
        1
        00:01:40,000 --> 00:01:42,000
        First

        2
        00:50:00,000 --> 00:50:02,000
        Later
        """
        let sub = ExternalSubtitle(id: "x", url: URL(string: "https://example.invalid/x.srt")!, languageCode: "en", label: "EN", format: "srt")
        let engine = MockEngine()
        let s = session(engine, loader: SubtitleLoader(fetch: { _ in Data(srt.utf8) }))
        await s.start(movie, resource: resource(subs: [sub]))
        s.selectSubtitle(.external("x"))
        engine.advance(to: 102)   // "First" heard at 1:42
        #expect(await waitUntil { !s.nearbyCues.isEmpty })
        s.syncCue(s.nearbyCues.first { $0.text == "First" }!)
        #expect(s.pendingSyncPoint != nil)
        engine.advance(to: 3127)  // "Later" heard at 52:07
        s.syncCue(s.nearbyCues.first { $0.text == "Later" }!)
        #expect(s.pendingSyncPoint == nil)
        #expect(abs(s.subtitleOffset.playerTime(forCueTime: 3000) - 3127) < 0.05)
        engine.advance(to: 3128)
        #expect(s.subtitleText == "Later")
    }

    @Test func dualSubtitlesAndEmbeddedText() async throws {
        let en = "1\n00:00:01,000 --> 00:00:05,000\nHello\n"
        let es = "1\n00:00:01,000 --> 00:00:05,000\nHola\n"
        let subs = [ExternalSubtitle(id: "en", url: URL(string: "https://e.invalid/en.srt")!, languageCode: "en", label: "EN", format: "srt"),
                    ExternalSubtitle(id: "es", url: URL(string: "https://e.invalid/es.srt")!, languageCode: "es", label: "ES", format: "srt")]
        let engine = MockEngine()
        let s = session(engine, loader: SubtitleLoader(fetch: { $0.lastPathComponent == "en.srt" ? Data(en.utf8) : Data(es.utf8) }))
        await s.start(movie, resource: resource(subs: subs))
        s.selectSubtitle(.external("en"))
        s.selectSecondarySubtitle("es")
        engine.advance(to: 2)
        #expect(await waitUntil { s.subtitleText == "Hello" && s.secondarySubtitleText == "Hola" })

        // Embedded tracks: the engine supplies the text and Bluebox draws it.
        s.selectSubtitle(.embedded("s0"))
        engine.snapshot.embeddedSubtitleText = "Embedded line"
        #expect(s.subtitleText == "Embedded line")
    }

    @Test func adjustmentsReachTheEngine() async {
        final class Spy: MockEngine { var applied: VideoAdjustments?; override func setVideoAdjustments(_ a: VideoAdjustments) { applied = a } }
        let engine = Spy()
        let s = session(engine)
        var a = VideoAdjustments(); a.saturation = 0
        s.setVideoAdjustments(a)
        #expect(engine.applied?.saturation == 0)
    }

    @Test func volumeClampsAndUnmuteComesBackAudible() {
        let engine = MockEngine()
        let s = session(engine)
        s.setVolume(1.4)
        #expect(s.volume == 1 && engine.volume == 1)
        s.setVolume(0)
        s.setMuted(true)
        #expect(engine.muted)
        s.setMuted(false)
        #expect(s.volume == 0.5 && !engine.muted)
        s.setMuted(true)
        s.setVolume(0.3)  // raising the volume unmutes, like the system's
        #expect(!s.isMuted && engine.volume == 0.3 && !engine.muted)
    }

    @Test func audioDelayIsClampedAndReappliedOnLoad() async {
        let engine = MockEngine()
        let s = session(engine)
        s.setAudioDelay(0.0504)
        #expect(s.audioDelay == 0.05)
        s.setAudioDelay(9)
        #expect(s.audioDelay == 5)
        engine.audioDelay = 0
        await s.start(movie, resource: resource())
        #expect(engine.audioDelay == 5)
        #expect(s.supportsAudioDelay)
    }
}
