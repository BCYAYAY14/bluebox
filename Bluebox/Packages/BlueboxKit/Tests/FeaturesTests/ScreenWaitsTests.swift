import Domain
@testable import Features
import Foundation
import Testing

private func title(_ id: Int, _ name: String) -> Title {
    Title(key: .movie(tmdbID: id), kind: .movie, name: name)
}

private struct Failed: Error {}

/// Pages that show what they have rather than waiting on the slowest answer.
@MainActor
@Suite struct ScreenWaitsTests {
    // MARK: Episode rows

    @Test func episodeRowsAreCheckingUntilTheirOwnAnswerArrives() {
        let e1 = MediaKey.episode(seriesID: 1, season: 1, episode: 1)
        let e2 = MediaKey.episode(seriesID: 1, season: 1, episode: 2)
        var answers = EpisodeAvailabilityAnswers(keys: [e1, e2], answered: [], playable: [], downloadable: [])
        #expect(answers.checking == [e1, e2])
        #expect(answers.playable.isEmpty)
        // The first answer fills its row without waiting for the second.
        answers.answer(e2, playable: true, downloadable: true)
        #expect(answers.checking == [e1])
        #expect(answers.playable == [e2])
        #expect(answers.downloadable == [e2])
        answers.answer(e1, playable: false, downloadable: false)
        #expect(answers.checking.isEmpty)
        #expect(answers.playable == [e2])
    }

    @Test func episodesAskedAgainKeepTheirLastAnswerMeanwhile() {
        let e1 = MediaKey.episode(seriesID: 1, season: 1, episode: 1)
        let e2 = MediaKey.episode(seriesID: 1, season: 1, episode: 2)
        var answers = EpisodeAvailabilityAnswers(keys: [e1, e2], answered: [e1], playable: [e1], downloadable: [])
        #expect(answers.checking == [e2])
        #expect(answers.playable == [e1])
        // A source that no longer has it: the row says so once it answers.
        answers.answer(e1, playable: false, downloadable: false)
        #expect(answers.playable.isEmpty)
    }

    // MARK: My Library › sources

    @Test func sourceGroupsFillInAsEachServerAnswers() {
        let plex = SourceID("plex"), webdav = SourceID("webdav")
        let old = LibraryView.SourceGroup(id: webdav, name: "NAS", items: [])
        var results = SourceCatalogResults(sources: [(plex, "Plex"), (webdav, "NAS")], previous: [old])
        // Before anyone answers, last time's groups stay.
        #expect(results.groups.map(\.id) == [webdav])
        #expect(results.pending == 2)
        let fresh = LibraryView.SourceGroup(id: plex, name: "Plex", items: [])
        results.record(.loaded(fresh), at: 0)
        #expect(results.groups.map(\.id) == [plex, webdav])
        // Too slow: named as unreachable, its old group kept.
        results.record(.unreachable, at: 1)
        #expect(results.groups.map(\.id) == [plex, webdav])
        #expect(results.unreachable == ["NAS"])
        #expect(results.pending == 0)
    }

    @Test func aFolderProblemShowsItsReasonInsteadOfAGroup() {
        let folder = SourceID("local-1")
        var results = SourceCatalogResults(sources: [(folder, "Films")], previous: [])
        results.record(.problem("Bluebox can't read “Films”."), at: 0)
        #expect(results.groups.isEmpty)
        #expect(results.problems == ["Bluebox can't read “Films”."])
        #expect(results.unreachable.isEmpty)
    }

    // MARK: New & Hot

    @Test func newAndHotShowsTheSectionsThatLoaded() async {
        let model = NewHotModel()
        await model.load(new: { [title(1, "New")] },
                         watching: { throw Failed() },
                         topShows: { [title(2, "Show")] },
                         topMovies: { throw Failed() })
        #expect(model.error == nil)
        #expect(model.new.map(\.name) == ["New"])
        #expect(model.topShows.map(\.name) == ["Show"])
        #expect(model.watching.isEmpty)
        #expect(!model.isLoading)
        #expect(model.phase(offline: false) == .content)
    }

    @Test func newAndHotFailsOnlyWhenEverySectionFails() async {
        let model = NewHotModel()
        await model.load(new: { throw Failed() }, watching: { throw Failed() },
                         topShows: { throw Failed() }, topMovies: { throw Failed() })
        #expect(model.error != nil)
        #expect(model.phase(offline: false) == .failed)
    }

