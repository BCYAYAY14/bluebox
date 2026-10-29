import Domain
@testable import Features
import Foundation
import Metadata
import Persistence
import Testing
import TestingSupport

// Home on the device (design questions 13–17): scoring, row order, Continue
// Watching's next episode, hiding, the per-profile file, and what it costs.

private let now = ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z")!
private let day: TimeInterval = 86_400

private func movie(_ id: Int, _ name: String? = nil, genres: [Int], rating: Double? = nil, released: Date? = nil) -> Title {
    Title(key: .movie(tmdbID: id), kind: .movie, name: name ?? "M\(id)", releaseDate: released, genreIDs: genres, voteAverage: rating)
}

private func finished(_ key: MediaKey, daysAgo: Double) -> WatchProgress {
    WatchProgress(key: key, position: 3600, duration: 3600, isCompleted: true, updatedAt: now.addingTimeInterval(-daysAgo * day))
}

private func partway(_ key: MediaKey, _ fraction: Double, daysAgo: Double) -> WatchProgress {
    WatchProgress(key: key, position: 3600 * fraction, duration: 3600, updatedAt: now.addingTimeInterval(-daysAgo * day))
}

@Suite struct TasteScoringTests {
    @Test func aWatchCountsHalfAsMuchEveryThirtyDays() {
        #expect(TasteRules.decay(since: now, now: now) == 1)
        #expect(abs(TasteRules.decay(since: now.addingTimeInterval(-30 * day), now: now) - 0.5) < 1e-9)
        #expect(abs(TasteRules.decay(since: now.addingTimeInterval(-60 * day), now: now) - 0.25) < 1e-9)
        // A clock that's behind doesn't make a watch count more than new.
        #expect(TasteRules.decay(since: now.addingTimeInterval(day), now: now) == 1)
    }

    @Test func finishedCountsDoublePastAQuarterAndThumbsChangeIt() {
        #expect(TasteRules.weight(base: 1, rating: nil) == 1)
        #expect(TasteRules.weight(base: 2, rating: nil) == 2)
        #expect(TasteRules.weight(base: 1, rating: RatingThumb.up.rating) == 2)      // a thumbs-up doubles it…
        #expect(TasteRules.weight(base: 2, rating: RatingThumb.up.rating) == 3)      // …up to Love's 3
        #expect(TasteRules.weight(base: 1, rating: RatingThumb.love.rating) == 3)
        #expect(TasteRules.weight(base: 2, rating: RatingThumb.down.rating) == -2)   // Not for Me counts against
    }

    @Test func historyGroupsEpisodesByShowAndIgnoresBarelyStarted() {
        let show = MediaKey.series(tmdbID: 7)
        let records = [
            finished(show.episode(season: 1, episode: 1)!, daysAgo: 3),
            finished(show.episode(season: 1, episode: 2)!, daysAgo: 2),
            partway(show.episode(season: 1, episode: 3)!, 0.5, daysAgo: 1),
            partway(.movie(tmdbID: 1), 0.3, daysAgo: 5),
            partway(.movie(tmdbID: 2), 0.1, daysAgo: 0),
        ]
        let watched = TasteRules.watched(records)
        #expect(watched.map(\.key) == [.movie(tmdbID: 2), show, .movie(tmdbID: 1)])
        #expect(watched.map(\.base) == [0, 1, 1])   // two episodes isn't "finished" a show; 10% isn't watched
        let three = TasteRules.watched(records + [finished(show.episode(season: 1, episode: 4)!, daysAgo: 0)])
        #expect(three.first { $0.key == show }?.base == 2)
    }

