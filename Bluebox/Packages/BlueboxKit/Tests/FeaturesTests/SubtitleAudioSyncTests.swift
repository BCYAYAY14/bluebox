import Foundation
@testable import Features
import Subtitles
import Testing
@testable import VLCPlayback

/// Sync to the Audio's plumbing around the fit: which stretches it listens
/// to, which recogniser it asks for, and the clip's own clock.
@MainActor
@Suite struct SubtitleAudioSyncTests {
    static func lines(from: Double, to: Double) -> [SubtitleCue] {
        stride(from: from, to: to, by: 4).map { SubtitleCue(start: $0, end: $0 + 2, text: "Line at \(Int($0))") }
    }

    @Test func listensOnlyWhereThereAreLines() {
        // A track in the video read only around the playhead (minute 40), as VLC does over the network.
        let cues = Self.lines(from: 2350, to: 2500)
        let windows = SubtitleAudioSync.withLines([1500, 2395, 4500], cues: cues, offset: SubtitleOffset())
        #expect(windows == [2395])
        // A subtitle file has lines everywhere: nothing is dropped.
        let all = Self.lines(from: 30, to: 6000)
        #expect(SubtitleAudioSync.withLines([1500, 2395, 4500], cues: all, offset: SubtitleOffset()) == [1500, 2395, 4500])
        #expect(SubtitleAudioSync.withLines([1500], cues: [], offset: SubtitleOffset()).isEmpty)
    }

    @Test func linesAreLookedForThroughTheTimingInUse() {
        // Shown 5 minutes late: the lines for player time 2395 are at 2095 in the file.
        let cues = Self.lines(from: 2050, to: 2200)
        #expect(SubtitleAudioSync.withLines([2395], cues: cues, offset: SubtitleOffset(seconds: 300)) == [2395])
        #expect(SubtitleAudioSync.withLines([2395], cues: cues, offset: SubtitleOffset()).isEmpty)
    }

    @Test func recognizerFollowsTheLanguageAndItsCodes() throws {
        // Two- and three-letter codes (Matroska tags are ISO 639-2) find the same language.
        for code in ["en", "eng", "en-US"] {
            let r = try #require(SubtitleAudioSync.recognizer(for: code), "no recogniser for \(code)")
            #expect(r.locale.language.languageCode == "en")
        }
        if let french = SubtitleAudioSync.recognizer(for: "fre") { #expect(french.locale.language.languageCode == "fr") }
        #expect(SubtitleAudioSync.recognizer(for: "und") == nil)
    }

    @Test func keptClipSaysHowLongItIs() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bluebox-keeplast-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // 70 s decoded (the seek landed early): the last 60 are kept.
        try (VLCAudioClip.wavHeader(dataBytes: 70 * 32_000) + Data(count: 70 * 32_000)).write(to: url)
        #expect(try VLCAudioClip.keepLast(60, of: url) == 60)
        #expect(try Data(contentsOf: url).count == 44 + 60 * 32_000)
        // 42.5 s decoded (it landed late): all of it, and the clip starts 17.5 s after the asked start.
        try (VLCAudioClip.wavHeader(dataBytes: 85 * 16_000) + Data(count: 85 * 16_000)).write(to: url)
        #expect(try VLCAudioClip.keepLast(60, of: url) == 42.5)
        // Under half a second: no sound to listen to.
        try (VLCAudioClip.wavHeader(dataBytes: 8_000) + Data(count: 8_000)).write(to: url)
        #expect(throws: VLCAudioClip.Failure.self) { try VLCAudioClip.keepLast(60, of: url) }
    }
}
