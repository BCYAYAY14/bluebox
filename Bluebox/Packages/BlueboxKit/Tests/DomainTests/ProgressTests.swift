import Domain
import Foundation
import Testing
import TestingSupport

@Suite struct MediaKeyTests {
    @Test func episodeKeyRoundTrip() {
        let k = MediaKey.episode(seriesID: 1399, season: 2, episode: 10)
        #expect(k.rawValue == "tmdb:tv:1399:s2e10")
        #expect(k.seriesKey == .series(tmdbID: 1399))
        #expect(k.episodeNumbers?.season == 2)
        #expect(k.episodeNumbers?.episode == 10)
        #expect(k.tmdbID == 1399)
    }

    @Test func nonEpisodeKeysHaveNoSeries() {
        #expect(MediaKey.movie(tmdbID: 5).seriesKey == nil)
        #expect(MediaKey.series(tmdbID: 5).seriesKey == nil)
        #expect(MediaKey(rawValue: "local:abc").tmdbID == nil)
        #expect(MediaKey(rawValue: "tmdb:tv:1:s1").episodeNumbers == nil)
    }

    @Test func codableAsPlainString() throws {
        let data = try JSONEncoder().encode([MediaKey.movie(tmdbID: 7)])
        #expect(String(data: data, encoding: .utf8) == #"["tmdb:movie:7"]"#)
        #expect(try JSONDecoder().decode([MediaKey].self, from: data) == [.movie(tmdbID: 7)])
    }
}

@Suite struct ProgressPolicyTests {
    let policy = ProgressPolicy.standard
    let key = MediaKey.movie(tmdbID: 1)
    let now = Date(timeIntervalSince1970: 1000)

    @Test func completionByFraction() {
        #expect(policy.isComplete(position: 3312, duration: 3600))   // 92%
        #expect(!policy.isComplete(position: 3000, duration: 3600))   // 83%, 10 min left
        #expect(!policy.isComplete(position: 1800, duration: 3600))
    }

    @Test func completionByRemainingTimeOnlyForLongItems() {
        // 2h movie, 100s left -> complete (credits).
        #expect(policy.isComplete(position: 7100, duration: 7200))
        // 5min short, 100s left (67%) -> not complete; absolute rule doesn't apply.
        #expect(!policy.isComplete(position: 200, duration: 300))
    }

    @Test func unknownDurationNeverCompletes() {
        #expect(!policy.isComplete(position: 99999, duration: nil))
        #expect(!policy.isComplete(position: 10, duration: 0))
    }

    @Test func sanitizesInvalidPositions() {
        #expect(policy.sanitize(position: -5, duration: 100) == 0)
        #expect(policy.sanitize(position: .nan, duration: 100) == 0)
        #expect(policy.sanitize(position: .infinity, duration: 100) == 0)
        #expect(policy.sanitize(position: 150, duration: 100) == 100)
        #expect(policy.sanitize(position: 150, duration: nil) == 150)
    }

    @Test func recordMarksCompletedAndSnapsToEnd() {
        let r = policy.record(key: key, position: 3500, duration: 3600, at: now)
        #expect(r.isCompleted)
        #expect(r.position == 3600)
        #expect(r.fraction == 1)
    }

    @Test func recordDropsNonFiniteDuration() {
        let r = policy.record(key: key, position: 50, duration: .nan, at: now)
        #expect(r.duration == nil)
        #expect(r.fraction == nil)
    }

    @Test func resumeRules() {
        #expect(policy.resumePosition(for: nil) == nil)
        #expect(policy.resumePosition(for: .fixture(key, 10, at: 0)) == nil)            // too early
        #expect(policy.resumePosition(for: .fixture(key, 600, at: 0)) == 600)
        #expect(policy.resumePosition(for: .fixture(key, 600, completed: true, at: 0)) == nil)
        #expect(policy.resumePosition(for: .fixture(key, 3550, at: 0)) == nil)          // effectively done
        #expect(policy.resumePosition(for: .fixture(key, 600, of: nil, at: 0)) == 600)  // unknown duration
    }

    /// The saved point is checked again against the file actually opened.
    @Test func startPositionStartsOverNearOrPastTheRealEnd() {
        let episode: TimeInterval = 24 * 60
        #expect(policy.startPosition(resumingAt: 600, duration: episode) == 600)
        #expect(policy.startPosition(resumingAt: 600, duration: nil) == 600)            // length not known yet
        #expect(policy.startPosition(resumingAt: nil, duration: episode) == nil)
        #expect(policy.startPosition(resumingAt: 0, duration: episode) == nil)
        #expect(policy.startPosition(resumingAt: .nan, duration: episode) == nil)
        #expect(policy.startPosition(resumingAt: episode - 60, duration: episode) == nil)  // credits
        #expect(policy.startPosition(resumingAt: episode, duration: episode) == nil)       // at the end
        #expect(policy.startPosition(resumingAt: episode + 300, duration: episode) == nil) // past a shorter copy's end
        // Short clips: only the 92% rule applies.
        #expect(policy.startPosition(resumingAt: 90, duration: 100) == 90)
        #expect(policy.startPosition(resumingAt: 95, duration: 100) == nil)
    }
}

