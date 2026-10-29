import Addons
import DesignSystem
import Domain
import Downloads
@testable import Features
import Foundation
import Testing

/// The pure rules behind the season menu, season list, release list and
/// Downloads shelves.
@MainActor
@Suite struct RedesignLogicTests {
    private func episode(_ s: Int, _ e: Int, minutes: Int? = 50) -> Episode {
        Episode(key: .episode(seriesID: 1, season: s, episode: e), seasonNumber: s, number: e, name: "E\(e)", runtimeMinutes: minutes)
    }

    private func done(_ ep: Episode) -> WatchProgress {
        WatchProgress(key: ep.key, position: 3000, duration: 3000, isCompleted: true, updatedAt: .now)
    }

    private func record(_ key: MediaKey, _ state: DownloadRecord.State, bytes: Int64 = 1_000_000_000) -> DownloadRecord {
        let v = MediaVariant(id: key.rawValue, sourceID: SourceID("x"), mediaKey: key, displayName: "x", location: .remote,
                             isDownloadable: true)
        return DownloadRecord(id: key.rawValue, mediaKey: key, title: "Show", subtitle: nil, origin: v, state: state,
                              receivedBytes: state == .completed ? bytes : 0, expectedBytes: bytes, createdAt: .now,
                              fileName: nil, subtitleFiles: [])
    }

    @Test func sizeEstimatesPreferKnownSizesThenTheReleaseRate() {
        let eps = [episode(1, 1, minutes: 40), episode(1, 2, minutes: nil)]
        var estimate = SeasonSizeEstimate(bytesPerMinute: nil, fallbackBytesPerMinute: 10)
        #expect(estimate.bytes(for: eps, knownSizes: [:]) == 400 + 450)
        estimate.bytesPerMinute = SeasonSizeEstimate.rate(releaseBytes: 2_000, runtimeMinutes: 40)  // 50 per minute
        #expect(estimate.bytes(for: eps, knownSizes: [eps[1].key: 7]) == 2_000 + 7)
        #expect(SeasonSizeEstimate.rate(releaseBytes: nil, runtimeMinutes: 40) == nil)
    }

    @Test func sizeLabelsAreRounded() {
        #expect(SeasonActionPlan.sizeLabel(6_030_000_000) == "about 6 GB")
        #expect(SeasonActionPlan.sizeLabel(7_240_000_000) == "about 7.2 GB")
        #expect(SeasonActionPlan.sizeLabel(11_380_000_000) == "about 11 GB")
        #expect(SeasonActionPlan.sizeLabel(846_000_000) == "about 850 MB")
    }

    @Test func seasonPlanSkipsWatchedAndAlreadyDownloadedEpisodes() {
        let eps = (1...5).map { episode(2, $0) }
        let progress = [eps[0].key: done(eps[0]), eps[1].key: done(eps[1])]
        let records = [eps[0].key: record(eps[0].key, .completed), eps[2].key: record(eps[2].key, .downloading),
                       eps[3].key: record(eps[3].key, .failed("x"))]
        let plan = SeasonActionPlan(episodes: eps, progress: progress, downloads: { records[$0] },
                                    downloadable: Set(eps.map(\.key)))
        #expect(plan.remaining.map(\.number) == [4, 5])          // unwatched, nothing saved (a failed one counts as nothing)
        #expect(plan.notDownloaded.map(\.number) == [2, 4, 5])
        #expect(plan.downloads.count == 2)
        #expect(plan.anyWatched && !plan.allWatched)
    }

    @Test func seasonListPutsSpecialsLastAndCountsWatched() {
        let summaries = [SeasonSummary(number: 0, name: "Specials", episodeCount: 2),
                         SeasonSummary(number: 2, name: "Season 2", episodeCount: 8),
                         SeasonSummary(number: 1, name: "Season 1", episodeCount: 2)]
        let progress = Dictionary(uniqueKeysWithValues: [episode(1, 1), episode(1, 2), episode(2, 1)].map { ($0.key, done($0)) })
        let choices = SeasonChoice.make(summaries, progress: progress)
        #expect(choices.map(\.number) == [1, 2, 0])
        #expect(choices[0].caption == "2 episodes · All watched")
        #expect(choices[1].caption == "8 episodes · 1 of 8 watched")
        #expect(choices[2].caption == "2 episodes")
    }