    @Test func affinityWeighsRecencyAndThumbs() {
        let scifi = MediaKey.movie(tmdbID: 1), drama = MediaKey.movie(tmdbID: 2), comedy = MediaKey.movie(tmdbID: 3)
        let watched = TasteRules.watched([finished(scifi, daysAgo: 0), partway(drama, 0.5, daysAgo: 30), finished(comedy, daysAgo: 0)])
        let genres: [MediaKey: [Int]] = [scifi: [878], drama: [18], comedy: [35]]
        let ratings = [comedy: RatingEntry(rating: RatingThumb.down.rating, date: now)]
        let a = TasteRules.affinity(watched: watched, ratings: ratings, genres: genres, now: now)
        #expect(a[878] == 2)
        #expect(abs((a[18] ?? 0) - 0.5) < 1e-9)    // past 25% (1), a month ago (× 0.5)
        #expect(a[35] == -2)
        // Rated without watching: counts from when it was rated.
        let liked = MediaKey.movie(tmdbID: 9)
        let b = TasteRules.affinity(watched: [], ratings: [liked: RatingEntry(rating: RatingThumb.love.rating, date: now.addingTimeInterval(-30 * day))],
                                    genres: [liked: [9648]], now: now)
        #expect(b[9648] == 1.5)
    }

    @Test func theScoreIsGenreAffinityOverRootNPlusRatingAndNewness() {
        let affinity: [Int: Double] = [878: 2, 18: 0.5]
        let t = movie(10, genres: [878, 18], rating: 8)
        let s = TopPicks.score(t, affinity: affinity, now: now)
        #expect(abs(s.score - ((2 + 0.5) / 2.0.squareRoot() + 0.3 * 2)) < 1e-9)
        #expect(s.genre == 878)
        let new = movie(11, genres: [878], rating: 6, released: now.addingTimeInterval(-5 * day))
        #expect(abs(TopPicks.score(new, affinity: affinity, now: now).score - (2 + 0.5)) < 1e-9)
    }

    @Test func picksLeaveOutWhatYouveSeenAndExplainThemselves() {
        let affinity: [Int: Double] = [878: 2, 9648: 1, 35: -2]
        let names = [878: "Science Fiction", 9648: "Mystery", 35: "Comedy"]
        let candidates = [
            movie(1, genres: [878], rating: 7), movie(2, genres: [9648], rating: 9), movie(3, genres: [35], rating: 9),
            movie(4, genres: [878], rating: 7), movie(5, genres: [99], rating: 9),
        ]
        let picks = TopPicks.picks(candidates: candidates, affinity: affinity, excluded: [.movie(tmdbID: 4)], genreNames: names, now: now)
        #expect(picks.map(\.title.key) == [.movie(tmdbID: 1), .movie(tmdbID: 2)])  // no comedy (disliked), no unrelated genre
        #expect(picks.map(\.reason) == ["Because you like Sci-Fi", "Because you like Mystery"])
        #expect(TopPicks.reason(genre: 12345, names: [:]) == "Picked for you")
    }

    @Test func aThumbsUpReordersThePicks() {
        let scifi = MediaKey.movie(tmdbID: 1), mystery = MediaKey.movie(tmdbID: 2)
        let watched = TasteRules.watched([finished(scifi, daysAgo: 1), finished(mystery, daysAgo: 1)])
        let genres: [MediaKey: [Int]] = [scifi: [878], mystery: [9648]]
        let candidates = [movie(10, genres: [878], rating: 7), movie(11, genres: [9648], rating: 7)]
        func first(_ ratings: [MediaKey: RatingEntry]) -> MediaKey? {
            let a = TasteRules.affinity(watched: watched, ratings: ratings, genres: genres, now: now)
            return TopPicks.picks(candidates: candidates, affinity: a, excluded: [], genreNames: [:], now: now).first?.title.key
        }
        #expect(first([mystery: RatingEntry(rating: RatingThumb.love.rating, date: now)]) == .movie(tmdbID: 11))
        #expect(first([scifi: RatingEntry(rating: RatingThumb.love.rating, date: now)]) == .movie(tmdbID: 10))
    }

    @Test func noMoreThanTwoFromOneFranchise() {
        let films = ["Dune", "Dune: Part Two", "Dune: Part Three", "Arrival"].enumerated().map { i, n in movie(i + 1, n, genres: [878]) }
        let picks = TopPicks.picks(candidates: films, affinity: [878: 1], excluded: [], genreNames: [:], now: now)
        #expect(picks.count == 3 && picks.contains { $0.title.name == "Arrival" })
        #expect(picks.filter { $0.title.name.hasPrefix("Dune") }.count == 2)
        #expect(TopPicks.franchise("Toy Story 3") == "toy story")
    }

