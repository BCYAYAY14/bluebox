import Domain
import Foundation
@testable import Metadata
import Testing

final class FakeOpenSubtitles: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var quotaLeft = 1

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(r) }
        let (status, body) = lock.withLock { handle(r) }
        return (body, HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    private func handle(_ r: URLRequest) -> (Int, Data) {
        if r.url!.host() == "dl.test" { return (200, Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8)) }
        guard r.value(forHTTPHeaderField: "Api-Key") == "key", r.value(forHTTPHeaderField: "User-Agent") == "Bluebox v1.0" else { return (401, Data()) }
        switch r.url!.path {
        case "/api/v1/login":
            return (200, json(["token": "jwt", "base_url": "vip-api.opensubtitles.com"]))
        case "/api/v1/subtitles":
            return (200, json(["data": [
                ["attributes": ["language": "en", "release": "Popular.MT", "download_count": 9000, "machine_translated": true,
                                "files": [["file_id": 3, "file_name": "a.srt"]]]],
                ["attributes": ["language": "en", "release": "Good", "download_count": 500, "files": [["file_id": 1]]]],
                ["attributes": ["language": "en", "release": "Better", "download_count": 800, "hearing_impaired": true, "files": [["file_id": 2]]]],
                ["attributes": ["language": "en", "release": "No files", "files": []]],
            ]]))
        case "/api/v1/download":
            guard quotaLeft > 0 else { return (406, json(["reset_time_utc": "2026-10-28T00:00:00Z"])) }
            quotaLeft -= 1
            return (200, json(["link": "https://dl.test/file.srt", "remaining": quotaLeft]))
        default: return (404, Data())
        }
    }
}

@Suite struct OpenSubtitlesTests {
    @Test func searchesByTMDBIDsAndRanksHumanSubtitlesFirst() async throws {
        let server = FakeOpenSubtitles()
        let s = OpenSubtitlesService(apiKey: "key", http: server)
        let results = try await s.search(.movie(tmdbID: 603), languages: ["EN", "es"])
        #expect(results.map(\.release) == ["Better", "Good", "Popular.MT"])
        #expect(results[0].hearingImpaired)
        let q = URLComponents(url: server.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(q.contains(URLQueryItem(name: "tmdb_id", value: "603")))
        #expect(q.contains(URLQueryItem(name: "languages", value: "en,es")))

        _ = try await s.search(.episode(seriesID: 1399, season: 2, episode: 3), languages: [])
        let q2 = URLComponents(url: server.requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(q2.contains(URLQueryItem(name: "parent_tmdb_id", value: "1399")))
        #expect(q2.contains(URLQueryItem(name: "season_number", value: "2")))
        #expect(q2.contains(URLQueryItem(name: "episode_number", value: "3")))
        #expect(try await s.search(MediaKey(rawValue: "local:abc"), languages: []).isEmpty)
    }

    @Test func downloadsThenReportsQuota() async throws {
        let server = FakeOpenSubtitles()
        let s = OpenSubtitlesService(apiKey: "key", http: server)
        let r = try await s.search(.movie(tmdbID: 603), languages: ["en"])[0]
        let data = try await s.download(r)
        #expect(String(decoding: data, as: UTF8.self).contains("Hi"))
        let body = try JSONSerialization.jsonObject(with: server.requests.last { $0.url!.path == "/api/v1/download" }!.httpBody!) as! [String: Any]
        #expect(body["file_id"] as? Int == 2)
        await #expect(throws: SubtitleSearchError.quotaExceeded(resetsAt: "2026-10-28T00:00:00Z")) { try await s.download(r) }
    }

    @Test func signInSwitchesToTheAccountHostAndSendsTheToken() async throws {
        let server = FakeOpenSubtitles()
        let s = OpenSubtitlesService(apiKey: "key", http: server)
        let session = try await s.signIn(username: "u", password: "p")
        #expect(session == .init(token: "jwt", baseHost: "vip-api.opensubtitles.com"))
        _ = try await s.search(.movie(tmdbID: 603), languages: [])
        let last = server.requests.last!
        #expect(last.url!.host() == "vip-api.opensubtitles.com")
        #expect(last.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
    }

    @Test func wrongKeyIsUnauthorized() async {
        let s = OpenSubtitlesService(apiKey: "nope", http: FakeOpenSubtitles())
        await #expect(throws: SubtitleSearchError.unauthorized) { _ = try await s.search(.movie(tmdbID: 1), languages: []) }
    }
}
