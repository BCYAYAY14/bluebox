import Addons
import Domain
@testable import Downloads
@testable import Features
import Foundation
@testable import Metadata
import Testing

/// The UI review's smart downloader: per-show rules over the defaults,
/// following watching, making room, picking releases within the caps,
/// upgrades, season packs and subtitles.
@Suite struct DownloadRulesTests {
    let show = MediaKey.series(tmdbID: 7)
    let seasons = [SeasonSummary(number: 1, name: "Season 1", episodeCount: 4),
                   SeasonSummary(number: 2, name: "Season 2", episodeCount: 2)]

    func e(_ s: Int, _ n: Int) -> MediaKey { show.episode(season: s, episode: n)! }

    func record(_ key: MediaKey, _ state: DownloadRecord.State = .completed, bytes: Int64 = 1_000,
                name: String = "Show.S01E01.720p.WEB-DL.mkv", resolution: String? = "720p", id: String? = nil) -> DownloadRecord {
        let v = MediaVariant(id: id ?? key.rawValue, sourceID: SourceID("addons"), mediaKey: key, displayName: name,
                             resolution: resolution, location: .remote, isDownloadable: true)
        return DownloadRecord(id: id ?? key.rawValue, mediaKey: key, title: "Show", subtitle: nil, origin: v, state: state,
                              receivedBytes: 0, expectedBytes: bytes, createdAt: .now, fileName: nil, subtitleFiles: [])
    }

    func watched(_ key: MediaKey, at seconds: TimeInterval = 0) -> WatchProgress {
        WatchProgress(key: key, position: 100, duration: 100, isCompleted: true, updatedAt: Date(timeIntervalSince1970: 1_000 + seconds))
    }

    func release(_ name: String, resolution: String? = nil, seeders: Int? = 50, size: Int64? = nil, hash: String? = nil,
                 url: URL? = nil, languages title: String? = nil) -> AddonRelease {
        let h = hash ?? (url == nil ? String(repeating: String(name.count % 10), count: 40) : nil)
        return AddonRelease(id: url?.absoluteString ?? "\(h!):0", title: title ?? name, name: "Add-on", infoHash: h, fileIndex: 0,
                            trackers: [], seeders: url == nil ? seeders : nil, sizeText: nil, resolution: resolution, container: "mkv",
                            url: url, filename: name, videoSize: size)
    }

    // MARK: Rules

