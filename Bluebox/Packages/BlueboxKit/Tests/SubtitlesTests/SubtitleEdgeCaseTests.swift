import Foundation
@testable import Subtitles
import Testing

@Suite struct SubtitleEdgeCaseTests {
    @Test func bytesUndefinedInWindows1252StillDecode() throws {
        // 0x81 and 0x8D have no Windows-1252 character; the file used to be "unreadable".
        var data = Data("1\n00:00:01,000 --> 00:00:02,000\nCaf".utf8)
        data.append(contentsOf: [0xE9, 0x20, 0x81])  // not UTF-8; 0x81 is undefined in Windows-1252
        data.append(contentsOf: Array("\n".utf8))
        let t = try SubtitleParser.parse(data, format: .srt)
        #expect(t.cues[0].text.hasPrefix("Café"))
    }

    @Test func aLongCueStaysVisibleUnderManyShortOnes() {
        var cues = [SubtitleCue(start: 0, end: 100, text: "SIGN")]
        for i in 0..<40 { cues.append(SubtitleCue(start: Double(i) * 2 + 1, end: Double(i) * 2 + 2, text: "line \(i)")) }
        let t = SubtitleTimeline(cues: cues)
        #expect(t.cues(at: 75.5).map(\.text) == ["SIGN", "line 37"])
        #expect(t.cues(at: 99).map(\.text) == ["SIGN"])
        #expect(t.cues(at: 100).isEmpty)
    }

    @Test func assDrawingCommandsAreNotShownAsText() throws {
        let ass = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.00,Sign,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100 0 100{\\p0}
        Dialogue: 0,0:00:01.00,0:00:03.00,Sign,,0,0,0,,{\\pos(10,10)\\p2}m 0 0 l 5 5{\\p0}Shop
        Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,{\\pos(5,5)}Hello, there
        """
        let t = try SubtitleParser.parse(Data(ass.utf8), format: .ass)
        #expect(t.cues.map(\.text) == ["Shop", "Hello, there"])
    }
}
