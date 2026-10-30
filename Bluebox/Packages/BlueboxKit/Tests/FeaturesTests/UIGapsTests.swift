import Domain
@testable import Features
import Foundation
import Testing

/// The rules behind the UI gaps work (design/GAPS-2026-10-28.md): failed vs
/// empty vs offline, the poster menu's entries, search sections, My List's
/// sort and filter, History, opening links and files, and sync status.

private func movie(_ id: Int, _ name: String, year: Int? = nil, rating: Double? = nil) -> Title {
    Title(key: .movie(tmdbID: id), kind: .movie, name: name, releaseDate: year.map(date), voteAverage: rating)
}

private func show(_ id: Int, _ name: String, year: Int? = nil, rating: Double? = nil) -> Title {
    Title(key: .series(tmdbID: id), kind: .series, name: name, releaseDate: year.map(date), voteAverage: rating)
}

private func date(_ year: Int) -> Date {
    Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 6, day: 1))!
}

@Suite struct LoadPhaseTests {
    @Test func contentStaysWhenARefreshFails() {
        #expect(LoadPhase.resolve(hasContent: true, isLoading: false, failed: false, isOffline: false) == .content)
        #expect(LoadPhase.resolve(hasContent: true, isLoading: false, failed: true, isOffline: false) == .stale(offline: false))
        #expect(LoadPhase.resolve(hasContent: true, isLoading: false, failed: true, isOffline: true) == .stale(offline: true))
        // Loading over content keeps the content.
        #expect(LoadPhase.resolve(hasContent: true, isLoading: true, failed: false, isOffline: false) == .content)
    }

    @Test func aFailureWithNothingToShowIsNeverEmpty() {
        #expect(LoadPhase.resolve(hasContent: false, isLoading: false, failed: true, isOffline: false) == .failed)
        #expect(LoadPhase.resolve(hasContent: false, isLoading: false, failed: true, isOffline: true) == .offline)
        #expect(LoadPhase.resolve(hasContent: false, isLoading: true, failed: false, isOffline: false) == .loading)
    }

    @Test func emptyOnlyWhenTheLoadReallyAnsweredNothing() {
        #expect(LoadPhase.resolve(hasContent: false, isLoading: false, failed: false, isOffline: false) == .empty)
        // Offline, "nothing" from a screen that needs the network can't be trusted…
        #expect(LoadPhase.resolve(hasContent: false, isLoading: false, failed: false, isOffline: true) == .offline)
        // …but it can for local data.
        #expect(LoadPhase.resolve(hasContent: false, isLoading: false, failed: false, isOffline: true, needsNetwork: false) == .empty)
    }

    @Test func onlyUnfinishedLoadsReloadWhenBackOnline() {
        #expect(LoadPhase.failed.reloadsWhenOnline)
        #expect(LoadPhase.offline.reloadsWhenOnline)
        #expect(LoadPhase.stale(offline: true).reloadsWhenOnline)
        #expect(!LoadPhase.content.reloadsWhenOnline)
        #expect(!LoadPhase.empty.reloadsWhenOnline)
    }

    @Test func offlineErrorsAreRecognisedFromEveryLayer() {
        #expect(UserFacingError.isOffline(URLError(.notConnectedToInternet)))
        #expect(UserFacingError.isOffline(MetadataError.offline))
        #expect(!UserFacingError.isOffline(URLError(.timedOut)))
        #expect(!UserFacingError.isOffline(MetadataError.notFound))
    }

    @Test func theOfflineBannerCountsReadyDownloads() {
        #expect(OfflineBanner.detail(ready: 3) == "3 downloads ready to watch")
        #expect(OfflineBanner.detail(ready: 1) == "1 download ready to watch")
        #expect(OfflineBanner.detail(ready: 0).hasPrefix("Nothing is downloaded"))
    }
}

@Suite struct QuickActionsTests {
    @Test func aMovieGetsEveryAction() {
        let a = QuickActions.build(kind: .movie, onList: false, watched: false, downloaded: false, canShare: true)
        #expect(a.groups == [[.play], [.addToList, .addToLists, .markWatched, .download], [.details, .share]])
    }

