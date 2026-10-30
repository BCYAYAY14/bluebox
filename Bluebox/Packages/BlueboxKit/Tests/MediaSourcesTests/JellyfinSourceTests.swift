import Domain
import Foundation
@testable import MediaSources
import Metadata
import Testing

/// Answers the handful of Jellyfin (or, as `flavour` says, Emby) endpoints Bluebox uses.
final class FakeJellyfin: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var password = "secret"
    var flavour = JellyfinSource.Flavour.jellyfin
    /// An Emby server that only answers under `/emby`.
    var onlyUnderEmbyPath = false
    /// Jellyfin 10.9 and later: played state only at `UserPlayedItems/{id}`.
    var onlyNewPlayedRoute = false
    /// A proxy in front of Emby that turns DELETE away.
    var refusesDelete = false
    /// This user's state per item ID, as `UserData` sends it.
    var userData: [String: [String: Any]] = [:]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let (status, body) = handle(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    private func handle(_ r: URLRequest) -> (Int, Data) {
        var path = r.url!.path
        if onlyUnderEmbyPath {
            guard path.hasPrefix("/emby/") else { return (404, Data()) }
            path.removeFirst("/emby".count)
        }
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        // Jellyfin reads `Authorization`; Emby reads `X-Emby-Authorization`, with the token alone in `X-Emby-Token`.
        let auth: String, signedIn: Bool
        switch flavour {
        case .jellyfin:
            auth = r.value(forHTTPHeaderField: "Authorization") ?? ""
            signedIn = auth.contains("Token=\"tok\"")
        case .emby:
            guard r.value(forHTTPHeaderField: "Authorization") == nil else { return (400, Data()) }
            auth = r.value(forHTTPHeaderField: "X-Emby-Authorization") ?? ""
            signedIn = r.value(forHTTPHeaderField: "X-Emby-Token") == "tok"
        }
        guard auth.hasPrefix("MediaBrowser Client=\"Bluebox\""), auth.contains("DeviceId=\"dev-1\"") else { return (400, Data()) }
        // The public info is asked for before the client knows which server it is.
        if path == "/System/Info/Public" {
            return flavour == .emby ? (200, json(["ServerName": "Den", "Version": "4.8.10.0"]))
                                    : (200, json(["ServerName": "Living Room", "Version": "10.10.0", "ProductName": "Jellyfin Server"]))
        }
        if path.hasPrefix("/Users/u1/PlayedItems/") || path.hasPrefix("/UserPlayedItems/") {
            guard signedIn else { return (401, Data()) }
            return played(r, path: path, query: q)
        }
        switch path {
        case "/Users/AuthenticateByName":
            let body = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: String]
            guard body?["Pw"] == password else { return (401, Data()) }
            return (200, json(["AccessToken": "tok", "User": ["Id": "u1", "Name": "Brian"]]))
        case "/Items":
            guard signedIn, q["userId"] == "u1" else { return (401, Data()) }
            if q["includeItemTypes"] == "Series" {
                return (200, json(["Items": [["Id": "s1", "Name": "Show", "Type": "Series", "ProviderIds": ["Tmdb": "1399"]],
                                             ["Id": "s2", "Name": "Obscure", "Type": "Series", "ProviderIds": [:]]],
                                   "TotalRecordCount": 2]))
            }
            let items: [[String: Any]] = [
                ["Id": "m1", "Name": "The Matrix", "Type": "Movie", "ProductionYear": 1999, "ProviderIds": ["Tmdb": "603"],
                 "MediaSources": [["Id": "ms1", "Container": "mp4", "Size": 1000, "RunTimeTicks": 81_600_000_000,
                                   "MediaStreams": [["Type": "Video", "Index": 0, "Height": 1080],
                                                    ["Type": "Subtitle", "Index": 2, "Language": "eng", "DisplayTitle": "English", "IsTextSubtitleStream": true],
                                                    ["Type": "Subtitle", "Index": 3, "Language": "eng", "DisplayTitle": "PGS", "IsTextSubtitleStream": false]]]]],
                ["Id": "e1", "Name": "Pilot", "Type": "Episode", "SeriesId": "s1", "SeriesName": "Show", "ParentIndexNumber": 1, "IndexNumber": 1,
                 "MediaSources": [["Id": "ms2", "Container": "mkv", "MediaStreams": [["Type": "Video", "Index": 0, "Height": 2160]]]]],
                ["Id": "e2", "Name": "Ep", "Type": "Episode", "SeriesId": "s2", "ParentIndexNumber": 2, "IndexNumber": 5,
                 "MediaSources": [["Id": "ms3", "Container": "mov,mp4,m4a"]]],
                ["Id": "x", "Name": "No media", "Type": "Movie"],
            ]
            var withState = items.map { item -> [String: Any] in
                var item = item
                if q["enableUserData"] == "true", let id = item["Id"] as? String { item["UserData"] = lock.withLock { userData[id] } ?? [:] }
                return item
            }
            if let ids = q["ids"]?.split(separator: ",").map(String.init) {
                withState = withState.filter { ids.contains($0["Id"] as? String ?? "") }
            }
            return (200, json(["Items": withState, "TotalRecordCount": withState.count]))
        case "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped":
            return signedIn ? (204, Data()) : (401, Data())
        default:
            return (404, Data())
        }
    }

    private func played(_ r: URLRequest, path: String, query: [String: String]) -> (Int, Data) {
        var path = path
        if path.hasPrefix("/UserPlayedItems/") {
            guard flavour == .jellyfin, query["userId"] == "u1" else { return (404, Data()) }
        } else if onlyNewPlayedRoute {
            return (404, Data())
        }
        let viaPost = path.hasSuffix("/Delete")
        if viaPost { path.removeLast("/Delete".count) }
        let id = String(path.split(separator: "/").last ?? "")
        let played: Bool
        switch r.httpMethod {
        case "POST": played = !viaPost
        case "DELETE":
            if refusesDelete { return (405, Data()) }
            played = false
        default: return (405, Data())
        }
        lock.withLock { userData[id] = ["Played": played, "PlaybackPositionTicks": 0] }
        return (200, json(["Played": played]))
    }
}

