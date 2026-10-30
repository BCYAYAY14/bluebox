import Domain
import Testing

@Suite struct SubtitleFileNameTests {
    @Test func readsLanguageNamesAndCodes() {
        #expect(SubtitleFileName("Subs/English.srt").languageCode == "en")
        #expect(SubtitleFileName("2_English.srt").languageCode == "en")
        #expect(SubtitleFileName("Movie.2019.1080p.en.srt", videoStem: "Movie.2019.1080p").languageCode == "en")
        #expect(SubtitleFileName("Movie.2019.eng.srt").languageCode == "en")
        #expect(SubtitleFileName("Spanish (Latin America).srt").languageCode == "es")
        #expect(SubtitleFileName("3_Brazilian.srt").languageCode == "pt")
        #expect(SubtitleFileName("Movie.pt-BR.srt").languageCode == "pt")
        #expect(SubtitleFileName("French.forced.srt").languageCode == "fr")
        #expect(SubtitleFileName("fre.ass").languageCode == "fr")
    }

    @Test func readsFlags() {
        let sdh = SubtitleFileName("Movie.en.sdh.srt", videoStem: "Movie")
        #expect(sdh.languageCode == "en" && sdh.isSDH && !sdh.isForced)
        let forced = SubtitleFileName("4_English_Forced.srt")
        #expect(forced.languageCode == "en" && forced.isForced)
        #expect(SubtitleFileName("English [SDH].srt").isSDH)
    }

    @Test func twoLetterCodesNeedTheVideosNameOrAShortName() {
        // "It" in a long title is a word, not Italian.
        #expect(SubtitleFileName("The.It.Crowd.S01E01.720p.HDTV.x264.srt").languageCode == nil)
        #expect(SubtitleFileName("The.It.Crowd.S01E01.it.srt", videoStem: "The.It.Crowd.S01E01").languageCode == "it")
        #expect(SubtitleFileName("de.srt").languageCode == "de")
        #expect(SubtitleFileName("Movie.2019.1080p.WEB.srt").languageCode == nil)
    }

    @Test func labels() {
        #expect(SubtitleFileName("2_English.srt").label(locale: .init(identifier: "en"), fallback: "x") == "English")
        #expect(SubtitleFileName("English.SDH.srt").label(locale: .init(identifier: "en"), fallback: "x") == "English SDH")
        #expect(SubtitleFileName("Movie.srt").label(locale: .init(identifier: "en"), fallback: "Movie.srt") == "Movie.srt")
    }

    @Test func recognisesSubtitleFiles() {
        #expect(SubtitleFileName.isSubtitle("a/b/English.SRT"))
        #expect(SubtitleFileName.isSubtitle("x.ass") && SubtitleFileName.isSubtitle("x.vtt"))
        #expect(!SubtitleFileName.isSubtitle("x.sub") && !SubtitleFileName.isSubtitle("x.mkv"))
    }
}
