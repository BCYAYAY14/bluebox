import CoreGraphics
import Foundation
@testable import Subtitles
import Testing

@Suite struct SoundCueTests {
    @Test func stripsCuesLyricsAndSpeakers() {
        #expect(SoundCues.strip("[siren wailing]\nDEB: Where were you last night?") == "Where were you last night?")
        #expect(SoundCues.strip("(sighs) I know.") == "I know.")
        #expect(SoundCues.strip("♪ Never gonna give you up ♪") == nil)
        #expect(SoundCues.strip("[door slams]") == nil)
        #expect(SoundCues.strip("- MAN #2: Run!\n- [screaming]") == "Run!")
        #expect(SoundCues.strip("- Hello.\n- Hi there.") == "- Hello.\n- Hi there.")
    }

    @Test func leavesTimesAndOrdinaryColonsAlone() {
        #expect(SoundCues.strip("Meet me at 10:30.") == "Meet me at 10:30.")
        #expect(SoundCues.strip("Note: it's late.") == "Note: it's late.")
        #expect(SoundCues.strip("I said: no.") == "I said: no.")
    }

    @Test func cueListDropsCueOnlyLines() {
        let cues = [SubtitleCue(start: 1, end: 2, text: "[music]"), SubtitleCue(start: 3, end: 4, text: "JOHN: Hi")]
        #expect(SoundCues.strip(cues) == [SubtitleCue(start: 3, end: 4, text: "Hi")])
        #expect(SoundCues.contains("[music]") && !SoundCues.contains("Hi"))
    }
}

@Suite struct SubtitleLineTests {
    let cues = [SubtitleCue(start: 10, end: 12, text: "One"), SubtitleCue(start: 15, end: 17, text: "Two"),
                SubtitleCue(start: 20, end: 22, text: "Three")]

    @Test func previousReplaysTheLineJustHeard() {
        // Well into "Two": back to its start.
        #expect(SubtitleLines.previous(cues, at: 16.5) == 15 - SubtitleLines.lead)
        // "Two" only just started: the one before.
        #expect(SubtitleLines.previous(cues, at: 15.5) == 10 - SubtitleLines.lead)
        // Between lines: the last one shown.
        #expect(SubtitleLines.previous(cues, at: 18.5) == 15 - SubtitleLines.lead)
        #expect(SubtitleLines.previous(cues, at: 5) == nil)
    }

    @Test func repeatedPressesWalkBack() {
        var t = 21.8  // past the replay window of "Three"
        var visited: [TimeInterval] = []
        for _ in 0..<3 {
            guard let p = SubtitleLines.previous(cues, at: t) else { break }
            visited.append(p); t = p
        }
        #expect(visited == [20, 15, 10].map { $0 - SubtitleLines.lead })
    }

    @Test func nextGoesToTheFollowingLine() {
        #expect(SubtitleLines.next(cues, at: 11) == 15 - SubtitleLines.lead)
        // Landed just before "Two" by a jump: next is "Three", not "Two" again.
        #expect(SubtitleLines.next(cues, at: 15 - SubtitleLines.lead) == 20 - SubtitleLines.lead)
        #expect(SubtitleLines.next(cues, at: 21) == nil)
    }

    @Test func followsTheSubtitleOffset() {
        let later = SubtitleOffset(seconds: 2)
        #expect(SubtitleLines.next(cues, at: 11, offset: later) == 12 - SubtitleLines.lead)
        #expect(SubtitleLines.currentIndex(cues, at: 16.5, offset: later) == 0)
        #expect(SubtitleLines.currentIndex(cues, at: 17.5, offset: later) == 1)
        #expect(SubtitleLines.currentIndex(cues, at: 1) == nil)
    }

    @Test func searchMatchesEveryWordAnyCase() {
        let more = cues + [SubtitleCue(start: 30, end: 31, text: "Café two")]
        #expect(SubtitleLines.search(more, query: "two") == [1, 3])
        #expect(SubtitleLines.search(more, query: "CAFE two") == [3])
        #expect(SubtitleLines.search(more, query: " ") == [0, 1, 2, 3])
    }
}

@Suite struct SubtitleAudioAlignmentTests {
    /// A script of distinct lines, a cue every 4 s.
    static let script: [SubtitleCue] = (0..<120).map { i in
        let words = ["river", "lantern", "copper", "meadow", "harbor", "violet", "thunder", "pepper", "falcon", "orchard",
                     "marble", "saddle", "candle", "silver", "willow", "garden", "rocket", "pillow", "basket", "anchor"]
        let a = words[i % 20], b = words[(i * 7 + 3) % 20], c = words[(i * 11 + 5) % 20]
        return SubtitleCue(start: Double(i) * 4 + 30, end: Double(i) * 4 + 33, text: "the \(a) and \(b) near \(c) number\(i)")
    }

