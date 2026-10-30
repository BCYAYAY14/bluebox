import CryptoKit
import Domain
import Foundation
import Metadata

/// Video files in a folder on a WebDAV server (a NAS, Nextcloud, nginx or
/// Apache). Folders are listed with PROPFIND one level at a time, down to a
/// depth and folder limit, and files are matched by name like local folders.
///
/// The password lives in the Keychain. Players get the file's URL with a
/// Basic `Authorization` header; servers that ask for Digest get Digest on
/// listings, and the player answers their challenge from the same login.
public actor WebDAVSource: MediaSource {
    public struct Credentials: Sendable, Equatable {
        public var server: URL
        public var username: String
        public var password: String
        public init(server: URL, username: String, password: String) {
            self.server = server; self.username = username; self.password = password
        }
    }

    public nonisolated let id: SourceID
    public nonisolated let kind = SourceKind.webdav
    public nonisolated let displayName: String
    public nonisolated let capabilities: SourceCapabilities = [.browse, .play, .download, .externalSubtitles, .requiresAuthentication]

    let credentials: Credentials
    let http: any HTTPClient
    let matcher: MediaMatcher?
    private var digest: HTTPLogin.DigestChallenge?
    private var nonceCount = 0
    private var scanned: [Entry]?
    private var scannedAt: Date?
    /// Catalog matches by path, kept across rescans like local folders.
    private var matches: [String: MediaKey] = [:]
    private var now: @Sendable () -> Date = { Date() }

    static let refreshInterval: TimeInterval = 600
    static let unmatchedRetryInterval: TimeInterval = 300
    static let maxDepth = 8
    static let maxFolders = 2000
    static let maxFiles = 20_000
    static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]
    /// NAS housekeeping folders that never hold videos worth listing.
    static let skippedFolders: Set<String> = ["@eadir", "#recycle", "#snapshot", "$recycle.bin", "lost+found"]

    struct Entry: Sendable {
        let id: String
        let url: URL
        let name: String
        let size: Int64?
        let key: MediaKey?
        let resolution: String?
        let subtitles: [URL]
    }

    public init(id: SourceID, name: String, credentials: Credentials, http: any HTTPClient, matcher: MediaMatcher?) {
        self.id = id; self.displayName = name; self.credentials = credentials; self.http = http; self.matcher = matcher
    }

    /// Tests: replaces the clock.
    func setClock(_ now: @escaping @Sendable () -> Date) { self.now = now }

    /// Checks the address and login by listing the folder. Returns the
    /// credentials to keep (the password goes in the Keychain) and a name.
    public static func connect(server raw: String, username: String, password: String,
                               http: any HTTPClient) async throws -> (Credentials, name: String) {
        guard let server = ServerAddress.normalize(raw) else {
            throw SourceError.invalidConfiguration("Enter the folder's address, like https://nas.example.com/dav/Movies")
        }
        let creds = Credentials(server: server, username: username, password: password)
        let probe = WebDAVSource(id: SourceID("probe"), name: "", credentials: creds, http: http, matcher: nil)
        _ = try await probe.list(directory(server), depth: "0")
        let last = server.lastPathComponent
        return (creds, last.isEmpty || last == "/" ? server.host() ?? "WebDAV" : last)
    }

    // MARK: MediaSource

    public func catalog() async throws -> [MediaVariant] { try await entries().map(variant) }

    public func variants(for key: MediaKey) async throws -> [MediaVariant] {
        try await entries().filter { $0.key == key }.map(variant)
    }

    public func rescan() async throws -> [MediaVariant] {
        scanned = nil
        matches = [:]
        return try await catalog()
    }

    public func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        if scanned == nil { _ = try await entries() }
        guard let e = scanned?.first(where: { $0.id == variant.id }) else { throw SourceError.notFound }
        return PlaybackResource(variant: variant, url: e.url, httpHeaders: playbackHeaders,
                                externalSubtitles: await downloadSubtitles(e))
    }

    public func testConnection() async -> SourceHealth {
        do {
            let all = try await entries(force: true)
            return SourceHealth(ok: true, message: "Connected as \(credentials.username). \(all.count) video\(all.count == 1 ? "" : "s").")
        } catch {
            return SourceHealth(ok: false, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Players can't answer a login prompt, so the login goes with the URL:
    /// AVPlayer sends the header, VLC turns it into the URL's user and password.
    var playbackHeaders: [String: String] {
        ["Authorization": HTTPLogin(username: credentials.username, password: credentials.password).basicHeader]
    }

    // MARK: Scanning

    func entries(force: Bool = false) async throws -> [Entry] {
        if !force, let scanned, let scannedAt {
            let age = now().timeIntervalSince(scannedAt)
            let allMatched = matcher == nil || !scanned.contains { $0.key == nil }
            if age < (allMatched ? Self.refreshInterval : Self.unmatchedRetryInterval) { return scanned }
        }
        let root = Self.directory(credentials.server)
        let rootPath = root.path(percentEncoded: false)
        var queue: [(URL, Int)] = [(root, 0)]
        var folders = 0
        var videos: [Listing] = []
        var subtitlesByFolder: [String: [URL]] = [:]
        while !queue.isEmpty, videos.count < Self.maxFiles {
            try Task.checkCancellation()
            let (dir, depth) = queue.removeFirst()
            let listing: [Listing]
            do { listing = try await list(dir, depth: "1") } catch {
                if dir == root { throw error }
                continue  // one unreadable folder doesn't hide the rest
            }
            for item in listing {
                let name = item.url.lastPathComponent
                if name.hasPrefix(".") { continue }
                if item.isDirectory {
                    guard depth < Self.maxDepth, folders < Self.maxFolders,
                          !Self.skippedFolders.contains(name.lowercased()) else { continue }
                    folders += 1
                    queue.append((Self.directory(item.url), depth + 1))
                    continue
                }
                let ext = item.url.pathExtension.lowercased()
                if LocalFolderSource.videoExtensions.contains(ext), !name.lowercased().contains("sample") {
                    videos.append(item)
                } else if Self.subtitleExtensions.contains(ext) {
                    subtitlesByFolder[item.url.deletingLastPathComponent().path(percentEncoded: false), default: []].append(item.url)
                }
            }
        }
        videos.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        var out: [Entry] = []
        for v in videos.prefix(Self.maxFiles) {
            try Task.checkCancellation()
            let filePath = v.url.path(percentEncoded: false)
            let relative = filePath.hasPrefix(rootPath) ? String(filePath.dropFirst(rootPath.count)) : filePath
            let parsed = MediaNameParser.parse(filename: v.url.lastPathComponent)
            var key = matches[relative]
            if key == nil, let matcher {
                key = await matcher(parsed)
                if let key { matches[relative] = key }
            }
            let siblings = subtitlesByFolder[v.url.deletingLastPathComponent().path(percentEncoded: false)] ?? []
            out.append(Entry(id: Self.variantID(relative), url: v.url, name: v.url.deletingPathExtension().lastPathComponent,
                             size: v.size, key: key, resolution: parsed.resolution,
                             subtitles: Self.sidecars(of: v.url, among: siblings)))
        }
        scanned = out
        scannedAt = now()
        return out
    }

    func variant(_ e: Entry) -> MediaVariant {
        MediaVariant(id: e.id, sourceID: id, mediaKey: e.key, displayName: e.name, container: e.url.pathExtension.lowercased(),
                     resolution: e.resolution, sizeBytes: e.size, location: .remote, isDownloadable: true)
    }

    static func variantID(_ relativePath: String) -> String {
        SHA256.hash(data: Data(relativePath.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `Movie.mkv` + `Movie.srt` / `Movie.en.srt`, as for local folders.
    static func sidecars(of video: URL, among subtitles: [URL]) -> [URL] {
        let stem = video.deletingPathExtension().lastPathComponent
        return subtitles.filter {
            let name = $0.deletingPathExtension().lastPathComponent
            return name == stem || name.hasPrefix(stem + ".")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The subtitle loader reads plain URLs, so sidecar files are fetched
    /// with the login into a temporary folder first. Failures are skipped.
    func downloadSubtitles(_ e: Entry) async -> [ExternalSubtitle] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "webdav-subtitles/\(id.rawValue)/\(e.id)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = e.url.deletingPathExtension().lastPathComponent
        var out: [ExternalSubtitle] = []
        for url in e.subtitles.prefix(8) {
            guard let (data, response) = try? await send(URLRequest(url: url)), (200..<300).contains(response.statusCode),
                  data.count < 4_000_000 else { continue }
            let file = folder.appending(path: url.lastPathComponent)
            guard (try? data.write(to: file)) != nil else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let lang = name == stem ? nil : String(name.dropFirst(stem.count + 1)).split(separator: ".").first.map(String.init)
            let label = lang.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? url.lastPathComponent
            out.append(ExternalSubtitle(id: "dav-\(e.id)-\(url.lastPathComponent)", url: file, languageCode: lang,
                                        label: label, format: url.pathExtension.lowercased()))
        }
        return out
    }

    // MARK: WebDAV

    struct Listing: Sendable, Equatable {
        let url: URL
        let isDirectory: Bool
        let size: Int64?
    }

    /// Folders are addressed with a trailing slash, which servers expect.
    static func directory(_ url: URL) -> URL {
        url.absoluteString.hasSuffix("/") ? url : URL(string: url.absoluteString + "/") ?? url
    }

    static let propfindBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>
        """.utf8)

    /// The folder's children (`depth` "1") or the folder itself ("0").
    func list(_ dir: URL, depth: String) async throws -> [Listing] {
        var req = URLRequest(url: dir)
        req.httpMethod = "PROPFIND"
        req.setValue(depth, forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.propfindBody
        req.timeoutInterval = 30
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await send(req) }
        catch let e as URLError where e.code == .timedOut { throw SourceError.timedOut }
        catch let e as SourceError { throw e }
        catch { throw SourceError.unreachable(error.localizedDescription) }
        switch response.statusCode {
        case 207, 200: break
        case 401, 403: throw SourceError.unauthorized
        case 404: throw SourceError.notFound
        case 405, 501: throw SourceError.invalidConfiguration("That address isn't a WebDAV folder.")
        default: throw SourceError.unreachable("The server returned \(response.statusCode).")
        }
        guard let parsed = MultistatusParser.parse(data, base: dir) else {
            throw SourceError.unreachable("The server sent a response Bluebox couldn't read.")
        }
        // The login only ever goes to the server it was typed for.
        let sameServer = parsed.filter { $0.url.host() == dir.host() && $0.url.scheme == dir.scheme && $0.url.port == dir.port }
        if depth == "0" { return sameServer }
        let own = Self.comparablePath(dir)
        return sameServer.filter { Self.comparablePath($0.url) != own }
    }

    static func comparablePath(_ url: URL) -> String {
        var p = url.path(percentEncoded: false)
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Sends with the login, switching to Digest when the server asks for it.
    func send(_ base: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = base
        authorize(&req)
        let (data, response) = try await http.send(req)
        guard response.statusCode == 401,
              let header = response.value(forHTTPHeaderField: "WWW-Authenticate"),
              let challenge = HTTPLogin.digestChallenge(in: header),
              challenge.nonce != digest?.nonce else { return (data, response) }
        digest = challenge
        nonceCount = 0
        req = base
        authorize(&req)
        return try await http.send(req)
    }

    private func authorize(_ req: inout URLRequest) {
        let login = HTTPLogin(username: credentials.username, password: credentials.password)
        if let digest, let url = req.url {
            nonceCount += 1
            let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let uri = (c?.percentEncodedPath ?? url.path) + (c?.percentEncodedQuery.map { "?" + $0 } ?? "")
            let cnonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
            if let h = login.digestHeader(digest, method: req.httpMethod ?? "GET", uri: uri, count: nonceCount, cnonce: String(cnonce)) {
                req.setValue(h, forHTTPHeaderField: "Authorization")
                return
            }
        }
        req.setValue(login.basicHeader, forHTTPHeaderField: "Authorization")
    }
}

/// Reads a WebDAV `207 Multi-Status` body: each `response`'s `href`, whether
/// it's a collection, and its length. Namespace prefixes vary by server.
final class MultistatusParser: NSObject, XMLParserDelegate {
    private let base: URL
    private var out: [WebDAVSource.Listing] = []
    private var text = ""
    private var href: String?
    private var isCollection = false
    private var length: Int64?
    private var inResponse = false

    private init(base: URL) { self.base = base }

    static func parse(_ data: Data, base: URL) -> [WebDAVSource.Listing]? {
        let delegate = MultistatusParser(base: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        return parser.parse() ? delegate.out : nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "response": inResponse = true; href = nil; isCollection = false; length = nil
        case "collection" where inResponse: isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href" where inResponse && href == nil: href = value
        case "getcontentlength" where inResponse: length = Int64(value)
        case "response":
            inResponse = false
            // hrefs are usually absolute paths, sometimes full URLs; both resolve against the folder.
            if let href, let url = URL(string: href, relativeTo: base)?.absoluteURL
                ?? href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap({ URL(string: $0, relativeTo: base)?.absoluteURL }) {
                out.append(.init(url: url, isDirectory: isCollection, size: length))
            }
        default: break
        }
        text = ""
    }
}
