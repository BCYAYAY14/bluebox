import Domain
import Downloads
@testable import Features
import Foundation
import Testing

/// Smart Downloads: which episodes to keep, the storage limit, watched films,
/// per-show switches and old saves.
@Suite struct SmartDownloadsTests {
    let show = MediaKey.series(tmdbID: 7)
    let seasons = [SeasonSummary(number: 0, name: "Specials", episodeCount: 3),
                   SeasonSummary(number: 1, name: "Season 1", episodeCount: 3),
                   SeasonSummary(number: 2, name: "Season 2", episodeCount: 2)]

    private func record(_ key: MediaKey, _ state: DownloadRecord.State) -> DownloadRecord {
        let v = MediaVariant(id: key.rawValue, sourceID: SourceID("x"), mediaKey: key, displayName: "x", location: .remote,
                             isDownloadable: true)
        return DownloadRecord(id: key.rawValue, mediaKey: key, title: "T", subtitle: nil, origin: v, state: state,
                              receivedBytes: 0, expectedBytes: 1, createdAt: .now, fileName: nil, subtitleFiles: [])
    }

    @Test func keepsTheNextEpisodesAcrossSeasonsSkippingSpecials() {
        let e = { (s: Int, n: Int) in self.show.episode(season: s, episode: n)! }
        #expect(SmartDownloads.nextEpisodes(after: e(1, 2), seasons: seasons, keep: 1) == [e(1, 3)])
        #expect(SmartDownloads.nextEpisodes(after: e(1, 2), seasons: seasons, keep: 3) == [e(1, 3), e(2, 1), e(2, 2)])
        #expect(SmartDownloads.nextEpisodes(after: e(2, 2), seasons: seasons, keep: 2).isEmpty)  // the end
        #expect(SmartDownloads.nextEpisodes(after: .movie(tmdbID: 1), seasons: seasons, keep: 2).isEmpty)
    }

    @Test func fetchesOnlyWhatsMissingAndStopsAtTheLimit() {
        let e = { (n: Int) in self.show.episode(season: 1, episode: n)! }
        let existing: [MediaKey: [DownloadRecord]] = [e(1): [record(e(1), .queued)], e(2): [record(e(2), .failed("x"))]]
        let fetch = SmartDownloads.toFetch([e(1), e(2), e(3)], existing: { existing[$0] ?? [] }, usedBytes: 5, limit: 10)
        #expect(fetch == [e(2), e(3)])  // queued one stays; a failed one is fetched again
        #expect(SmartDownloads.toFetch([e(3)], existing: { _ in [] }, usedBytes: 10, limit: 10).isEmpty)
        #expect(SmartDownloads.toFetch([e(3)], existing: { _ in [] }, usedBytes: .max, limit: nil) == [e(3)])
    }

    @Test func watchedFilmsGoAfterTheirDays() {
        let now = Date()
        let old = MediaKey.movie(tmdbID: 1), recent = MediaKey.movie(tmdbID: 2), unwatched = MediaKey.movie(tmdbID: 3)
        let episode = show.episode(season: 1, episode: 1)!
        let records = [old, recent, unwatched, episode].map { record($0, .completed) } + [record(.movie(tmdbID: 4), .downloading)]
        let finished: [MediaKey: Date] = [old: now.addingTimeInterval(-8 * 86_400), recent: now.addingTimeInterval(-3_600),
                                          episode: now.addingTimeInterval(-30 * 86_400), .movie(tmdbID: 4): .distantPast]
        #expect(SmartDownloads.filmsToDelete(records, finished: finished, afterDays: 7, now: now).map(\.mediaKey) == [old])
        #expect(SmartDownloads.filmsToDelete(records, finished: finished, afterDays: 0, now: now).count == 2)
        #expect(SmartDownloads.filmsToDelete(records, finished: finished, afterDays: nil, now: now).isEmpty)
    }

    @Test func perShowSwitch() {
        var s = DownloadSettings()
        let episode = show.episode(season: 1, episode: 1)!
        #expect(s.smartDownloads(for: episode))
        s.smartDownloadsOff.insert(show.rawValue)
        #expect(!s.smartDownloads(for: episode))
        #expect(s.smartDownloads(for: .series(tmdbID: 8)))
        s.smartDownloads = false
        #expect(!s.smartDownloads(for: .series(tmdbID: 8)))
    }

    @Test func oldSavesMapOntoSmartDownloadsAndNeverSurvivesAReload() throws {
        let decode = { (json: String) in try JSONDecoder().decode(DownloadSettings.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"maxConcurrent":2}"#).smartDownloads)  // new install: on
        #expect(try !decode(#"{"deleteAfterWatching":false,"downloadNextEpisode":false}"#).smartDownloads)
        #expect(try decode(#"{"deleteAfterWatching":false,"downloadNextEpisode":true}"#).smartDownloads)
        var s = DownloadSettings()
        s.deleteWatchedFilmsAfterDays = nil
        s.storageLimitBytes = 20_000_000_000
        s.smartDownloadsOff = [show.rawValue]
        let back = try JSONDecoder().decode(DownloadSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.deleteWatchedFilmsAfterDays == nil)
    }
}