    @Test func littleHistoryMeansNoPersonalRows() {
        let one = TasteRules.watched([finished(.movie(tmdbID: 1), daysAgo: 1)])
        #expect(!TasteRules.hasEnoughHistory(one, ratings: [:]))
        let two = TasteRules.watched([finished(.movie(tmdbID: 1), daysAgo: 1), partway(.movie(tmdbID: 2), 0.4, daysAgo: 1)])
        #expect(TasteRules.hasEnoughHistory(two, ratings: [:]))
    }

    @Test func genreRowsFollowYourTasteWithTheSameCount() {
        let all = [Genre(id: 16, name: "Animation"), Genre(id: 35, name: "Comedy"), Genre(id: 18, name: "Drama"),
                   Genre(id: 9648, name: "Mystery"), Genre(id: 878, name: "Science Fiction"), Genre(id: 53, name: "Thriller"),
                   Genre(id: 27, name: "Horror"), Genre(id: 10765, name: "Sci-Fi & Fantasy")]
        // No taste: today's fixed rows, in the genre list's order.
        #expect(GenreRowOrder.pick(available: all, affinity: [:], kind: .movie, count: 3).map(\.id) == [16, 35, 18])
        // Horror first, then the fixed ones.
        #expect(GenreRowOrder.pick(available: all, affinity: [27: 3, 35: -1], kind: .movie, count: 3).map(\.id) == [27, 16, 35])
        // TV maps film Sci-Fi onto Sci-Fi & Fantasy.
        #expect(GenreRowOrder.pick(available: all, affinity: [878: 2], kind: .series, count: 2).map(\.id) == [10765, 16])
    }
}

@MainActor
@Suite struct HomeRowOrderTests {
    private func row(_ id: String, _ ids: [Int] = [1]) -> HomeRow {
        HomeRow(id: id, title: id, titles: ids.map { movie($0, genres: []) })
    }

    @Test func personalAndEditorialRowsTakeTurns() {
        let editorial = ["trending", "top-series", "movies", "series", "top-movies", "acclaimed"].map { row($0) }
        let personal = ["top-picks", "because-1", "because-2"].map { row($0) }
        let out = HomeLayout.interleave(editorial: editorial, personal: personal).map(\.id)
        #expect(out == ["trending", "top-series", "top-picks", "movies", "because-1", "series", "because-2", "top-movies", "acclaimed"])
    }

    @Test func withNoHistoryHomeLooksLikeToday() {
        let editorial = ["a", "b", "c"].map { row($0) }
        #expect(HomeLayout.interleave(editorial: editorial, personal: []).map(\.id) == ["a", "b", "c"])
        // Short editorial (a failed list): personal rows still all show.
        #expect(HomeLayout.interleave(editorial: [row("a")], personal: [row("p"), row("q")]).map(\.id) == ["a", "p", "q"])
    }

    @Test func hiddenTitlesLeaveEveryRowAndEmptyRowsGo() {
        let rows = [row("a", [1, 2, 3]), row("b", [2])]
        let out = HomeLayout.hiding([.movie(tmdbID: 2)], from: rows)
        #expect(out.map(\.id) == ["a"])
        #expect(out[0].titles.compactMap(\.key.tmdbID) == [1, 3])
    }

    @Test func personalRowTitlesGoThroughOneHelper() {
        #expect(HomeRowTitles.topPicks(.makeDefault()) == "Top Picks for You")
        let sam = Profile(id: "s", name: "Sam", updatedAt: now)
        #expect(HomeRowTitles.topPicks(sam) == "Top Picks for Sam")
        #expect(HomeRowTitles.becauseYouWatched("Sintel") == "Because You Watched Sintel")
        #expect(HomeRowTitles.continueWatching(sam) == "Continue Watching")
    }
}

@Suite struct ContinueWatchingNextEpisodeTests {
    let show = MediaKey.series(tmdbID: 5)
    let seasons = [SeasonSummary(number: 1, name: "S1", episodeCount: 3), SeasonSummary(number: 2, name: "S2", episodeCount: 8)]
    func ep(_ s: Int, _ e: Int) -> MediaKey { show.episode(season: s, episode: e)! }