    @Test func togglesFollowTheCurrentState() {
        let a = QuickActions.build(kind: .movie, onList: true, watched: true, downloaded: true, canShare: false)
        #expect(a.groups == [[.play], [.removeFromList, .addToLists, .markUnwatched, .showDownloads], [.details]])
    }

    @Test func aSeriesPosterHasNoSingleItemActions() {
        // Watched and Download need one thing to act on: a series poster has many episodes.
        let a = QuickActions.build(kind: .series, onList: false, watched: false, downloaded: false, canShare: true)
        #expect(a.groups == [[.play], [.addToList, .addToLists], [.details, .share]])
    }

    @Test func continueWatchingResumesAndCanLeaveTheRow() {
        let ep = MediaKey.episode(seriesID: 1, season: 2, episode: 3)
        let a = QuickActions.build(kind: .series, episode: ep, inProgress: true, nearlyFinished: true,
                                   onList: false, watched: false, downloaded: false, canShare: false, removable: true)
        #expect(a.groups == [[.resume, .playNext], [.addToList, .addToLists, .markWatched, .download], [.goToShow], [.removeFromRow]])
    }

    @Test func watchPartyRidesWithPlay() {
        // Start a Party sits under Play; hosting one, it becomes Add to Party Queue; a guest gets neither.
        let start = QuickActions.build(kind: .movie, onList: false, watched: false, downloaded: false, canShare: false, party: .start)
        #expect(start.groups.first == [.play, .startParty])
        let host = QuickActions.build(kind: .series, onList: false, watched: false, downloaded: false, canShare: false, party: .addToQueue)
        #expect(host.groups.first == [.play, .addToParty])
        let guest = QuickActions.build(kind: .movie, onList: false, watched: false, downloaded: false, canShare: false, party: .none)
        #expect(guest.groups.first == [.play])
    }
}

@Suite struct SearchSectionsTests {
    let people = [Person(id: 1, name: "Cillian Murphy"), Person(id: 2, name: "Cillian Scott")]

    @Test func theBestTitleLeadsAndIsNotRepeated() {
        let titles = [show(10, "Peaky Blinders"), movie(11, "Oppenheimer"), movie(12, "Sunshine"), show(13, "Kin")]
        let s = SearchSections.build(query: "peaky", titles: titles, people: people)
        #expect(s.top == .title(titles[0]))
        #expect(s.people.map(\.id) == [1, 2])
        #expect(s.films.map(\.name) == ["Oppenheimer", "Sunshine"])
        #expect(s.shows.map(\.name) == ["Kin"])
    }

    @Test func aPersonsFullNameMakesThemTheTopResult() {
        let titles = [movie(11, "Oppenheimer"), show(10, "Peaky Blinders")]
        let s = SearchSections.build(query: "cillian MURPHY ", titles: titles, people: people)
        #expect(s.top == .person(people[0]))
        #expect(s.people.map(\.id) == [2])
        #expect(s.films.count == 1 && s.shows.count == 1)
    }

    @Test func aTitleNamedLikeThePersonStillWins() {
        let titles = [movie(20, "Cillian Murphy")]
        let s = SearchSections.build(query: "Cillian Murphy", titles: titles, people: people)
        #expect(s.top == .title(titles[0]))
        #expect(s.people.count == 2)
        #expect(s.films.isEmpty)
    }

    @Test func peopleAloneStillHaveATopResult() {
        let s = SearchSections.build(query: "cill", titles: [], people: people)
        #expect(s.top == .person(people[0]))
        #expect(!s.isEmpty)
        #expect(SearchSections.build(query: "x", titles: [], people: []).isEmpty)
    }

    @Test func accentsAndCaseDontMatter() {
        #expect(SearchSections.normalized(" Amélie ") == SearchSections.normalized("amelie"))
    }
}

@Suite struct MyListArrangementTests {
    // Newest added first, as the store returns them.
    let list = [
        movie(1, "The Long Field", year: 2019, rating: 7.1),
        show(2, "Harbor Lights", year: 2023, rating: 8.4),
        movie(3, "Sintel", year: 2010, rating: nil),
        show(4, "Northern Line", year: nil, rating: 6.0),
        movie(5, "A Quiet Place", year: 2018, rating: 7.5),
    ]

