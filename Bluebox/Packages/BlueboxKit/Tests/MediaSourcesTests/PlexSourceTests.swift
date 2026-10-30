import Domain
import Foundation
@testable import MediaSources
import Metadata
import Testing

/// plex.tv's PIN and resources endpoints, and one Plex Media Server at
/// `plex.example.com:32400` with a movie library, a TV library and music.
final class FakePlex: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _pinPolls = 0
    var requests: [URLRequest] { lock.withLock { _requests } }
    static let serverToken = "fake-server-token"
    static let accountToken = "fake-account-token"
    /// PIN polls before the user "approves" it on plex.tv.
    var pollsUntilApproved = 2

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        if request.url?.host() == "unreachable.example.com" { throw URLError(.cannotConnectToHost) }
        let (status, body) = handle(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    private func handle(_ r: URLRequest) -> (Int, Data) {
        let url = r.url!
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard r.value(forHTTPHeaderField: "X-Plex-Client-Identifier") == "dev-1",
              r.value(forHTTPHeaderField: "X-Plex-Product") == "Bluebox" else { return (400, Data()) }
        let token = r.value(forHTTPHeaderField: "X-Plex-Token")
        if url.host() == "plex.tv" {
            switch (r.httpMethod ?? "GET", url.path) {
            case ("POST", "/api/v2/pins"):
                return (201, json(["id": 77, "code": "ABCD"]))
            case ("GET", "/api/v2/pins/77"):
                let polls = lock.withLock { _pinPolls += 1; return _pinPolls }
                return (200, json(["id": 77, "code": "ABCD", "authToken": polls >= pollsUntilApproved ? Self.accountToken as Any : NSNull()]))
            case ("GET", "/api/v2/resources"):
                guard token == Self.accountToken, q["includeRelay"] == "0" else { return (401, Data()) }
                return (200, json([
                    ["name": "Player", "provides": "player", "connections": []],
                    ["name": "Den", "provides": "server", "owned": true, "accessToken": Self.serverToken, "connections": [
                        ["uri": "https://relay.example.com:8443", "local": false, "relay": true],
                        ["uri": "https://plex.example.com:32400", "local": false, "relay": false],
                        ["uri": "https://unreachable.example.com:32400", "local": true, "relay": false],
                    ]],
                ]))
            default: return (404, Data())
            }
        }
        guard url.host() == "plex.example.com", token == Self.serverToken else { return (401, Data()) }
        switch url.path {
        case "/":
            return (200, json(["MediaContainer": ["friendlyName": "Den", "machineIdentifier": "machine-1"]]))
        case "/library/sections":
            return (200, json(["MediaContainer": ["Directory": [["key": "1", "type": "movie", "title": "Films"],
                                                                ["key": "2", "type": "show", "title": "TV"],
                                                                ["key": "3", "type": "artist", "title": "Music"]]]]))
        case "/library/sections/1/all":
            guard q["type"] == "1", q["includeGuids"] == "1" else { return (400, Data()) }
            return (200, json(["MediaContainer": ["Metadata": [
                ["ratingKey": "10", "title": "The Matrix", "year": 1999, "Guid": [["id": "imdb://tt0133093"], ["id": "tmdb://603"]],
                 "Media": [["container": "mkv", "videoResolution": "1080", "duration": 8_160_000,
                            "Part": [["key": "/library/parts/100/1/file.mkv", "size": 5000, "container": "mkv"]]]]],
                ["ratingKey": "11", "title": "Old Film", "year": 1950, "Guid": [["id": "imdb://tt0000011"]],
                 "Media": [["container": "mp4", "videoResolution": "sd", "Part": [["key": "/library/parts/101/1/file.mp4"]]]]],
                ["ratingKey": "12", "title": "Home Video", "year": 2015,
                 "Media": [["container": "mov", "videoResolution": "4k", "Part": [["key": "/library/parts/102/1/file.mov"]]]]],
                ["ratingKey": "13", "title": "No Media"],
            ]]]))
        case "/library/sections/2/all":
            if q["type"] == "2" {
                guard q["includeGuids"] == "1" else { return (400, Data()) }
                return (200, json(["MediaContainer": ["Metadata": [
                    ["ratingKey": "20", "title": "Show", "year": 2011, "Guid": [["id": "tmdb://1399"]]],
                    ["ratingKey": "21", "title": "Obscure Show"],
                ]]]))
            }
            guard q["type"] == "4" else { return (400, Data()) }
            return (200, json(["MediaContainer": ["Metadata": [
                ["ratingKey": "200", "title": "Pilot", "index": 1, "parentIndex": 1, "grandparentTitle": "Show", "grandparentRatingKey": "20",
                 "Media": [["container": "mkv", "videoResolution": "720", "Part": [["key": "/library/parts/200/1/file.mkv"]]]]],
                ["ratingKey": "210", "title": "Ep", "index": 5, "parentIndex": 2, "grandparentTitle": "Obscure Show", "grandparentRatingKey": "21",
                 "Media": [["container": "mp4", "Part": [["key": "/library/parts/210/1/file.mp4"]]]]],
                ["ratingKey": "211", "title": "Special", "grandparentRatingKey": "21",
                 "Media": [["Part": [["key": "/library/parts/211/1/file.mp4"]]]]],
            ]]]))
        case "/library/metadata/10":
            return (200, json(["MediaContainer": ["Metadata": [
                ["ratingKey": "10", "title": "The Matrix", "Media": [["Part": [["key": "/library/parts/100/1/file.mkv", "Stream": [
                    ["streamType": 1, "codec": "h264"],
                    ["streamType": 3, "key": "/library/streams/501", "codec": "srt", "languageCode": "eng", "displayTitle": "English (SRT External)"],
                    ["streamType": 3, "codec": "pgs", "displayTitle": "Embedded PGS"],
                ]]]]]],
            ]]]))
        case "/:/timeline":
            return (200, Data())
        default:
            return (404, Data())
        }
    }
}