    @Test func aFinishedEpisodeMovesOnToTheNextOne() {
        let done = finished(ep(1, 2), daysAgo: 1)
        let out = ContinueWatchingRules.build(inProgress: [], recent: [done], shows: [show: .init(seasons: seasons)], now: now)
        #expect(out.count == 1)
        #expect(out[0].next == .init(key: ep(1, 3), season: 1, episode: 3, isNew: false))
        // Across a season.
        let finale = ContinueWatchingRules.build(inProgress: [], recent: [finished(ep(1, 3), daysAgo: 1)],
                                                 shows: [show: .init(seasons: seasons)], now: now)
        #expect(finale.first?.next?.key == ep(2, 1))
    }

    @Test func caughtUpShowsLeaveTheRow() {
        // The last listed episode.
        #expect(ContinueWatchingRules.build(inProgress: [], recent: [finished(ep(2, 8), daysAgo: 1)],
                                            shows: [show: .init(seasons: seasons)], now: now).isEmpty)
        // Listed but not aired yet.
        #expect(ContinueWatchingRules.build(inProgress: [], recent: [finished(ep(2, 4), daysAgo: 1)],
                                            shows: [show: .init(seasons: seasons, lastAired: ep(2, 4))], now: now).isEmpty)
        // No season list, but the tracker says that was the latest.
        #expect(ContinueWatchingRules.build(inProgress: [], recent: [finished(ep(2, 4), daysAgo: 1)],
                                            shows: [show: .init(lastAired: ep(2, 4))], now: now).isEmpty)
    }

    @Test func aNewAiringIsTaggedAndGoesFirst() {
        let movieInProgress = partway(.movie(tmdbID: 1), 0.4, daysAgo: 0)
        let done = finished(ep(2, 3), daysAgo: 5)
        let info = ContinueWatchingRules.ShowInfo(seasons: seasons, lastAired: ep(2, 4), lastAiredDate: now.addingTimeInterval(-day))
        let out = ContinueWatchingRules.build(inProgress: [movieInProgress], recent: [movieInProgress, done], shows: [show: info], now: now)
        #expect(out.map(\.progress.key) == [ep(2, 3), .movie(tmdbID: 1)])
        #expect(out[0].next?.isNew == true && out[0].next?.key == ep(2, 4))
        // Aired a month ago: next, not new.
        let old = ContinueWatchingRules.ShowInfo(seasons: seasons, lastAired: ep(2, 4), lastAiredDate: now.addingTimeInterval(-30 * day))
        #expect(ContinueWatchingRules.build(inProgress: [], recent: [done], shows: [show: old], now: now).first?.next?.isNew == false)
        // No air date: the new-episode check's announcement decides.
        let announced = ContinueWatchingRules.build(inProgress: [], recent: [done], shows: [show: .init(lastAired: ep(2, 4))],
                                                    announced: [ep(2, 4).rawValue], now: now)
        #expect(announced.first?.next == .init(key: ep(2, 4), season: 2, episode: 4, isNew: true))
    }

    @Test func inProgressResumesAndANewerFinishedEpisodeWins() {
        let older = partway(ep(1, 1), 0.5, daysAgo: 3)
        let out = ContinueWatchingRules.build(inProgress: [older], recent: [older], shows: [:], now: now)
        #expect(out.map(\.progress.key) == [ep(1, 1)] && out[0].next == nil)
        let newer = finished(ep(1, 2), daysAgo: 1)
        let moved = ContinueWatchingRules.build(inProgress: [older], recent: [newer, older], shows: [show: .init(seasons: seasons)], now: now)
        #expect(moved.count == 1 && moved[0].next?.key == ep(1, 3))
    }

    @Test func removedOrUnknownOrOldShows() {
        // Taken out of the row (reset to 0): stays out.
        let reset = WatchProgress(key: ep(1, 3), position: 0, duration: nil, updatedAt: now)
        #expect(ContinueWatchingRules.build(inProgress: [], recent: [reset, finished(ep(1, 2), daysAgo: 1)],
                                            shows: [show: .init(seasons: seasons)], now: now).isEmpty)
        // A possible finale with nothing known: shown, number unknown (playing works it out).
        let unknown = ContinueWatchingRules.build(inProgress: [], recent: [finished(ep(1, 10), daysAgo: 1)],
                                                  shows: [show: .init(lastAired: ep(2, 2))], now: now)
        #expect(unknown.first?.next == .init(key: nil, season: nil, episode: nil, isNew: false))
        #expect(WatchEntry(progress: unknown[0].progress, title: Title(key: show, kind: .series, name: "S"), next: unknown[0].next).label
                == "Next Episode")
        // Months ago: no longer followed.
        #expect(ContinueWatchingRules.build(inProgress: [], recent: [finished(ep(1, 1), daysAgo: 120)],
                                            shows: [show: .init(seasons: seasons)], now: now).isEmpty)
    }

    @Test func labels() {
        let t = Title(key: show, kind: .series, name: "S")
        let p = finished(ep(2, 3), daysAgo: 1)
        #expect(WatchEntry(progress: p, title: t, next: .init(key: ep(2, 4), season: 2, episode: 4, isNew: false)).label == "S2·E4 · Next")
        #expect(WatchEntry(progress: p, title: t, next: .init(key: ep(2, 4), season: 2, episode: 4, isNew: true)).label == "S2·E4 · New Episode")
        // The menu acts on the next episode, not yet started.
        let menu = WatchEntry(progress: p, title: t, next: .init(key: ep(2, 4), season: 2, episode: 4, isNew: false)).menuEntry
        #expect(menu?.progress.key == ep(2, 4) && menu?.progress.position == 0)
    }
}

