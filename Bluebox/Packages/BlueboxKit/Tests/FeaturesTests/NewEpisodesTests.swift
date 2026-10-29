import Domain
@testable import Features
import Foundation
import Persistence
import Playback
import Testing
import TestingSupport

@Suite struct NewEpisodeRulesTests {
    let show = MediaKey.series(tmdbID: 9_100_001)
    let now = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!

    func episode(_ s: Int, _ e: Int, daysAgo: Double) -> Episode {
        Episode(key: show.episode(season: s, episode: e)!, seasonNumber: s, number: e, name: "E\(e)",
                airDate: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func airing(last: Episode?, next: Episode? = nil) -> AiringInfo {
        AiringInfo(seriesKey: show, status: "Returning Series", lastEpisode: last, nextEpisode: next)
    }

    @Test func firstCheckIsABaselineThenANewEpisodeIsAnnouncedOnce() {
        let e4 = episode(2, 4, daysAgo: 1)
        #expect(NewEpisodeRules.newEpisode(airing: airing(last: e4), lastSeen: nil, isFirstCheck: true, now: now) == nil)
        let seen = show.episode(season: 2, episode: 3)
        #expect(NewEpisodeRules.newEpisode(airing: airing(last: e4), lastSeen: seen, isFirstCheck: false, now: now) == e4)
        #expect(NewEpisodeRules.newEpisode(airing: airing(last: e4), lastSeen: e4.key, isFirstCheck: false, now: now) == nil)
    }

    @Test func oldOrBackwardsEpisodesAreNotNews() {
        let old = episode(2, 4, daysAgo: 30)
        #expect(NewEpisodeRules.newEpisode(airing: airing(last: old), lastSeen: show.episode(season: 2, episode: 3),
                                           isFirstCheck: false, now: now) == nil)
        let corrected = episode(2, 2, daysAgo: 1)
        #expect(NewEpisodeRules.newEpisode(airing: airing(last: corrected), lastSeen: show.episode(season: 2, episode: 3),
                                           isFirstCheck: false, now: now) == nil)
        let future = episode(2, 5, daysAgo: -2)
        #expect(NewEpisodeRules.newEpisode(airing: airing(last: future), lastSeen: show.episode(season: 2, episode: 4),
                                           isFirstCheck: false, now: now) == nil)
    }

    @Test func autoDownloadsTheEpisodesSinceTheLastSeenOne() {
        let latest = episode(2, 6, daysAgo: 0)
        #expect(NewEpisodeRules.episodesToDownload(series: show, latest: latest, lastSeen: show.episode(season: 2, episode: 4))
                == [show.episode(season: 2, episode: 5)!, show.episode(season: 2, episode: 6)!])
        // A new season (or a whole season at once): from its first episode, capped.
        let drop = episode(3, 12, daysAgo: 0)
        let all = NewEpisodeRules.episodesToDownload(series: show, latest: drop, lastSeen: show.episode(season: 2, episode: 10), limit: 10)
        #expect(all.count == 10 && all.first == show.episode(season: 3, episode: 3) && all.last == drop.key)
    }

    @Test func comingSoonSortsByDayWithYoursFirst() {
        let t1 = Title(key: .movie(tmdbID: 1), kind: .movie, name: "B")
        let t2 = Title(key: .movie(tmdbID: 2), kind: .movie, name: "A")
        let t3 = Title(key: .movie(tmdbID: 3), kind: .movie, name: "C")
        let items = [
            ComingSoonItem(title: t1, kind: .movie, date: now.addingTimeInterval(86_400 * 2), isYours: false),
            ComingSoonItem(title: t2, kind: .movie, date: now.addingTimeInterval(86_400 * 2 + 60), isYours: true),
            ComingSoonItem(title: t3, kind: .movie, date: now, isYours: false),
        ]
        #expect(NewEpisodeRules.sortComingSoon(items).map(\.title.name) == ["C", "A", "B"])
    }

    @Test func settingsDecodeOldSavesAndPerShowChoicesWin() throws {
        let decoded = try JSONDecoder().decode(NewEpisodeSettings.self, from: Data(#"{"notify":false}"#.utf8))
        #expect(!decoded.notify && !decoded.autoDownloadByDefault)
        var s = NewEpisodeSettings()
        s.autoDownloadByDefault = true
        s.autoDownloadShows[show.rawValue] = false
        #expect(!s.autoDownloads(show) && s.autoDownloads(.series(tmdbID: 2)))
        let state = try JSONDecoder().decode(EpisodeTrackerState.self, from: Data("{}".utf8))
        #expect(state.reminders.isEmpty && state.lastSeen.isEmpty)
    }
}

@MainActor
@Suite struct ScrobbleObserverTests {
    let key = MediaKey.movie(tmdbID: 7)

    func snap(_ status: PlaybackStatus, at position: TimeInterval) -> PlaybackSnapshot {
        var s = PlaybackSnapshot()
        s.status = status
        s.position = position
        s.duration = 1000
        return s
    }

    @Test func startPauseResumeAndStopOnClose() {
        let o = ScrobbleObserver()
        #expect(o.step(key: key, snapshot: snap(.loading, at: 0)).isEmpty)
        #expect(o.step(key: key, snapshot: snap(.playing, at: 100)) == [.start(key, 10)])
        #expect(o.step(key: key, snapshot: snap(.playing, at: 110)).isEmpty)
        #expect(o.step(key: key, snapshot: snap(.buffering, at: 120)).isEmpty)
        #expect(o.step(key: key, snapshot: snap(.paused, at: 200)) == [.pause(key, 20)])
        #expect(o.step(key: key, snapshot: snap(.playing, at: 200)) == [.start(key, 20)])
        #expect(o.step(key: nil, snapshot: nil) == [.stop(key, 20)])
        #expect(o.step(key: nil, snapshot: nil).isEmpty)
    }

    @Test func endingStopsAt100AndUpNextStartsTheNextItem() {
        let o = ScrobbleObserver()
        let next = MediaKey.movie(tmdbID: 8)
        _ = o.step(key: key, snapshot: snap(.playing, at: 900))
        #expect(o.step(key: key, snapshot: snap(.ended, at: 1000)) == [.stop(key, 100)])
        #expect(o.step(key: key, snapshot: snap(.paused, at: 1000)).isEmpty)  // sitting on the last frame
        #expect(o.step(key: next, snapshot: snap(.playing, at: 0)) == [.start(next, 0)])
        // Up Next while playing: the old item stops at its progress, the new one starts.
        let third = MediaKey.movie(tmdbID: 9)
        #expect(o.step(key: third, snapshot: snap(.playing, at: 50)) == [.stop(next, 0), .start(third, 5)])
    }
}

@MainActor
@Suite struct FeatureAPITests {
    func model() throws -> AppModel {
        AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                 prefs: PreferencesStore(defaults: UserDefaults(suiteName: "features.\(UUID().uuidString)")!), forceSample: true)
    }

    @Test func remindersAndAutoDownloadChoicesPersist() async throws {
        let app = try model()
        let title = Title(key: .movie(tmdbID: 133701), kind: .movie, name: "Tears of Steel")
        #expect(!app.isReminderSet(title.key))
        app.features.tracker.reminders.insert(title.key.rawValue)
        #expect(app.isReminderSet(title.key))
        app.setAutoDownloadNewEpisodes(true, for: .episode(seriesID: 5, season: 1, episode: 1))
        #expect(app.autoDownloadsNewEpisodes(.series(tmdbID: 5)))
        #expect(app.features.prefs.value(NewEpisodeSettings.self, for: FeatureServices.Keys.newEpisodeSettings)?
                    .autoDownloadShows[MediaKey.series(tmdbID: 5).rawValue] == true)
    }

    @Test func sampleCatalogDegradesGracefully() async throws {
        let app = try model()
        #expect(await app.videos(for: .movie(tmdbID: 133701)).isEmpty)
        #expect(!app.hasPersonPages)
        await #expect(throws: Error.self) { try await app.person(id: 1) }
        #expect(app.debridLibraryName == nil)
        #expect(await app.comingSoon().isEmpty)
    }

    @Test func watchedToggleWritesProgress() async throws {
        let app = try model()
        let key = MediaKey.movie(tmdbID: 133701)
        try await app.setWatched(key, true)
        #expect(try await app.store.progress(for: key)?.isCompleted == true)
        try await app.setWatched(key, false)
        #expect(try await app.store.progress(for: key)?.isCompleted == false)
    }
}
