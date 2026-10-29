import Foundation
import Subtitles
import Testing

@Suite struct SubtitleParserTests {
    @Test func srtWithBOMCRLFAndTags() throws {
        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i> there\r\nSecond line\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\n{\\an8}Top &amp; tail\r\n"
        let t = try SubtitleParser.parse(Data(srt.utf8), format: .srt)
        #expect(t.cues.count == 2)
        #expect(t.cues[0] == SubtitleCue(start: 1, end: 3.5, text: "Hello there\nSecond line"))
        #expect(t.cues[1].text == "Top & tail")
    }

    @Test func srtSkipsMalformedBlocks() throws {
        let srt = "1\n00:00:01,000 --> garbage\nBad\n\n2\n00:00:02,000 --> 00:00:03,000\nGood\n"
        let t = try SubtitleParser.parse(Data(srt.utf8), format: .srt)
        #expect(t.cues.map(\.text) == ["Good"])
    }

    @Test func webVTT() throws {
        let vtt = """
        WEBVTT - title

        NOTE a comment

        STYLE
        ::cue { color: red }

        intro
        00:01.000 --> 00:02.500 align:start position:10%
        <v Roger>Hi</v>

        01:00:00.000 --> 01:00:01.000
        Late
        """
        let t = try SubtitleParser.parse(Data(vtt.utf8), format: .webVTT)
        #expect(t.cues.count == 2)
        #expect(t.cues[0] == SubtitleCue(start: 1, end: 2.5, text: "Hi"))
        #expect(t.cues[1].start == 3600)
    }

    @Test func assDialogueKeepsCommasInText() throws {
        let ass = """
        [Script Info]
        Title: x

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.50,0:00:02.00,Default,,0,0,0,,{\\b1}Well,\\Nthat's it, then
        Comment: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,ignored
        """
        let t = try SubtitleParser.parse(Data(ass.utf8), format: .ass)
        #expect(t.cues == [SubtitleCue(start: 1.5, end: 2, text: "Well,\nthat's it, then")])
    }

    @Test func emptyFileThrows() {
        #expect(throws: SubtitleError.empty) { try SubtitleParser.parse(Data("WEBVTT\n\n".utf8), format: .webVTT) }
    }

    @Test func latin1Fallback() throws {
        var data = Data("1\n00:00:01,000 --> 00:00:02,000\nCaf".utf8)
        data.append(0xE9)  // é in Windows-1252, invalid UTF-8
        data.append(contentsOf: Array("\n".utf8))
        let t = try SubtitleParser.parse(data, format: .srt)
        #expect(t.cues[0].text == "Café")
    }

    @Test func formatDetection() {
        #expect(SubtitleFormat(fileExtension: "SRT") == .srt)
        #expect(SubtitleFormat(fileExtension: "ssa") == .ass)
        #expect(SubtitleFormat(fileExtension: "sub") == nil)
    }
}

@Suite struct SubtitleOffsetTests {
    let timeline = SubtitleTimeline(cues: [
        SubtitleCue(start: 10, end: 12, text: "A"),
        SubtitleCue(start: 11, end: 14, text: "B"),   // overlaps A
        SubtitleCue(start: 20, end: 22, text: "C"),
    ])

    @Test func lookupWithoutOffset() {
        #expect(timeline.text(at: 9.99) == nil)
        #expect(timeline.text(at: 10) == "A")
        #expect(timeline.text(at: 11.5) == "A\nB")
        #expect(timeline.text(at: 12) == "B")       // end is exclusive
        #expect(timeline.text(at: 21) == "C")
        #expect(timeline.text(at: 100) == nil)
    }

    @Test func positiveOffsetDelaysSubtitles() {
        let offset = SubtitleOffset(seconds: 2)
        #expect(timeline.text(at: 10, offset: offset) == nil)
        #expect(timeline.text(at: 12, offset: offset) == "A")
        #expect(timeline.text(at: 22, offset: offset) == "C")
    }

    @Test func negativeOffsetShowsSubtitlesEarlier() {
        let offset = SubtitleOffset(seconds: -1.5)
        #expect(timeline.text(at: 8.5, offset: offset) == "A")
        #expect(timeline.text(at: 18.4, offset: offset) == nil)
        #expect(timeline.text(at: 18.5, offset: offset) == "C")
    }

    @Test func nudgingIsExactAndClamped() {
        var o = SubtitleOffset()
        for _ in 0..<3 { o.nudge(by: SubtitleOffset.step) }
        #expect(o.seconds == 0.3)
        #expect(o.label == "+0.3 s")
        o.nudge(by: -SubtitleOffset.coarseStep)
        #expect(o.seconds == -0.7)
        #expect(o.label == "−0.7 s")
        o.nudge(by: -10_000)
        #expect(o.seconds == -SubtitleOffset.limit)
        o.reset()
        #expect(o.label == "0.0 s")
        #expect(SubtitleOffset(seconds: .nan).seconds == 0)
    }

    @Test func dropsZeroLengthCues() {
        let t = SubtitleTimeline(cues: [SubtitleCue(start: 5, end: 5, text: "x"), SubtitleCue(start: 6, end: 5, text: "y")])
        #expect(t.cues.isEmpty)
    }

    @Test func loaderRejectsUnknownExtension() async {
        await #expect(throws: SubtitleError.unsupportedFormat("sub")) {
            try await SubtitleLoader(fetch: { _ in Data() }).load(URL(string: "https://x/a.sub")!)
        }
    }
}
