import Domain
import Foundation
@testable import MediaSources
import Metadata
import Testing
import TestingSupport

@Suite struct DebridLibraryTests {
    static let key = "SECRET-TEST-KEY"

    /// Matches the open films and "Open Show" by name, like the app's matcher.
    static let matcher: MediaMatcher = { parsed in
        switch (MediaNameParser.normalized(parsed.title), parsed.kind) {
        case ("sintel", .movie): .movie(tmdbID: 45745)
        case ("bigbuckbunny", .movie): .movie(tmdbID: 10378)
        case ("tearsofsteel", .movie): .movie(tmdbID: 133701)
        case ("openshow", .episode(let s, let e)): .episode(seriesID: 9_100_001, season: s, episode: e)
        default: nil
        }
    }

    func realDebrid() -> (FixtureHTTPClient, RealDebridAPI) {
        let http = FixtureHTTPClient()
        http.on("rest/1.0/torrents", .fixture("rd_torrents"))
        http.on("torrents/info/T2", .fixture("rd_torrent_info"))
        http.on("rest/1.0/downloads", .fixture("rd_downloads"))
        http.on("unrestrict/link", .init(body: Data(#"{"download":"https://cdn.real-debrid.example/fresh/sintel.mkv"}"#.utf8)))
        http.on("rest/1.0/user", .init(body: Data(#"{"username":"viewer","type":"premium"}"#.utf8)))
        return (http, RealDebridAPI(key: Self.key, http: http, base: URL(string: "https://rd.test/rest/1.0/")!))
    }

    @Test func realDebridListsFinishedVideoFilesOnce() async throws {
        let (http, api) = realDebrid()
        let files = try await api.files()
        #expect(Set(files.map(\.id)) == ["rd:t:T1:0", "rd:t:T2:1", "rd:t:T2:3", "rd:d:D2", "rd:d:D3"])
        // Still downloading, not video, or already listed as a torrent file: left out.
        #expect(!files.contains { $0.filename.contains("Still.Downloading") || $0.filename == "Readme.txt" })
        let pack = try #require(files.first { $0.id == "rd:t:T2:3" })
        #expect(pack.filename == "S01E02.mkv" && pack.parentName == "Open.Show.S01.1080p" && pack.reference == "https://real-debrid.com/d/LINK3")
        // The key travels only in the Authorization header.
        for r in http.requests {
            #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
            #expect(!r.url!.absoluteString.contains(Self.key))
        }
        #expect(try await api.accountName() == "viewer")
    }

    @Test func libraryMatchesNamesIncludingBareEpisodeFilesInPacks() async throws {
        let (_, api) = realDebrid()
        let source = DebridLibrarySource(api: api, matcher: Self.matcher)
        let entries = try await source.library()
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        #expect(byID["rd:t:T1:0"]?.key == .movie(tmdbID: 45745))
        #expect(byID["rd:t:T2:1"]?.key == .episode(seriesID: 9_100_001, season: 1, episode: 1))
        #expect(byID["rd:t:T2:3"]?.key == .episode(seriesID: 9_100_001, season: 1, episode: 2))  // title from the folder
        #expect(byID["rd:d:D2"]?.key == .movie(tmdbID: 10378))
        #expect(byID["rd:d:D3"]?.key == nil)  // unmatched
        #expect(entries.first?.id == "rd:d:D3")  // newest first

        let variants = try await source.variants(for: .episode(seriesID: 9_100_001, season: 1, episode: 2))
        #expect(variants.count == 1 && variants[0].isDownloadable && variants[0].location == .remote)
        #expect(variants[0].container == "mkv")
        #expect(try await source.catalog().count == 5)
    }

    @Test func playingUnrestrictsTheLinkFresh() async throws {
        let (http, api) = realDebrid()
        let source = DebridLibrarySource(api: api, matcher: Self.matcher)
        let variant = try #require(try await source.variants(for: .movie(tmdbID: 45745)).first)
        let resource = try await source.resolve(variant)
        #expect(resource.url.absoluteString == "https://cdn.real-debrid.example/fresh/sintel.mkv")
        let unrestrict = try #require(http.requests.last)
        #expect(unrestrict.httpMethod == "POST" && unrestrict.url!.path.hasSuffix("unrestrict/link"))
        #expect(String(decoding: unrestrict.httpBody ?? Data(), as: UTF8.self) == "link=https://real-debrid.com/d/LINK1")
        let health = await source.testConnection()
        #expect(health.ok && health.message.contains("viewer") && !health.message.contains(Self.key))
    }

    @Test func rejectedKeyIsUnauthorizedAndNothingIsConfiguredWithoutOne() async throws {
        let http = FixtureHTTPClient()
        http.on("torrents", .init(status: 401))
        http.on("downloads", .init(status: 401))
        let source = DebridLibrarySource(api: RealDebridAPI(key: "bad", http: http), matcher: nil)
        await #expect(throws: SourceError.unauthorized) { try await source.library() }
        let empty = DebridLibrarySource(api: nil, matcher: nil)
        await #expect(throws: SourceError.notConfigured) { try await empty.library() }
        #expect(try await empty.variants(for: .movie(tmdbID: 1)).isEmpty)
        #expect(await !empty.testConnection().ok)
    }

    @Test func premiumizeUsesDirectLinksAndFolderNames() async throws {
        let http = FixtureHTTPClient()
        http.on("item/listall", .fixture("pm_listall"))
        let api = PremiumizeAPI(key: Self.key, http: http, base: URL(string: "https://pm.test/api/")!)
        let source = DebridLibrarySource(api: api, matcher: Self.matcher)
        let entries = try await source.library()
        #expect(Set(entries.map(\.id)) == ["pm:P1", "pm:P3"])
        #expect(entries.first { $0.id == "pm:P3" }?.key == .episode(seriesID: 9_100_001, season: 2, episode: 4))
        #expect(entries.first { $0.id == "pm:P1" }?.key == .movie(tmdbID: 133701))
        let v = try #require(try await source.variants(for: .movie(tmdbID: 133701)).first)
        #expect(try await source.resolve(v).url.absoluteString == "https://cdn.premiumize.example/P1/tos.mkv")
    }

    @Test func torBoxListsFinishedTorrentsAndRequestsALink() async throws {
        let http = FixtureHTTPClient()
        http.on("torrents/mylist", .fixture("tb_mylist"))
        http.on("torrents/requestdl", .init(body: Data(#"{"success":true,"data":"https://store.torbox.example/dl/bbb.mp4"}"#.utf8)))
        let api = TorBoxAPI(key: Self.key, http: http, base: URL(string: "https://tb.test/v1/api/")!)
        let source = DebridLibrarySource(api: api, matcher: Self.matcher)
        let entries = try await source.library()
        #expect(entries.map(\.id) == ["tb:11:0"])
        #expect(entries[0].key == .movie(tmdbID: 10378))
        let v = try #require(try await source.variants(for: .movie(tmdbID: 10378)).first)
        #expect(try await source.resolve(v).url.absoluteString == "https://store.torbox.example/dl/bbb.mp4")
        let req = try #require(http.requests.last?.url)
        let items = URLComponents(url: req, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "torrent_id", value: "11")) && items.contains(URLQueryItem(name: "file_id", value: "0")))
    }

    @Test func sampleAndNonVideoFilesAreSkipped() {
        #expect(DebridFile.isVideo("Movie.2020.mkv"))
        #expect(!DebridFile.isVideo("movie-sample.mkv"))
        #expect(!DebridFile.isVideo("/Pack/Sample/sample.mp4"))
        #expect(!DebridFile.isVideo("poster.jpg"))
    }
}
