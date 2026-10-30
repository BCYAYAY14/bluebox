@testable import Addons
import Domain
@testable import Features
import Foundation
import Metadata
import Testing

/// Home's rows from add-on catalogs, against faked add-on answers: which
/// items become titles, paging by `skip`, and the profile's limit.
@Suite struct AddonCatalogRowsTests {
    private static func item(_ id: String, _ name: String, type: String = "movie", genres: [String] = [], extra: String = "") -> String {
        let g = genres.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"id":"\#(id)","type":"\#(type)","name":"\#(name)","genres":[\#(g)]\#(extra)}"#
    }

    private static func page(_ items: [String]) -> String { #"{"metas":[\#(items.joined(separator: ","))]}"# }

    private func catalog(canPage: Bool = true, type: String = "movie") -> ResolvedCatalog {
        var settings = AddonSettings()
        settings.addons = [InstalledAddon(id: "lists", kind: .custom(base: "https://lists.example"), name: "Lists",
                                          catalogs: [AddonCatalog(type: type, catalogID: "top", name: "Top", canPage: canPage)])]
        settings.customLinks["lists"] = "https://lists.example/cfg"
        return settings.homeCatalogs(debridKey: "")[0]
    }

    private func reader(_ transport: CatalogTransportStub, cache: CachedMetadataProvider? = nil) -> AddonCatalogReader {
        AddonCatalogReader(client: AddonClient(transport: transport), bridge: nil, cache: cache)
    }

    @Test func itemsWithIMDbOrTMDBIDsBecomeTitlesAndTheRestAreLeftOut() async throws {
        let body = Self.page([
            Self.item("tt0133093", "The Matrix", extra: #","releaseInfo":"1999","imdbRating":"8.7""#),
            Self.item("tmdb:1399", "Thrones", type: "series"),
            Self.item("kitsu:1", "Cowboy Bebop", type: "series"),
            Self.item("kitsu:2", "Has IMDb", type: "series", extra: #","imdb_id":"tt0213338""#),
            Self.item("tt0133093", "The Matrix again"),
        ])
        let transport = CatalogTransportStub(["/cfg/catalog/movie/top.json": body])
        let page = try await reader(transport).page(catalog(canPage: false))
        #expect(page.items.map(\.name) == ["The Matrix", "Thrones", "Has IMDb"])
        #expect(page.items.map(\.key) == [.movie(imdbID: "tt0133093"), .series(tmdbID: 1399), .series(imdbID: "tt0213338")])
        #expect(page.items[0].voteAverage == 8.7 && page.items[0].year == 1999)
        #expect(page.items[1].kind == .series)
        // No `skip`: one page only.
        #expect(page.totalPages == 1)
        #expect(try await reader(transport).page(catalog(canPage: false), page: 2).items.isEmpty)
    }

    @Test func seeAllPagesBySkippingTheFirstPagesSize() async throws {
        let first = Self.page((0..<3).map { Self.item("tt100000\($0)", "First \($0)") })
        let second = Self.page((0..<2).map { Self.item("tt200000\($0)", "Second \($0)") })
        let transport = CatalogTransportStub(["/cfg/catalog/movie/top.json": first,
                                              "/cfg/catalog/movie/top/skip=3.json": second,
                                              "/cfg/catalog/movie/top/skip=6.json": Self.page([])])
        let r = reader(transport)
        let one = try await r.page(catalog(), page: 1)
        #expect(one.items.count == 3 && one.totalPages == 2)
        let two = try await r.page(catalog(), page: 2)
        #expect(two.items.map(\.name) == ["Second 0", "Second 1"] && two.totalPages == 3)
        let three = try await r.page(catalog(), page: 3)
        #expect(three.items.isEmpty && three.totalPages == 3)
        #expect(transport.paths.contains("/cfg/catalog/movie/top/skip=6.json"))

        // A Home row keeps the first few.
        #expect(try await r.page(catalog(), limit: 2).items.count == 2)
    }

    @Test func pagesAreCachedLikeTheOtherLists() async throws {
        let transport = CatalogTransportStub(["/cfg/catalog/movie/top.json": Self.page([Self.item("tt1000001", "One")])])
        let cache = CachedMetadataProvider(SampleMetadataProvider())
        let r = reader(transport, cache: cache)
        _ = try await r.page(catalog())
        _ = try await r.page(catalog())
        #expect(transport.paths.count == 1)
    }

    @Test func aKidsProfileSeesOnlyWhatItsLimitAllows() async throws {
        let body = Self.page([
            Self.item("tt1000001", "Cartoon", genres: ["Animation"]),
            Self.item("tt1000002", "Thriller", genres: ["Thriller"]),
            Self.item("tt1000003", "Family Film", genres: ["Family"]),
            Self.item("tt1000004", "Rated Grown-up", genres: ["Animation"]),
        ])
        let transport = CatalogTransportStub(["/cfg/catalog/movie/top.json": body])
        let cache = CachedMetadataProvider(SampleMetadataProvider())
        cache.noteCertification("R", for: .movie(imdbID: "tt1000004"))
        let r = reader(transport, cache: cache)
        #expect(try await r.page(catalog()).items.count == 4)

        cache.contentFilter = ContentFilter(maximum: .age7, familyOnlyWhenUnrated: true)
        #expect(try await r.page(catalog()).items.map(\.name) == ["Cartoon", "Family Film"])
        // A row still fills from what's left.
        #expect(try await r.page(catalog(), limit: 1).items.map(\.name) == ["Cartoon"])
    }

    @Test func aRowsTitlesFollowTheItemsOwnType() {
        let c = AddonCatalog(type: "anime", catalogID: "season", name: "Season")
        let item = try? JSONDecoder().decode(AddonMetaItem.self, from: Data(Self.item("tt3000001", "Film", type: "movie").utf8))
        let noType = try? JSONDecoder().decode(AddonMetaItem.self, from: Data(#"{"id":"tt3000002","name":"Show"}"#.utf8))
        #expect(item.flatMap { AddonItemMapping.title($0, catalog: c) }?.kind == .movie)
        #expect(noType.flatMap { AddonItemMapping.title($0, catalog: c) }?.key == .series(imdbID: "tt3000002"))
    }
}

/// Answers by URL path (and the extras in it).
final class CatalogTransportStub: AddonTransport, @unchecked Sendable {
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
