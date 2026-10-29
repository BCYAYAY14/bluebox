import Foundation

/// My Bluebox: what a profile has watched, worked out on the device from the
/// progress records it already keeps. Nothing is sent anywhere.
///
/// The library keeps one record per film or episode (the latest position and
/// when it was last watched), not a log of every sitting, so the numbers are
/// honest approximations: a record's time counts on the day it was last
/// watched, and a finished one counts its full length.
public struct WatchStatistics: Sendable, Equatable {
    /// A show, film or genre with how long was spent on it.
    public struct Ranked: Sendable, Hashable, Identifiable {
        /// The media key (shows and films) or "genre:<id>".
        public let id: String
        public let name: String
        public let seconds: TimeInterval
        /// Episodes (shows), 1 (films), or titles (genres) counted in it.
        public let count: Int
        public init(id: String, name: String, seconds: TimeInterval, count: Int) {
            self.id = id; self.name = name; self.seconds = seconds; self.count = count
        }
    }

    /// The most episodes of one show watched on one day.
    public struct Binge: Sendable, Equatable {
        public let show: MediaKey
        public let name: String
        public let episodes: Int
        /// The start of that day.
        public let day: Date
        public init(show: MediaKey, name: String, episodes: Int, day: Date) {
            self.show = show; self.name = name; self.episodes = episodes; self.day = day
        }
    }

    /// The "Year in Bluebox" card.
    public struct Year: Sendable, Equatable {
        public let year: Int
        public let seconds: TimeInterval
        public let filmsFinished: Int
        public let episodesFinished: Int
        public let topShow: Ranked?
        public let topFilm: Ranked?
        public let topGenre: Ranked?
        /// 1–12, the month with the most watching.
        public let busiestMonth: Int?
        public let longestBinge: Binge?
        public var titlesFinished: Int { filmsFinished + episodesFinished }
    }

    public let secondsThisMonth: TimeInterval
    public let secondsThisYear: TimeInterval
    public let secondsAllTime: TimeInterval
    public let filmsFinished: Int
    public let episodesFinished: Int
    public let topShows: [Ranked]
    public let topFilms: [Ranked]
    public let topGenres: [Ranked]
    public let longestBinge: Binge?
    /// Seconds by weekday, Monday first (7 values).
    public let byWeekday: [TimeInterval]
    /// Seconds by hour of the day, midnight first (24 values).
    public let byHour: [TimeInterval]
    public let year: Year

    public var titlesFinished: Int { filmsFinished + episodesFinished }
    public var isEmpty: Bool { secondsAllTime == 0 && titlesFinished == 0 }

    /// What the computation needs about a film or show: its name and genres
    /// (from the cached title data; missing ones just don't count towards genres).
    public struct TitleInfo: Sendable, Hashable {
        public let name: String
        public let genreIDs: [Int]
        public init(name: String, genreIDs: [Int]) { self.name = name; self.genreIDs = genreIDs }
    }

    /// How many shows, films and genres the lists keep.
    public static let topCount = 5
    /// Positions under this weren't really watched (an accidental tap, a peek).
    public static let minimumCounted: TimeInterval = 30

    /// How long a record counts for: the full length once finished, else how far it got.
    public static func watchedSeconds(_ p: WatchProgress) -> TimeInterval {
        let duration = p.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var s = p.isCompleted ? (duration ?? p.position) : p.position
        guard s.isFinite, s > 0 else { return 0 }
        if let duration { s = min(s, duration) }
        return p.isCompleted || s >= minimumCounted ? s : 0
    }

