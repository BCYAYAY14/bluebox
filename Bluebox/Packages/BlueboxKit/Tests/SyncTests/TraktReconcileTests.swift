import Domain
import Foundation
import Metadata
@testable import Persistence
@testable import Sync
import Testing
import TestingSupport

/// What wins when Bluebox and Trakt both changed something.
@Suite struct HistoryReconcileTests {
    let m = MediaKey.movie(tmdbID: 1)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func watched(_ at: Date) -> WatchProgress { WatchProgress(key: m, position: 100, duration: 100, isCompleted: true, updatedAt: at) }
    func reset(_ at: Date) -> WatchProgress { WatchProgress(key: m, position: 0, duration: 100, updatedAt: at) }
    func partway(_ at: Date) -> WatchProgress { WatchProgress(key: m, position: 50, duration: 100, updatedAt: at) }

    @Test func firstSyncSendsAndImportsEverything() {
        let other = MediaKey.movie(tmdbID: 2)
        let p = HistoryReconcile.plan(local: [m: watched(t0)], remote: [other: t0], base: nil)
        #expect(p.addRemote == [m: t0])
        #expect(p.importLocal == [other: t0])
        #expect(Set(p.agreed.keys) == [m, other])
    }

    @Test func removedOnTraktAndUntouchedHereIsUnwatchedHere() {
        let p = HistoryReconcile.plan(local: [m: watched(t0)], remote: [:], base: [m: t0])
        #expect(p.markLocalUnwatched == [m])
        #expect(p.addRemote.isEmpty && p.agreed[m] == nil)
    }

    @Test func removedOnTraktButWatchedAgainHereSinceWinsForHere() {
        let later = t0.addingTimeInterval(3600)
        let p = HistoryReconcile.plan(local: [m: watched(later)], remote: [:], base: [m: t0])
        #expect(p.addRemote == [m: later])
        #expect(p.markLocalUnwatched.isEmpty)
    }

    @Test func unwatchedHereAfterTraktsPlayRemovesItOnTrakt() {
        let p = HistoryReconcile.plan(local: [m: reset(t0.addingTimeInterval(60))], remote: [m: t0], base: [m: t0])
        #expect(p.removeRemote == [m])
        #expect(p.importLocal.isEmpty && p.agreed[m] == nil)
    }

    @Test func watchedAgainOnTraktAfterUnwatchingHereWinsForTrakt() {
        let p = HistoryReconcile.plan(local: [m: reset(t0)], remote: [m: t0.addingTimeInterval(60)], base: [m: t0])
        #expect(p.importLocal == [m: t0.addingTimeInterval(60)])
        #expect(p.removeRemote.isEmpty)
    }

    @Test func aRewatchInProgressHereLeavesTraktsPlayAlone() {
        let p = HistoryReconcile.plan(local: [m: partway(t0.addingTimeInterval(60))], remote: [m: t0], base: [m: t0])
        #expect(p.removeRemote.isEmpty && p.importLocal.isEmpty && Set(p.agreed.keys) == [m])
    }

    @Test func aScrobbledPlayIsNotSentAgainButALaterRewatchIs() {
        let close = HistoryReconcile.plan(local: [m: watched(t0.addingTimeInterval(120))], remote: [m: t0], base: [m: t0])
        #expect(close.addRemote.isEmpty)
        let rewatch = HistoryReconcile.plan(local: [m: watched(t0.addingTimeInterval(86_400))], remote: [m: t0], base: [m: t0])
        #expect(rewatch.addRemote == [m: t0.addingTimeInterval(86_400)])
    }

    @Test func notWatchedAnywhereIsLeftAlone() {
        let p = HistoryReconcile.plan(local: [m: partway(t0)], remote: [:], base: [m: t0])
        #expect(p == HistoryReconcile.Plan())
    }
}

@Suite struct RatingsReconcileTests {
    let m = MediaKey.movie(tmdbID: 1)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func differentRatingsNewerWins() {
        let localNewer = RatingsReconcile.plan(local: [m: LocalRating(rating: 8, updatedAt: t0.addingTimeInterval(10))],
                                               remote: [m: RemoteRating(rating: 6, ratedAt: t0)], base: [m: t0])
        #expect(localNewer.setRemote[m]?.rating == 8 && localNewer.setLocal.isEmpty)
        let remoteNewer = RatingsReconcile.plan(local: [m: LocalRating(rating: 8, updatedAt: t0)],
                                                remote: [m: RemoteRating(rating: 6, ratedAt: t0.addingTimeInterval(10))], base: [m: t0])
        #expect(remoteNewer.setLocal[m]?.rating == 6 && remoteNewer.setRemote.isEmpty)
    }

    @Test func removalsCarryOverUnlessTheOtherSideRatedAgain() {
        // Cleared here after Trakt's rating → removed on Trakt.
        var p = RatingsReconcile.plan(local: [m: LocalRating(rating: nil, updatedAt: t0.addingTimeInterval(10))],
                                      remote: [m: RemoteRating(rating: 7, ratedAt: t0)], base: [m: t0])
        #expect(p.removeRemote == [m])
        // Rated again on Trakt after clearing here → Trakt's rating comes back.
        p = RatingsReconcile.plan(local: [m: LocalRating(rating: nil, updatedAt: t0)],
                                  remote: [m: RemoteRating(rating: 7, ratedAt: t0.addingTimeInterval(10))], base: [m: t0])
        #expect(p.setLocal[m]?.rating == 7)
        // Removed on Trakt, untouched here → removed here.
        p = RatingsReconcile.plan(local: [m: LocalRating(rating: 7, updatedAt: t0.addingTimeInterval(-10))], remote: [:],
                                  base: [m: t0])
        #expect(p.removeLocal == [m])
        // Removed on Trakt, but changed here since → sent again.
        p = RatingsReconcile.plan(local: [m: LocalRating(rating: 9, updatedAt: t0.addingTimeInterval(10))], remote: [:],
                                  base: [m: t0])
        #expect(p.setRemote[m]?.rating == 9)
        // First sync: everything is added both ways.
        p = RatingsReconcile.plan(local: [m: LocalRating(rating: 9, updatedAt: t0)], remote: [:], base: nil)
        #expect(p.setRemote[m]?.rating == 9 && Set(p.agreed.keys) == [m])
    }
}