    @Test func releaseRowsReadTheParsedFacts() throws {
        let samples = ReleaseFacts.reviewSamples
        let uhd = try #require(samples.first { $0.resolution == "2160p" && $0.info.hdr == [.hdr10] })
        #expect(uhd.info.tags.contains("HDR10") && uhd.info.tags.contains("HEVC") && uhd.info.tags.contains("Atmos")
                && uhd.info.tags.contains("BluRay"))
        #expect(ReleaseFacts.quality("2160p") == "4K")
        #expect(ReleaseFacts.quality(nil) == "SD")
        #expect(ReleaseFacts.linkState(samples[0])?.text == "Cached")
        #expect(ReleaseFacts.linkState(samples[1]) == nil)
        #expect(ReleaseFacts.details(samples[1])?.hasPrefix("Group NTb") == true)
        var shared = samples[1]
        shared.alsoFrom = ["Comet"]
        #expect(ReleaseFacts.provenance(shared) == "From Torrentio, also Comet")
    }

    @Test func sortingKeepsRankOnTies() {
        let samples = ReleaseFacts.reviewSamples
        #expect(ReleaseListSort.best.apply(samples) == samples)
        let bySeeders = ReleaseListSort.seeders.apply(samples)
        #expect(bySeeders.first?.isDebrid == true)  // cached beats any swarm
        #expect(bySeeders[1].seeders == 230)
        #expect(ReleaseListSort.smallest.apply(samples).first?.sizeText == "410 MB")
        #expect(ReleaseListSort.quality.apply(samples).prefix(2).allSatisfy { $0.resolution == "2160p" })
    }

    @Test func pickerStartsFromSettingsSort() {
        #expect(ReleaseListSort.initial(remembered: nil, settings: .quality) == .quality)
        #expect(ReleaseListSort.initial(remembered: nil, settings: .size) == .largest)
        // A choice made in the picker sticks until Settings' sort changes.
        let saved = ReleaseListSort.memory(.smallest, settings: .seeders)
        #expect(ReleaseListSort.initial(remembered: saved, settings: .seeders) == .smallest)
        #expect(ReleaseListSort.initial(remembered: saved, settings: .quality) == .quality)
        #expect(ReleaseListSort.initial(remembered: "best", settings: .seeders) == .seeders)  // older format
    }

    @Test func mobileDataAndSameGroupMarks() {
        let samples = ReleaseFacts.reviewSamples
        let saver = MobileDataRanking(maxResolution: "720p", preferSmallest: true, allowsTorrents: true, allowsDebrid: true)
        let uhd = ReleaseMarks(release: samples[2], choice: nil, mobile: saver)
        #expect(uhd.cellular && uhd.aboveCap && !uhd.sameGroup)
        let small = ReleaseMarks(release: samples[6], choice: nil, mobile: saver)
        #expect(!small.cellular && !small.aboveCap)
        // Off mobile data nothing is marked.
        #expect(ReleaseMarks(release: samples[2], choice: nil, mobile: nil) == ReleaseMarks())
        let choice = ShowChoice(group: "ntb", resolution: "1080p", bingeGroup: nil, addonID: nil)
        #expect(ReleaseMarks(release: samples[1], choice: choice, mobile: nil).sameGroup)
    }

    @Test func shelvesSplitActiveMoviesAndShows() {
        let rows = [
            record(.movie(tmdbID: 1), .completed), record(.movie(tmdbID: 2), .downloading),
            record(.episode(seriesID: 5, season: 1, episode: 2), .completed),
            record(.episode(seriesID: 5, season: 1, episode: 1), .completed),
            record(.episode(seriesID: 5, season: 2, episode: 1), .queued),
        ].map { DownloadRowModel(record: $0, stats: nil, wait: nil) }
        let shelves = DownloadShelves.make(rows)
        #expect(shelves.active.count == 2)
        #expect(shelves.running == 1)
        #expect(shelves.movies.count == 1)
        #expect(shelves.shows.count == 1)
        #expect(shelves.shows[0].rows.map { $0.record.mediaKey?.episodeNumbers?.episode } == [1, 2])
        #expect(shelves.shows[0].summary == "Season 1 · 2 episodes · " + Formatters.bytes(2_000_000_000))
    }
}
