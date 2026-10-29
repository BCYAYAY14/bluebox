import Domain
import Foundation
@testable import Playback
import Testing

@MainActor
@Suite struct ScrubbingTests {
    let movie = NowPlayingItem(key: .movie(tmdbID: 1), title: "One")

    func make() async -> (PlayerSession, MockEngine) {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), deviceID: "test")
        await s.start(movie, resource: resource())
        return (s, engine)
    }

    @Test func scrubbingPausesPreviewsThenLandsExactlyAndResumes() async {
        let (s, engine) = await make()
        #expect(s.snapshot.status == .playing)
        s.scrub(to: 100)
        s.scrub(to: 120)
        #expect(s.isScrubbing)
        #expect(s.snapshot.status == .paused)
        #expect(s.appearsPlaying)  // the button keeps showing Pause mid-drag
        #expect(engine.scrubs == [100, 120])
        #expect(engine.seeks.isEmpty)

        await s.endScrub(at: 130)
        #expect(!s.isScrubbing)
        #expect(engine.seeks == [130])
        #expect(s.snapshot.position == 130)
        #expect(s.snapshot.status == .playing)
    }

    @Test func scrubbingWhilePausedStaysPaused() async {
        let (s, _) = await make()
        s.togglePlayPause()
        #expect(s.snapshot.status == .paused)
        s.scrub(to: 50)
        #expect(!s.appearsPlaying)
        await s.endScrub(at: 60)
        #expect(s.snapshot.status == .paused)
        #expect(s.snapshot.position == 60)
    }

    @Test func abLoopDoesNotFightTheScrub() async {
        let (s, engine) = await make()
        engine.advance(to: 10); s.cycleLoop()
        engine.advance(to: 20); s.cycleLoop()
        #expect(s.loopEnd == 20)
        s.scrub(to: 500)
        engine.advance(to: 500)  // past B while dragging: no jump back to A
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.seeks.isEmpty)
        await s.endScrub(at: 500)
        #expect(engine.seeks.first == 500)
    }

    @Test func diagnosticsFormatting() {
        #expect(PlaybackDiagnostics.formatBitrate(8_400_000) == "8.4 Mbps")
        #expect(PlaybackDiagnostics.formatBitrate(640_000) == "640 kbps")
        #expect(PlaybackDiagnostics.sourceKind(of: URL(fileURLWithPath: "/a.mkv")) == "Local file")
        #expect(PlaybackDiagnostics.sourceKind(of: URL(string: "http://127.0.0.1:8080/stream/x")) == "Torrent")
        #expect(PlaybackDiagnostics.sourceKind(of: URL(string: "https://example.com/a.mp4")) == "Network")
    }
}