@Suite struct TraktTwoWayTests {
    @Test func unwatchingHereRemovesThePlayOnTraktAndRemovalOnTraktUnwatchesHere() async throws {
        let server = FakeTrakt()
        server.watchedMovies = [10: "2026-01-02T03:04:05.000Z", 11: "2026-01-02T03:04:05.000Z"]
        let (client, sync, store, _) = try TraktTests.make(server)
        try await TraktTests.connect(client)
        try await sync.sync()
        #expect(try await store.progress(for: .movie(tmdbID: 10))?.isCompleted == true)

        // Unwatched here; removed from Trakt's history there.
        try await store.save(WatchProgress(key: .movie(tmdbID: 10), position: 0, duration: nil, updatedAt: .now))
        server.watchedMovies[11] = nil
        try await sync.sync()
        let removed = server.removalBodies.first?["movies"] as? [[String: Any]]
        #expect((removed?.first?["ids"] as? [String: Any])?["tmdb"] as? Int == 10)
        #expect(server.watchedMovies[10] == nil)
        #expect(try await store.progress(for: .movie(tmdbID: 11))?.isCompleted == false)

        // Settled: nothing more either way.
        try await sync.sync()
        #expect(server.removalBodies.count == 1)
        #expect(server.historyBodies.isEmpty)
    }

    @Test func ratingsSyncBothWays() async throws {
        let server = FakeTrakt()
        server.movieRatings = [20: (6, "2026-01-01T00:00:00.000Z")]
        let (client, sync, _, _) = try TraktTests.make(server)
        try await TraktTests.connect(client)
        await sync.setRating(9, for: .movie(tmdbID: 21))
        try await sync.sync()
        #expect(await sync.rating(for: .movie(tmdbID: 20)) == 6)
        #expect(server.movieRatings[21]?.rating == 9)

        // Cleared here → removed on Trakt; the marker goes once it's sent.
        await sync.setRating(nil, for: .movie(tmdbID: 21))
        try await sync.sync()
        #expect(server.movieRatings[21] == nil)
        #expect(await sync.ratings.all()[.movie(tmdbID: 21)] == nil)
    }

    @Test func scrobblesAndOfflineStopsBecomePlays() async throws {
        let server = FakeTrakt()
        let (client, sync, _, _) = try TraktTests.make(server)
        try await TraktTests.connect(client)
        await sync.scrobble(.start, key: .episode(seriesID: 5, season: 1, episode: 2), progress: 12.5)
        let body = try #require(server.scrobbles.first)
        #expect(body.action == "start")
        #expect(((body.body["show"] as? [String: Any])?["ids"] as? [String: Any])?["tmdb"] as? Int == 5)
        #expect((body.body["episode"] as? [String: Any])?["number"] as? Int == 2)
        #expect(body.body["progress"] as? Double == 12.5)
        #expect(body.body["movie"] == nil)

        server.failScrobbles = true
        await sync.scrobble(.pause, key: .movie(tmdbID: 30), progress: 50)  // dropped
        await sync.scrobble(.stop, key: .movie(tmdbID: 31), progress: 95)  // kept as a play
        #expect(await sync.pendingPlays == 1)
        try await sync.sync()
        #expect(await sync.pendingPlays == 0)
        let sent = server.historyBodies.flatMap { $0["movies"] as? [[String: Any]] ?? [] }
            .compactMap { ($0["ids"] as? [String: Any])?["tmdb"] as? Int }
        #expect(sent.contains(31) && !sent.contains(30))
    }

    @Test func rateLimitsAreWaitedOut() async throws {
        let server = FakeTrakt()
        let limited = HTTPClientWrapper(server, rateLimitFirst: 2)
        let client = TraktClient(config: FakeTrakt.config, http: limited, secrets: MemorySecretStore(), sleep: { _ in })
        try await TraktTests.connect(client)
        let store = try LibraryStore.make(inMemory: true)
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "trakt.\(UUID().uuidString)")!)
        limited.armed = true
        try await TraktSync(client: client, store: store, prefs: prefs).sync()
        #expect(limited.limited == 2)
    }
}

/// Answers 429 to the first `rateLimitFirst` authorized requests once armed.
final class HTTPClientWrapper: HTTPClient, @unchecked Sendable {
    let inner: any HTTPClient
    let rateLimitFirst: Int
    private let lock = NSLock()
    private var _armed = false
    private var _limited = 0
    var armed: Bool {
        get { lock.withLock { _armed } }
        set { lock.withLock { _armed = newValue } }
    }
    var limited: Int { lock.withLock { _limited } }

    init(_ inner: any HTTPClient, rateLimitFirst: Int) { self.inner = inner; self.rateLimitFirst = rateLimitFirst }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let limit: Bool = lock.withLock {
            guard _armed, _limited < rateLimitFirst else { return false }
            _limited += 1
            return true
        }
        if limit {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "1"])!)
        }
        return try await inner.send(request)
    }
}
