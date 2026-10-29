import Domain
@testable import Features
import Foundation
import Persistence
import Testing
import TestingSupport

@Suite struct SmartListRulesTests {
    let shortFilm = Title(key: .movie(tmdbID: 1), kind: .movie, name: "Short")
    let longFilm = Title(key: .movie(tmdbID: 2), kind: .movie, name: "Long")
    let watchedFilm = Title(key: .movie(tmdbID: 3), kind: .movie, name: "Seen")
    let unknownFilm = Title(key: .movie(tmdbID: 4), kind: .movie, name: "Unknown")
    let show = Title(key: .series(tmdbID: 5), kind: .series, name: "Show")

    var input: SmartListInput {
        var i = SmartListInput()
        i.pool = [shortFilm, longFilm, watchedFilm, unknownFilm, show]
        i.facts = [shortFilm.key: TitleFacts(runtimeMinutes: 92), longFilm.key: TitleFacts(runtimeMinutes: 100, has4K: true),
                   watchedFilm.key: TitleFacts(runtimeMinutes: 80), show.key: TitleFacts(runtimeMinutes: 30)]
        i.completed = [watchedFilm.key]
        return i
    }

    @Test func unwatchedFilmsUnder100MinutesNeedAKnownRuntime() {
        // 100 exactly isn't under; watched, unknown runtime and shows are out.
        #expect(SmartListRules.titles(.shortFilms, from: input).map(\.key) == [shortFilm.key])
    }

    @Test func available4KUsesWhatWasSeenAndDownloads() {
        var i = input
        let downloadedShow = Title(key: .series(tmdbID: 9), kind: .series, name: "Downloaded show")
        i.downloaded = [downloadedShow, longFilm]
        i.downloaded4K = [downloadedShow.key]
        #expect(SmartListRules.titles(.available4K, from: i).map(\.key) == [longFilm.key, downloadedShow.key])
        #expect(SmartListRules.titles(.available4K, from: SmartListInput(pool: [shortFilm])).isEmpty)
    }

    @Test func downloadedAndContinueWatchingPassThrough() {
        var i = input
        i.downloaded = [show]
        i.watching = [longFilm, show]
        #expect(SmartListRules.titles(.downloaded, from: i) == [show])
        #expect(SmartListRules.titles(.continueWatching, from: i) == [longFilm, show])
    }

    @Test func recognises4KLabels() {
        #expect(SmartListRules.is4K("2160p"))
        #expect(SmartListRules.is4K("4K HDR"))
        #expect(SmartListRules.is4K("UHD"))
        #expect(!SmartListRules.is4K("1080p"))
        #expect(!SmartListRules.is4K(nil))
    }
}

@Suite struct ListPlayOrderTests {
    let a = Title(key: .movie(tmdbID: 1), kind: .movie, name: "A")
    let b = Title(key: .series(tmdbID: 2), kind: .series, name: "B")
    let c = Title(key: .movie(tmdbID: 3), kind: .movie, name: "C")
    let d = Title(key: .series(tmdbID: 4), kind: .series, name: "D")

    @Test func showsFirstThenFilmsInListOrder() {
        #expect(ListPlayOrder.order([a, b, c, d], shuffled: false).map(\.name) == ["B", "D", "A", "C"])
        #expect(Set(ListPlayOrder.order([a, b, c, d], shuffled: true).map(\.name)) == ["A", "B", "C", "D"])
    }

    @Test func upNextFollowsTheQueueFromWhatIsPlaying() {
        let queue = [b, d, a, c]
        // An episode counts as its show.
        #expect(ListPlayOrder.after(.episode(seriesID: 2, season: 3, episode: 8), in: queue)?.map(\.name) == ["D", "A", "C"])
        #expect(ListPlayOrder.after(c.key, in: queue)?.isEmpty == true)
        // Something not on the list: the queue doesn't take over.
        #expect(ListPlayOrder.after(.movie(tmdbID: 99), in: queue) == nil)
    }

    @Test func summaryLine() {
        #expect(ListPlayOrder.summary(count: 7, minutes: 580) == "7 titles · 9 h 40 min")
        #expect(ListPlayOrder.summary(count: 1, minutes: 0) == "1 title")
        #expect(ListPlayOrder.summary(count: 2, minutes: 120) == "2 titles · 2 h")
        #expect(ListPlayOrder.summary(count: 2, minutes: 45) == "2 titles · 45 min")
    }
}

@Suite struct ManualSortTests {
    let list = (1...4).map { Title(key: .movie(tmdbID: $0), kind: $0 == 3 ? .series : .movie, name: "T\($0)") }

    @Test func manualFollowsTheHandSetOrderThenNewestFirst() {
        // Recently added order is T1…T4; the hand-set order names only three.
        let manual: [MediaKey] = [list[2].key, list[0].key, list[3].key]
        let arranged = MyListArrangement.arrange(list, filter: .all, sort: .manual, manual: manual)
        #expect(arranged.map(\.name) == ["T3", "T1", "T4", "T2"])
        #expect(MyListArrangement.arrange(list, filter: .films, sort: .manual, manual: manual).map(\.name) == ["T1", "T4", "T2"])
    }

    @Test func smartListsHaveNoAddedDate() {
        #expect(!MyListSort.options(smart: true).contains(.recentlyAdded))
        #expect(MyListSort.options(smart: false).first == .recentlyAdded)
        #expect(MyListSort.manual.title(smart: true) == "Default")
        #expect(MyListSort.manual.title(smart: false) == "Manual")
    }
}

@MainActor
@Suite struct LibraryListsTests {
    func app() throws -> AppModel {
        AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                 prefs: PreferencesStore(defaults: UserDefaults(suiteName: "lists.\(UUID().uuidString)")!), forceSample: true)
    }

    @Test func theGridIsMyListThenYourListsThenSmartLists() async throws {
        let app = try app()
        let film = Title(key: .movie(tmdbID: 45745), kind: .movie, name: "Sintel")
        try await app.store.setWatchlisted(film, true)
        let mine = try await app.store.createList(name: "Halloween", symbol: "moon.fill")
        try await app.store.setOnList(film, listID: mine.id, true)
        try await app.store.noteTitleFacts(film.key, runtimeMinutes: 15)

        let tiles = try await app.librarySummaries()
        #expect(tiles.first?.id == .myList)
        #expect(tiles.first?.name == "My List")
        #expect(tiles[1].id == .own(mine.id))
        #expect(tiles[1].caption == "1 title")
        // "Available in 4K" stays out while nothing is known to be 4K.
        #expect(tiles.dropFirst(2).map(\.id) == [.smart(.shortFilms), .smart(.downloaded), .smart(.continueWatching)])
        #expect(tiles[2].count == 1)
        #expect(tiles[2].caption == "Smart · 1 title")

        try await app.store.noteTitleFacts(film.key, has4K: true)
        #expect(try await app.librarySummaries().contains { $0.id == .smart(.available4K) && $0.count == 1 })
        #expect(try await app.listTitles(.own(mine.id)).map(\.key) == [film.key])
    }

    @Test func playAllQueuesTheRestForUpNext() async throws {
        let app = try app()
        let a = Title(key: .movie(tmdbID: 1), kind: .movie, name: "A")
        let b = Title(key: .movie(tmdbID: 2), kind: .movie, name: "B")
        app.listQueue = ListPlayOrder.order([a, b], shuffled: false)
        // Nothing can be resolved in the sample catalogue, so Up Next has nothing, and nothing crashes.
        #expect(await app.nextInListQueue(after: .movie(tmdbID: 99)) == nil)
    }
}