    @Test func recentlyAddedKeepsTheStoresOrder() {
        #expect(MyListArrangement.arrange(list, filter: .all, sort: .recentlyAdded).map(\.key) == list.map(\.key))
    }

    @Test func titleIgnoresLeadingArticles() {
        let names = MyListArrangement.arrange(list, filter: .all, sort: .title).map(\.name)
        #expect(names == ["Harbor Lights", "The Long Field", "Northern Line", "A Quiet Place", "Sintel"])
    }

    @Test func releaseDateNewestFirstUndatedLast() {
        let names = MyListArrangement.arrange(list, filter: .all, sort: .releaseDate).map(\.name)
        #expect(names == ["Harbor Lights", "The Long Field", "A Quiet Place", "Sintel", "Northern Line"])
    }

    @Test func ratingHighestFirstUnratedLast() {
        let names = MyListArrangement.arrange(list, filter: .all, sort: .rating).map(\.name)
        #expect(names == ["Harbor Lights", "A Quiet Place", "The Long Field", "Northern Line", "Sintel"])
    }

    @Test func typeChipsFilterBeforeSorting() {
        #expect(MyListArrangement.arrange(list, filter: .films, sort: .title).map(\.name) == ["The Long Field", "A Quiet Place", "Sintel"])
        #expect(MyListArrangement.arrange(list, filter: .shows, sort: .recentlyAdded).map(\.name) == ["Harbor Lights", "Northern Line"])
    }
}

@Suite struct WatchHistoryTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2  // Monday
        return c
    }()

    // Thursday 29 October 2026, noon UTC.
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))! }

    func entry(_ id: Int, daysAgo: Double, completed: Bool = true) -> (WatchProgress, HistoryEntry) {
        let p = WatchProgress(key: .movie(tmdbID: id), position: 100, duration: 100, isCompleted: completed,
                              updatedAt: now.addingTimeInterval(-daysAgo * 86_400))
        return (p, HistoryEntry(progress: p, title: movie(id, "M\(id)")))
    }

    @Test func onlyFinishedRecordsNewestFirst() {
        let records = [entry(1, daysAgo: 3).0, entry(2, daysAgo: 1, completed: false).0, entry(3, daysAgo: 0.1).0]
        #expect(WatchHistory.finished(records).map(\.key) == [.movie(tmdbID: 3), .movie(tmdbID: 1)])
    }

    @Test func groupsByDay() {
        let entries = [entry(1, daysAgo: 0.1), entry(2, daysAgo: 1), entry(3, daysAgo: 2), entry(4, daysAgo: 20),
                       entry(5, daysAgo: 40), entry(6, daysAgo: 400)].map(\.1)
        let groups = WatchHistory.grouped(entries, now: now, calendar: cal)
        #expect(groups.map(\.title) == ["Today", "Yesterday", "This Week", "Earlier This Month", "September", "September 2025"])
        #expect(groups.map { $0.entries.count } == [1, 1, 1, 1, 1, 1])
    }

    @Test func episodesSayWhichOne() {
        let p = WatchProgress(key: .episode(seriesID: 9, season: 2, episode: 2), position: 1, duration: 1, isCompleted: true, updatedAt: now)
        #expect(HistoryEntry(progress: p, title: show(9, "Harbor Lights")).detail == "S2·E2")
        #expect(entry(1, daysAgo: 0).1.detail == "Film")
    }
}

@Suite struct ExternalItemTests {
    @Test func magnetLinks() {
        let m = "magnet:?xt=urn:btih:08ada5a7a6183aae1e09d831df6748d566095a10&dn=Sintel"
        #expect(ExternalItem.classify(URL(string: m)!) == .magnet(m))
        #expect(ExternalItem.classify(text: "  \(m)\n") == .magnet(m))
        // Not a BitTorrent magnet.
        #expect(ExternalItem.classify(URL(string: "magnet:?xt=urn:sha1:abc")!) == nil)
    }

