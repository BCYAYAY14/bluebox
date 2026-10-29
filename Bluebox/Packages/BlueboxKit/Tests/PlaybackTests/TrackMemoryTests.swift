import Domain
import Foundation
@testable import Playback
import Testing

/// Audio and subtitle choices carry over to the next item a session plays.
@MainActor
@Suite struct TrackMemoryTests {
    let first = NowPlayingItem(key: .episode(seriesID: 7, season: 1, episode: 1), title: "Show")
    let second = NowPlayingItem(key: .episode(seriesID: 7, season: 1, episode: 2), title: "Show")

    @Test func subtitleChoiceFollowsToTheNextEpisode() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress())
        await s.start(first, resource: resource("a"))
        s.selectSubtitle(.embedded("s0"))
        #expect(s.rememberedSubtitle?.languageCode == "en")

        await s.start(second, resource: resource("b"))
        #expect(s.subtitleSelection == .embedded("s0"))
        #expect(engine.embeddedSelection == "s0")
    }

    @Test func offStaysOffEvenWithAPreferredLanguage() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress())
        var style = s.subtitleStyle
        style.preferredLanguage = "en"
        s.subtitleStyle = style
        await s.start(first, resource: resource("a"))
        #expect(s.subtitleSelection == .embedded("s0"))  // the preference picks English
        s.selectSubtitle(.off)
        await s.start(second, resource: resource("b"))
        #expect(s.subtitleSelection == .off)
    }

    @Test func playPauseFlipsBeforeTheEngineAnswers() async {
        let engine = SlowEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress())
        await s.start(first, resource: resource("a"), autoplay: false)
        #expect(!s.appearsPlaying)
        s.togglePlayPause()
        #expect(s.appearsPlaying)  // engine still says paused
        #expect(engine.snapshot.status == .paused)
        engine.snapshot.status = .playing
        #expect(s.optimisticPlaying == nil)
    }

    @Test func quickSkipsAddUp() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress())
        await s.start(first, resource: resource("a"))
        await s.skip(by: 10)
        await s.skip(by: 10)
        #expect(engine.seeks.last == 20)
    }
}

/// Play and pause take effect later, like VLC.
@MainActor
final class SlowEngine: MockEngine {
    override func play() {}
}
