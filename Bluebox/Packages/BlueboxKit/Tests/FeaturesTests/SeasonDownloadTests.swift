import Addons
import DesignSystem
import Domain
import Downloads
@testable import Features
import Foundation
import Persistence
import TestingSupport
import Testing

/// Download Season (progress, asking first, the Downloads card) and the
/// optimistic updates behind instant buttons.
@MainActor
@Suite struct SeasonDownloadTests {
    private func episode(_ s: Int, _ e: Int, minutes: Int? = 50) -> Episode {
        Episode(key: .episode(seriesID: 1, season: s, episode: e), seasonNumber: s, number: e, name: "E\(e)", runtimeMinutes: minutes)
    }

    private func record(_ key: MediaKey, _ state: DownloadRecord.State, received: Int64 = 0,
                        expected: Int64? = 1_000_000_000) -> DownloadRecord {
        let v = MediaVariant(id: key.rawValue, sourceID: SourceID("x"), mediaKey: key, displayName: "x", location: .remote,
                             isDownloadable: true)
        return DownloadRecord(id: key.rawValue, mediaKey: key, title: "Show", subtitle: nil, origin: v, state: state,
                              receivedBytes: state == .completed ? (expected ?? received) : received, expectedBytes: expected,
                              createdAt: .now, fileName: nil, subtitleFiles: [])
    }