@Suite struct PersonalHomeCacheTests {
    func rows(_ fp: String, builtAt: Date) -> PersonalHomeSnapshot.Rows {
        .init(fingerprint: fp, builtAt: builtAt, topPicks: [], because: [], genreOrder: [878])
    }

    @Test func rowsLastSixHoursOrUntilHistoryChanges() {
        var s = PersonalHomeSnapshot()
        s.rows["all"] = rows("abc", builtAt: now)
        #expect(s.freshRows("all", fingerprint: "abc", now: now.addingTimeInterval(5.9 * 3600)) != nil)
        #expect(s.freshRows("all", fingerprint: "abc", now: now.addingTimeInterval(6 * 3600)) == nil)
        #expect(s.freshRows("all", fingerprint: "abd", now: now) == nil)          // you watched something
        #expect(s.freshRows("movies", fingerprint: "abc", now: now) == nil)
    }

    @Test func recommendationsLastADay() {
        var s = PersonalHomeSnapshot()
        let seed = MediaKey.movie(tmdbID: 1)
        s.recommendations[seed.rawValue] = .init(fetchedAt: now, titles: [movie(2, genres: [])])
        #expect(s.freshRecommendations(for: seed, now: now.addingTimeInterval(23 * 3600))?.count == 1)
        #expect(s.freshRecommendations(for: seed, now: now.addingTimeInterval(24 * 3600)) == nil)
        s.prune(now: now.addingTimeInterval(25 * 3600))
        #expect(s.recommendations.isEmpty)
    }

    @Test func theFileIsPerProfile() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "home-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PersonalHomeStore(directory: dir)
        var s = PersonalHomeSnapshot()
        s.rows["all"] = rows("x", builtAt: now)
        await store.save(s, profileID: "default")
        #expect(await store.load(profileID: "default") == s)
        #expect(await store.load(profileID: "sam") == nil)
        store.remove(profileID: "default")
        #expect(await store.load(profileID: "default") == nil)
    }

    @Test func theFingerprintChangesWhenYouWatchOrRate() {
        let a = HomeHistory(records: [finished(.movie(tmdbID: 1), daysAgo: 1)], ratings: [:])
        let b = HomeHistory(records: [partway(.movie(tmdbID: 2), 0.1, daysAgo: 0), finished(.movie(tmdbID: 1), daysAgo: 1)], ratings: [:])
        let c = HomeHistory(records: a.records, ratings: [.movie(tmdbID: 1): RatingEntry(rating: 10, date: now)])
        #expect(a.fingerprint(.all) == HomeHistory(records: a.records, ratings: [:]).fingerprint(.all))
        #expect(a.fingerprint(.all) != b.fingerprint(.all))
        #expect(a.fingerprint(.all) != c.fingerprint(.all))
        #expect(a.fingerprint(.all) != a.fingerprint(.movies))
    }
}

