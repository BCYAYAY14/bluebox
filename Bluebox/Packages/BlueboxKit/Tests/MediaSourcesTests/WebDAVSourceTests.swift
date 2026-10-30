import CryptoKit
import Domain
import Foundation
@testable import MediaSources
import Metadata
import Testing

/// A WebDAV server holding a small tree under `/dav/Movies/`. It answers
/// PROPFIND with a `207 Multi-Status` body and GET with the file's bytes, and
/// wants Basic auth, or Digest when `digestOnly` is set.
final class FakeWebDAV: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    var password = "not-a-real-password"
    var digestOnly = false
    /// Folders answering 403, to check one bad folder doesn't hide the rest.
    var forbidden: Set<String> = []
    let nonce = "fake-nonce-1"

    /// Paths (decoded) to file sizes; folders end in "/".
    let tree: [String: Int64] = [
        "/dav/Movies/": 0,
        "/dav/Movies/Tears.of.Steel.2012.1080p.mkv": 1000,
        "/dav/Movies/Tears.of.Steel.2012.1080p.en.srt": 10,
        "/dav/Movies/Tears.of.Steel.2012.1080p.sample.mkv": 5,
        "/dav/Movies/notes.txt": 3,
        "/dav/Movies/.hidden.mkv": 4,
        "/dav/Movies/Spaced Folder/": 0,
        "/dav/Movies/Spaced Folder/Big Buck Bunny (2008).mp4": 2000,
        "/dav/Movies/Shows/": 0,
        "/dav/Movies/Shows/Season 1/": 0,
        "/dav/Movies/Shows/Season 1/The.Show.S01E02.720p.mkv": 3000,
        "/dav/Movies/Shows/@eaDir/": 0,
        "/dav/Movies/Shows/@eaDir/thumb.mkv": 1,
        "/dav/Movies/Locked/": 0,
        "/dav/Movies/Locked/Secret.mkv": 1,
    ]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, headers, body) = handle(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    private func authorized(_ r: URLRequest) -> Bool {
        let auth = r.value(forHTTPHeaderField: "Authorization") ?? ""
        if digestOnly {
            let p = HTTPLogin.parameters(String(auth.dropFirst("Digest ".count)))
            guard auth.hasPrefix("Digest "), p["nonce"] == nonce, let uri = p["uri"], let nc = p["nc"], let cnonce = p["cnonce"] else { return false }
            let md5 = { (s: String) in Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
            let ha1 = md5("brian:Fake NAS:\(password)"), ha2 = md5("\(r.httpMethod ?? "GET"):\(uri)")
            return p["response"] == md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
        }
        return auth == "Basic " + Data("brian:\(password)".utf8).base64EncodedString()
    }

    private func handle(_ r: URLRequest) -> (Int, [String: String], Data) {
        guard authorized(r) else {
            let challenge = digestOnly ? #"Digest realm="Fake NAS", nonce="\#(nonce)", qop="auth", algorithm=MD5"# : #"Basic realm="Fake NAS""#
            return (401, ["WWW-Authenticate": challenge], Data())
        }
        let path = r.url!.path(percentEncoded: false)
        let folder = path.hasSuffix("/") ? path : path + "/"
        if forbidden.contains(folder) { return (403, [:], Data()) }
        switch r.httpMethod {
        case "PROPFIND":
            guard tree[folder] != nil else { return tree[path] != nil ? (207, [:], multistatus([path])) : (404, [:], Data()) }
            var paths = [folder]
            if r.value(forHTTPHeaderField: "Depth") == "1" {
                paths += tree.keys.filter { key in
                    guard key != folder, key.hasPrefix(folder) else { return false }
                    let rest = key.dropFirst(folder.count).dropLast(key.hasSuffix("/") ? 1 : 0)
                    return !rest.contains("/")
                }.sorted()
            }
            var body = multistatus(paths)
            // A server may list something elsewhere; the login mustn't follow it.
            if folder == "/dav/Movies/" {
                body = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "</D:multistatus>", with: """
                    <D:response><D:href>https://elsewhere.example.net/dav/Movies/Trap.mkv</D:href>\
                    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>9</D:getcontentlength></D:prop></D:propstat></D:response>
                    </D:multistatus>
                    """).utf8)
            }
            return (207, ["Content-Type": "application/xml"], body)
        case "GET":
            guard tree[path] != nil else { return (404, [:], Data()) }
            return (200, [:], Data(path.hasSuffix(".srt") ? "1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8 : "video".utf8))
        default:
            return (405, [:], Data())
        }
    }

    private func multistatus(_ paths: [String]) -> Data {
        let responses = paths.map { p in
            let href = p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            let type = p.hasSuffix("/") ? "<D:collection/>" : ""
            let length = p.hasSuffix("/") ? "" : "<D:getcontentlength>\(tree[p] ?? 0)</D:getcontentlength>"
            return "<D:response><D:href>\(href)</D:href><D:propstat><D:prop><D:resourcetype>\(type)</D:resourcetype>\(length)</D:prop>"
                + "<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
        }
        return Data((#"<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">"#
                     + responses.joined() + "</D:multistatus>").utf8)
    }
}

@Suite struct WebDAVSourceTests {
    static let matcher: MediaMatcher = { parsed in
        switch parsed.title {
        case "Tears of Steel": .movie(tmdbID: 133701)
        case "The Show": .episode(seriesID: 42, season: 1, episode: 2)
        default: nil
        }
    }

    func connected(_ server: FakeWebDAV, matcher: MediaMatcher? = WebDAVSourceTests.matcher) async throws -> WebDAVSource {
        let (creds, name) = try await WebDAVSource.connect(server: "nas.example.com/dav/Movies/", username: "brian",
                                                           password: server.password, http: server)
        #expect(name == "Movies")
        #expect(creds.server.absoluteString == "https://nas.example.com/dav/Movies")
        return WebDAVSource(id: SourceID("dav"), name: name, credentials: creds, http: server, matcher: matcher)
    }

    @Test func wrongPasswordIsUnauthorized() async {
        let server = FakeWebDAV()
        await #expect(throws: SourceError.unauthorized) {
            _ = try await WebDAVSource.connect(server: "https://nas.example.com/dav/Movies", username: "brian",
                                               password: "wrong-fake-password", http: server)
        }
    }

    @Test func rejectsPlainHTTPOutsideTheLocalNetwork() async {
        await #expect(throws: SourceError.self) {
            _ = try await WebDAVSource.connect(server: "http://nas.example.com/dav", username: "brian", password: "x", http: FakeWebDAV())
        }
        #expect(ServerAddress.normalize("http://192.168.1.20:5005/dav") != nil)
    }

    @Test func missingFolderIsNotFound() async {
        await #expect(throws: SourceError.notFound) {
            _ = try await WebDAVSource.connect(server: "https://nas.example.com/dav/Nope", username: "brian",
                                               password: "not-a-real-password", http: FakeWebDAV())
        }
    }

    @Test func listsVideosInNestedFoldersAndSkipsTheRest() async throws {
        let server = FakeWebDAV()
        server.forbidden = ["/dav/Movies/Locked/"]
        let source = try await connected(server)
        let names = try await source.catalog().map(\.displayName).sorted()
        // No subtitles, text, hidden files, samples, NAS thumbnails, other servers, or the unreadable folder.
        #expect(names == ["Big Buck Bunny (2008)", "Tears.of.Steel.2012.1080p", "The.Show.S01E02.720p"])
        let tears = try await source.variants(for: .movie(tmdbID: 133701))
        #expect(tears.count == 1)
        #expect(tears.first?.sizeBytes == 1000)
        #expect(tears.first?.resolution == "1080p")
        #expect(tears.first?.container == "mkv")
        #expect(try await source.variants(for: .episode(seriesID: 42, season: 1, episode: 2)).count == 1)
        #expect(!server.requests.contains { $0.url?.host() == "elsewhere.example.net" })
        // Every request carried the login, only to the server it was typed for.
        #expect(server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true })
    }

    @Test func scansAreReusedAndMatchesKept() async throws {
        let server = FakeWebDAV()
        let lookups = Switch()
        let source = WebDAVSource(id: SourceID("dav"), name: "Movies",
                                  credentials: .init(server: URL(string: "https://nas.example.com/dav/Movies")!,
                                                     username: "brian", password: server.password),
                                  http: server) { parsed in
            lookups.called()
            return await WebDAVSourceTests.matcher(parsed)
        }
        await source.setClock { lookups.now }
        _ = try await source.catalog()
        let requests = server.requests.count, calls = lookups.calls
        _ = try await source.catalog()
        #expect(server.requests.count == requests)
        // Once stale, only the unmatched files (Big Buck Bunny, Secret) are looked up again.
        lookups.now = lookups.now.addingTimeInterval(WebDAVSource.refreshInterval + 1)
        _ = try await source.catalog()
        #expect(server.requests.count > requests)
        #expect(lookups.calls == calls + 2)
    }

    @Test func playbackURLCarriesNoPasswordButTheHeaderDoes() async throws {
        let server = FakeWebDAV()
        let source = try await connected(server)
        let variant = try #require(try await source.variants(for: .movie(tmdbID: 133701)).first)
        let resource = try await source.resolve(variant)
        #expect(resource.url.absoluteString == "https://nas.example.com/dav/Movies/Tears.of.Steel.2012.1080p.mkv")
        #expect(resource.url.user == nil && resource.url.password == nil)
        #expect(resource.httpHeaders["Authorization"] == "Basic " + Data("brian:not-a-real-password".utf8).base64EncodedString())
        #expect(Redactor.redact(headers: resource.httpHeaders)["Authorization"] == "REDACTED")
        // The sidecar subtitle was fetched with the login into a local file.
        let sub = try #require(resource.externalSubtitles.first)
        #expect(sub.url.isFileURL)
        #expect(sub.languageCode == "en")
        #expect(try String(contentsOf: sub.url, encoding: .utf8).contains("Hello"))
    }

    @Test func folderNamesWithSpacesResolve() async throws {
        let source = try await connected(FakeWebDAV())
        let bunny = try #require(try await source.catalog().first { $0.displayName.hasPrefix("Big Buck") })
        let resource = try await source.resolve(bunny)
        #expect(resource.url.path(percentEncoded: false) == "/dav/Movies/Spaced Folder/Big Buck Bunny (2008).mp4")
    }

    @Test func answersADigestChallenge() async throws {
        let server = FakeWebDAV()
        server.digestOnly = true
        let source = try await connected(server)
        #expect(try await source.catalog().count == 4)
        #expect(server.requests.last?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Digest ") == true)
    }

    /// RFC 2617 §3.5's worked example.
    @Test func digestMatchesTheRFCExample() throws {
        let challenge = try #require(HTTPLogin.digestChallenge(in: #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#))
        let header = try #require(HTTPLogin(username: "Mufasa", password: "Circle Of Life")
            .digestHeader(challenge, method: "GET", uri: "/dir/index.html", count: 1, cnonce: "0a4f113b"))
        #expect(header.contains(#"response="6629fae49393a05397450978507c4ef1""#))
        #expect(header.contains(#"opaque="5ccc069c403ebaf9f0171e9517f40e41""#))
    }
}