@Suite struct JellyfinSourceTests {
    func signedIn(_ server: FakeJellyfin, matcher: MediaMatcher? = nil) async throws -> JellyfinSource {
        let (creds, name) = try await JellyfinSource.signIn(server: "media.example.com/", username: "brian", password: "secret",
                                                            http: server, deviceID: "dev-1")
        #expect(name == "Living Room")
        #expect(creds.server.absoluteString == "https://media.example.com")
        #expect(creds.accessToken == "tok")
        return JellyfinSource(id: SourceID("jf"), name: name, credentials: creds, http: server, deviceID: "dev-1", matcher: matcher)
    }

    @Test func wrongPasswordIsUnauthorized() async {
        let server = FakeJellyfin(); server.password = "other"
        await #expect(throws: SourceError.unauthorized) {
            _ = try await JellyfinSource.signIn(server: "https://media.example.com", username: "brian", password: "secret",
                                                http: server, deviceID: "dev-1")
        }
    }

    @Test func rejectsPlainHTTPOutsideTheLocalNetwork() {
        #expect(JellyfinSource.normalize("http://media.example.com") == nil)
        #expect(JellyfinSource.normalize("http://192.168.1.20:8096")?.absoluteString == "http://192.168.1.20:8096")
    }

    @Test func mapsItemsToCatalogKeys() async throws {
        let server = FakeJellyfin()
        let source = try await signedIn(server, matcher: { parsed in
            parsed.title == "Obscure" ? .episode(seriesID: 77, season: 2, episode: 5) : nil
        })
        let movie = try await source.variants(for: .movie(tmdbID: 603))
        #expect(movie.count == 1)
        #expect(movie[0].container == "mp4" && movie[0].resolution == "1080p" && movie[0].isDownloadable)
        #expect(abs((movie[0].duration ?? 0) - 8160) < 0.01)
        let ep = try await source.variants(for: .episode(seriesID: 1399, season: 1, episode: 1))
        #expect(ep.first?.container == "m3u8")      // MKV goes through server HLS
        #expect(ep.first?.resolution == "4K")
        #expect(ep.first?.displayName == "Show S1E1 · Pilot")
        // Series without a TMDB ID fall back to the matcher.
        #expect(try await source.variants(for: .episode(seriesID: 77, season: 2, episode: 5)).first?.container == "mov")
        #expect(try await source.catalog().count == 3)  // the item without media is skipped
    }

    @Test func resolvesDirectPlayHLSAndSubtitles() async throws {
        let server = FakeJellyfin()
        let source = try await signedIn(server)
        let movie = try await source.variants(for: .movie(tmdbID: 603))[0]
        let r = try await source.resolve(movie)
        let c = try #require(URLComponents(url: r.url, resolvingAgainstBaseURL: false))
        #expect(c.path == "/Videos/m1/stream.mp4")
        let q = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value!) })
        #expect(q["static"] == "true" && q["mediaSourceId"] == "ms1" && q["ApiKey"] == "tok")
        #expect(r.externalSubtitles.count == 1)  // image-based PGS is left to the server
        #expect(r.externalSubtitles[0].url.path == "/Videos/m1/ms1/Subtitles/2/Stream.vtt")
        #expect(r.externalSubtitles[0].format == "vtt")

        let ep = try await source.variants(for: .episode(seriesID: 1399, season: 1, episode: 1))[0]
        #expect(try await source.resolve(ep).url.path == "/Videos/e1/master.m3u8")
        // The token never goes in API request URLs, only the header.
        #expect(server.requests.filter { $0.url!.path == "/Items" }.allSatisfy { !$0.url!.absoluteString.contains("tok") })
    }

    @Test func reportsStoppedPositionInTicks() async throws {
        let server = FakeJellyfin()
        let source = try await signedIn(server)
        await source.reportProgress(itemID: "m1", position: 12.5, isPaused: true, stopped: true)
        let req = try #require(server.requests.last { $0.url!.path == "/Sessions/Playing/Stopped" })
        let body = try #require(try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
        #expect(body["PositionTicks"] as? Int == 125_000_000)
        #expect(body["ItemId"] as? String == "m1")
    }
}
