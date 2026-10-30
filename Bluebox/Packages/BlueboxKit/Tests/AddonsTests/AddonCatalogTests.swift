@testable import Addons
import Foundation
import Testing

/// Add-on catalogs as Home rows: reading them from manifests, your switches
/// and order, and their pages (question 10 A).
@Suite struct AddonCatalogTests {
    static let listsManifest = #"""
    {"id":"org.example.lists","version":"2.0.0","name":"Lists","resources":["catalog",{"name":"stream","types":["movie"]}],
     "types":["movie","series"],
     "catalogs":[
       {"type":"movie","id":"popular","name":"Popular Films","extra":[{"name":"skip"},{"name":"genre","options":["Action","Drama",""]}]},
       {"type":"series","id":"trending","extraSupported":["skip","genre"],"extraRequired":[]},
       {"type":"movie","id":"search","name":"Search","extra":[{"name":"search","isRequired":true}]},
       {"type":"anime","id":"seasonal","name":"This Season","extra":[{"name":"genre","isRequired":true,"options":["Winter","Spring"]}]},
       {"type":"movie","id":"needs-genre","name":"Broken","extra":[{"name":"genre","isRequired":true}]},
       {"type":"tv","id":"channels","name":"Channels"},
       {"type":"movie","name":"No ID"},
       {"type":"movie","id":"popular","name":"Popular Again"}
     ]}
    """#

    private func manifest(_ json: String) throws -> AddonManifest {
        try JSONDecoder().decode(AddonManifest.self, from: Data(json.utf8))
    }

    private func manifest(name: String, catalogs: Int) throws -> AddonManifest {
        let list = (0..<catalogs).map { #"{"type":"movie","id":"c\#($0)","name":"\#(name) \#($0)"}"# }.joined(separator: ",")
        return try manifest(#"{"id":"x","name":"\#(name)","resources":["catalog"],"types":["movie"],"catalogs":[\#(list)]}"#)
    }

    @Test func readsTheCatalogsBlueboxCanShow() throws {
        let m = try manifest(Self.listsManifest)
        // An odd catalog (no ID) doesn't cost the rest.
        #expect(m.catalogs.count == 7)
        let shown = m.homeCatalogs
        #expect(shown.map(\.id) == ["movie/popular", "series/trending", "anime/seasonal"])

        let popular = shown[0]
        #expect(popular.name == "Popular Films" && popular.canPage && !popular.genreRequired)
        #expect(popular.genres == ["Action", "Drama"])
        // The old form's extras, and a name made up when there's none.
        #expect(shown[1].canPage && shown[1].name == "Lists Series")
        // Needs a genre: it has options, so the first is used.
        #expect(shown[2].genreRequired && !shown[2].canPage && !shown[2].isMovie)
        #expect(shown[2].extra() == ["genre": "Winter"])
        #expect(shown[2].extra(genre: "Spring", skip: 0) == ["genre": "Spring"])
        #expect(popular.extra(skip: 100) == ["skip": "100"])
    }

    @Test func catalogURLsFollowTheProtocol() {
        let base = URL(string: "https://lists.example/cfg=abc/")!
        #expect(AddonCatalogPath.url(base: base, resource: "catalog", type: "movie", id: "top").absoluteString
                == "https://lists.example/cfg=abc/catalog/movie/top.json")
        #expect(AddonCatalogPath.url(base: base, resource: "catalog", type: "movie", id: "top",
                                     extra: ["skip": "100", "genre": "Sci-Fi & Fantasy"]).absoluteString
                == "https://lists.example/cfg=abc/catalog/movie/top/genre=Sci-Fi%20%26%20Fantasy&skip=100.json")
        // A slash in an ID stays inside its segment.
        #expect(AddonCatalogPath.url(base: base, resource: "catalog", type: "series", id: "a/b").absoluteString
                == "https://lists.example/cfg=abc/catalog/series/a%2Fb.json")
    }

    @Test func onlyTheFirstFewAreOnByDefault() throws {
        var settings = AddonSettings()
        settings.addons = [InstalledAddon(id: "a", kind: .custom(base: "https://a.example"), name: "A"),
                           InstalledAddon(id: "b", kind: .custom(base: "https://b.example"), name: "B")]
        settings.updateCatalogs(of: "a", from: try manifest(name: "A", catalogs: 4))
        settings.updateCatalogs(of: "b", from: try manifest(name: "B", catalogs: 5))
        #expect(settings.addons[0].catalogs?.allSatisfy(\.isShown) == true)
        #expect(settings.addons[1].catalogs?.map(\.isShown) == [true, true, false, false, false])
        #expect(settings.shownCatalogCount == AddonSettings.defaultHomeCatalogs)
    }

    @Test func aNewManifestKeepsYourSwitchesAndOrder() throws {
        var settings = AddonSettings()
        settings.addons = [InstalledAddon(id: "a", kind: .custom(base: "https://a.example"), name: "A")]
        settings.updateCatalogs(of: "a", from: try manifest(name: "A", catalogs: 3))
        settings.setCatalog("movie/c0", of: "a", shown: false)
        settings.moveCatalogs(of: "a", from: IndexSet(integer: 2), to: 0)
        #expect(settings.addons[0].catalogs?.map(\.catalogID) == ["c2", "c0", "c1"])
        // Down as well as up, as List hands them over.
        settings.moveCatalogs(of: "a", from: IndexSet(integer: 0), to: 3)
        #expect(settings.addons[0].catalogs?.map(\.catalogID) == ["c0", "c1", "c2"])
        settings.moveCatalogs(of: "a", from: IndexSet(integer: 2), to: 0)

        // c1 is gone, c3 is new.
        let next = try manifest(#"{"id":"x","name":"A","resources":["catalog"],"types":["movie"],"catalogs":[{"type":"movie","id":"c0","name":"Renamed"},{"type":"movie","id":"c2"},{"type":"movie","id":"c3"}]}"#)
        settings.updateCatalogs(of: "a", from: next)
        let catalogs = settings.addons[0].catalogs ?? []
        #expect(catalogs.map(\.catalogID) == ["c2", "c0", "c3"])
        #expect(catalogs.map(\.isShown) == [true, false, true])
        #expect(catalogs[1].name == "Renamed")
    }

    @Test func homeTakesShownCatalogsFromAddonsThatAreOn() throws {
        var settings = AddonSettings()
        settings.addons = [InstalledAddon(id: "a", kind: .custom(base: "https://a.example"), name: "A"),
                           InstalledAddon(id: "b", kind: .custom(base: "https://b.example"), name: "B")]
        settings.customLinks = ["a": "https://a.example/cfg", "b": "https://b.example/cfg"]
        settings.updateCatalogs(of: "a", from: try manifest(name: "A", catalogs: 2))
        settings.updateCatalogs(of: "b", from: try manifest(name: "B", catalogs: 2))
        settings.setCatalog("movie/c0", of: "a", shown: false)
        #expect(settings.homeCatalogs(debridKey: "").map(\.id) == ["a/movie/c1", "b/movie/c0", "b/movie/c1"])
        #expect(settings.homeCatalogs(debridKey: "").first?.addon.base.absoluteString == "https://a.example/cfg")

        settings.addons[1].isEnabled = false
        #expect(settings.homeCatalogs(debridKey: "").map(\.id) == ["a/movie/c1"])
        // See All still finds one you turned off.
        #expect(settings.resolvedCatalog(addonID: "a", catalogID: "movie/c0", debridKey: "") != nil)
        settings.isEnabled = false
        #expect(settings.homeCatalogs(debridKey: "").isEmpty)
    }

    @Test func listOnlyAddonsAreNeverAskedForReleases() throws {
        let lists = try manifest(name: "Lists", catalogs: 1)
        var addon = InstalledAddon.custom(base: URL(string: "https://lists.example/cfg")!, manifest: lists)
        #expect(addon.catalogsOnly == true && addon.types.isEmpty)
        var settings = AddonSettings()
        settings.addons = [addon]
        settings.customLinks[addon.id] = "https://lists.example/cfg"
        settings.updateCatalogs(of: addon.id, from: lists)
        #expect(settings.resolvedAddons(debridKey: "").isEmpty)
        #expect(settings.homeCatalogs(debridKey: "").count == 1)

        addon = InstalledAddon.custom(base: URL(string: "https://s.example")!, manifest: try manifest(Self.listsManifest))
        #expect(addon.catalogsOnly == nil && addon.types == ["movie"])
    }

    @Test func settingsFromBeforeCatalogsStillLoad() throws {
        let old = #"{"id":"custom.1","kind":{"custom":{"base":"https://a.example"}},"name":"A","isEnabled":true,"types":["movie"]}"#
        let addon = try JSONDecoder().decode(InstalledAddon.self, from: Data(old.utf8))
        #expect(addon.catalogs == nil && addon.catalogsOnly == nil)
        var settings = AddonSettings()
        settings.addons = [addon]
        settings.customLinks["custom.1"] = "https://a.example/cfg"
        #expect(settings.addonsMissingCatalogs.map(\.id) == ["custom.1"])

        // A saved catalog missing a field added later keeps its place.
        let saved = try JSONDecoder().decode(AddonCatalog.self, from: Data(#"{"type":"movie","catalogID":"top","name":"Top"}"#.utf8))
        #expect(saved.isShown && saved.genres.isEmpty)
    }

    @Test func catalogPagesAreReadLeniently() async throws {
        let body = #"""
        {"metas":[
          {"id":"tt0133093","type":"movie","name":"The Matrix","poster":"https://img.example/m.jpg","releaseInfo":"1999","imdbRating":"8.7","genres":["Action"]},
          {"id":"kitsu:1","type":"series","name":"Cowboy Bebop","imdb_id":"tt0213338","poster":"file:///etc/passwd"},
          {"id":603,"type":"movie","name":"Number ID","year":1999},
          {"id":"tt1","name":""},
          {"type":"movie","name":"No ID"},
          "not an object"
        ]}
        """#
        let transport = CatalogTransport(["/cfg/catalog/movie/top/skip=100.json": body, "/cfg/catalog/movie/broken.json": "<html>"])
        let client = AddonClient(transport: transport)
        let items = try await client.catalog(base: URL(string: "https://lists.example/cfg")!, type: "movie", id: "top", extra: ["skip": "100"])
        #expect(items.map(\.name) == ["The Matrix", "Cowboy Bebop", "Number ID"])
        #expect(items[0].imdb == "tt0133093" && items[0].poster == "https://img.example/m.jpg")
        #expect(items[1].imdb == "tt0213338" && items[1].poster == nil)
        #expect(items[2].id == "603" && items[2].releaseInfo == "1999" && items[2].imdb == nil)

        await #expect(throws: AddonError.unexpectedResponse) {
            try await client.catalog(base: URL(string: "https://lists.example/cfg")!, type: "movie", id: "broken")
        }
    }
}

/// Answers by URL path (and the extras in it).
final class CatalogTransport: AddonTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let bodies: [String: String]
    private var log: [String] = []
    init(_ bodies: [String: String]) { self.bodies = bodies }
    var paths: [String] { lock.withLock { log } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path(percentEncoded: true) ?? ""
        lock.withLock { log.append(path) }
        let body = bodies[path]
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        return (Data((body ?? "Not found").utf8), response)
    }
}
