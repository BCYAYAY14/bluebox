import Domain
import Testing
import TestingSupport

@Suite struct SeriesCursorTests {
    let seasons = [
        SeasonSummary(number: 0, name: "Specials", episodeCount: 3),
        SeasonSummary(number: 1, name: "S1", episodeCount: 2),
        SeasonSummary(number: 2, name: "S2", episodeCount: 0),   // announced, empty
        SeasonSummary(number: 3, name: "S3", episodeCount: 4),
    ]
    func ep(_ s: Int, _ e: Int) -> MediaKey { .episode(seriesID: 7, season: s, episode: e) }

    @Test func nextCrossesSeasonsAndSkipsEmptyOnes() {
        #expect(SeriesCursor.next(after: 1, 1, seasons: seasons)! == (1, 2))
        #expect(SeriesCursor.next(after: 1, 2, seasons: seasons)! == (3, 1))
        #expect(SeriesCursor.next(after: 3, 4, seasons: seasons) == nil)
        #expect(SeriesCursor.next(after: 0, 3, seasons: seasons)! == (1, 1))
    }

    @Test func cinemetaSeriesKeysWork() {
        let show = MediaKey.series(imdbID: "tt0903747")
        func imdb(_ s: Int, _ e: Int) -> MediaKey { .episode(imdbSeriesID: "tt0903747", season: s, episode: e) }
        #expect(SeriesCursor.target(series: show, progress: [], seasons: seasons)?.key == imdb(1, 1))
        let finished = [WatchProgress.fixture(imdb(1, 2), 3500, at: 5)]
        #expect(SeriesCursor.target(series: show, progress: finished, seasons: seasons)?.key == imdb(3, 1))
        // Another show's progress doesn't count.
        #expect(SeriesCursor.target(series: show, progress: [.fixture(ep(1, 2), 900, at: 2)], seasons: seasons)?.key == imdb(1, 1))
    }

    @Test func freshSeriesStartsAtFirstRegularEpisode() {
        let t = SeriesCursor.target(seriesID: 7, progress: [], seasons: seasons)
        #expect(t == .init(key: ep(1, 1), season: 1, episode: 1, isResume: false))
    }

    @Test func resumesInProgressEpisode() {
        let p = [WatchProgress.fixture(ep(1, 1), 3600, completed: true, at: 1), .fixture(ep(1, 2), 900, at: 2)]
        #expect(SeriesCursor.target(seriesID: 7, progress: p, seasons: seasons)?.key == ep(1, 2))
        #expect(SeriesCursor.target(seriesID: 7, progress: p, seasons: seasons)?.isResume == true)
    }

    @Test func advancesAfterFinishedEpisode() {
        let p = [WatchProgress.fixture(ep(1, 2), 3500, at: 5)]   // past completion threshold
        let t = SeriesCursor.target(seriesID: 7, progress: p, seasons: seasons)
        #expect(t?.key == ep(3, 1))
        #expect(t?.isResume == false)
    }

    @Test func rewatchingOlderEpisodeFollowsLatestActivity() {
        let p = [WatchProgress.fixture(ep(3, 2), 3600, completed: true, at: 1), .fixture(ep(1, 1), 600, at: 9)]
        #expect(SeriesCursor.target(seriesID: 7, progress: p, seasons: seasons)?.key == ep(1, 1))
    }

    @Test func finishedSeriesReturnsNil() {
        let p = [WatchProgress.fixture(ep(3, 4), 3600, completed: true, at: 1)]
        #expect(SeriesCursor.target(seriesID: 7, progress: p, seasons: seasons) == nil)
    }

    @Test func ignoresOtherSeries() {
        let p = [WatchProgress.fixture(.episode(seriesID: 8, season: 1, episode: 2), 600, at: 1)]
        #expect(SeriesCursor.target(seriesID: 7, progress: p, seasons: seasons)?.key == ep(1, 1))
    }
}