    /// Works the statistics out. Pure and quick (a few thousand records take
    /// well under a millisecond), but callers run it off the main actor anyway.
    /// - Parameters:
    ///   - titles: name and genres per film or show key (episodes look up their show).
    ///   - genreNames: TMDB genre names by ID.
    public static func compute(records: [WatchProgress], titles: [MediaKey: TitleInfo], genreNames: [Int: String],
                               now: Date, calendar: Calendar = .current) -> WatchStatistics {
        let counted = records.compactMap { p -> (WatchProgress, TimeInterval)? in
            let s = watchedSeconds(p)
            return s > 0 || p.isCompleted ? (p, s) : nil
        }
        let thisYear = calendar.component(.year, from: now)
        let month = calendar.dateInterval(of: .month, for: now)
        let inYear = counted.filter { calendar.component(.year, from: $0.0.updatedAt) == thisYear }

        var weekday = [TimeInterval](repeating: 0, count: 7)
        var hour = [TimeInterval](repeating: 0, count: 24)
        for (p, s) in counted {
            // Calendar weekdays are 1 (Sunday) … 7 (Saturday); Monday first here.
            let w = (calendar.component(.weekday, from: p.updatedAt) + 5) % 7
            weekday[w] += s
            hour[calendar.component(.hour, from: p.updatedAt)] += s
        }

        let all = Totals(counted, titles: titles, genreNames: genreNames, calendar: calendar)
        let year = Totals(inYear, titles: titles, genreNames: genreNames, calendar: calendar)
        var months = [Int: TimeInterval]()
        for (p, s) in inYear { months[calendar.component(.month, from: p.updatedAt), default: 0] += s }
        let busiest = months.filter { $0.value > 0 }.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key

        return WatchStatistics(
            secondsThisMonth: counted.filter { month?.contains($0.0.updatedAt) ?? false }.reduce(0) { $0 + $1.1 },
            secondsThisYear: year.seconds,
            secondsAllTime: all.seconds,
            filmsFinished: all.filmsFinished,
            episodesFinished: all.episodesFinished,
            topShows: all.shows, topFilms: all.films, topGenres: all.genres,
            longestBinge: all.binge,
            byWeekday: weekday, byHour: hour,
            year: Year(year: thisYear, seconds: year.seconds, filmsFinished: year.filmsFinished,
                       episodesFinished: year.episodesFinished, topShow: year.shows.first, topFilm: year.films.first,
                       topGenre: year.genres.first, busiestMonth: busiest, longestBinge: year.binge))
    }

    /// Sums for one span of records (all time, or one year).
    private struct Totals {
        var seconds: TimeInterval = 0
        var filmsFinished = 0
        var episodesFinished = 0
        var shows: [Ranked] = []
        var films: [Ranked] = []
        var genres: [Ranked] = []
        var binge: Binge?

        init(_ records: [(WatchProgress, TimeInterval)], titles: [MediaKey: TitleInfo], genreNames: [Int: String], calendar: Calendar) {
            var showTime: [MediaKey: (TimeInterval, Int)] = [:]
            var filmTime: [MediaKey: TimeInterval] = [:]
            var genreTime: [Int: (TimeInterval, Set<MediaKey>)] = [:]
            var days: [MediaKey: [Date: Int]] = [:]
            for (p, s) in records {
                seconds += s
                let owner = p.key.seriesKey ?? p.key
                if p.key.seriesKey != nil {
                    if p.isCompleted { episodesFinished += 1 }
                    var t = showTime[owner] ?? (0, 0)
                    t.0 += s; t.1 += 1
                    showTime[owner] = t
                    days[owner, default: [:]][calendar.startOfDay(for: p.updatedAt), default: 0] += 1
                } else if p.key.isMovie {
                    if p.isCompleted { filmsFinished += 1 }
                    filmTime[owner, default: 0] += s
                }
                for g in Set(titles[owner]?.genreIDs ?? []) {
                    var t = genreTime[g] ?? (0, [])
                    t.0 += s; t.1.insert(owner)
                    genreTime[g] = t
                }
            }
            func name(_ key: MediaKey) -> String? { titles[key]?.name }
            shows = Self.top(showTime.compactMap { k, v in
                v.0 > 0 ? Ranked(id: k.rawValue, name: name(k) ?? "Unknown Show", seconds: v.0, count: v.1) : nil
            })
            films = Self.top(filmTime.compactMap { k, v in
                v > 0 ? Ranked(id: k.rawValue, name: name(k) ?? "Unknown Film", seconds: v, count: 1) : nil
            })
            genres = Self.top(genreTime.compactMap { g, v in
                guard v.0 > 0, let n = genreNames[g] else { return nil }
                return Ranked(id: "genre:\(g)", name: n, seconds: v.0, count: v.1.count)
            })
            // Most episodes in a day; ties go to the more recent day.
            var best: (MediaKey, Date, Int)?
            for (show, byDay) in days {
                for (day, n) in byDay where n >= 2 {
                    if let b = best, (n, day, show.rawValue) <= (b.2, b.1, b.0.rawValue) { continue }
                    best = (show, day, n)
                }
            }
            binge = best.map { Binge(show: $0.0, name: name($0.0) ?? "Unknown Show", episodes: $0.2, day: $0.1) }
        }

        /// Longest first; ties by name so the order is the same every time.
        static func top(_ items: [Ranked]) -> [Ranked] {
            Array(items.sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) }.prefix(WatchStatistics.topCount))
        }
    }
}