@MainActor
@Suite struct HidingTests {
    func app() throws -> AppModel {
        AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                 prefs: PreferencesStore(defaults: UserDefaults(suiteName: "hiding.\(UUID().uuidString)")!), forceSample: true)
    }

    @Test func hiddenTitlesArePerProfileAndUndoable() throws {
        let app = try app()
        let t = movie(1, "Velocity", genres: [28])
        app.hideTitle(t)
        #expect(app.hiddenKeys() == [t.key])
        #expect(app.hiddenTitleList().map(\.title) == [t])
        #expect(app.toast?.message == "Hidden from Home")
        app.toast?.action?()
        #expect(app.hiddenKeys().isEmpty)
        app.hideTitle(t)
        // Another profile has its own list.
        let store = HiddenTitlesStore(prefs: app.prefs)
        #expect(store.keys(profileID: "someone-else").isEmpty)
        app.unhideTitle(t.key)
        #expect(app.hiddenTitleList().isEmpty)
    }

    @Test func notInterestedIsOnPostersButNotContinueWatching() {
        let poster = QuickActions.build(kind: .movie, onList: false, watched: false, downloaded: false, canShare: true, hideable: true)
        #expect(poster.groups.last == [.notInterested, .details, .share])
        let cw = QuickActions.build(kind: .movie, inProgress: true, onList: false, watched: false, downloaded: false,
                                    canShare: false, removable: true)
        #expect(!cw.groups.joined().contains(.notInterested))
    }

    @Test func homeDropsHiddenAndWatchedTitles() async throws {
        let app = try app()
        // Two finished films: enough history for personal rows (sample catalog).
        _ = try await app.store.save(finished(.movie(tmdbID: 45745), daysAgo: 1))     // Sintel
        _ = try await app.store.save(finished(.movie(tmdbID: 10378), daysAgo: 2))     // Big Buck Bunny
        try await app.store.store(SampleMetadataProvider.titles)
        let model = HomeModel()
        await model.load(app, category: .all)
        let shown = Set(model.visibleRows(app.currentProfile).filter { $0.style != .topTen }.flatMap(\.titles).map(\.key))
        #expect(!shown.contains(.movie(tmdbID: 45745)) && !shown.contains(.movie(tmdbID: 10378)))
        #expect(!model.topPicks.isEmpty)
        let victim = try #require(model.visibleRows(app.currentProfile).first { $0.style != .topTen }?.titles.first)
        app.hideTitle(victim)
        model.hidden = app.hiddenKeys()
        #expect(!model.visibleRows(app.currentProfile).flatMap(\.titles).contains(victim))
        #expect(model.visibleHero?.key != victim.key)
    }
}

/// Home's TMDB requests, counted at the HTTP layer with canned responses.
@MainActor
@Suite struct HomeRequestCountTests {
    static func page(_ ids: Range<Int>, tv: Bool = false, genre: Int = 878) -> FixtureHTTPClient.Reply {
        let results = ids.map { id -> [String: Any] in
            var r: [String: Any] = ["id": id, "overview": "", "poster_path": "/p\(id).jpg", "backdrop_path": "/b\(id).jpg",
                                    "genre_ids": [genre, 18], "vote_average": 7.0]
            if tv { r["name"] = "Show \(id)"; r["first_air_date"] = "2020-01-01"; r["media_type"] = "tv" }
            else { r["title"] = "Film \(id)"; r["release_date"] = "2020-01-01"; r["media_type"] = "movie" }
            return r
        }
        let body = try! JSONSerialization.data(withJSONObject: ["page": 1, "results": results, "total_pages": 1])
        return .init(body: body)
    }

    static func genres(_ list: [(Int, String)]) -> FixtureHTTPClient.Reply {
        .init(body: try! JSONSerialization.data(withJSONObject: ["genres": list.map { ["id": $0.0, "name": $0.1] as [String: Any] }]))
    }

    static func detail(_ id: Int, recs: Range<Int>) -> FixtureHTTPClient.Reply {
        let recPage = try! JSONSerialization.jsonObject(with: page(recs).body)
        let body = try! JSONSerialization.data(withJSONObject: [
            "id": id, "title": "Seed \(id)", "genres": [["id": 878, "name": "Science Fiction"]], "recommendations": recPage,
        ])
        return .init(body: body)
    }