    private func app() throws -> AppModel {
        AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                 prefs: PreferencesStore(defaults: UserDefaults(suiteName: "season.\(UUID().uuidString)")!), forceSample: true)
    }

    // MARK: Season progress

    @Test func seasonProgressCountsByStateAndWeighsByBytes() {
        let eps = (1...4).map { episode(2, $0) }
        let status = SeasonDownloadStatus(records: [
            record(eps[0].key, .completed, expected: 1_000),
            record(eps[1].key, .downloading, received: 500, expected: 1_000),
            record(eps[2].key, .queued, expected: 2_000),
        ], preparing: 0)
        #expect(status.total == 3)
        #expect(status.completed == 1 && status.downloading == 1 && status.queued == 1)
        #expect(status.inProgress && !status.isComplete && !status.isStopped)
        #expect(abs(status.fraction - 1_500.0 / 4_000) < 0.0001)  // bytes, not episodes
        #expect(status.detail == "1 of 3 · 37%")
        #expect(status.unfinished == 2)
    }

    @Test func seasonProgressCountsEpisodesWhenSizesAreUnknownOrStillPreparing() {
        let eps = (1...4).map { episode(1, $0) }
        let status = SeasonDownloadStatus(records: [
            record(eps[0].key, .completed, expected: 1_000),
            record(eps[1].key, .downloading, received: 10, expected: nil),
        ], preparing: 2)
        #expect(status.total == 4)
        #expect(abs(status.fraction - 0.25) < 0.0001)  // one of four episodes done
        #expect(status.inProgress)

        let finding = SeasonDownloadStatus(records: [], preparing: 3)
        #expect(finding.detail == "Finding releases…")
        #expect(finding.fraction == 0)
    }

    @Test func seasonProgressKnowsPausedFailedAndDone() {
        let eps = (1...2).map { episode(1, $0) }
        let paused = SeasonDownloadStatus(records: [record(eps[0].key, .paused, received: 500, expected: 1_000),
                                                    record(eps[1].key, .completed, expected: 1_000)])
        #expect(paused.isStopped && !paused.inProgress)
        #expect(paused.detail == "Paused · 1 of 2 · 75%")
        let failed = SeasonDownloadStatus(records: [record(eps[0].key, .failed("No peers"))])
        #expect(failed.detail == "1 failed · 0 of 1")
        let done = SeasonDownloadStatus(records: eps.map { record($0.key, .completed, expected: 2_000) })
        #expect(done.isComplete && done.fraction == 1 && done.knownBytes == 4_000)
        #expect(SeasonDownloadStatus(records: []).isEmpty)
    }

    // MARK: Asking first

    @Test func seasonDownloadsAskFirstWhenBigOnMobileDataOrShortOfSpace() {
        typealias C = SeasonDownloadCheck
        #expect(C.check(bytes: 2_000_000_000, episodes: 2, onMobileData: false, wifiOnly: false, freeBytes: 50_000_000_000) == .none)
        #expect(C.check(bytes: 9_600_000_000, episodes: 8, onMobileData: false, wifiOnly: false, freeBytes: nil)
                == .large(bytes: 9_600_000_000, episodes: 8))
        #expect(C.check(bytes: 1_000_000_000, episodes: 1, onMobileData: true, wifiOnly: true, freeBytes: nil)
                == .mobileData(bytes: 1_000_000_000, episodes: 1, wifiOnly: true))
        // Not fitting beats everything else.
        #expect(C.check(bytes: 9_000_000_000, episodes: 8, onMobileData: true, wifiOnly: false, freeBytes: 4_000_000_000)
                == .notEnoughSpace(bytes: 9_000_000_000, free: 4_000_000_000, episodes: 8))
        #expect(C.check(bytes: 0, episodes: 0, onMobileData: true, wifiOnly: false, freeBytes: 0) == .none)
    }

    @Test func confirmationSaysWhatHappensOnMobileData() {
        let eps = [episode(2, 1), episode(2, 2)]
        let held = SeasonDownloadRequest(seriesKey: .series(tmdbID: 1), season: 2, seasonName: "Season 2", seriesName: "Show",
                                         episodes: eps, bytes: 3_000_000_000,
                                         check: .mobileData(bytes: 3_000_000_000, episodes: 2, wifiOnly: true))
        #expect(held.title == "Download on mobile data?")
        #expect(held.message.contains("2 episodes, about 3 GB"))
        #expect(held.message.contains("Wi‑Fi only"))
        let big = SeasonDownloadRequest(seriesKey: .series(tmdbID: 1), season: 2, seasonName: "Season 2", seriesName: "Show",
                                        episodes: eps, bytes: 9_600_000_000, check: .large(bytes: 9_600_000_000, episodes: 2))
        #expect(big.title == "Download Season 2?")
        #expect(big.id == SeasonDownloadRequest.jobID(.series(tmdbID: 1), 2))
    }

    // MARK: Downloads page

    @Test func queueCardSumsWhatsInProgress() {
        let s2 = (1...3).map { episode(2, $0) }
        let queue = [
            record(s2[1].key, .downloading, received: 250, expected: 1_000),
            record(s2[2].key, .queued, expected: 1_000),
            record(.movie(tmdbID: 9), .paused, received: 500, expected: 2_000),
        ]
        let summary = DownloadQueueSummary(queue: queue, stats: { _ in DownloadLiveStats(bytesPerSecond: 1_000_000) },
                                           wait: { _ in .wifi })
        #expect(summary.headline == "1 downloading · 1 queued · 1 paused")
        #expect(abs(summary.fraction - 750.0 / 4_000) < 0.0001)
        #expect(summary.detail?.hasPrefix(Formatters.bytes(1_000_000) + "/s · about ") == true)
        // Nothing transferring: the first waiting download's reason speaks for the queue.
        let waiting = DownloadQueueSummary(queue: [record(s2[2].key, .queued)], stats: { _ in nil }, wait: { _ in .wifi })
        #expect(waiting.detail == "Waiting for Wi‑Fi")
        #expect(DownloadQueueSummary(queue: [], stats: { _ in nil }, wait: { _ in nil }).headline == "All downloads finished")
    }

    @Test func queueRowsSayTheSourceAndWhyTheyStall() {
        let hash = String(repeating: "e", count: 40)
        let v = MediaVariant(id: "\(hash):0", sourceID: SourceID("addons"), mediaKey: .movie(tmdbID: 1), displayName: "x",
                             location: .remote, isDownloadable: true)
        var r = DownloadRecord(id: "addons/\(hash):0", mediaKey: .movie(tmdbID: 1), title: "Film", subtitle: nil, origin: v,
                               state: .downloading, receivedBytes: 1_100_000_000, expectedBytes: 2_300_000_000, createdAt: .now,
                               fileName: nil, subtitleFiles: [])
        let moving = DownloadQueueRowModel(record: r, stats: DownloadLiveStats(bytesPerSecond: 3_100_000, peers: 42), wait: nil,
                                           idle: 1, debridName: "Real-Debrid", addonsID: SourceID("addons"))
        #expect(moving.sourceLine == "Torrent · 42 peers" && moving.tone == .running)
        let stuck = DownloadQueueRowModel(record: r, stats: DownloadLiveStats(peers: 0), wait: nil, idle: 125,
                                          debridName: "Real-Debrid", addonsID: SourceID("addons"))
        #expect(stuck.sourceLine == "No peers for 2 min" && stuck.tone == .stalled)
        #expect(stuck.progressLine.hasSuffix("stalled"))
        r.state = .paused
        let paused = DownloadQueueRowModel(record: r, stats: nil, wait: nil, idle: nil, debridName: "Real-Debrid",
                                           addonsID: SourceID("addons"))
        #expect(paused.tone == .waiting && paused.progressLine.hasPrefix("Paused · "))
    }

    @Test func ruleSummaryReadsLikeTheCard() {
        var s = DownloadSettings(keepNextEpisodes: 2, downloadQuality: .p1080)
        let show = MediaKey.series(tmdbID: 1)
        #expect(DownloadRuleSummary.text(s.rule(for: show), window: .anyTime, newEpisodes: false)
                == "Keeping next 2 · 1080p · Wi‑Fi · delete after watching")
        s.deleteWatchedEpisodes = false
        #expect(DownloadRuleSummary.text(s.rule(for: show), window: .overnight, newEpisodes: true)
                == "Keeping next 2 · 1080p · Wi‑Fi overnight · keep after watching · new episodes")
        s.showRules[show.rawValue] = ShowDownloadRule(smartDownloads: false)
        #expect(DownloadRuleSummary.text(s.rule(for: show), window: .anyTime, newEpisodes: false)
                == "Smart Downloads off · keeps what you download")
    }

    // MARK: Watched, optimistically

    @Test func markingEpisodesDrawsTheNewProgressBeforeSaving() {
        let eps = [episode(1, 1, minutes: 40), episode(1, 2)]
        let started = WatchProgress(key: eps[1].key, position: 600, duration: 3000, updatedAt: .distantPast)
        let watched = AppModel.progressAfterMarking(eps, watched: true, current: [eps[1].key: started], deviceID: "d")
        #expect(watched[eps[0].key]?.isCompleted == true && watched[eps[0].key]?.duration == 2400)
        #expect(watched[eps[1].key]?.isCompleted == true && watched[eps[1].key]?.duration == 3000)
        let unwatched = AppModel.progressAfterMarking(eps, watched: false, current: watched, deviceID: "d")
        #expect(unwatched.values.allSatisfy { !$0.isCompleted && $0.position == 0 })
    }

    // MARK: Optimistic updates

    struct SaveFailed: Error {}

    @Test func optimisticUpdateShowsAtOnceAndKeepsItWhenTheSaveWorks() async {
        var shown = false
        var seenDuringSave: Bool?
        let ok = await Optimistic.update(from: false, to: true, apply: { shown = $0 }) { seenDuringSave = shown }
        #expect(ok && shown)
        #expect(seenDuringSave == true)  // already on screen while saving
    }

    @Test func optimisticUpdateRollsBackWhenTheSaveFails() async {
        var shown = ["a", "b"]
        var failure: Error?
        let ok = await Optimistic.update(from: shown, to: ["a"], apply: { shown = $0 },
                                         commit: { throw SaveFailed() }, failed: { failure = $0 })
        #expect(!ok)
        #expect(shown == ["a", "b"])
        #expect(failure is SaveFailed)
    }

    @Test func appRollsBackWithAToast() async throws {
        let app = try app()
        var onList = false
        let ok = await app.optimistic("Couldn't add to My List", from: false, to: true, apply: { onList = $0 }) {
            throw SaveFailed()
        }
        #expect(!ok && !onList)
        #expect(app.toast?.title == "Couldn't add to My List")
        #expect(app.toast?.style == .error)
    }

    @Test func myListSavesAndBumpsTheLibrary() async throws {
        let app = try app()
        let title = Title(key: .movie(tmdbID: 42), kind: .movie, name: "Film")
        let before = app.libraryRevision
        try await app.setOnMyList(title, true)
        #expect(try await app.store.isOnWatchlist(title.key))
        #expect(app.libraryRevision > before)
        try await app.setOnMyList(title, false)
        #expect(try await !app.store.isOnWatchlist(title.key))
    }

    // MARK: Season jobs

    @Test func cancelingASeasonStopsItsPreparingEpisodesOnly() throws {
        let app = try app()
        let series = MediaKey.series(tmdbID: 1)
        let s2 = (1...3).map { episode(2, $0).key }
        let s3 = episode(3, 1).key
        app.preparingDownloads = Set(s2 + [s3])
        #expect(app.preparingCount(series, season: 2) == 3)
        app.cancelSeasonDownload(series, season: 2, seasonName: "Season 2")
        #expect(app.preparingDownloads == [s3])
        #expect(!app.isQueueingSeason(series, season: 2))
    }

    @Test func seasonDownloadMarksEveryEpisodePreparingAtOnce() throws {
        let app = try app()
        let series = MediaKey.series(tmdbID: 1)
        let eps = (1...3).map { episode(2, $0) }
        app.downloadSeason(eps, seriesKey: series, season: 2, seriesName: "Show")
        // Synchronously, before any lookup has run.
        #expect(app.preparingCount(series, season: 2) == 3)
        #expect(app.isQueueingSeason(series, season: 2))
        app.cancelSeasonDownload(series, season: 2, seasonName: "Season 2")
        #expect(app.preparingCount(series, season: 2) == 0)
    }

    // MARK: Lookups side by side

    @Test func concurrentMapKeepsOrderAndOverlapsTheWaits() async {
        let clock = ContinuousClock()
        let items = Array(0..<20)
        var out: [Int] = []
        let elapsed = await clock.measure {
            out = await concurrentMap(items, limit: 6) { i in
                try? await Task.sleep(for: .milliseconds(50))
                return i * 2
            }
        }
        #expect(out == items.map { $0 * 2 })
        // One after another would take 20 × 50 ms = 1 s; six at a time, about four rounds.
        print("[bench] 20 lookups × 50 ms, 6 at a time: \(elapsed.formatted(.units(allowed: [.milliseconds]))) (sequential ≈ 1000 ms)")
        #expect(elapsed < .milliseconds(700))
    }
}
