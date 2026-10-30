import Domain
import Foundation
@testable import Playback
import Subtitles
import Testing

@MainActor
@Suite struct SubtitleFeatureSessionTests {
    let movie = NowPlayingItem(key: .movie(tmdbID: 1), title: "One")
    nonisolated static let srt = """
    1
    00:00:10,000 --> 00:00:12,000
    [door slams]

    2
    00:00:15,000 --> 00:00:17,000
    DEB: Where were you?

    3
    00:00:20,000 --> 00:00:22,000
    Out. Walking.
    """

    func loader() -> SubtitleLoader { SubtitleLoader(fetch: { _ in Data(Self.srt.utf8) }) }
    let file = ExternalSubtitle(id: "f", url: URL(string: "https://x.test/a.srt")!, languageCode: "en", label: "English", format: "srt")

    @Test func hideSoundCuesCleansTheLineAndTheList() async throws {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), subtitleLoader: loader())
        await s.start(movie, resource: resource(subs: [file]))
        s.selectSubtitle(.external("f"))
        #expect(await waitUntil { s.subtitleCues.count == 3 })
        engine.advance(to: 16)
        #expect(s.subtitleText == "DEB: Where were you?")
        s.subtitleStyle.hidesSoundCues = true
        #expect(s.subtitleText == "Where were you?")
        #expect(s.subtitleCues.map(\.text) == ["Where were you?", "Out. Walking."])
        engine.advance(to: 11)
        #expect(s.subtitleText == nil)
    }

    @Test func previousAndNextLine() async throws {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), subtitleLoader: loader())
        await s.start(movie, resource: resource(subs: [file]))
        s.selectSubtitle(.external("f"))
        #expect(await waitUntil { !s.subtitleCues.isEmpty })
        engine.advance(to: 18)
        #expect(await s.jumpToLine(next: false))
        #expect(engine.snapshot.position == 15 - SubtitleLines.lead)
        #expect(await s.jumpToLine(next: true))
        #expect(engine.snapshot.position == 20 - SubtitleLines.lead)
        #expect(await s.jumpToLine(next: true) == false)
        // With a delay the lines move with it.
        s.nudgeSubtitles(by: 1)
        engine.advance(to: 12)
        #expect(await s.jumpToLine(next: true))
        #expect(engine.snapshot.position == 16 - SubtitleLines.lead)
    }

    @Test func cTurnsSubtitlesOffAndBack() async throws {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), subtitleLoader: loader())
        await s.start(movie, resource: resource(subs: [file]))
        s.selectSubtitle(.embedded("s0"))
        #expect(s.toggleSubtitles() == .off)
        #expect(s.toggleSubtitles() == .embedded("s0"))
        // Never on in this video: the preferred language, else the first track.
        s.selectSubtitle(.off)
        let fresh = PlayerSession(engine: MockEngine(), progress: MemoryProgress(), subtitleLoader: loader())
        await fresh.start(movie, resource: resource(subs: [file]))
        fresh.selectSubtitle(.off)
        #expect(fresh.toggleSubtitles() == .embedded("s0"))
    }

    @Test func torrentFilePickedOnlyWithoutAVideoTrackInTheLanguage() async throws {
        let torrentFR = ExternalSubtitle(id: ExternalSubtitle.torrentPrefix + "Subs/French.srt", url: URL(string: "https://x.test/f.srt")!,
                                         languageCode: "fr", label: "French", format: "srt")
        let torrentEN = ExternalSubtitle(id: ExternalSubtitle.torrentPrefix + "Subs/English.srt", url: URL(string: "https://x.test/e.srt")!,
                                         languageCode: "en", label: "English", format: "srt")
        // The video has English (MockEngine's "s0"): that wins over the torrent's English.
        let a = PlayerSession(engine: MockEngine(), progress: MemoryProgress(), subtitleLoader: loader())
        a.subtitleStyle.preferredLanguage = "en"
        await a.start(movie, resource: resource(subs: [torrentEN]))
        #expect(a.subtitleSelection == .embedded("s0"))
        // French: only the torrent has it, so it's picked.
        let b = PlayerSession(engine: MockEngine(), progress: MemoryProgress(), subtitleLoader: loader())
        b.subtitleStyle.preferredLanguage = "fr"
        await b.start(movie, resource: resource(subs: [torrentFR]))
        #expect(b.subtitleSelection == .external(torrentFR.id))
    }

    @Test func burnInFollowsPictureInPictureAndTheLine() async throws {
        let engine = BurnInEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), subtitleLoader: loader())
        await s.start(movie, resource: resource(subs: [file]))
        s.selectSubtitle(.external("f"))
        #expect(await waitUntil { !s.subtitleCues.isEmpty })
        engine.advance(to: 21)
        #expect(engine.burnIns.isEmpty)
        s.drawsSubtitlesInPicture = true
        #expect(engine.burnIns.last??.primary == "Out. Walking.")
        s.subtitleStyle.relativeSize = 0.06
        #expect(engine.burnIns.last??.style.relativeSize == 0.06)
        s.drawsSubtitlesInPicture = false
        #expect(engine.burnIns.last! == nil)
    }

    @Test func applyingASyncResultSetsTheDelay() async throws {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), subtitleLoader: loader())
        await s.start(movie, resource: resource(subs: [file]))
        s.applySubtitleOffset(SubtitleOffset(seconds: 1.4, scale: 1.04))
        #expect(s.subtitleOffset.seconds == 1.4 && s.subtitleOffset.scale == 1.04)
    }
}

@MainActor
final class BurnInEngine: MockEngine {
    var burnIns: [SubtitleBurnIn?] = []
    override func setSubtitleBurnIn(_ burnIn: SubtitleBurnIn?) { burnIns.append(burnIn) }
}
