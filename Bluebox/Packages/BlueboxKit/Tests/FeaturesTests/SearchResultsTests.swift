import Domain
@testable import Features
import Foundation
import Testing

/// A fetch that ignores cancellation and answers only when opened, like a
/// request shared through `CachedMetadataProvider` that outlives its caller.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private func title(_ id: Int, _ name: String) -> Title {
    Title(key: .movie(tmdbID: id), kind: .movie, name: name)
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
}

@MainActor
@Suite struct SearchResultsTests {
    /// The "stuck after a search or two" bug: a query still answering when the
    /// next one started left `isLoading` set for good, and every later query
    /// returned without asking.
    @Test func aNewQueryLoadsWhileTheLastOneIsStillAnswering() async {
        let results = PagedTitles()
        let gate = Gate()
        let first = Task { @MainActor in
            await results.load("dune", fetch: { _ in
                await gate.wait()
                return Page(items: [title(1, "Dune")], page: 1, totalPages: 1)
            })
        }
        await waitUntil { results.isLoading }
        first.cancel()  // the debounce task is cancelled on the next keystroke…
        await results.load("dune 2", fetch: { _ in Page(items: [title(2, "Dune: Part Two")], page: 1, totalPages: 1) })
        #expect(results.items.map(\.name) == ["Dune: Part Two"])
        #expect(!results.isLoading)
        await gate.release()  // …but its request finishes later
        await first.value
        #expect(results.items.map(\.name) == ["Dune: Part Two"])
        #expect(!results.isLoading)
        // And the one after that still runs.
        await results.load("alien", fetch: { _ in Page(items: [title(3, "Alien")], page: 1, totalPages: 1) })
        #expect(results.items.map(\.name) == ["Alien"])
    }

    /// Same, with the next page (started by scrolling to the end) still loading.
    @Test func aNewQueryLoadsWhileTheNextPageIsStillLoading() async {
        let results = PagedTitles()
        let gate = Gate()
        await results.load("star", fetch: { page in
            if page == 2 { await gate.wait() }
            return Page(items: [title(page * 10, "Star \(page)")], page: page, totalPages: 3)
        })
        let more = Task { @MainActor in await results.loadMore() }
        await waitUntil { results.isLoading }
        await results.load("moon", fetch: { _ in Page(items: [title(99, "Moon")], page: 1, totalPages: 1) })
        #expect(results.items.map(\.name) == ["Moon"])
        await gate.release()
        await more.value
        #expect(results.items.map(\.name) == ["Moon"])
        #expect(!results.isLoading)
    }

    @Test func keepsTheLastResultsUntilTheNewOnesArrive() async {
        let results = PagedTitles()
        await results.load("dune", fetch: { _ in Page(items: [title(1, "Dune")], page: 1, totalPages: 1) })
        let gate = Gate()
        let next = Task { @MainActor in
            await results.load("dune 2", fetch: { _ in
                await gate.wait()
                return Page(items: [title(2, "Dune: Part Two")], page: 1, totalPages: 1)
            })
        }
        await waitUntil { results.isLoading }
        #expect(results.items.map(\.name) == ["Dune"])
        #expect(results.isStale)
        #expect(!results.showsSkeleton)
        await gate.release()
        await next.value
        #expect(results.items.map(\.name) == ["Dune: Part Two"])
        #expect(!results.isStale)
    }

    @Test func aCachedAnswerShowsAtOnce() async {
        let results = PagedTitles()
        await results.load("dune", cached: Page(items: [title(1, "Dune")], page: 1, totalPages: 2),
                           fetch: { page in Page(items: [title(page, "Dune \(page)")], page: page, totalPages: 2) })
        #expect(results.items.map(\.name) == ["Dune"])
        #expect(results.answered(for: "dune"))
        await results.loadMore()
        #expect(results.items.map(\.name) == ["Dune", "Dune 2"])
    }

    @Test func clearingTheQueryForgetsEverything() async {
        let results = PagedTitles()
        await results.load("dune", fetch: { _ in Page(items: [title(1, "Dune")], page: 1, totalPages: 1) })
        await results.reset(nil)
        #expect(results.items.isEmpty)
        #expect(!results.answered(for: "dune"))
        #expect(!results.isEmptyResult)
    }
}