    @Test func showRulesOverrideTheDefaultsAndDeletingNeedsPermission() {
        var s = DownloadSettings(keepNextEpisodes: 1, downloadQuality: .p1080, maxEpisodeBytes: 3_000_000_000, audioLanguage: "en")
        #expect(s.rule(for: e(1, 1)) == DownloadRule(smartDownloads: true, keepNext: 1, quality: .p1080, maxEpisodeBytes: 3_000_000_000,
                                                      audioLanguage: "en", deleteAfterWatching: true, isCustom: false))
        s.showRules[show.rawValue] = ShowDownloadRule(keepNext: 3, quality: .p720, audioLanguage: "ja", deleteAfterWatching: false)
        let custom = s.rule(for: e(2, 1))
        #expect(custom.keepNext == 3 && custom.quality == .p720 && custom.audioLanguage == "ja")
        #expect(!custom.deleteAfterWatching && custom.isCustom)
        // Another show keeps the defaults; films never have an episode size cap.
        #expect(!s.rule(for: .series(tmdbID: 8)).isCustom)
        #expect(s.rule(for: .movie(tmdbID: 1)).maxEpisodeBytes == nil)
        // The master switch wins over a show that deletes after watching.
        s.showRules[show.rawValue]?.deleteAfterWatching = true
        s.allowsDeleting = false
        #expect(!s.rule(for: e(1, 1)).deleteAfterWatching)
    }

    @Test func aShowsOwnSwitchWinsOverTheGlobalOne() {
        var s = DownloadSettings(smartDownloads: false)
        s.showRules[show.rawValue] = ShowDownloadRule(smartDownloads: true)
        #expect(s.smartDownloads(for: e(1, 1)))
        s.smartDownloads = true
        s.showRules[show.rawValue] = ShowDownloadRule(smartDownloads: false)
        #expect(!s.smartDownloads(for: e(1, 1)))
        #expect(ShowDownloadRule().isEmpty && !ShowDownloadRule(keepNext: 2).isEmpty)
    }

    @Test func newFieldsRoundTripAndOldSavesTakeDefaults() throws {
        var s = DownloadSettings(downloadQuality: .p720, maxEpisodeBytes: 2_000_000_000, audioLanguage: "fr",
                                 deleteWatchedEpisodes: false, allowsDeleting: false, followOtherDevices: false,
                                 window: .overnight, fetchSubtitles: false)
        s.showRules = [show.rawValue: ShowDownloadRule(keepNext: 5)]
        let back = try JSONDecoder().decode(DownloadSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        let old = try JSONDecoder().decode(DownloadSettings.self, from: Data(#"{"maxConcurrent":3,"window":"someday"}"#.utf8))
        #expect(old.maxConcurrent == 3 && old.window == .anyTime && old.downloadQuality == .best)
        #expect(old.allowsDeleting && old.followOtherDevices && old.fetchSubtitles && old.showRules.isEmpty)
    }

    // MARK: Following watching

    @Test func planTopsUpAfterTheLastWatchedAndDeletesWatched() {
        let records = [record(e(1, 1)), record(e(1, 2)), record(e(1, 3), .queued)]
        let progress = [e(1, 1): watched(e(1, 1), at: 0), e(1, 2): watched(e(1, 2), at: 60)]
        let rule = DownloadSettings(keepNextEpisodes: 3).rule(for: show)
        let plan = SmartDownloads.seriesPlan(records: records, progress: progress, seasons: seasons, rule: rule)
        #expect(plan.fetch == [e(1, 4), e(2, 1)])  // E3 is already queued
        #expect(plan.delete.map(\.mediaKey) == [e(1, 1), e(1, 2)])
    }

    @Test func planLeavesAnUnstartedShowAndKeepsWatchedWhenTheRuleSays() {
        let records = [record(e(1, 1))]
        let rule = DownloadSettings().rule(for: show)
        #expect(SmartDownloads.seriesPlan(records: records, progress: [:], seasons: seasons, rule: rule) == .init())
        var keeping = rule
        keeping.deleteAfterWatching = false
        let plan = SmartDownloads.seriesPlan(records: records, progress: [e(1, 1): watched(e(1, 1))], seasons: seasons, rule: keeping)
        #expect(plan.fetch == [e(1, 2)] && plan.delete.isEmpty)
        var off = rule
        off.smartDownloads = false
        #expect(SmartDownloads.seriesPlan(records: records, progress: [e(1, 1): watched(e(1, 1))], seasons: seasons, rule: off) == .init())
    }

    // MARK: Making room

    @Test func makeRoomDeletesTheOldestWatchedOnly() {
        let a = record(e(1, 1), bytes: 4), b = record(e(1, 2), bytes: 4), c = record(.movie(tmdbID: 3), bytes: 4)
        let watched = [(record: b, watchedAt: Date(timeIntervalSince1970: 20)), (record: a, watchedAt: Date(timeIntervalSince1970: 10)),
                       (record: c, watchedAt: Date(timeIntervalSince1970: 30))]
        // 12 used of 14, 4 more needed: 2 over, the oldest watched (a) goes.
        #expect(SmartDownloads.makeRoom(neededBytes: 4, usedBytes: 12, limit: 14, watched: watched)?.map(\.id) == [a.id])
        // 6 over: a and b.
        #expect(SmartDownloads.makeRoom(neededBytes: 8, usedBytes: 12, limit: 14, watched: watched)?.map(\.id) == [a.id, b.id])
        // Fits already, or no limit: nothing goes.
        #expect(SmartDownloads.makeRoom(neededBytes: 1, usedBytes: 12, limit: 14, watched: watched) == [])
        #expect(SmartDownloads.makeRoom(neededBytes: 100, usedBytes: 12, limit: nil, watched: watched) == [])
        // Can't fit even with every watched one gone: nothing is deleted for nothing.
        #expect(SmartDownloads.makeRoom(neededBytes: 100, usedBytes: 12, limit: 14, watched: watched) == nil)
        #expect(SmartDownloads.makeRoom(neededBytes: 4, usedBytes: 12, limit: 14, watched: []) == nil)
    }

    // MARK: Download window

    @Test func downloadWindowOpensOvernightOrWhileCharging() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: hour, minute: 30))! }
        #expect(DownloadWindow.anyTime.isOpen(at: at(14), isCharging: false, calendar: cal))
        #expect(DownloadWindow.overnight.isOpen(at: at(1), isCharging: false, calendar: cal))
        #expect(DownloadWindow.overnight.isOpen(at: at(5), isCharging: false, calendar: cal))
        #expect(!DownloadWindow.overnight.isOpen(at: at(6), isCharging: true, calendar: cal))
        #expect(!DownloadWindow.overnight.isOpen(at: at(0), isCharging: true, calendar: cal))
        #expect(DownloadWindow.whileCharging.isOpen(at: at(14), isCharging: true, calendar: cal))
        #expect(!DownloadWindow.whileCharging.isOpen(at: at(3), isCharging: false, calendar: cal))
    }

    // MARK: Picking releases

    @Test func pickKeepsToTheCapsAndPrefersTheAudioLanguage() {
        let uhd = release("Show.S01E01.2160p.WEB-DL.mkv", resolution: "2160p", size: 8_000_000_000)
        let big = release("Show.S01E01.1080p.REMUX.mkv", resolution: "1080p", size: 6_000_000_000)
        let fhd = release("Show.S01E01.1080p.WEB-DL.mkv", resolution: "1080p", size: 2_000_000_000)
        let french = release("Show.S01E01.1080p.FRENCH.WEB-DL.mkv", resolution: "1080p", size: 2_100_000_000)
        let dead = release("Show.S01E01.720p.WEB-DL.mkv", resolution: "720p", seeders: 0, size: 900_000_000)
        var rule = DownloadSettings(downloadQuality: .p1080, maxEpisodeBytes: 3_000_000_000).rule(for: e(1, 1))
        #expect(SmartDownloads.pickRelease([uhd, big, fhd, french], rule: rule, strict: true)?.id == fhd.id)
        rule.audioLanguage = "fr"
        #expect(SmartDownloads.pickRelease([uhd, big, fhd, french], rule: rule, strict: true)?.id == french.id)
        // Nothing within the caps: an automatic download waits, one you asked for takes the best.
        rule.quality = .p480
        #expect(SmartDownloads.pickRelease([uhd, fhd, dead], rule: rule, strict: true) == nil)
        #expect(SmartDownloads.pickRelease([uhd, fhd, dead], rule: rule, strict: false)?.id == uhd.id)
    }

    // MARK: Upgrades

    @Test func upgradesAreHigherResolutionOrAProperSourceOverACinemaCopy() {
        let rule = DownloadSettings().rule(for: .movie(tmdbID: 1))
        let have720 = DownloadUpgrade.info(of: record(.movie(tmdbID: 1), name: "Film.2026.720p.WEB-DL.mkv", resolution: "720p"))
        let cam = DownloadUpgrade.info(of: record(.movie(tmdbID: 1), name: "Film.2026.1080p.CAM.mkv", resolution: "1080p"))
        let web1080 = release("Film.2026.1080p.WEB-DL.mkv", resolution: "1080p")
        let web720 = release("Film.2026.720p.WEBRip.x264.mkv", resolution: "720p")
        let ts2160 = release("Film.2026.2160p.HDTS.mkv", resolution: "2160p")
        let thin = release("Film.2026.2160p.BluRay.mkv", resolution: "2160p", seeders: 1)
        #expect(DownloadUpgrade.isBetter(web1080, than: have720, currentID: "x", rule: rule))
        #expect(!DownloadUpgrade.isBetter(web720, than: have720, currentID: "x", rule: rule))  // same resolution, nothing gained
        #expect(!DownloadUpgrade.isBetter(ts2160, than: have720, currentID: "x", rule: rule))  // a cinema copy is never better
        #expect(!DownloadUpgrade.isBetter(thin, than: have720, currentID: "x", rule: rule))    // one seeder isn't reliable
        #expect(DownloadUpgrade.isBetter(web1080, than: cam, currentID: "x", rule: rule))     // WEB-DL over CAM at 1080p
        #expect(!DownloadUpgrade.isBetter(web1080, than: have720, currentID: web1080.id, rule: rule))
        // Above the quality cap doesn't count.
        let capped = DownloadSettings(downloadQuality: .p720).rule(for: .movie(tmdbID: 1))
        #expect(!DownloadUpgrade.isBetter(web1080, than: have720, currentID: "x", rule: capped))
    }

    @Test func theSameTorrentIsNotAnUpgrade() {
        let hash = String(repeating: "a", count: 40)
        let have = record(.movie(tmdbID: 1), name: "Film.2026.720p.WEB-DL.mkv", resolution: "720p", id: "\(hash):0")
        let sameTorrent = release("Film.2026.1080p.WEB-DL.mkv", resolution: "1080p", hash: hash)
        let other = release("Film.2026.1080p.BluRay.mkv", resolution: "1080p", hash: String(repeating: "b", count: 40))
        let rule = DownloadSettings().rule(for: .movie(tmdbID: 1))
        #expect(DownloadUpgrade.best([sameTorrent, other], for: have, rule: rule)?.id == other.id)
    }

    // MARK: Season packs

    @Test func seasonPacksAreTorrentsNamedForTheSeasonWithoutAnEpisode() {
        let pack = release("Show.S02.1080p.WEB-DL", resolution: "1080p", languages: "Show.S02.1080p.WEB-DL\nShow.S02E01.1080p.WEB-DL.mkv")
        let named = release("Show Season 2 Complete 720p", resolution: "720p")
        let range = release("Show.S01-S04.1080p.BluRay", resolution: "1080p")
        let episode = release("Show.S02E01.1080p.WEB-DL.mkv", resolution: "1080p")
        let debrid = release("Show.S02.1080p.WEB-DL", url: URL(string: "https://debrid.example/x.mkv"))
        #expect(SeasonPacks.isPack(pack, season: 2))
        #expect(SeasonPacks.isPack(named, season: 2))
        #expect(SeasonPacks.isPack(range, season: 3) && !SeasonPacks.isPack(range, season: 5))
        #expect(!SeasonPacks.isPack(episode, season: 2))
        #expect(!SeasonPacks.isPack(pack, season: 1))
        #expect(!SeasonPacks.isPack(debrid, season: 2))
        let ids = Set((1...3).map { SeasonPacks.variantID(hash: "ABC", season: 2, episode: $0) })
        #expect(ids.count == 3)
        let one = SeasonPacks.variantID(hash: String(repeating: "c", count: 40), season: 2, episode: 3)
        #expect(DownloadRecord.infoHash(fromVariantID: one) != nil)
        #expect(StremioSource.torrent(fromVariantID: one)?.fileIndex == nil)  // picked by episode, not index
    }

    // MARK: Subtitles

    @Test func subtitlesAreFetchedOnlyWhenTheDownloadLacksTheLanguage() {
        var r = record(e(1, 1))
        #expect(DownloadSubtitles.languageToFetch(preferred: "en", record: r) == "en")
        #expect(DownloadSubtitles.languageToFetch(preferred: nil, record: r) == nil)
        r.subtitleFiles = [.init(fileName: "x.srt", languageCode: "eng", label: "English", format: "srt")]
        #expect(DownloadSubtitles.languageToFetch(preferred: "en", record: r) == nil)
        let results = [SubtitleSearchResult(id: 1, language: "en", release: "a", downloadCount: 900, hearingImpaired: false, machineTranslated: true),
                       SubtitleSearchResult(id: 2, language: "en", release: "b", downloadCount: 10, hearingImpaired: false, machineTranslated: false),
                       SubtitleSearchResult(id: 3, language: "fr", release: "c", downloadCount: 5_000, hearingImpaired: false, machineTranslated: false)]
        #expect(DownloadSubtitles.best(results, language: "en")?.id == 2)
    }
}
