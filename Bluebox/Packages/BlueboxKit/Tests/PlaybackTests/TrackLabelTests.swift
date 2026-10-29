import Foundation
@testable import Playback
import Testing

@Suite struct TrackLabelTests {
    let en = Locale(identifier: "en_US")

    private func parse(_ raw: String, code: String? = nil, index: Int? = nil) -> TrackLabel {
        TrackLabel.parse(raw, languageCode: code, index: index, locale: en)
    }

    @Test func dropsVLCBracketedLanguage() {
        #expect(parse("Italian - [Italian]") == TrackLabel(title: "Italian", languageCode: "it"))
        #expect(parse("English (US) - [English]") == TrackLabel(title: "English (US)", languageCode: "en"))
    }

    @Test func splitsTagsOutOfParentheses() {
        let l = parse("English (SDH / US) - [English]")
        #expect(l.title == "English (US)")
        #expect(l.details == ["SDH"])
        #expect(parse("English (Forced)").details == ["Forced"])
        #expect(parse("English (AD)").details == ["Audio Description"])
    }

    @Test func tagsAfterTheLanguage() {
        #expect(parse("English SDH").detail == "SDH")
        #expect(parse("English CC").detail == "SDH")
        #expect(parse("English 5.1 - [English]") == TrackLabel(title: "English", details: ["5.1"], languageCode: "en"))
        #expect(parse("Japanese Stereo").details == ["Stereo"])
    }

    @Test func codecsAreDropped() {
        let l = parse("AC3 5.1 - [English]")
        #expect(l.title == "English")
        #expect(l.details == ["5.1"])
        #expect(parse("DTS-HD MA 7.1 - [French]").title == "French")
        #expect(parse("DTS-HD MA 7.1 - [French]").details == ["7.1"])
    }

    @Test func genericNamesFallBackToTheLanguage() {
        #expect(parse("Track 1 - [English]").title == "English")
        #expect(parse("Track 2", code: "fre").title == "French")
        #expect(parse("", code: "ger").title == "German")
        #expect(parse("", index: 2).title == "Track 3")
    }

    @Test func descriptionsAreKeptWhole() {
        let l = parse("Commentary by director - [English]")
        #expect(l.title == "English")
        #expect(l.details == ["Commentary by director"])
        #expect(parse("Commentary - [English]").details == ["Commentary"])
    }

    @Test func releaseGroupPrefixAndCompoundLanguages() {
        let l = parse("[NF] Spanish (Spain) - [Spanish; Castilian]")
        #expect(l.title == "Spanish (Spain)")
        #expect(l.details.isEmpty)
        #expect(parse("[NF] Vietnamese - [Vietnamese]").title == "Vietnamese")
    }

    @Test func regionsAndLanguageCodes() {
        #expect(parse("Portuguese (Brazil)").title == "Portuguese (Brazil)")
        #expect(parse("Spanish (Latin America) - [Spanish]").title == "Spanish (Latin America)")
        #expect(parse("eng").title == "English")
        // A short tag isn't mistaken for a language code ("SDH", "HI").
        #expect(parse("SDH - [English]") == TrackLabel(title: "English", details: ["SDH"], languageCode: "en"))
        #expect(parse("HI", code: "en").title == "English")
    }

    @Test func unknownNamesStayAsTheyAre() {
        #expect(parse("Director's cut audio").title == "Director's cut audio")
    }

    @Test func numbersDuplicates() {
        let tracks = [
            MediaTrack(id: "1", kind: .subtitle, label: "[NF] Vietnamese - [Vietnamese]", languageCode: "vie"),
            MediaTrack(id: "2", kind: .subtitle, label: "[NF] Vietnamese - [Vietnamese]", languageCode: "vie"),
            MediaTrack(id: "3", kind: .subtitle, label: "English (SDH) - [English]", languageCode: "eng"),
        ]
        let labels = TrackLabel.labels(for: tracks, locale: en)
        #expect(labels["1"]?.detail == "Track 1")
        #expect(labels["2"]?.detail == "Track 2")
        #expect(labels["3"]?.detail == "SDH")
    }

    @Test func choicePrefersTheSameLanguageAndVariant() {
        let next = [
            MediaTrack(id: "a", kind: .subtitle, label: "English (Forced) - [English]", languageCode: "eng"),
            MediaTrack(id: "b", kind: .subtitle, label: "English - [English]", languageCode: "eng"),
            MediaTrack(id: "c", kind: .subtitle, label: "English (SDH) - [English]", languageCode: "eng"),
            MediaTrack(id: "d", kind: .subtitle, label: "Italian - [Italian]", languageCode: "ita"),
        ]
        let plain = TrackChoice(MediaTrack(id: "x", kind: .subtitle, label: "English", languageCode: "en"))
        #expect(plain.best(in: next)?.id == "b")
        let sdh = TrackChoice(MediaTrack(id: "x", kind: .subtitle, label: "English SDH", languageCode: "en-US"))
        #expect(sdh.best(in: next)?.id == "c")
        #expect(TrackChoice(languageCode: "it").best(in: next)?.id == "d")
        #expect(TrackChoice(languageCode: "de").best(in: next) == nil)
        #expect(TrackChoice.off.best(in: next) == nil)
    }
}