    @Test func aSectionThatFailsOnReloadKeepsWhatItHad() async {
        let model = NewHotModel()
        await model.load(new: { [title(1, "New")] }, watching: { [title(2, "Hot")] },
                         topShows: { [] }, topMovies: { [] })
        await model.load(new: { throw Failed() }, watching: { [title(3, "Hotter")] },
                         topShows: { [] }, topMovies: { [] })
        #expect(model.new.map(\.name) == ["New"])
        #expect(model.watching.map(\.name) == ["Hotter"])
        #expect(model.error == nil)
    }

    // MARK: iPad layout changes

    @Test func goingCompactTakesTheOpenPagesAlong() {
        let open: [Route] = [.title(title(1, "Dune"))]
        let mapped = TabLayoutMapping(tab: .myList, homeCategory: .all, paths: [.myList: open]).normalized(compact: true)
        #expect(mapped.tab == .library)
        #expect(mapped.paths[.library] == open)
        #expect(mapped.paths[.myList] == [])
    }

    @Test func goingWideTakesThemBack() {
        let open: [Route] = [.title(title(1, "Dune"))]
        let compact = TabLayoutMapping(tab: .shows, homeCategory: .all, paths: [.shows: open]).normalized(compact: true)
        #expect(compact.tab == .home)
        #expect(compact.homeCategory == .series)
        #expect(compact.paths[.home] == open)
        let wide = compact.normalized(compact: false)
        #expect(wide.tab == .shows)
        #expect(wide.homeCategory == .all)
        #expect(wide.paths[.shows] == open)
        #expect(wide.paths[.home] == [])
    }

    @Test func aTabWithNothingOpenLeavesTheOtherTabsPagesAlone() {
        let theirs: [Route] = [.title(title(2, "Alien"))]
        let mapped = TabLayoutMapping(tab: .library, homeCategory: .all, paths: [.myList: theirs]).normalized(compact: false)
        #expect(mapped.tab == .myList)
        #expect(mapped.paths[.myList] == theirs)
    }

    @Test func aTabThatExistsInBothLayoutsStaysPut() {
        let open: [Route] = [.title(title(1, "Dune"))]
        let state = TabLayoutMapping(tab: .newHot, homeCategory: .all, paths: [.newHot: open])
        #expect(state.normalized(compact: true) == state)
        #expect(state.normalized(compact: false) == state)
    }

    // MARK: Search

    @Test func aLaterPageThatFailsKeepsTheResultsAndRetries() async {
        let results = PagedTitles()
        let failing = CallFlag()
        await results.load("star", fetch: { page in
            if page == 2, failing.isOn { throw Failed() }
            return Page(items: [title(page * 10, "Star \(page)")], page: page, totalPages: 3)
        })
        failing.isOn = true
        await results.loadMore()
        #expect(results.error == nil)
        #expect(results.moreError != nil)
        #expect(results.items.map(\.name) == ["Star 1"])
        // Scrolling to the end again doesn't hammer a failing server…
        await results.loadMore()
        #expect(results.items.map(\.name) == ["Star 1"])
        // …Retry does ask.
        failing.isOn = false
        await results.retryMore()
        #expect(results.moreError == nil)
        #expect(results.items.map(\.name) == ["Star 1", "Star 2"])
    }

    @Test func aFirstPageThatFailsIsStillAnError() async {
        let results = PagedTitles()
        await results.load("star", fetch: { _ in throw Failed() })
        #expect(results.error != nil)
        #expect(results.moreError == nil)
    }
}

/// A switch a `@Sendable` fetch can read.
private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

@Suite struct DeadlineTests {
    @Test func returnsTheAnswerWhenItComesInTime() async {
        let value = await Deadline.value(within: 2) { 42 }
        #expect(value == 42)
    }

    @Test func givesUpAtTheLimitEvenWhenTheWorkIgnoresCancellation() async {
        let start = ContinuousClock.now
        // The limit doesn't cancel the work (it goes on to fill a cache), so this wait runs on.
        let value = await Deadline.value(within: 0.05) { () -> Int? in
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        #expect(value == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func cancellingTheCallerEndsTheWaitAtOnce() async {
        let start = ContinuousClock.now
        // Work that ignores cancellation, under a long limit: only the caller's cancellation can end this.
        let waiting = Task {
            await Deadline.value(within: 30) { () -> Int? in
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { c.resume() }
                }
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        let value = await waiting.value
        #expect(value == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func aCallerCancelledBeforeAskingStillGetsNil() async {
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Deadline.value(within: 30) { () -> Int? in
                try? await Task.sleep(for: .seconds(5))
                return 1
            }
        }
        let start = ContinuousClock.now
        #expect(await waiting.value == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
