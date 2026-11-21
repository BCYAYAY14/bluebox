import Domain
import Foundation
@testable import Playback
import Subtitles
import Testing

/// A drift fix on an embedded text track Bluebox draws (VLC's MKV tracks):
/// the speed reaches the engine with the delay, and the track can be retimed.
/// Before, VLC's tracks took the delay alone.
@MainActor
@Suite struct EmbeddedSubtitleSpeedTests {
    let movie = NowPlayingItem(key: .movie(tmdbID: 9), title: "Nine")

    /// The mock's track, as one Bluebox draws, on an engine that applies the speed.
    func overlayTrack(_ engine: MockEngine, scales: Bool = true) {
        engine.snapshot.embeddedSubtitles = [MediaTrack(id: "s0", kind: .subtitle, label: "English", languageCode: "en", drawnByBluebox: true)]
        engine.snapshot.scalesEmbeddedSubtitles = scales
    }

    @Test func aSyncsSpeedReachesTheEngine() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress())
        await s.start(movie, resource: resource())
        overlayTrack(engine)
        s.selectSubtitle(.embedded("s0"))
        #expect(s.canRetimeSubtitleLines)
        s.applySubtitleOffset(SubtitleOffset(seconds: -2, scale: 25 / (24000.0 / 1001)))
        #expect(engine.subtitleDelays.last == -2)
        #expect(abs((engine.subtitleScales.last ?? 1) - 25 / (24000.0 / 1001)) < 1e-4)
        s.convertSubtitleFrameRate(subtitleFPS: 24000.0 / 1001, videoFPS: 25)
        #expect(abs((engine.subtitleScales.last ?? 1) - 25 / (24000.0 / 1001)) < 1e-4)
        s.resetSubtitleOffset()
        #expect(engine.subtitleScales.last == 1)
    }

    @Test func onlyTracksBlueboxDrawsWhereTheEngineScalesThem() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress())
        await s.start(movie, resource: resource())
        // The mock's own track: drawn by the engine (styled ASS, pictures): the delay only.
        s.selectSubtitle(.embedded("s0"))
        #expect(!s.canRetimeSubtitleLines)
        // Drawn by Bluebox, but an engine without a speed (AVPlayer): the delay only.
        overlayTrack(engine, scales: false)
        #expect(!s.canRetimeSubtitleLines)
        overlayTrack(engine)
        #expect(s.canRetimeSubtitleLines)
    }
}
