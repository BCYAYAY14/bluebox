@testable import Features
import Foundation
import Playback
import Testing

@MainActor
@Suite struct SubtitleLanguageGroupTests {
    func row(_ id: String, _ title: String, _ code: String?, detail: String? = nil, selected: Bool = false) -> TrackRow {
        TrackRow(id: id, title: title, detail: detail, source: .video, isBitmap: false, languageCode: code,
                 selected: selected, selection: .embedded(id))
    }

    @Test func tracksOfOneLanguageShareARowInOrder() {
        let rows = [row("1", "English", "en"), row("2", "English", "eng", detail: "SDH", selected: true),
                    row("3", "Spanish", "es"), row("4", "English (US)", "en", detail: "Forced"), row("5", "Commentary", nil)]
        let groups = TrackRows.languageGroups(rows, locale: Locale(identifier: "en"))
        #expect(groups.map(\.title) == ["English", "Spanish", "Commentary"])
        #expect(groups[0].rows.map(\.id) == ["1", "2", "4"])
        #expect(groups[0].selected?.id == "2")
        #expect(groups[1].selected == nil)
    }

    @Test func longListsKeepYourLanguageAndTheChosenOne() {
        let codes = ["fr", "de", "it", "ja", "ko", "pt", "ru", "zh", "nl", "sv", "en"]
        let rows = codes.enumerated().map { i, c in row("\(i)", c, c, selected: c == "ja") }
        let groups = TrackRows.languageGroups(rows, locale: Locale(identifier: "en"))
        let parts = TrackRows.split(groups, preferred: ["en"])
        #expect(parts.shown.contains { $0.languageCode == "en" })
        #expect(parts.shown.contains { $0.languageCode == "ja" })
        #expect(parts.shown.count + parts.more.count == codes.count)
    }
}