    @Test func filesByKind() {
        let torrent = URL(fileURLWithPath: "/tmp/Sintel.torrent")
        let video = URL(fileURLWithPath: "/tmp/Tears.of.Steel.2012.1080p.MKV")
        let folder = URL(fileURLWithPath: "/tmp/Films", isDirectory: true)
        #expect(ExternalItem.classify(torrent, isDirectory: false) == .torrentFile(torrent))
        #expect(ExternalItem.classify(video, isDirectory: false) == .videoFile(video))
        #expect(ExternalItem.classify(folder, isDirectory: true) == .folder(folder))
        #expect(ExternalItem.classify(URL(fileURLWithPath: "/tmp/notes.txt"), isDirectory: false) == nil)
    }

    @Test func linksToVideosButNotPages() {
        let link = URL(string: "https://media.example.com/films/sintel.mp4")!
        #expect(ExternalItem.classify(link) == .videoLink(link))
        #expect(ExternalItem.classify(URL(string: "https://example.com/watch?v=1")!) == nil)
        #expect(ExternalItem.classify(text: "hello there") == nil)
    }

    @Test func blueboxLinksAreLeftToTheirOwnHandlers() {
        #expect(ExternalItem.classify(URL(string: "bluebox://connect?url=x")!) == nil)
        #expect(ExternalItem.classify(URL(string: "bluebox://auth-callback#token")!) == nil)
    }

    @MainActor @Test func aVideoLinkOpensTheSheetWithItsDirectLink() async throws {
        let app = AppModel.demo(seed: false)
        app.handleOpenURL(URL(string: "https://media.example.com/films/Sintel.2010.mp4")!)
        for _ in 0..<100 where app.externalOpen == nil { try await Task.sleep(for: .milliseconds(20)) }
        let state = try #require(app.externalOpen)
        #expect(state.source == "Opened from a link")
        guard case .ready(_, let variant) = state.phase else { Issue.record("not ready: \(state.phase)"); return }
        #expect(variant.displayName == "Sintel.2010")
        // It went the Settings › Sources way: saved as a direct link.
        #expect(await app.directLinkItems().map(\.url.absoluteString) == ["https://media.example.com/films/Sintel.2010.mp4"])
    }
}

@Suite struct SyncIssueTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func nothingWhileSyncingOrWithoutAnAccount() {
        #expect(SyncIssue.current(account: .syncing, signedIn: true, hadAccount: true, lastSynced: nil,
                                  trakt: .idle, traktConnected: false, traktConfigured: false, now: now).isEmpty)
        #expect(SyncIssue.current(account: .failed("x"), signedIn: false, hadAccount: false, lastSynced: nil,
                                  trakt: .idle, traktConnected: false, traktConfigured: false, now: now).isEmpty)
    }

    @Test func anExpiredSessionAsksToSignInAgain() {
        let issues = SyncIssue.current(account: .failed("Signed out"), signedIn: false, hadAccount: true,
                                       lastSynced: now.addingTimeInterval(-600), trakt: .idle, traktConnected: false,
                                       traktConfigured: false, now: now)
        #expect(issues.count == 1)
        #expect(issues[0].fix == .signIn)
        #expect(issues[0].fixTitle == "Sign In Again")
        #expect(issues[0].title.hasPrefix("Not syncing since "))
    }

    @Test func aPassingFailureOffersTryNowButNotWhileOffline() {
        let args = (account: AccountModel.Status.failed("The server didn't answer."), signedIn: true)
        let online = SyncIssue.current(account: args.account, signedIn: args.signedIn, hadAccount: true, lastSynced: nil,
                                       trakt: .failed("Trakt is down."), traktConnected: true, traktConfigured: true, now: now)
        #expect(online.map(\.fix) == [.retry, .retry])
        #expect(online.map(\.service) == [.account, .trakt])
        let offline = SyncIssue.current(account: args.account, signedIn: args.signedIn, hadAccount: true, lastSynced: nil,
                                        trakt: .failed("x"), traktConnected: false, traktConfigured: true, offline: true, now: now)
        // Only what needs you: Trakt was disconnected.
        #expect(offline.map(\.fix) == [.reconnectTrakt])
    }
}
