import Foundation
@testable import Subtitles
import Testing

@Suite struct SpeechSubtitlesTests {
    /// Words from a sentence, a third of a second each, as the recogniser gives them.
    func words(_ text: String, from start: TimeInterval, each: TimeInterval = 0.3) -> [HeardWord] {
        text.split(separator: " ").enumerated().map { i, w in
            HeardWord((i == 0 ? "" : " ") + w, start: start + Double(i) * each, end: start + Double(i + 1) * each - 0.05)
        }
    }

    @Test func fullStopsAndPausesEndSentences() {
        let heard = words("I've been looking for you. All this time", from: 10) + words("Where were you", from: 14)
        let sentences = SpeechSubtitles.sentences(heard)
        #expect(sentences.map(\.text) == ["I've been looking for you.", "All this time", "Where were you"])
        #expect(sentences[0].start == 10)
    }

    @Test func aTitleDoesntEndTheSentence() {
        let sentences = SpeechSubtitles.sentences(words("Ask Mr. Holmes and Dr. Watson. They know", from: 0))
        #expect(sentences.map(\.text) == ["Ask Mr. Holmes and Dr. Watson.", "They know"])
    }

    @Test func aShortSentenceIsOneLineWithItsWordsTimes() {
        let sentence = SpeechSubtitles.sentences(words("Where were you last night?", from: 5))[0]
        let cues = SpeechSubtitles.cues([sentence])
        #expect(cues.count == 1)
        #expect(cues[0].text == "Where were you last night?")
        #expect(cues[0].start == 5)
        // A moment after the last word ends.
        #expect(abs(cues[0].end - (5 + 1.45 + SpeechSubtitles.linger)) < 0.001)
    }

    @Test func aLongSentenceIsCutIntoLinesOfTwoRows() {
        let text = "This is a very long sentence that somebody says without stopping for breath, which goes on and on well past what fits on two rows of a subtitle"
        let cues = SpeechSubtitles.cues(SpeechSubtitles.sentences(words(text, from: 0, each: 0.2)))
        #expect(cues.count >= 2)
        for cue in cues {
            let rows = cue.text.split(separator: "\n")
            #expect(rows.count <= 2)
            #expect(rows.allSatisfy { $0.count <= 42 })
        }
        // In order, and never two at once.
        for (a, b) in zip(cues, cues.dropFirst()) { #expect(a.end <= b.start) }
    }

    @Test func aTranslationSharesTheSentencesTime() {
        let sentence = SpeechSubtitles.sentences(words("ずっと 君を 探してたんだ。", from: 20, each: 0.6))[0]
        let cues = SpeechSubtitles.cues([sentence], translations: [sentence.key: "I've been looking for you all this time."])
        #expect(cues.count == 1)
        #expect(cues[0].text == "I've been looking for you all this time.")
        #expect(cues[0].start == 20)
    }

    @Test func aLongTranslationIsCutWhereThereAreSpaces() {
        let sentence = SpokenSentence(words: [HeardWord("x", start: 0, end: 8)])
        let long = "Every word of this translation is longer than the sentence heard, so it has to be cut into two lines that each take part of the time."
        let cues = SpeechSubtitles.cues(for: sentence, translation: long)
        #expect(cues.count == 2)
        #expect(cues[0].start == 0 && abs(cues[1].end - 8) < 0.001)
        #expect(cues.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " ") == long)
    }

    @Test func linesStayUpLongEnoughToRead() {
        let quick = [SubtitleCue(start: 1, end: 1.2, text: "Hi."), SubtitleCue(start: 1.5, end: 2, text: "Hey.")]
        let settled = SpeechSubtitles.settle(quick)
        // The first is cut short by the next, never over it.
        #expect(settled[0].end <= 1.5)
        #expect(settled[1].end >= 2.5)
    }

    @Test func denseScriptsWrapIntoShorterRows() {
        let text = "これはとても長い日本語の文章で二行に分けなければなりません"
        let wrapped = SpeechSubtitles.wrap(text)
        #expect(wrapped.contains("\n"))
        #expect(wrapped.replacingOccurrences(of: "\n", with: "") == text)
        #expect(SpeechSubtitles.wrap("Short line.") == "Short line.")
    }

    @Test func srtRoundTripsThroughTheParser() throws {
        let cues = [SubtitleCue(start: 1.5, end: 3, text: "One"), SubtitleCue(start: 3661.25, end: 3663, text: "Two\nrows")]
        let srt = SpeechSubtitles.srt(cues)
        #expect(srt.contains("01:01:01,250 --> 01:01:03,000"))
        let parsed = try SubtitleParser.parse(Data(srt.utf8), format: .srt)
        #expect(parsed.cues.map(\.text) == ["One", "Two\nrows"])
        #expect(abs(parsed.cues[1].start - 3661.25) < 0.001)
    }

    @Test func inventedLinesAreDropped() {
        let cues = [SubtitleCue(start: 0, end: 1, text: "Hello."), SubtitleCue(start: 1, end: 2, text: "Thanks for watching!"),
                    SubtitleCue(start: 2, end: 3, text: "No."), SubtitleCue(start: 3, end: 4, text: "No."), SubtitleCue(start: 4, end: 5, text: "No.")]
        #expect(SpeechSubtitles.withoutInventedLines(cues).map(\.text) == ["Hello.", "No.", "No."])
    }
}

@Suite struct CoveredTimeTests {
    @Test func rangesMergeAndGapsAreFound() {
        var covered = CoveredTime()
        covered.insert(30...60)
        covered.insert(60.5...90)
        covered.insert(200...230)
        #expect(covered.ranges == [30...90, 200...230])
        #expect(covered.reach(from: 45) == 90)
        #expect(covered.reach(from: 100) == 100)
        #expect(covered.firstGap(from: 45, before: 300).map { $0 > 90 && $0 < 91 } == true)
        #expect(covered.firstGap(from: 0, before: 300) == 0)
        #expect(!covered.covers(300))
        covered.insert(0...30)
        covered.insert(90...200)
        covered.insert(230...300)
        #expect(covered.covers(300))
        #expect(covered.total == 300)
    }

    @Test func survivesCoding() throws {
        let covered = CoveredTime([0...10, 50...70])
        let back = try JSONDecoder().decode(CoveredTime.self, from: JSONEncoder().encode(covered))
        #expect(back == covered)
    }
}
