import Foundation
@testable import SystemSnapshot
import Testing

/// The links widgets, Spotlight and Siri open, and the snapshot they read.
struct SystemLinkTests {
    @Test func linksRoundTrip() {
        let links: [SystemLink] = [
            .title(key: "tmdb:tv:1399", episode: nil),
            .title(key: "tmdb:tv:1399", episode: "tmdb:tv:1399:s1e2"),
            .play(key: "imdb:movie:tt0133093"),
            .myList,
            .search("heist & co"),
        ]
        for link in links { #expect(SystemLink(url: link.url) == link) }
    }

    @Test func otherLinksAreNotOurs() {
        for raw in ["bluebox://connect?u=x", "bluebox://auth-callback#access_token=x", "magnet:?xt=urn:btih:abc",
                    "https://bluebox.app/title?key=tmdb:tv:1", "bluebox://title", "bluebox://play?key="] {
            #expect(SystemLink(url: URL(string: raw)!) == nil, "\(raw)")
        }
    }

    /// Local files and URLs mean nothing outside this device's library, and
    /// a link from a web page shouldn't carry anything long or odd.
    @Test func onlyCatalogueKeys() {
        #expect(SystemLink(url: URL(string: "bluebox://play?key=local:abc123")!) == nil)
        #expect(SystemLink(url: URL(string: "bluebox://title?key=tmdb:\(String(repeating: "9", count: 200))")!) == nil)
        #expect(SystemLink(url: URL(string: "bluebox://title?key=tmdb:tv:1&episode=url:x")!) == .title(key: "tmdb:tv:1", episode: nil))
    }
}

@Suite(.serialized) struct LibrarySnapshotStoreTests {
    let store = LibrarySnapshotStore(folder: FileManager.default.temporaryDirectory
        .appending(path: "SystemSnapshotTests-\(UUID().uuidString)"), isShared: false)

    private func item(_ key: String, title: String, series: String? = nil, thumbnail: String? = nil) -> LibrarySnapshot.Item {
        .init(key: key, titleKey: series ?? key, title: title, thumbnail: thumbnail, link: SystemLink.play(key: key).url)
    }

    @Test func writesReadsAndPrunesPosters() throws {
        defer { store.removeAll() }
        #expect(store.read() == nil)
        let a = try store.saveThumbnail(Data([1, 2, 3]), for: "tmdb:movie:1")
        let b = try store.saveThumbnail(Data([4]), for: "tmdb:tv:2")
        #expect(a == "tmdb-movie-1.jpg")
        let snapshot = LibrarySnapshot(continueWatching: [item("tmdb:movie:1", title: "One", thumbnail: a)],
                                       upNext: [item("tmdb:tv:2:s1e3", title: "Two", series: "tmdb:tv:2")])
        try store.write(snapshot)
        #expect(store.read()?.continueWatching == snapshot.continueWatching)
        #expect(store.hasThumbnail(for: "tmdb:movie:1"))
        #expect(!store.hasThumbnail(for: "tmdb:tv:2"), "a poster nothing uses is deleted (\(b))")
        store.removeAll()
        #expect(store.read() == nil)
    }

    @Test func titlesAndResume() {
        let snapshot = LibrarySnapshot(continueWatching: [item("tmdb:tv:2:s1e1", title: "Two", series: "tmdb:tv:2")],
                                       upNext: [item("tmdb:tv:3:s2e1", title: "Three", series: "tmdb:tv:3")],
                                       myList: [item("tmdb:tv:2", title: "Two"), item("tmdb:movie:4", title: "Four")])
        #expect(snapshot.titles.map(\.titleKey) == ["tmdb:tv:2", "tmdb:tv:3", "tmdb:movie:4"])
        #expect(snapshot.resumeFirst?.key == "tmdb:tv:2:s1e1")
        #expect(snapshot.resumable(titleKey: "tmdb:tv:3")?.key == "tmdb:tv:3:s2e1")
        #expect(snapshot.resumable(titleKey: "tmdb:movie:4") == nil)
    }

    /// The widgets read what the app wrote, possibly from an older or newer
    /// version: the JSON keeps its names and dates, and another version reads as none.
    @Test func encodingIsStableAndVersioned() throws {
        defer { store.removeAll() }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let film = LibrarySnapshot.Item(key: "tmdb:movie:1", titleKey: "tmdb:movie:1", title: "Arrival", progress: 0.5,
                                        minutesLeft: 58, link: SystemLink.play(key: "tmdb:movie:1").url)
        try store.write(LibrarySnapshot(generatedAt: date, continueWatching: [film]))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(json["generatedAt"] as? String == "2027-01-15T08:00:00Z")
        let first = try #require((json["continueWatching"] as? [[String: Any]])?.first)
        #expect(first["title"] as? String == "Arrival")
        #expect(first["link"] as? String == "bluebox://play?key=tmdb:movie:1")
        #expect(store.read()?.generatedAt == date)

        var newer = try #require(store.read())
        newer.version = 2
        try store.write(newer)
        #expect(store.read() == nil)
    }

    /// Spotlight gets exactly the rows and downloads, each link once, so what
    /// leaves them leaves Spotlight; the result's identifier is its link.
    @Test func spotlightSet() {
        let watching = item("tmdb:tv:2:s1e1", title: "Two", series: "tmdb:tv:2")
        var next = item("tmdb:tv:3:s2e1", title: "Three", series: "tmdb:tv:3")
        next.subtitle = "S2·E1"
        next.isNew = true
        let listed = LibrarySnapshot.Item(key: "tmdb:movie:4", titleKey: "tmdb:movie:4", title: "Four",
                                          link: SystemLink.title(key: "tmdb:movie:4", episode: nil).url)
        let snapshot = LibrarySnapshot(continueWatching: [watching], upNext: [next], myList: [listed])
        let downloaded = [watching, item("tmdb:movie:5", title: "Five")]
        let entries = snapshot.spotlightEntries(downloads: downloaded)
        #expect(entries.map(\.item.key) == ["tmdb:tv:2:s1e1", "tmdb:tv:3:s2e1", "tmdb:movie:4", "tmdb:movie:5"])
        #expect(entries.map(\.detail) == ["Continue Watching", "New Episode", "My List", "Downloads"])
        #expect(entries[1].displayName == "Three · S2·E1")
        #expect(entries[1].contentDescription == "S2·E1 · New Episode")
        #expect(entries.allSatisfy { SystemLink(url: URL(string: $0.id)!) != nil })

        // Watched to the end and off My List: gone from Spotlight's set.
        let later = LibrarySnapshot(upNext: [next])
        #expect(later.spotlightEntries().map(\.item.key) == ["tmdb:tv:3:s2e1"])
        #expect(LibrarySnapshot.empty.spotlightEntries().isEmpty)
    }

    /// AltStore renames the App Group to one of the user's team; anything
    /// else in Info.plist is ignored.
    @Test func appGroupCandidates() {
        #expect(LibrarySnapshotStore.appGroupCandidates(info: [:]) == ["group.app.bluebox.Bluebox"])
        let info: [String: Any] = ["ALTAppGroups": ["group.app.bluebox.Bluebox.ABCDE12345", "nonsense", "group.app.bluebox.Bluebox"]]
        #expect(LibrarySnapshotStore.appGroupCandidates(info: info)
            == ["group.app.bluebox.Bluebox", "group.app.bluebox.Bluebox.ABCDE12345"])
    }
}
