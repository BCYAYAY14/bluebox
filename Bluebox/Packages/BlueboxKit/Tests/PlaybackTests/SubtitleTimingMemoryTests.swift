import Domain
import Foundation
@testable import Playback
import Subtitles
import Testing

/// Subtitle timing kept per video and subtitle track between plays: a
/// `PlayerSession` is new each time something plays, and the delay used to
/// be lost with it (and carried over to the next file chosen in the same play).
@MainActor
@Suite struct SubtitleTimingMemoryTests {
    let movie = NowPlayingItem(key: .movie(tmdbID: 7), title: "Seven")
    let english = ExternalSubtitle(id: "en", url: URL(string: "https://x.test/en.srt")!, languageCode: "en", label: "English", format: "srt")
    let other = ExternalSubtitle(id: "en2", url: URL(string: "https://x.test/en2.srt")!, languageCode: "en", label: "English 2", format: "srt")

    @MainActor final class Store {
        var saved: [String: SubtitleOffset] = [:]
        var memory: SubtitleTimingMemory {
            SubtitleTimingMemory(load: { key, track in self.saved["\(key.rawValue)|\(track)"] },
                                 save: { key, track, offset in self.saved["\(key.rawValue)|\(track)"] = offset })
        }
    }

    func session(_ store: Store, defaultDelay: TimeInterval = 0) -> (PlayerSession, MockEngine) {
        let engine = MockEngine()
        let loader = SubtitleLoader(fetch: { _ in Data("1\n00:00:10,000 --> 00:00:12,000\nHello there.\n".utf8) })
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), subtitleLoader: loader)
        s.subtitleTimings = store.memory
        s.defaultSubtitleDelay = defaultDelay
        return (s, engine)
    }

    @Test func aFixHoldsTheNextTimeTheFilePlays() async {
        let store = Store()
        let (first, _) = session(store)
        await first.start(movie, resource: resource(subs: [english]))
        first.selectSubtitle(.external("en"))
        first.nudgeSubtitles(by: 2.3)
        first.setSubtitleSpeed(25 / (24000.0 / 1001))
        await first.end()

        // Played again: a new session, the same file.
        let (again, _) = session(store)
        await again.start(movie, resource: resource(subs: [english]))
        #expect(again.subtitleOffset.isDefault)
        again.selectSubtitle(.external("en"))
        #expect(again.subtitleOffset.seconds == 2.3)
        #expect(abs(again.subtitleOffset.scale - 25 / (24000.0 / 1001)) < 1e-4)
    }

    @Test func anotherFileStartsFromTheDefaultNotTheLastFilesFix() async {
        let store = Store()
        let (s, engine) = session(store, defaultDelay: 0.5)
        await s.start(movie, resource: resource(subs: [english, other]))
        #expect(s.subtitleOffset.seconds == 0.5)
        s.selectSubtitle(.external("en"))
        // The default still applies to the first file chosen.
        #expect(s.subtitleOffset.seconds == 0.5)
        s.nudgeSubtitles(by: 20)
        #expect(s.subtitleOffset.seconds == 20.5)
        // Before, the 20.5 s carried over to a file timed differently.
        s.selectSubtitle(.external("en2"))
        #expect(s.subtitleOffset.seconds == 0.5)
        #expect(engine.subtitleDelays.last == 0.5)
        // Back to the first: its fix again.
        s.selectSubtitle(.external("en"))
        #expect(s.subtitleOffset.seconds == 20.5)
        // Off and on again keeps it.
        s.selectSubtitle(.off)
        s.selectSubtitle(.external("en"))
        #expect(s.subtitleOffset.seconds == 20.5)
    }

    @Test func theDefaultIsntSavedAndAResetForgetsTheFix() async {
        let store = Store()
        let (s, _) = session(store, defaultDelay: 0.5)
        await s.start(movie, resource: resource(subs: [english]))
        s.selectSubtitle(.external("en"))
        s.nudgeSubtitles(by: 1)
        #expect(store.saved.count == 1)
        s.nudgeSubtitles(by: -1)
        #expect(store.saved.isEmpty)
        s.applySubtitleOffset(SubtitleOffset(seconds: 4))
        s.resetSubtitleOffset()
        #expect(store.saved.values.allSatisfy { $0.isDefault })
    }

    @Test func aTrackInTheVideoIsSavedWithTheVideosFile() async {
        let store = Store()
        let (s, engine) = session(store)
        await s.start(movie, resource: resource("release-a", subs: []))
        engine.advance(to: 1)
        s.selectSubtitle(.embedded("s0"))
        s.nudgeSubtitles(by: -1.5)
        #expect(store.saved.keys.contains { $0.hasSuffix("track:release-a.mp4#s0") })
        await s.end()
        // Another release of the same film: its track 0 has nothing saved.
        let (b, _) = session(store)
        await b.start(movie, resource: resource("release-b", subs: []))
        b.selectSubtitle(.embedded("s0"))
        #expect(b.subtitleOffset.isDefault)
    }
}
