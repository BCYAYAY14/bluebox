import Foundation
@testable import Subtitles
import Testing

@Suite struct SubtitleParserRegressionTests {
    @Test func srtWithoutBlankLinesBetweenCues() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nHello\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n"
        let t = try SubtitleParser.parse(Data(srt.utf8), format: .srt)
        #expect(t.cues.map(\.text) == ["Hello", "World"])
        #expect(t.cues[1].start == 3)
    }

    @Test func vttCueSettingsAfterATab() throws {
        let vtt = "WEBVTT\n\n00:00:04.000 --> 00:00:05.000\tline:0\nTop\n"
        let t = try SubtitleParser.parse(Data(vtt.utf8), format: .webVTT)
        #expect(t.cues.first?.text == "Top")
    }

    @Test func utf16WithoutByteOrderMark() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nHello there\n"
        let le = try SubtitleParser.parse(srt.data(using: .utf16LittleEndian)!, format: .srt)
        let be = try SubtitleParser.parse(srt.data(using: .utf16BigEndian)!, format: .srt)
        #expect(le.cues.first?.text == "Hello there")
        #expect(be.cues.first?.text == "Hello there")
    }

    @Test func lowercaseAndCarriageReturnASS() throws {
        let ass = "[events]\rformat: Layer, Start, End, Style, Text\rdialogue: 0,0:00:01.00,0:00:02.00,Default,Hi\r"
        let t = try SubtitleParser.parse(Data(ass.utf8), format: .ass)
        #expect(t.cues.first?.text == "Hi")
    }

    @Test func lessThanAndGreaterThanInTextSurvive() {
        #expect(SubtitleParser.stripTags("<i>a < b and c > d</i>") == "a < b and c > d")
        #expect(SubtitleParser.stripTags("<font color=\"#fff\">Hey</font> <c.yellow>you</c>") == "Hey you")
    }
}

@Suite struct SubtitleAnchorTests {
    @Test func pinningToTheGrid() {
        var s = SubtitleStyle()
        s.horizontalOffset = 0.2
        s.pin(.top, .leading)
        #expect(s.anchor == .top && s.alignment == .leading && s.horizontalOffset == 0)
        #expect(!s.isDefaultPosition)
        s.pin(.middle, .center)
        #expect(s.anchor == .middle)
        s.resetPosition()
        #expect(s.isDefaultPosition && s.alignment == .center)
    }

    @Test func middleAnchorRoundTrips() throws {
        var s = SubtitleStyle()
        s.anchor = .middle
        let back = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(s))
        #expect(back.anchor == .middle)
    }
}