    /// What a recogniser would hear if the speech plays at `heard = cue / scale + delay`.
    static func heard(_ cues: [SubtitleCue], delay: Double, scale: Double = 1, within: ClosedRange<Double>) -> [SubtitleAudioAlignment.HeardWord] {
        cues.flatMap { c -> [SubtitleAudioAlignment.HeardWord] in
            let words = c.text.split(separator: " ").map(String.init)
            let step = (c.end - c.start) / Double(words.count)
            return words.enumerated().compactMap { i, w in
                let t = (c.start + step * (Double(i) + 0.5)) / scale + delay
                return within.contains(t) ? .init(w, at: t) : nil
            }
        }
    }

    @Test func findsTheDelay() throws {
        let words = Self.heard(Self.script, delay: 2.4, within: 100...160)
        let r = try #require(SubtitleAudioAlignment.fit(words: words, cues: Self.script))
        #expect(abs(r.offset.seconds - 2.4) < 0.3)
        #expect(r.offset.scale == 1 && !r.fittedDrift)
    }

    @Test func findsDriftFromTwoStretches() throws {
        // Made for 25 fps, playing at 23.976: cue time runs fast by 25/23.976.
        let scale = 25.0 / (24000.0 / 1001)
        let words = Self.heard(Self.script, delay: -1.5, scale: scale, within: 60...120)
            + Self.heard(Self.script, delay: -1.5, scale: scale, within: 380...440)
        let r = try #require(SubtitleAudioAlignment.fit(words: words, cues: Self.script))
        #expect(r.fittedDrift)
        #expect(abs(r.offset.scale - scale) < 0.003)
        // Lines land where they're heard.
        for c in [Self.script[10], Self.script[90]] {
            #expect(abs(r.offset.playerTime(forCueTime: c.start) - (c.start / scale - 1.5)) < 0.4)
        }
    }

    @Test func delayOnlyWhenDriftCantBeApplied() throws {
        let words = Self.heard(Self.script, delay: 3, within: 60...120) + Self.heard(Self.script, delay: 3, within: 380...440)
        let r = try #require(SubtitleAudioAlignment.fit(words: words, cues: Self.script, fitsDrift: false))
        #expect(!r.fittedDrift && abs(r.offset.seconds - 3) < 0.3)
    }

    @Test func refusesUnrelatedSpeech() {
        let words = (0..<80).map { SubtitleAudioAlignment.HeardWord(["alpha", "bravo", "charlie", "delta"][$0 % 4] + "\($0)", at: Double($0)) }
        #expect(SubtitleAudioAlignment.fit(words: words, cues: Self.script) == nil)
    }

    @Test func toleratesMisheardWords() throws {
        var words = Self.heard(Self.script, delay: 0.8, within: 100...200)
        for i in stride(from: 0, to: words.count, by: 3) { words[i].text = "uh" }  // a third misheard
        let r = try #require(SubtitleAudioAlignment.fit(words: words, cues: Self.script))
        #expect(abs(r.offset.seconds - 0.8) < 0.3)
    }
}

@Suite struct SubtitleBurnInTests {
    @Test func drawsAtTheBottomInsideTheMargins() throws {
        let burn = SubtitleBurnIn(primary: "Where were you last night?", secondary: nil, style: SubtitleStyle())
        let r = try #require(burn.render(frame: CGSize(width: 1920, height: 1080)))
        #expect(r.image.width > 200 && r.image.width < 1920)
        #expect(r.image.height > 30 && r.image.height < 200)
        // Bottom: near the default margin from the bottom (Core Image counts up from the bottom).
        #expect(r.origin.y < 1080 * 0.12)
        // Centred.
        #expect(abs((r.origin.x + CGFloat(r.image.width) / 2) - 960) < 4)
        #expect(SubtitleBurnIn.png(r.image) != nil)
    }

    @Test func topAnchorAndSecondLine() throws {
        var style = SubtitleStyle(); style.anchor = .top
        let one = try #require(SubtitleBurnIn(primary: "Hello", secondary: nil, style: style).render(frame: CGSize(width: 1280, height: 720)))
        let two = try #require(SubtitleBurnIn(primary: "Hello", secondary: "Hola", style: style).render(frame: CGSize(width: 1280, height: 720)))
        #expect(one.origin.y > 720 * 0.7)
        #expect(two.image.height > one.image.height)
        #expect(one.topLeft.y < 720 * 0.1)
    }

    @Test func nothingToDraw() {
        #expect(SubtitleBurnIn(primary: nil, secondary: "", style: SubtitleStyle()).render(frame: CGSize(width: 100, height: 100)) == nil)
    }
}
