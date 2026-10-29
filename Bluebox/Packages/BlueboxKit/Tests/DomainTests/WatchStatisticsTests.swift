import Domain
import Foundation
import Testing

@Suite struct WatchStatisticsTests {
    /// Fixed calendar and clock: Thursday 29 October 2026, 21:00 UTC.
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }
    static let now = date(2026, 10, 29, 21)

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    let show = MediaKey.series(tmdbID: 1)
    let otherShow = MediaKey.series(tmdbID: 2)
    let film = MediaKey.movie(tmdbID: 10)
    let oldFilm = MediaKey.movie(tmdbID: 11)

    func episode(_ series: Int, _ s: Int, _ e: Int) -> MediaKey { .episode(seriesID: series, season: s, episode: e) }

    var titles: [MediaKey: WatchStatistics.TitleInfo] {
        [show: .init(name: "Harbor Lights", genreIDs: [18, 9648]),
         otherShow: .init(name: "Night Shift", genreIDs: [35]),
         film: .init(name: "Tears of Steel", genreIDs: [878, 28]),
         oldFilm: .init(name: "Sintel", genreIDs: [16])]
    }
    let names = [18: "Drama", 9648: "Mystery", 35: "Comedy", 878: "Science Fiction", 28: "Action", 16: "Animation"]

    /// Four episodes of one show on one evening, one of another show, a film
    /// this month, a film last year, and a peek that doesn't count.
    var records: [WatchProgress] {
        let evening = Self.date(2026, 10, 24, 20)
        return [
            WatchProgress(key: episode(1, 1, 1), position: 3000, duration: 3000, isCompleted: true, updatedAt: evening),
            WatchProgress(key: episode(1, 1, 2), position: 3000, duration: 3000, isCompleted: true, updatedAt: evening.addingTimeInterval(3000)),
            WatchProgress(key: episode(1, 1, 3), position: 3000, duration: 3000, isCompleted: true, updatedAt: evening.addingTimeInterval(6000)),
            WatchProgress(key: episode(1, 1, 4), position: 1500, duration: 3000, updatedAt: evening.addingTimeInterval(8000)),
            WatchProgress(key: episode(2, 1, 1), position: 1800, duration: 1800, isCompleted: true, updatedAt: Self.date(2026, 3, 2, 9)),
            WatchProgress(key: film, position: 5400, duration: 5400, isCompleted: true, updatedAt: Self.date(2026, 10, 2, 22)),
            WatchProgress(key: oldFilm, position: 7200, duration: 7200, isCompleted: true, updatedAt: Self.date(2025, 6, 1, 15)),
            WatchProgress(key: MediaKey.movie(tmdbID: 99), position: 12, duration: 6000, updatedAt: Self.now),
        ]
    }

    func compute() -> WatchStatistics {
        WatchStatistics.compute(records: records, titles: titles, genreNames: names, now: Self.now, calendar: Self.calendar)
    }

    @Test func hoursThisMonthYearAndAllTime() {
        let s = compute()
        // October: 3 × 50 min + 25 min + 90 min film.
        #expect(s.secondsThisMonth == 3000 * 3 + 1500 + 5400)
        #expect(s.secondsThisYear == s.secondsThisMonth + 1800)
        #expect(s.secondsAllTime == s.secondsThisYear + 7200)
    }

    @Test func titlesFinishedCountsFilmsAndEpisodes() {
        let s = compute()
        #expect(s.filmsFinished == 2)
        #expect(s.episodesFinished == 4)
        #expect(s.titlesFinished == 6)
        #expect(s.year.filmsFinished == 1)
        #expect(s.year.episodesFinished == 4)
    }

    @Test func topShowsFilmsAndGenres() {
        let s = compute()
        #expect(s.topShows.map(\.name) == ["Harbor Lights", "Night Shift"])
        #expect(s.topShows.first?.count == 4)
        #expect(s.topFilms.map(\.name) == ["Sintel", "Tears of Steel"])
        // Drama and Mystery both have Harbor Lights' 10,500 s; ties go by name.
        #expect(s.topGenres.prefix(2).map(\.name) == ["Drama", "Mystery"])
        #expect(s.year.topFilm?.name == "Tears of Steel")
        #expect(s.year.topGenre?.name == "Drama")
    }

    @Test func longestBingeIsMostEpisodesOfOneShowInADay() {
        let binge = compute().longestBinge
        #expect(binge?.name == "Harbor Lights")
        #expect(binge?.episodes == 4)
        #expect(binge?.day == Self.calendar.startOfDay(for: Self.date(2026, 10, 24)))
    }

    @Test func dayOfWeekAndHourAreMondayFirst() {
        let s = compute()
        #expect(s.byWeekday.count == 7 && s.byHour.count == 24)
        // 24 October 2026 is a Saturday: index 5 when Monday is 0.
        #expect(s.byWeekday[5] == 3000 * 3 + 1500)
        #expect(s.byHour[20] == 6000)  // episodes 1 and 2 were last watched in the 8 pm hour
        #expect(s.year.busiestMonth == 10)
    }

    @Test func peeksDontCountAndNothingWatchedIsEmpty() {
        let peek = WatchProgress(key: film, position: 20, duration: 5400, updatedAt: Self.now)
        #expect(WatchStatistics.watchedSeconds(peek) == 0)
        let s = WatchStatistics.compute(records: [peek], titles: titles, genreNames: names, now: Self.now, calendar: Self.calendar)
        #expect(s.isEmpty)
        #expect(s.longestBinge == nil)
    }

    @Test func finishedWithoutDurationCountsItsPosition() {
        let p = WatchProgress(key: film, position: 4000, duration: nil, isCompleted: true, updatedAt: Self.now)
        #expect(WatchStatistics.watchedSeconds(p) == 4000)
        let over = WatchProgress(key: film, position: 9000, duration: 5400, updatedAt: Self.now)
        #expect(WatchStatistics.watchedSeconds(over) == 5400)
    }

    @Test func titlesWithoutCachedDataStillCount() {
        let s = WatchStatistics.compute(records: records, titles: [:], genreNames: names, now: Self.now, calendar: Self.calendar)
        #expect(s.topShows.first?.name == "Unknown Show")
        #expect(s.topGenres.isEmpty)
        #expect(s.secondsAllTime > 0)
    }
}

@Suite struct SpoilerGuardTests {
    let key = MediaKey.episode(seriesID: 1, season: 2, episode: 3)

    @Test func offHidesNothing() {
        #expect(!SpoilerGuard.hides(isOn: false, progress: nil))
    }

    @Test func unwatchedEpisodesAreHidden() {
        #expect(SpoilerGuard.hides(isOn: true, progress: nil))
        // A minute in is still "not watched yet": the opening may be a cold open.
        #expect(SpoilerGuard.hides(isOn: true, progress: WatchProgress(key: key, position: 60, duration: 3000, updatedAt: .now)))
    }

    @Test func startedOrWatchedEpisodesShow() {
        #expect(!SpoilerGuard.hides(isOn: true, progress: WatchProgress(key: key, position: 600, duration: 3000, updatedAt: .now)))
        #expect(!SpoilerGuard.hides(isOn: true, progress: WatchProgress(key: key, position: 0, duration: 3000, isCompleted: true, updatedAt: .now)))
    }

    @Test func revealingShowsOne() {
        #expect(!SpoilerGuard.hides(isOn: true, progress: nil, revealed: true))
    }
}