@Suite struct ProgressMergeTests {
    let key = MediaKey.episode(seriesID: 1, season: 1, episode: 1)

    @Test func newerTimestampWinsEvenIfPositionIsSmaller() {
        let old = WatchProgress.fixture(key, 2000, at: 100, device: "mac")
        let new = WatchProgress.fixture(key, 300, at: 200, device: "phone")  // user rewound on phone
        #expect(ProgressMerge.merge(old, new) == new)
        #expect(ProgressMerge.merge(new, old) == new)
    }

    @Test func staleUpdateDoesNotOverwrite() {
        let current = WatchProgress.fixture(key, 1200, at: 500)
        let stale = WatchProgress.fixture(key, 1800, at: 400)
        let (winner, changed) = ProgressMerge.apply(incoming: stale, to: current)
        #expect(winner == current)
        #expect(!changed)
    }

    @Test func tieBreaksAreSymmetric() {
        let a = WatchProgress.fixture(key, 100, at: 10, device: "a")
        let b = WatchProgress.fixture(key, 100, completed: true, at: 10, device: "b")
        #expect(ProgressMerge.merge(a, b) == b)
        #expect(ProgressMerge.merge(b, a) == b)

        let c = WatchProgress.fixture(key, 100, at: 10, device: "c")
        let d = WatchProgress.fixture(key, 200, at: 10, device: "a")
        #expect(ProgressMerge.merge(c, d) == d)
        #expect(ProgressMerge.merge(d, c) == d)

        let e = WatchProgress.fixture(key, 100, at: 10, device: "e")
        let f = WatchProgress.fixture(key, 100, at: 10, device: "f")
        #expect(ProgressMerge.merge(e, f) == ProgressMerge.merge(f, e))
    }

    @Test func applyToNothingInserts() {
        let p = WatchProgress.fixture(key, 100, at: 10)
        let (w, changed) = ProgressMerge.apply(incoming: p, to: nil)
        #expect(w == p && changed)
    }
}

@Suite struct RedactorTests {
    @Test func redactsCredentialQueryItemsAndUserInfo() {
        let url = URL(string: "https://user:pw@host.example/v?api_key=SECRET&page=2&ApiKey=X")!
        let s = Redactor.redact(url)
        #expect(!s.contains("SECRET"))
        #expect(!s.contains("pw"))
        #expect(s.contains("page=2"))
        #expect(s.contains("ApiKey=REDACTED"))
    }

    @Test func redactsAuthHeaders() {
        let h = Redactor.redact(headers: ["Authorization": "Bearer x", "Accept": "json", "X-Emby-Token": "t"])
        #expect(h["Authorization"] == "REDACTED")
        #expect(h["X-Emby-Token"] == "REDACTED")
        #expect(h["Accept"] == "json")
    }
}

@Suite struct WatchlistMergeTests {
    let t = Title(key: .movie(tmdbID: 1), kind: .movie, name: "One")
    func e(_ s: TimeInterval, removed: Bool) -> WatchlistEntry {
        WatchlistEntry(title: t, addedAt: .init(timeIntervalSince1970: 0), isRemoved: removed, updatedAt: .init(timeIntervalSince1970: s))
    }

    @Test func newerWinsAndTiesFavourPresent() {
        #expect(WatchlistMerge.incomingWins(e(2, removed: true), over: e(1, removed: false)))
        #expect(!WatchlistMerge.incomingWins(e(1, removed: true), over: e(2, removed: false)))
        #expect(WatchlistMerge.incomingWins(e(1, removed: false), over: e(1, removed: true)))
        #expect(!WatchlistMerge.incomingWins(e(1, removed: true), over: e(1, removed: false)))
        #expect(!WatchlistMerge.incomingWins(e(1, removed: false), over: e(1, removed: false)))
    }

    @Test func millisecondRoundingIsStable() {
        let d = Date(timeIntervalSince1970: 1_793_000_123.4567)
        #expect(d.millisecondRounded == d.millisecondRounded.millisecondRounded)
        #expect(d.millisecondsSince1970 == 1_793_000_123_457)
    }
}