    func makeApp(_ http: FixtureHTTPClient) throws -> AppModel {
        let secrets = MemorySecretStore([SecretAccount.tmdb: "0123456789abcdef0123456789abcdef"])
        return AppModel(store: try LibraryStore.make(inMemory: true), secrets: secrets,
                        prefs: PreferencesStore(defaults: UserDefaults(suiteName: "requests.\(UUID().uuidString)")!), http: http)
    }

    func tmdb(_ http: FixtureHTTPClient) -> Int { http.requests.filter { $0.url?.host == "api.themoviedb.org" }.count }

    @Test func coldHomeMakesAtMostTwelveAndCachedHomeNone() async throws {
        let http = FixtureHTTPClient()
        http.on("trending/all/week", Self.page(1000..<1020))
        http.on("movie/popular", Self.page(1100..<1120))
        http.on("tv/popular", Self.page(1200..<1220, tv: true))
        http.on("movie/top_rated", Self.page(1300..<1320))
        // TMDB's film genres (the six fixed rows' among them) and a TV list.
        http.on("genre/movie/list", Self.genres([(28, "Action"), (16, "Animation"), (35, "Comedy"), (18, "Drama"),
                                                 (9648, "Mystery"), (878, "Science Fiction"), (53, "Thriller")]))
        http.on("genre/tv/list", Self.genres([(10765, "Sci-Fi & Fantasy"), (18, "Drama")]))
        http.on("discover/movie", Self.page(1400..<1420))
        http.on("movie/101", Self.detail(101, recs: 1500..<1510))
        http.on("movie/102", Self.detail(102, recs: 1510..<1520))
        let app = try makeApp(http)
        #expect(app.catalogMode == .live)
        // History: two sci-fi films (their titles are in the local cache, as after playing them).
        try await app.store.store([movie(101, "Seed One", genres: [878]), movie(102, "Seed Two", genres: [878, 53])])
        _ = try await app.store.save(finished(.movie(tmdbID: 101), daysAgo: 1))
        _ = try await app.store.save(finished(.movie(tmdbID: 102), daysAgo: 2))
        let dir = FileManager.default.temporaryDirectory.appending(path: "home-requests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        app.personalHome = PersonalHomeStore(directory: dir)

        let clock = ContinuousClock()
        let cold = HomeModel()
        let coldTime = await clock.measure { await cold.load(app, category: .all) }
        let coldCount = tmdb(http)
        #expect(coldCount <= 12)
        #expect(coldCount == 11)   // 4 lists + 2 genre lists + 3 genre rows + 2 "Because You Watched"
        #expect(cold.catalogError == nil)
        #expect(cold.topPicks.count >= TopPicks.minimumPicks)
        #expect(cold.because.map(\.seed.key) == [.movie(tmdbID: 101), .movie(tmdbID: 102)])
        let ids = cold.visibleRows(app.currentProfile).map(\.id)
        #expect(ids.contains("top-picks") && ids.contains("because-tmdb:movie:101"))

        // Again in the same session: everything is cached.
        let warm = HomeModel()
        let warmTime = await clock.measure { await warm.load(app, category: .all) }
        #expect(tmdb(http) == coldCount)
        #expect(warm.visibleRows(app.currentProfile).map(\.id) == ids)

        // Next launch (memory cold, the profile's file kept): the recommendations come from the file.
        let relaunched = try makeApp(http)
        try await relaunched.store.store([movie(101, "Seed One", genres: [878]), movie(102, "Seed Two", genres: [878, 53])])
        _ = try await relaunched.store.save(finished(.movie(tmdbID: 101), daysAgo: 1))
        _ = try await relaunched.store.save(finished(.movie(tmdbID: 102), daysAgo: 2))
        relaunched.personalHome = PersonalHomeStore(directory: dir)
        let before = tmdb(http)
        let launch = HomeModel()
        await launch.load(relaunched, category: .all)
        #expect(tmdb(http) - before == 9)
        #expect(launch.because.count == 2)
        print("Home TMDB requests: cold \(coldCount), cached 0, relaunch \(tmdb(http) - before); load time cold \(coldTime), warm \(warmTime)")
    }
}
