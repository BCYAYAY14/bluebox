import Domain
import Foundation
import Metadata

/// A Jellyfin server the user signs in to. Movies and episodes are matched to
/// the catalog by the TMDB IDs Jellyfin stores, falling back to name and year.
///
/// MP4/MOV/M4V play directly; other containers are remuxed or transcoded by the
/// server to HLS, which AVPlayer handles.
public actor JellyfinSource: MediaSource {
    public struct Credentials: Codable, Sendable, Equatable {
        public var server: URL
        public var userID: String
        public var accessToken: String
        public var username: String
        public init(server: URL, userID: String, accessToken: String, username: String) {
            self.server = server; self.userID = userID; self.accessToken = accessToken; self.username = username
        }
    }

    public nonisolated let id: SourceID
    public nonisolated let kind = SourceKind.jellyfin
    public nonisolated let displayName: String
    public nonisolated let capabilities: SourceCapabilities = [.browse, .search, .play, .download, .externalSubtitles,
                                                               .reportsProgress, .requiresAuthentication]

    let credentials: Credentials
    let http: any HTTPClient
    let deviceID: String
    let matcher: MediaMatcher?
    private var items: [Entry]?
    private var loadedAt: Date?
    static let refreshInterval: TimeInterval = 600
    static let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]

    struct Entry: Sendable {
        let itemID: String
        let mediaSourceID: String
        let name: String
        let key: MediaKey?
        let container: String?
        let resolution: String?
        let size: Int64?
        let duration: TimeInterval?
        let subtitles: [Subtitle]
        struct Subtitle: Sendable { let index: Int; let language: String?; let title: String }
    }

    public init(id: SourceID, name: String, credentials: Credentials, http: any HTTPClient, deviceID: String, matcher: MediaMatcher?) {
        self.id = id; self.displayName = name; self.credentials = credentials
        self.http = http; self.deviceID = deviceID; self.matcher = matcher
    }

    // MARK: Sign-in

    /// Signs in with a username and password. The password isn't stored; the
    /// returned token is (by the caller, in the Keychain).
    public static func signIn(server raw: String, username: String, password: String, http: any HTTPClient,
                              deviceID: String) async throws -> (Credentials, serverName: String) {
        guard let server = normalize(raw) else { throw SourceError.invalidConfiguration("Enter the server address, like https://media.example.com") }
        let publicInfo: PublicInfo = try await send(request(server, "System/Info/Public", deviceID: deviceID), http: http)
        var req = request(server, "Users/AuthenticateByName", deviceID: deviceID)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let auth: AuthResult = try await send(req, http: http)
        return (Credentials(server: server, userID: auth.User.Id, accessToken: auth.AccessToken, username: auth.User.Name ?? username),
                publicInfo.ServerName ?? server.host() ?? "Jellyfin")
    }

    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), let host = u.host(), !host.isEmpty else { return nil }
        if scheme == "https" { return u }
        if scheme == "http", DirectURLSource.isLocalNetworkHost(host) { return u }
        return nil
    }

    // MARK: MediaSource

    public func catalog() async throws -> [MediaVariant] { try await entries().map(variant) }

    public func variants(for key: MediaKey) async throws -> [MediaVariant] {
        try await entries().filter { $0.key == key }.map(variant)
    }

    public func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        guard let e = try await entries().first(where: { $0.itemID == variant.id }) else { throw SourceError.notFound }
        let subs = e.subtitles.map { s in
            ExternalSubtitle(id: "jf-\(e.itemID)-\(s.index)",
                             url: url("Videos/\(e.itemID)/\(e.mediaSourceID)/Subtitles/\(s.index)/Stream.vtt", [:]),
                             languageCode: s.language, label: s.title, format: "vtt")
        }
        return PlaybackResource(variant: variant, url: streamURL(e), externalSubtitles: subs)
    }

    public func testConnection() async -> SourceHealth {
        do {
            let all = try await entries(force: true)
            return SourceHealth(ok: true, message: "Signed in as \(credentials.username). \(all.count) videos.")
        } catch {
            return SourceHealth(ok: false, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Reports the position to the server so Jellyfin's own resume points stay current.
    public func reportProgress(itemID: String, position: TimeInterval, isPaused: Bool, stopped: Bool) async {
        var req = request(credentials.server, stopped ? "Sessions/Playing/Stopped" : "Sessions/Playing/Progress",
                          deviceID: deviceID, token: credentials.accessToken)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: AnyEncodable] = ["ItemId": .init(itemID), "PositionTicks": .init(Int64(position * 10_000_000)),
                                            "IsPaused": .init(isPaused), "CanSeek": .init(true)]
        req.httpBody = try? JSONEncoder().encode(body)
        _ = try? await http.send(req)
    }

    // MARK: Library

    func entries(force: Bool = false) async throws -> [Entry] {
        if !force, let items, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.refreshInterval { return items }
        let series = try await fetchAll(types: "Series", fields: "ProviderIds")
        let seriesTMDB: [String: Int] = Dictionary(series.compactMap { s in s.tmdbID.map { (s.Id, $0) } }) { a, _ in a }
        let seriesNames: [String: (String, Int?)] = Dictionary(series.map { ($0.Id, ($0.Name ?? "", $0.ProductionYear)) }) { a, _ in a }
        let videos = try await fetchAll(types: "Movie,Episode", fields: "ProviderIds,MediaSources,ProductionYear")
        var out: [Entry] = []
        for v in videos {
            guard let source = v.MediaSources?.first else { continue }
            var key: MediaKey?
            if v.type == "Movie" {
                if let id = v.tmdbID { key = .movie(tmdbID: id) }
                else if let matcher, let name = v.Name {
                    key = await matcher(ParsedMediaName(title: name, year: v.ProductionYear, kind: .movie, resolution: nil, container: nil))
                }
            } else if let season = v.ParentIndexNumber, let ep = v.IndexNumber, let sid = v.SeriesId {
                if let tmdb = seriesTMDB[sid] { key = .episode(seriesID: tmdb, season: season, episode: ep) }
                else if let matcher, let (name, year) = seriesNames[sid] {
                    key = await matcher(ParsedMediaName(title: name, year: year, kind: .episode(season: season, episode: ep),
                                                        resolution: nil, container: nil))
                }
            }
            let streams = source.MediaStreams ?? []
            let height = streams.first { $0.type == "Video" }?.Height
            let subs = streams.filter { $0.type == "Subtitle" && ($0.IsTextSubtitleStream ?? false) }.compactMap { s -> Entry.Subtitle? in
                guard let idx = s.Index else { return nil }
                return Entry.Subtitle(index: idx, language: s.Language, title: s.DisplayTitle ?? s.Language ?? "Subtitle \(idx)")
            }
            var name = v.Name ?? "Untitled"
            if v.type == "Episode", let series = v.SeriesName, let s = v.ParentIndexNumber, let e = v.IndexNumber {
                name = "\(series) S\(s)E\(e) · \(name)"
            }
            out.append(Entry(itemID: v.Id, mediaSourceID: source.Id ?? v.Id, name: name, key: key,
                             container: source.Container?.split(separator: ",").first.map { String($0).lowercased() },
                             resolution: height.map(Self.resolutionLabel), size: source.Size,
                             duration: (source.RunTimeTicks ?? v.RunTimeTicks).map { TimeInterval($0) / 10_000_000 },
                             subtitles: subs))
        }
        items = out
        loadedAt = Date()
        return out
    }

    private func fetchAll(types: String, fields: String) async throws -> [Item] {
        var all: [Item] = []
        let page = 500
        while true {
            let q = ["userId": credentials.userID, "recursive": "true", "includeItemTypes": types, "fields": fields,
                     "startIndex": String(all.count), "limit": String(page), "enableImages": "false", "enableUserData": "false"]
            var req = URLRequest(url: url("Items", q, includeKey: false))
            authorize(&req)
            let result: ItemsResult = try await Self.send(req, http: http)
            all += result.Items
            if result.Items.count < page || all.count >= (result.TotalRecordCount ?? Int.max) { return all }
        }
    }

    func variant(_ e: Entry) -> MediaVariant {
        MediaVariant(id: e.itemID, sourceID: id, mediaKey: e.key, displayName: e.name,
                     container: Self.directPlayContainers.contains(e.container ?? "") ? e.container : "m3u8",
                     resolution: e.resolution, sizeBytes: e.size, duration: e.duration, location: .remote,
                     isDownloadable: Self.directPlayContainers.contains(e.container ?? ""))
    }

    func streamURL(_ e: Entry) -> URL {
        if Self.directPlayContainers.contains(e.container ?? "") {
            return url("Videos/\(e.itemID)/stream.\(e.container!)", ["static": "true", "mediaSourceId": e.mediaSourceID,
                                                                     "deviceId": deviceID])
        }
        return url("Videos/\(e.itemID)/master.m3u8", [
            "mediaSourceId": e.mediaSourceID, "deviceId": deviceID, "videoCodec": "h264,hevc", "audioCodec": "aac,ac3,eac3",
            "segmentContainer": "mp4", "playSessionId": UUID().uuidString,
        ])
    }

    static func resolutionLabel(_ h: Int) -> String {
        switch h { case 2000...: "4K"; case 1000...: "1080p"; case 700...: "720p"; default: "\(h)p" }
    }

    // MARK: HTTP

    /// AVPlayer can't add headers to media requests, so media URLs carry the
    /// token as Jellyfin's `ApiKey` query parameter. API calls use the header.
    func url(_ path: String, _ query: [String: String], includeKey: Bool = true) -> URL {
        var c = URLComponents(url: credentials.server.appending(path: path), resolvingAgainstBaseURL: false)!
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if includeKey { items.append(URLQueryItem(name: "ApiKey", value: credentials.accessToken)) }
        c.queryItems = items.isEmpty ? nil : items
        return c.url!
    }

    private func authorize(_ req: inout URLRequest) {
        req.setValue(Self.authHeader(deviceID: deviceID, token: credentials.accessToken), forHTTPHeaderField: "Authorization")
    }

    static func authHeader(deviceID: String, token: String?) -> String {
        var h = #"MediaBrowser Client="Bluebox", Device="\#(deviceName)", DeviceId="\#(deviceID)", Version="1.0""#
        if let token { h += #", Token="\#(token)""# }
        return h
    }

    static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "iOS"
        #endif
    }

    private func request(_ server: URL, _ path: String, deviceID: String, token: String? = nil) -> URLRequest {
        Self.request(server, path, deviceID: deviceID, token: token)
    }

    static func request(_ server: URL, _ path: String, deviceID: String, token: String? = nil) -> URLRequest {
        var r = URLRequest(url: server.appending(path: path))
        r.setValue(authHeader(deviceID: deviceID, token: token), forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
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

    // MARK: Wire format (field names as Jellyfin sends them)

    struct PublicInfo: Decodable { let ServerName: String?; let Version: String? }
    struct AuthResult: Decodable {
        struct User: Decodable { let Id: String; let Name: String? }
        let User: User
        let AccessToken: String
    }
    struct ItemsResult: Decodable { let Items: [Item]; let TotalRecordCount: Int? }
    struct Item: Decodable {
        let Id: String
        let Name: String?
        let type: String
        let ProductionYear: Int?
        let ProviderIds: [String: String]?
        let SeriesId: String?
        let SeriesName: String?
        let ParentIndexNumber: Int?
        let IndexNumber: Int?
        let RunTimeTicks: Int64?
        let MediaSources: [Source]?
        var tmdbID: Int? { (ProviderIds?["Tmdb"] ?? ProviderIds?["tmdb"]).flatMap(Int.init) }

        enum CodingKeys: String, CodingKey {
            case Id, Name, ProductionYear, ProviderIds, SeriesId, SeriesName, ParentIndexNumber, IndexNumber, RunTimeTicks, MediaSources
            case type = "Type"
        }
    }
    struct Source: Decodable {
        let Id: String?
        let Container: String?
        let Size: Int64?
        let RunTimeTicks: Int64?
        let MediaStreams: [Stream]?
    }
    struct Stream: Decodable {
        let type: String?
        let Index: Int?
        let Language: String?
        let DisplayTitle: String?
        let Height: Int?
        let IsTextSubtitleStream: Bool?
        enum CodingKeys: String, CodingKey {
            case Index, Language, DisplayTitle, Height, IsTextSubtitleStream
            case type = "Type"
        }
    }
}

/// Mixed-type JSON body values.
struct AnyEncodable: Encodable, Sendable {
    let encode: @Sendable (Encoder) throws -> Void
    init<T: Encodable & Sendable>(_ v: T) { encode = { try v.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}
