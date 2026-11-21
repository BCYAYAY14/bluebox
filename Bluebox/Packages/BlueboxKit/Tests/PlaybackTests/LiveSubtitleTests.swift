import Domain
import Foundation
@testable import Playback
import Subtitles
import Testing

/// Generated subtitles are a track whose lines grow while it plays.
@MainActor
@Suite struct LiveSubtitleTests {
    let item = NowPlayingItem(key: .movie(tmdbID: 7), title: "Film")
    let sub = ExternalSubtitle(id: ExternalSubtitle.generatedPrefix + "en", url: URL(fileURLWithPath: "/nonexistent/en.srt"),
                               languageCode: "en", label: "English", format: "srt")

    @Test func linesWrittenLaterShowWhenTheirTimeComes() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), deviceID: "test")
        await s.start(item, resource: resource())
        s.addSubtitleTrack(sub, cues: [])
        #expect(s.externalSubtitles.contains { $0.id == sub.id })
        // Not turned on just by being added.
        #expect(s.subtitleSelection == .off)
        s.selectSubtitle(.external(sub.id), remember: false)
        engine.snapshot.position = 12
        #expect(await waitUntil { s.position == 12 })
        #expect(s.subtitleText == nil)
        // Written while it plays: shown at once, without reading the (missing) file.
        s.updateLiveSubtitle(id: sub.id, cues: [SubtitleCue(start: 10, end: 14, text: "Hello there.")])
        #expect(s.subtitleText == "Hello there.")
        #expect(s.subtitleError == nil)
        #expect(s.subtitleCues.count == 1)
        await s.end()
    }

    @Test func aNewVideoForgetsTheLines() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), deviceID: "test")
        await s.start(item, resource: resource("a"))
        s.addSubtitleTrack(sub, cues: [SubtitleCue(start: 0, end: 5, text: "Old")])
        await s.start(NowPlayingItem(key: .movie(tmdbID: 8), title: "Other"), resource: resource("b"))
        #expect(!s.externalSubtitles.contains { $0.id == sub.id })
        await s.end()
    }

    @Test func worksAsTheSecondLine() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), deviceID: "test")
        await s.start(item, resource: resource())
        s.addSubtitleTrack(sub, cues: [])
        s.selectSecondarySubtitle(sub.id)
        engine.snapshot.position = 3
        #expect(await waitUntil { s.position == 3 })
        s.updateLiveSubtitle(id: sub.id, cues: [SubtitleCue(start: 2, end: 4, text: "Second")])
        #expect(s.secondarySubtitleText == "Second")
        await s.end()
    }
}
