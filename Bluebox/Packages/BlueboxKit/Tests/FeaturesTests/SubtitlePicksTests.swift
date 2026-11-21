import Domain
@testable import Features
import Foundation
import Metadata
@testable import Playback
import Testing

/// The automatic search's choice, the file kept per title, and the small
/// subtitle helpers around them.
@Suite struct SubtitlePicksTests {
    func sub(_ site: SubtitleSite, _ release: String, _ lang: String = "en", downloads: Int = 0, mt: Bool = false) -> OnlineSubtitle {
        OnlineSubtitle(site: site, source: .url(URL(string: "https://x.test/\(site.rawValue)/\(release)/\(lang)")!, headers: [:]),
                       language: lang, release: release, downloadCount: downloads, machineTranslated: mt)
    }

    @Test func autoSearchTakesTheReleaseThenTheMostDownloaded() {
        let playing = "Show.S01E01.1080p.WEB.h264-ETHEL"
        let merged = SubtitleSearchMerge.merge([
            [sub(.openSubtitles, "Show S01E01", downloads: 90_000, mt: true),
             sub(.openSubtitles, "Show.S01E01.720p.HDTV-OTHER", downloads: 400)],
            [sub(.subdl, "Show.S01E01.1080p.WEB.h264-ETHEL", downloads: 12)],
            [sub(.podnapisi, "Show.S01E01.1080p.WEB.h264-ETHEL", "fr", downloads: 5_000)],
        ], release: playing, languages: ["en", "fr"])
        // The file made for this release in English, over more downloads, French or a machine translation.
        #expect(AutoSubtitleSearch.best(merged, language: "en")?.site == .subdl)
        // With no release match, the most downloaded made by a person.
        let plain = SubtitleSearchMerge.merge([
            [sub(.openSubtitles, "Show S01E01 A", downloads: 30), sub(.openSubtitles, "Show S01E01 B", downloads: 3_000)],
            [sub(.subdl, "Show S01E01 C", downloads: 900_000, mt: true)],
        ], release: nil, languages: ["en"])
        #expect(AutoSubtitleSearch.best(plain, language: "eng")?.release == "Show S01E01 B")
        // A machine translation only when there's nothing else.
        #expect(AutoSubtitleSearch.best([sub(.subdl, "x", mt: true)], language: "en")?.machineTranslated == true)
        #expect(AutoSubtitleSearch.best(merged, language: "de") == nil)
    }

    @Test func autoSearchRespectsChoicesAndTheRule() {
        #expect(AutoSubtitleSearch.language(preferred: "en", remembered: nil, rule: .fullTrack) == "en")
        #expect(AutoSubtitleSearch.language(preferred: "en", remembered: .off, rule: nil) == nil)
        #expect(AutoSubtitleSearch.language(preferred: "en", remembered: TrackChoice(languageCode: "ja"), rule: nil) == "ja")
        #expect(AutoSubtitleSearch.language(preferred: "en", remembered: nil, rule: .forcedOnly) == nil)
        #expect(AutoSubtitleSearch.language(preferred: nil, remembered: nil, rule: nil) == nil)
    }

    @Test func aChosenFileIsKeptWithItsTitle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bluebox-kept-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KeptSubtitleStore(folder: root.appending(path: "Kept"))
        let key = MediaKey.movie(tmdbID: 42)
        let download = root.appending(path: "Movie.2019.WEB-opensubtitles12.en.srt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8).write(to: download)

        let kept = try store.keep(download, for: key, duration: 6000)
        #expect(kept.lastPathComponent == download.lastPathComponent)  // its language tag still names it
        #expect(store.kept(for: key, duration: 6002) == kept)
        #expect(store.kept(for: key, duration: nil) == kept)
        // Another cut of the film: not put back.
        #expect(store.kept(for: key, duration: 5400) == nil)
        #expect(store.kept(for: .movie(tmdbID: 43), duration: 6000) == nil)
        // Putting it back doesn't copy it onto itself.
        #expect(store.holds(kept) && !store.holds(download))
        #expect(try store.keep(kept, for: key, duration: 6000) == kept)
        // A newer pick replaces it.
        let other = root.appending(path: "Other.fr.srt")
        try Data("x".utf8).write(to: other)
        let replaced = try store.keep(other, for: key, duration: 6000)
        #expect(store.kept(for: key, duration: 6000) == replaced)
        #expect(!FileManager.default.fileExists(atPath: kept.path))
        store.delete(key)
        #expect(store.kept(for: key, duration: nil) == nil)
    }

    @Test func downloadedFileNamesAreTheSameEveryLaunch() {
        let s = sub(.subdl, "Show.S01E01.WEB-ETHEL")
        let name = AppModel.subtitleFileName(s, format: "srt")
        #expect(name == AppModel.subtitleFileName(s, format: "srt"))
        #expect(name.hasPrefix("Show.S01E01.WEB-ETHEL-subdl") && name.hasSuffix(".en.srt"))
        // FNV-1a of the ID: fixed, unlike Swift's per-launch `hashValue`.
        var h = HomeHistory.FNV()
        h.add(s.id)
        #expect(name.contains("subdl\(h.value % 1_000_000)."))
    }

    @Test func untaggedAudioIsUntagged() {
        #expect(GenerateSubtitlesPage.isUntagged(nil))
        #expect(GenerateSubtitlesPage.isUntagged("und"))
        #expect(GenerateSubtitlesPage.isUntagged("mul"))
        #expect(!GenerateSubtitlesPage.isUntagged("ja"))
        #expect(!GenerateSubtitlesPage.isUntagged("jpn"))
    }

    @Test @MainActor func oneTapTurnsOnTheLanguagesPlainTrack() {
        func row(_ id: String, _ detail: String?) -> TrackRow {
            TrackRow(id: id, title: "English", detail: detail, source: .video, isBitmap: false, languageCode: "en", selected: false,
                     selection: .embedded(id))
        }
        let g = TrackLanguageGroup(id: "en", title: "English", languageCode: "en", rows: [row("1", "Forced"), row("2", "SDH"), row("3", nil)])
        #expect(g.standard?.id == "3")
        let noPlain = TrackLanguageGroup(id: "en", title: "English", languageCode: "en", rows: [row("1", "Forced"), row("2", "SDH")])
        #expect(noPlain.standard?.id == "2")
    }
}
