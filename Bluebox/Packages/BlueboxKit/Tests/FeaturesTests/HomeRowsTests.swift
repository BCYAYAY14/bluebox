import Domain
@testable import Features
import Foundation
import Persistence
import Testing

/// Home's rows show each title once (`HomeModel.withoutRepeats`).
@MainActor
@Suite struct HomeRowsTests {
    private func movies(_ ids: ClosedRange<Int>) -> [Title] {
        ids.map { Title(key: .movie(tmdbID: $0), kind: .movie, name: "M\($0)") }
    }

    private func ids(_ row: HomeRow) -> [Int] { row.titles.compactMap(\.key.tmdbID) }

    @Test func laterRowsDropTitlesShownAboveOrInATopTen() {
        let rows = [
            HomeRow(id: "trending", title: "Trending Now", titles: movies(1...6)),
            HomeRow(id: "popular", title: "Popular Movies", titles: movies(1...22)),
            HomeRow(id: "top", title: "Top 10 Movies", titles: movies(7...16), style: .topTen),
        ]
        let out = HomeModel.withoutRepeats(rows)
        #expect(out.map(\.id) == ["trending", "popular", "top"])
        #expect(ids(out[0]) == Array(1...6))                 // the first row stays as it is
        #expect(ids(out[1]) == Array(17...22))               // minus Trending and the Top 10
        #expect(ids(out[2]) == Array(7...16))                // Top 10 keeps its ranks
    }

    @Test func aRowLeftTooShortGoes() {
        let rows = [
            HomeRow(id: "trending", title: "Trending Now", titles: movies(1...10)),
            HomeRow(id: "acclaimed", title: "Critically Acclaimed", titles: movies(5...12)),
            HomeRow(id: "short", title: "Short", titles: movies(30...32)),
        ]
        let out = HomeModel.withoutRepeats(rows)
        // Acclaimed would keep only 11 and 12; a short row with no repeats stays.
        #expect(out.map(\.id) == ["trending", "short"])
    }

    /// A reload that brings back the same rows is equal, so Home skips the write.
    @Test func rowsCompareByWhatTheyShow() {
        let action = Genre(id: 28, name: "Action")
        let row = HomeRow(id: "genre-28", title: "Action Movies", titles: movies(1...5), genre: (action, .movie))
        #expect(row == HomeRow(id: "genre-28", title: "Action Movies", titles: movies(1...5), genre: (action, .movie)))
        #expect(row != HomeRow(id: "genre-28", title: "Action Movies", titles: movies(1...6), genre: (action, .movie)))
        #expect(row != HomeRow(id: "genre-28", title: "Action Movies", titles: movies(1...5), genre: (action, .series)))
        #expect(row != HomeRow(id: "genre-28", title: "Action Movies", titles: movies(1...5)))
        var picked = row
        picked.reasons = [.movie(tmdbID: 1): "Because you like Action"]
        #expect(row != picked)
    }
}

/// Coming back to a page keeps it when nothing it's built from changed (`PageLoadMemory`).
@Suite struct PageLoadMemoryTests {
    struct Key: Hashable, Sendable {
        let revision: Int
        let profile: String
    }

    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func nothingIsCurrentBeforeALoad() {
        let memory = PageLoadMemory<Key>()
        #expect(!memory.isCurrent(Key(revision: 0, profile: "a"), now: start))
    }

    @Test func aRecentLoadOfTheSameKeyIsKept() {
        var memory = PageLoadMemory<Key>()
        memory.remember(Key(revision: 3, profile: "a"), at: start)
        #expect(memory.isCurrent(Key(revision: 3, profile: "a"), now: start.addingTimeInterval(10)))
        #expect(memory.isCurrent(Key(revision: 3, profile: "a"), now: start.addingTimeInterval(PageLoadMemory<Key>.maxAge - 1)))
    }

    @Test func aChangedKeyLoads() {
        var memory = PageLoadMemory<Key>()
        memory.remember(Key(revision: 3, profile: "a"), at: start)
        // Watching something (the library revision), or another profile.
        #expect(!memory.isCurrent(Key(revision: 4, profile: "a"), now: start.addingTimeInterval(1)))
        #expect(!memory.isCurrent(Key(revision: 3, profile: "b"), now: start.addingTimeInterval(1)))
    }

    @Test func anOldLoadLoadsAgain() {
        var memory = PageLoadMemory<Key>()
        memory.remember(Key(revision: 3, profile: "a"), at: start)
        #expect(!memory.isCurrent(Key(revision: 3, profile: "a"), now: start.addingTimeInterval(PageLoadMemory<Key>.maxAge)))
        // A clock set back doesn't make the load look fresh.
        #expect(!memory.isCurrent(Key(revision: 3, profile: "a"), now: start.addingTimeInterval(-60)))
    }

    @Test func forgettingLoadsAgain() {
        var memory = PageLoadMemory<Key>()
        memory.remember(Key(revision: 3, profile: "a"), at: start)
        memory.forget()
        #expect(!memory.isCurrent(Key(revision: 3, profile: "a"), now: start))
    }
}

/// Home's full load, run twice for the same page: the second keeps it (coming
/// back from a title page) unless forced (pull to refresh).
@MainActor
@Suite struct HomeReloadTests {
    @Test func aSecondLoadOfTheSamePageIsSkippedUnlessForced() async throws {
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                           prefs: PreferencesStore(defaults: UserDefaults(suiteName: "reload.\(UUID().uuidString)")!), forceSample: true)
        let model = HomeModel()
        await model.load(app, category: .all)
        #expect(!model.isLoading)
        let shown = model.rows.map(\.id)
        // Changed behind the model's back: a skipped load leaves it, a forced one rebuilds.
        model.rows = []
        await model.load(app, category: .all)
        #expect(model.rows.isEmpty)
        await model.load(app, category: .all, force: true)
        #expect(model.rows.map(\.id) == shown)
        // Another category is another page: it loads.
        await model.load(app, category: .movies)
        #expect(!model.rows.isEmpty)
    }
}
