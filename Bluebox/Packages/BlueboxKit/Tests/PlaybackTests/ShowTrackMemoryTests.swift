import Domain
import Foundation
@testable import Playback
import Subtitles
import Testing

/// Picks kept per show across players, the second line on a video's own
/// tracks, and Turn On following the audio.
@MainActor
@Suite struct ShowTrackMemoryTests {
    let episode1 = NowPlayingItem(key: .episode(seriesID: 7, season: 1, episode: 1), title: "Show")
    let episode2 = NowPlayingItem(key: .episode(seriesID: 7, season: 1, episode: 2), title: "Show")

    /// What `AppModel` does: a fresh session for every play, sharing one memory.
    private func session(_ engine: MockEngine, memory: Box, preferred: String? = "en", turnsOn: SubtitleStyle.TurnOn = .always) -> PlayerSession {
        let s = PlayerSession(engine: engine, progress: MemoryProgress())
        var style = s.subtitleStyle
        style.preferredLanguage = preferred
        style.turnsOn = turnsOn
        s.subtitleStyle = style
        s.showTrackChoices = { key in memory.value.entry(for: (key.seriesKey ?? key).rawValue) }
        s.onTrackChosen = { key, audio, subtitle in memory.value.remember(audio: audio, subtitle: subtitle, for: (key.seriesKey ?? key).rawValue) }
        return s
    }

    @Test func offForAShowSurvivesANewPlayer() async {
        let memory = Box()
        let first = session(TracksEngine(), memory: memory)
        await first.start(episode1, resource: resource("a"))
        #expect(first.subtitleSelection == .embedded("en"))  // the preferred language
        first.selectSubtitle(.off)

        // Next episode, new player: still Off, though English is there and preferred.
        let next = session(TracksEngine(), memory: memory)
        await next.start(episode2, resource: resource("b"))
        #expect(next.subtitleSelection == .off)
        #expect(next.rememberedSubtitle?.isOff == true)
    }

    @Test func aLanguagePickedForAShowWinsOverThePreferredOne() async {
        let memory = Box()
        let first = session(TracksEngine(), memory: memory)
        await first.start(episode1, resource: resource("a"))
        first.selectSubtitle(.embedded("ja"))
        first.selectAudio("a-ja")
        let next = session(TracksEngine(), memory: memory)
        await next.start(episode2, resource: resource("b"))
        #expect(next.subtitleSelection == .embedded("ja"))
        #expect(next.snapshot.selectedAudioID == "a-ja")
        // Another show isn't touched.
        let other = session(TracksEngine(), memory: memory)
        await other.start(NowPlayingItem(key: .episode(seriesID: 9, season: 1, episode: 1), title: "Other"), resource: resource("c"))
        #expect(other.subtitleSelection == .embedded("en"))
        // Only what was picked is kept: picking audio leaves the subtitle pick alone.
        #expect(memory.value.entry(for: episode1.key.seriesKey!.rawValue)?.subtitle?.languageCode == "ja")
    }

    @Test func theSecondLineFindsATrackInsideTheVideo() async {
        let engine = TracksEngine()
        let s = session(engine, memory: Box())
        var style = s.subtitleStyle
        style.secondaryLanguage = "ja"
        s.subtitleStyle = style
        await s.start(episode1, resource: resource("a"))
        #expect(s.subtitleSelection == .embedded("en"))
        #expect(s.secondarySubtitleID == "ja")
        #expect(engine.secondaryEmbeddedSelection == "ja")
    }

    @Test func theSecondLineWaitsForTheVideosTracks() async {
        let engine = TracksEngine()
        engine.tracksLater = true
        let s = session(engine, memory: Box())
        var style = s.subtitleStyle
        style.secondaryLanguage = "ja"
        s.subtitleStyle = style
        await s.start(episode1, resource: resource("a"), autoplay: false)
        #expect(s.secondarySubtitleID == nil)
        engine.publishTracks()
        #expect(s.secondarySubtitleID == "ja")
    }

    @Test func turnOnFollowsTheAudio() async {
        // English audio, English preferred: only the Forced track.
        let english = TracksEngine()
        english.audio = "a-en"
        let s = session(english, memory: Box(), turnsOn: .foreignAudio)
        await s.start(episode1, resource: resource("a"))
        #expect(s.subtitleSelection == .embedded("en-forced"))
        // Japanese audio: the full English track.
        let japanese = TracksEngine()
        japanese.audio = "a-ja"
        let j = session(japanese, memory: Box(), turnsOn: .foreignAudio)
        await j.start(episode1, resource: resource("a"))
        #expect(j.subtitleSelection == .embedded("en"))
        // Settings' audio language switching to English a moment later: down to Forced.
        j.selectAudio("a-en", remember: false)
        #expect(j.subtitleSelection == .embedded("en-forced"))
        // Forced Only: forced whatever the audio.
        let forced = TracksEngine()
        forced.audio = "a-ja"
        let f = session(forced, memory: Box(), turnsOn: .forcedOnly)
        await f.start(episode1, resource: resource("a"))
        #expect(f.subtitleSelection == .embedded("en-forced"))
        #expect(f.ruleDecision == .forcedOnly)
    }