@Suite struct PlexSourceTests {
    static let matcher: MediaMatcher = { parsed in
        switch (parsed.title, parsed.kind) {
        case ("Home Video", .movie): .movie(tmdbID: 999)
        case ("Obscure Show", .episode(season: 2, episode: 5)): .episode(seriesID: 555, season: 2, episode: 5)
        default: nil
        }
    }

    func connected(_ server: FakePlex) async throws -> PlexSource {
        let (creds, name) = try await PlexSource.connect(server: "plex.example.com:32400/", token: " \(FakePlex.serverToken) ",
                                                         http: server, clientID: "dev-1")
        #expect(name == "Den")
        #expect(creds.machineID == "machine-1")
        #expect(creds.token == FakePlex.serverToken)
        #expect(creds.server.absoluteString == "https://plex.example.com:32400")
        return PlexSource(id: SourceID("plex"), name: name, credentials: creds, http: server, clientID: "dev-1", matcher: Self.matcher)
    }

    @Test func wrongTokenIsUnauthorized() async {
        await #expect(throws: SourceError.unauthorized) {
            _ = try await PlexSource.connect(server: "https://plex.example.com:32400", token: "wrong-fake-token",
                                             http: FakePlex(), clientID: "dev-1")
        }
    }

    @Test func matchesByPlexGUIDsThenByName() async throws {
        let source = try await connected(FakePlex())
        let all = try await source.catalog()
        // Music, items without media and episodes without numbers are left out.
        #expect(Set(all.map(\.id)) == ["10", "11", "12", "200", "210"])
        // TMDB is preferred, IMDb when it's all there is, then the matcher.
        #expect(try await source.variants(for: .movie(tmdbID: 603)).map(\.id) == ["10"])
        #expect(try await source.variants(for: .movie(imdbID: "tt0000011")).map(\.id) == ["11"])
        #expect(try await source.variants(for: .movie(tmdbID: 999)).map(\.id) == ["12"])
        #expect(try await source.variants(for: .episode(seriesID: 1399, season: 1, episode: 1)).map(\.id) == ["200"])
        #expect(try await source.variants(for: .episode(seriesID: 555, season: 2, episode: 5)).map(\.id) == ["210"])
        let matrix = try #require(all.first { $0.id == "10" })
        #expect(matrix.resolution == "1080p")
        #expect(matrix.container == "mkv")
        #expect(matrix.sizeBytes == 5000)
        #expect(matrix.duration == 8160)
        #expect(all.first { $0.id == "12" }?.resolution == "4K")
        #expect(all.first { $0.id == "200" }?.displayName == "Show S1E1 · Pilot")
    }

    @Test func directPlayURLAndExternalSubtitles() async throws {
        let source = try await connected(FakePlex())
        let matrix = try #require(try await source.variants(for: .movie(tmdbID: 603)).first)
        let resource = try await source.resolve(matrix)
        let c = try #require(URLComponents(url: resource.url, resolvingAgainstBaseURL: false))
        #expect(c.host == "plex.example.com" && c.port == 32400 && c.path == "/library/parts/100/1/file.mkv")
        #expect(c.queryItems?.first { $0.name == "X-Plex-Token" }?.value == FakePlex.serverToken)
        // Logs never see the token.
        #expect(!Redactor.redact(resource.url).contains(FakePlex.serverToken))
        #expect(resource.externalSubtitles.count == 1)
        let sub = try #require(resource.externalSubtitles.first)
        #expect(sub.format == "srt" && sub.languageCode == "eng")
        #expect(sub.url.path == "/library/streams/501")
    }

    @Test func reportsProgressToTheServer() async throws {
        let server = FakePlex()
        let source = try await connected(server)
        await source.reportProgress(ratingKey: "10", position: 61.5, duration: 8160, isPaused: true, stopped: true)
        let timeline = try #require(server.requests.last { $0.url?.path == "/:/timeline" })
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: timeline.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["state"] == "stopped" && q["time"] == "61500" && q["duration"] == "8160000" && q["ratingKey"] == "10")
    }

    @Test func pinSignInFindsAServerThatAnswers() async throws {
        let server = FakePlex()
        let pin = try await PlexSource.startPIN(http: server, clientID: "dev-1")
        #expect(pin.code == "ABCD")
        #expect(pin.authURL.absoluteString.hasPrefix("https://app.plex.tv/auth#?"))
        #expect(pin.authURL.absoluteString.contains("code=ABCD") && pin.authURL.absoluteString.contains("clientID=dev-1"))
        #expect(try await PlexSource.checkPIN(pin, http: server, clientID: "dev-1") == nil)
        let account = try #require(try await PlexSource.checkPIN(pin, http: server, clientID: "dev-1"))
        let (creds, name) = try await PlexSource.discoverServer(accountToken: account, http: server, clientID: "dev-1")
        #expect(name == "Den")
        // The relay is skipped, the unreachable address tried and passed over, and the server's own token kept.
        #expect(creds.server.absoluteString == "https://plex.example.com:32400")
        #expect(creds.token == FakePlex.serverToken)
        #expect(!server.requests.contains { $0.url?.host() == "relay.example.com" })
    }

    @Test func accountWithoutServersIsNotFound() async {
        final class NoServers: HTTPClient, @unchecked Sendable {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        await #expect(throws: SourceError.notFound) {
            _ = try await PlexSource.discoverServer(accountToken: FakePlex.accountToken, http: NoServers(), clientID: "dev-1")
        }
    }
}
