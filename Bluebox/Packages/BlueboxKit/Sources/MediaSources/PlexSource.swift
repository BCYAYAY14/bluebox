import Domain
import Foundation
import Metadata

/// A Plex Media Server. Movies and episodes are matched by the TMDB and IMDb
/// GUIDs Plex stores (`includeGuids`), falling back to name and year. Files
/// play directly from the server: AVPlayer or VLC by container, no transcode.
///
/// Sign-in is either a server address and token, or plex.tv's PIN flow,
/// which finds the account's server and a connection that answers.
public actor PlexSource: MediaSource {
    public struct Credentials: Codable, Sendable, Equatable {
        public var server: URL
        public var token: String
        public var machineID: String
        public init(server: URL, token: String, machineID: String) {
            self.server = server; self.token = token; self.machineID = machineID
        }
    }

    public nonisolated let id: SourceID
    public nonisolated let kind = SourceKind.plex
    public nonisolated let displayName: String
    public nonisolated let capabilities: SourceCapabilities = [.browse, .play, .download, .externalSubtitles,
                                                               .reportsProgress, .requiresAuthentication]

    let credentials: Credentials
    let http: any HTTPClient
    let clientID: String
    let matcher: MediaMatcher?
    private var items: [Entry]?
    private var loadedAt: Date?
    static let refreshInterval: TimeInterval = 600
    static let plexTV = URL(string: "https://plex.tv")!

    struct Entry: Sendable {
        let ratingKey: String
        let name: String
        let key: MediaKey?
        let partKey: String
        let container: String?
        let resolution: String?
        let size: Int64?
        let duration: TimeInterval?
    }

    public init(id: SourceID, name: String, credentials: Credentials, http: any HTTPClient, clientID: String, matcher: MediaMatcher?) {
        self.id = id; self.displayName = name; self.credentials = credentials
        self.http = http; self.clientID = clientID; self.matcher = matcher
    }

    // MARK: Sign-in

    /// Checks a server address and token (Settings › Network › "Show advanced",
    /// or a browser's `X-Plex-Token`). Returns credentials and the server's name.
    public static func connect(server raw: String, token: String, http: any HTTPClient,
                               clientID: String) async throws -> (Credentials, serverName: String) {
        guard let server = ServerAddress.normalize(raw) else {
            throw SourceError.invalidConfiguration("Enter the server address, like https://plex.example.com:32400")
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let root: Root = try await send(request(server, "/", clientID: clientID, token: token), http: http)
        let machine = root.MediaContainer.machineIdentifier ?? ""
        return (Credentials(server: server, token: token, machineID: machine),
                root.MediaContainer.friendlyName ?? server.host() ?? "Plex")
    }

    /// A plex.tv sign-in code: the user approves it at `authURL`, then `poll`
    /// returns the account token.
    public struct PIN: Sendable, Equatable {
        public let id: Int
        public let code: String
        public let authURL: URL
    }

    public static func startPIN(http: any HTTPClient, clientID: String) async throws -> PIN {
        var req = request(plexTV, "/api/v2/pins", clientID: clientID, token: nil, query: ["strong": "true"])
        req.httpMethod = "POST"
        let pin: PinResult = try await send(req, http: http)
        var c = URLComponents(string: "https://app.plex.tv/auth")!
        // The app reads its parameters from the fragment.
        var q = URLComponents()
        q.queryItems = [URLQueryItem(name: "clientID", value: clientID), URLQueryItem(name: "code", value: pin.code),
                        URLQueryItem(name: "context[device][product]", value: product)]
        c.fragment = "?" + (q.percentEncodedQuery ?? "")
        return PIN(id: pin.id, code: pin.code, authURL: c.url!)
    }

    /// The account token once the PIN is approved, nil while it's waiting.
    public static func checkPIN(_ pin: PIN, http: any HTTPClient, clientID: String) async throws -> String? {
        let result: PinResult = try await send(request(plexTV, "/api/v2/pins/\(pin.id)", clientID: clientID, token: nil), http: http)
        return result.authToken.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The account's first server that answers, with its own access token.
    /// Connections are tried local first, then remote; plain http only on the
    /// local network; relays are skipped (they're slow and capped).
    public static func discoverServer(accountToken: String, http: any HTTPClient,
                                      clientID: String) async throws -> (Credentials, serverName: String) {
        let req = request(plexTV, "/api/v2/resources", clientID: clientID, token: accountToken,
                          query: ["includeHttps": "1", "includeRelay": "0"])
        let resources: [Resource] = try await send(req, http: http)
        let servers = resources.filter { $0.provides.split(separator: ",").contains("server") }
        guard !servers.isEmpty else { throw SourceError.notFound }
        for server in servers.sorted(by: { ($0.owned ?? false) && !($1.owned ?? false) }) {
            let token = server.accessToken ?? accountToken
            let connections = (server.connections ?? []).filter { !($0.relay ?? false) }
                .sorted { ($0.local ?? false) && !($1.local ?? false) }
            for c in connections {
                guard let url = ServerAddress.normalize(c.uri) else { continue }
                if let (creds, _) = try? await connect(server: url.absoluteString, token: token, http: http, clientID: clientID) {
                    return (creds, server.name)
                }
            }
        }
        throw SourceError.unreachable("None of your Plex servers answered from here.")
    }

    // MARK: MediaSource

    public func catalog() async throws -> [MediaVariant] { try await entries().map(variant) }

    public func variants(for key: MediaKey) async throws -> [MediaVariant] {
        try await entries().filter { $0.key == key }.map(variant)
    }

    public func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        guard let e = try await entries().first(where: { $0.ratingKey == variant.id }) else { throw SourceError.notFound }
        return PlaybackResource(variant: variant, url: url(e.partKey, ["download": "0"]), externalSubtitles: await subtitles(e))
    }

    /// Sidecar subtitle files, from the item's full metadata (library listings
    /// leave streams out). Embedded tracks are read by the player itself.
    func subtitles(_ e: Entry) async -> [ExternalSubtitle] {
        guard let full: Container<Metadata> = try? await get("/library/metadata/\(e.ratingKey)", [:]),
              let part = full.MediaContainer.Metadata?.first?.Media?.first?.Part?.first(where: { $0.key == e.partKey }) else { return [] }
        return (part.Stream ?? []).compactMap { s in
            guard s.streamType == 3, let key = s.key, let codec = s.codec?.lowercased(),
                  ["srt", "vtt", "webvtt", "ass", "ssa"].contains(codec) else { return nil }
            return ExternalSubtitle(id: "plex-\(e.ratingKey)-\(key.split(separator: "/").last ?? "")", url: url(key, [:]),
                                    languageCode: s.languageCode, label: s.displayTitle ?? s.language ?? "Subtitles",
                                    format: codec == "webvtt" ? "vtt" : codec)
        }
    }

    public func testConnection() async -> SourceHealth {
        do {
            let all = try await entries(force: true)
            return SourceHealth(ok: true, message: "Connected to \(displayName). \(all.count) videos.")
        } catch {
            return SourceHealth(ok: false, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Reports the position to the server (`/:/timeline`) so Plex's own
    /// resume points and watched marks stay current.
    public func reportProgress(ratingKey: String, position: TimeInterval, duration: TimeInterval?, isPaused: Bool, stopped: Bool) async {
        var q = ["ratingKey": ratingKey, "key": "/library/metadata/\(ratingKey)",
                 "state": stopped ? "stopped" : isPaused ? "paused" : "playing",
                 "time": String(Int(position * 1000))]
        if let duration { q["duration"] = String(Int(duration * 1000)) }
        let req = Self.request(credentials.server, "/:/timeline", clientID: clientID, token: credentials.token, query: q)
        _ = try? await http.send(req)
    }

    // MARK: Library

    func entries(force: Bool = false) async throws -> [Entry] {
        if !force, let items, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.refreshInterval { return items }
        let sections: Container<Directory> = try await get("/library/sections", [:])
        var out: [Entry] = []
        for section in sections.MediaContainer.Directory ?? [] {
            switch section.type {
            case "movie":
                let movies: Container<Metadata> = try await get("/library/sections/\(section.key)/all", ["type": "1", "includeGuids": "1"])
                for m in movies.MediaContainer.Metadata ?? [] {
                    var key = m.movieKey
                    if key == nil, let matcher {
                        key = await matcher(ParsedMediaName(title: m.title, year: m.year, kind: .movie, resolution: nil, container: nil))
                    }
                    if let e = entry(m, name: m.title, key: key) { out.append(e) }
                }
            case "show":
                let shows: Container<Metadata> = try await get("/library/sections/\(section.key)/all", ["type": "2", "includeGuids": "1"])
                let byKey = Dictionary((shows.MediaContainer.Metadata ?? []).map { ($0.ratingKey, $0) }) { a, _ in a }
                let episodes: Container<Metadata> = try await get("/library/sections/\(section.key)/all", ["type": "4"])
                for ep in episodes.MediaContainer.Metadata ?? [] {
                    guard let season = ep.parentIndex, let number = ep.index else { continue }
                    let show = ep.grandparentRatingKey.flatMap { byKey[$0] }
                    var key = show.flatMap { $0.seriesKey(season: season, episode: number) }
                    if key == nil, let matcher, let name = show?.title ?? ep.grandparentTitle {
                        key = await matcher(ParsedMediaName(title: name, year: show?.year, kind: .episode(season: season, episode: number),
                                                            resolution: nil, container: nil))
                    }
                    let name = "\(ep.grandparentTitle ?? show?.title ?? "") S\(season)E\(number) · \(ep.title)"
                    if let e = entry(ep, name: name, key: key) { out.append(e) }
                }
            default: continue  // music and photos
            }
        }
        items = out
        loadedAt = Date()
        return out
    }

    private func entry(_ m: Metadata, name: String, key: MediaKey?) -> Entry? {
        guard let media = m.Media?.first, let part = media.Part?.first, let partKey = part.key else { return nil }
        return Entry(ratingKey: m.ratingKey, name: name, key: key, partKey: partKey,
                     container: (part.container ?? media.container)?.lowercased(),
                     resolution: media.videoResolution.map(Self.resolutionLabel), size: part.size,
                     duration: (part.duration ?? media.duration ?? m.duration).map { TimeInterval($0) / 1000 })
    }

    func variant(_ e: Entry) -> MediaVariant {
        MediaVariant(id: e.ratingKey, sourceID: id, mediaKey: e.key, displayName: e.name, container: e.container,
                     resolution: e.resolution, sizeBytes: e.size, duration: e.duration, location: .remote, isDownloadable: true)
    }

    static func resolutionLabel(_ r: String) -> String {
        switch r.lowercased() { case "4k": "4K"; case "sd": "SD"; default: r.hasSuffix("p") ? r : r + "p" }
    }

    // MARK: HTTP

    /// Media URLs carry the token as `X-Plex-Token`, since players can't add
    /// headers; API calls use the header.
    func url(_ path: String, _ query: [String: String]) -> URL {
        var c = URLComponents(url: credentials.server, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = path.hasPrefix("/") ? path : "/" + path
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "X-Plex-Token", value: credentials.token))
        c.queryItems = items
        return c.url!
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T {
        try await Self.send(Self.request(credentials.server, path, clientID: clientID, token: credentials.token, query: query), http: http)
    }

    static var product: String { "Bluebox" }

    static func request(_ base: URL, _ path: String, clientID: String, token: String?, query: [String: String] = [:]) -> URLRequest {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = path
        c.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var r = URLRequest(url: c.url!)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(clientID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        r.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        r.setValue(JellyfinSource.deviceName, forHTTPHeaderField: "X-Plex-Device")
        if let token { r.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        r.timeoutInterval = 20
        return r
    }

    static func send<T: Decodable>(_ req: URLRequest, http: any HTTPClient) async throws -> T {
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await http.send(req) }
        catch let e as URLError where e.code == .timedOut { throw SourceError.timedOut }
        catch { throw SourceError.unreachable(error.localizedDescription) }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw SourceError.unauthorized
        case 404: throw SourceError.notFound
        default: throw SourceError.unreachable("The server returned \(response.statusCode).")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw SourceError.unreachable("The server sent a response Bluebox couldn't read.") }
    }

    // MARK: Wire format (field names as Plex sends them)

    struct Root: Decodable {
        struct Info: Decodable { let friendlyName: String?; let machineIdentifier: String? }
        let MediaContainer: Info
    }
    struct PinResult: Decodable { let id: Int; let code: String; let authToken: String? }
    struct Resource: Decodable {
        struct Connection: Decodable { let uri: String; let local: Bool?; let relay: Bool? }
        let name: String
        let provides: String
        let owned: Bool?
        let accessToken: String?
        let connections: [Connection]?
    }
    struct Container<T: Decodable>: Decodable {
        struct Inner: Decodable { let Directory: [T]?; let Metadata: [T]? }
        let MediaContainer: Inner
    }
    struct Directory: Decodable { let key: String; let type: String; let title: String? }
    struct Metadata: Decodable {
        let ratingKey: String
        let title: String
        let year: Int?
        let duration: Int?
        let index: Int?
        let parentIndex: Int?
        let grandparentTitle: String?
        let grandparentRatingKey: String?
        let Guid: [GuidRef]?
        let Media: [Media]?
        struct GuidRef: Decodable { let id: String }

        func guid(_ scheme: String) -> String? {
            Guid?.first { $0.id.hasPrefix(scheme + "://") }.map { String($0.id.dropFirst(scheme.count + 3)) }
        }
        var movieKey: MediaKey? {
            if let tmdb = guid("tmdb").flatMap(Int.init) { return .movie(tmdbID: tmdb) }
            return guid("imdb").map { .movie(imdbID: $0) }
        }
        func seriesKey(season: Int, episode: Int) -> MediaKey? {
            if let tmdb = guid("tmdb").flatMap(Int.init) { return .episode(seriesID: tmdb, season: season, episode: episode) }
            return guid("imdb").map { .episode(imdbSeriesID: $0, season: season, episode: episode) }
        }
    }
    struct Media: Decodable {
        let container: String?
        let videoResolution: String?
        let duration: Int?
        let Part: [Part]?
    }
    struct Part: Decodable {
        let key: String?
        let container: String?
        let size: Int64?
        let duration: Int?
        let Stream: [Stream]?
    }
    struct Stream: Decodable {
        let streamType: Int?
        let key: String?
        let codec: String?
        let language: String?
        let languageCode: String?
        let displayTitle: String?
    }
}