    @Test func turnOnWaitsToHearTheAudio() async {
        let engine = TracksEngine()
        engine.tracksLater = true
        engine.audio = "a-en"
        let s = session(engine, memory: Box(), turnsOn: .foreignAudio)
        await s.start(episode1, resource: resource("a"), autoplay: false)
        #expect(s.subtitleSelection == .off)
        engine.publishTracks()
        #expect(s.subtitleSelection == .embedded("en-forced"))
    }

    @Test func picksAreCountedPerItem() async {
        let s = session(TracksEngine(), memory: Box())
        await s.start(episode1, resource: resource("a"))
        #expect(s.subtitlePicks == 0)  // the preferred language isn't a person's pick
        s.selectSubtitle(.off)
        #expect(s.subtitlePicks == 1)
        await s.start(episode2, resource: resource("b"))
        #expect(s.subtitlePicks == 0)
    }

    @Test func theDecisionTable() {
        let d = SubtitleTurnOnRule.decision
        #expect(d(.always, "en", "en", true) == .fullTrack)
        #expect(d(.foreignAudio, "en", "eng", true) == .forcedOnly)
        #expect(d(.foreignAudio, "en", "ja", true) == .fullTrack)
        #expect(d(.foreignAudio, "en", nil, true) == .fullTrack)
        #expect(d(.foreignAudio, "en", "und", true) == .fullTrack)
        #expect(d(.foreignAudio, "en", nil, false) == .waitForAudio)
        #expect(d(.forcedOnly, "en", "ja", true) == .forcedOnly)
        let tracks = [MediaTrack(id: "1", kind: .subtitle, label: "English (Forced)", languageCode: "en"),
                      MediaTrack(id: "2", kind: .subtitle, label: "English", languageCode: "en")]
        #expect(SubtitleTurnOnRule.forced(tracks).map(\.id) == ["1"])
    }

    @Test func turnOnIsSavedWithTheStyle() throws {
        var style = SubtitleStyle()
        // Left out while it's the default, so older builds read the same bytes.
        #expect(!String(decoding: try JSONEncoder().encode(style), as: UTF8.self).contains("turnsOn"))
        style.turnsOn = .foreignAudio
        let back = try JSONDecoder().decode(SubtitleStyle.self, from: try JSONEncoder().encode(style))
        #expect(back.turnsOn == .foreignAudio)
        #expect(try JSONDecoder().decode(SubtitleStyle.self, from: Data("{}".utf8)).turnsOn == .always)
    }

    @Test func memoryKeepsTheLatestShows() {
        var m = ShowTrackMemory()
        for i in 0..<(ShowTrackMemory.limit + 5) {
            m.remember(audio: nil, subtitle: .off, for: "show\(i)", at: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(m.shows.count == ShowTrackMemory.limit)
        #expect(m.entry(for: "show0") == nil && m.entry(for: "show\(ShowTrackMemory.limit + 4)") != nil)
        let back = try? JSONDecoder().decode(ShowTrackMemory.self, from: JSONEncoder().encode(m))
        #expect(back == m)
    }
}

/// The memory the app would keep in preferences.
@MainActor
final class Box {
    var value = ShowTrackMemory()
}

/// English, English (Forced) and Japanese subtitles inside the video (handed
/// to Bluebox, like an MKV's text in VLC), with English and Japanese audio.
@MainActor
final class TracksEngine: MockEngine {
    var audio = "a-en"
    /// Tracks show up only on `publishTracks()`, like a stream still opening.
    var tracksLater = false

    override func load(_ resource: PlaybackResource, startAt: TimeInterval?) async throws {
        try await super.load(resource, startAt: startAt)
        var s = snapshot
        s.embeddedSubtitles = []
        snapshot = s
        if !tracksLater { publishTracks() }
    }

    func publishTracks() {
        var s = snapshot
        s.embeddedSubtitles = [
            MediaTrack(id: "en", kind: .subtitle, label: "English", languageCode: "en", drawnByBluebox: true),
            MediaTrack(id: "en-forced", kind: .subtitle, label: "English (Forced)", languageCode: "en", drawnByBluebox: true),
            MediaTrack(id: "ja", kind: .subtitle, label: "Japanese", languageCode: "ja", drawnByBluebox: true),
        ]
        s.audioTracks = [MediaTrack(id: "a-en", kind: .audio, label: "English", languageCode: "en"),
                         MediaTrack(id: "a-ja", kind: .audio, label: "Japanese", languageCode: "ja")]
        s.selectedAudioID = audio
        snapshot = s
    }
}
