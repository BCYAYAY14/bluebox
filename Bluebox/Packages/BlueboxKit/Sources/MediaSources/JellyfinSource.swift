import Domain
import Foundation
import Metadata

/// A Jellyfin or Emby server the user signs in to. The two share an API
/// (Jellyfin began as a fork of Emby); `Flavour` covers where they differ.
/// Movies and episodes are matched to the catalog by the TMDB IDs the server
/// stores, falling back to name and year.
///
/// MP4/MOV/M4V play directly; other containers are remuxed or transcoded by the
/// server to HLS, which AVPlayer handles.
///
/// Progress goes both ways: playback is reported to the server, and the
/// server's watched state and resume points (from its other apps) come back
/// through `watchProgress()` and the progress handler.
public actor JellyfinSource: MediaSource {
    public enum Flavour: String, Codable, Sendable, Identifiable {
        case jellyfin, emby
        public var id: String { rawValue }
        public var displayName: String { self == .emby ? "Emby" : "Jellyfin" }
        var kind: SourceKind { self == .emby ? .emby : .jellyfin }
        /// The query parameter that carries the token on media URLs.
        var tokenParameter: String { self == .emby ? "api_key" : "ApiKey" }
    }

    public struct Credentials: Codable, Sendable, Equatable {
        /// Includes `/emby` for Emby servers that only answer there.
        public var server: URL
        public var userID: String
        public var accessToken: String
        public var username: String
        public var flavour: Flavour
        public init(server: URL, userID: String, accessToken: String, username: String, flavour: Flavour = .jellyfin) {
            self.server = server; self.userID = userID; self.accessToken = accessToken; self.username = username
            self.flavour = flavour
        }
    }

    public nonisolated let id: SourceID
    public nonisolated let flavour: Flavour
    public nonisolated var kind: SourceKind { flavour.kind }
    public nonisolated let displayName: String
    public nonisolated let capabilities: SourceCapabilities = [.browse, .search, .play, .download, .externalSubtitles,
                                                               .reportsProgress, .requiresAuthentication]

    let credentials: Credentials
    let http: any HTTPClient
    let deviceID: String
    let matcher: MediaMatcher?
    private var items: [Entry]?
    private var loadedAt: Date?
    private var progressHandler: (@Sendable ([WatchProgress]) async -> Void)?
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
        var userData: UserState?
        struct Subtitle: Sendable { let index: Int; let language: String?; let title: String }
    }

    /// This user's state for an item on the server.
    struct UserState: Sendable, Equatable {
        var position: TimeInterval
        var played: Bool
        var lastPlayed: Date?
    }

    public init(id: SourceID, name: String, credentials: Credentials, http: any HTTPClient, deviceID: String, matcher: MediaMatcher?) {
        self.id = id; self.displayName = name; self.credentials = credentials; self.flavour = credentials.flavour
        self.http = http; self.deviceID = deviceID; self.matcher = matcher
    }

    // MARK: Sign-in

    /// Signs in with a username and password. The password isn't stored; the
    /// returned token is (by the caller, in the Keychain). Whether it's
    /// Jellyfin or Emby comes from the server's public info, and an Emby
    /// server that only answers under `/emby` is found there. `expecting` is
    /// what the user said they were adding, for a server that doesn't say.
    public static func signIn(server raw: String, username: String, password: String, http: any HTTPClient,
                              deviceID: String, expecting: Flavour = .jellyfin) async throws -> (Credentials, serverName: String) {
        guard var server = normalize(raw) else { throw SourceError.invalidConfiguration("Enter the server address, like https://media.example.com") }
        let publicInfo: PublicInfo
        do {
            publicInfo = try await send(request(server, "System/Info/Public", deviceID: deviceID, flavour: expecting), http: http)
        } catch SourceError.notFound where server.lastPathComponent.lowercased() != "emby" {
            server = server.appending(path: "emby")
            publicInfo = try await send(request(server, "System/Info/Public", deviceID: deviceID, flavour: .emby), http: http)
        }
        let flavour = flavour(of: publicInfo, otherwise: expecting)
        var req = request(server, "Users/AuthenticateByName", deviceID: deviceID, flavour: flavour)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let auth: AuthResult = try await send(req, http: http)
        return (Credentials(server: server, userID: auth.User.Id, accessToken: auth.AccessToken, username: auth.User.Name ?? username,
                            flavour: flavour),
                publicInfo.ServerName ?? server.host() ?? flavour.displayName)
    }

    /// Jellyfin names itself in `ProductName` ("Jellyfin Server"); Emby may not
    /// send one, but its versions are 4.x where Jellyfin's are 10.x.
    static func flavour(of info: PublicInfo, otherwise fallback: Flavour = .jellyfin) -> Flavour {
        if let product = info.ProductName?.lowercased() {
            if product.contains("jellyfin") { return .jellyfin }
            if product.contains("emby") { return .emby }
        }
        guard let major = info.Version?.split(separator: ".").first.flatMap({ Int($0) }) else { return fallback }
        return major >= 10 ? .jellyfin : .emby
    }

    static func normalize(_ raw: String) -> URL? { ServerAddress.normalize(raw) }

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

    /// Reports the position to the server so its own resume points stay current.
    public func reportProgress(itemID: String, position: TimeInterval, isPaused: Bool, stopped: Bool) async {
        var req = request(stopped ? "Sessions/Playing/Stopped" : "Sessions/Playing/Progress")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: AnyEncodable] = ["ItemId": .init(itemID), "PositionTicks": .init(Int64(position * 10_000_000)),
                                            "IsPaused": .init(isPaused), "CanSeek": .init(true)]
        req.httpBody = try? JSONEncoder().encode(body)
        _ = try? await http.send(req)
        // Read before writing: `items?[i].userData = … items?[i] …` is an exclusivity trap.
        if let i = items?.firstIndex(where: { $0.itemID == itemID }) {
            let played = items?[i].userData?.played ?? false
            items?[i].userData = UserState(position: position, played: played, lastPlayed: Date())
        }
    }

    // MARK: Watched state from the server

    /// Called with the server's progress each time the library is fetched.
    public func setProgressHandler(_ handler: @escaping @Sendable ([WatchProgress]) async -> Void) {
        progressHandler = handler
    }

    /// The server's watched state and resume points for everything it holds
    /// that matched the catalog, one record per title (the newest when several
    /// files are the same title).
    public func watchProgress() async throws -> [WatchProgress] {
        Self.progress(from: try await entries())
    }

    /// Fetches fresh state for one movie or episode, or every episode of a
    /// show, and returns its progress. Used when a title page opens.
    public func refreshWatchProgress(for key: MediaKey) async -> [WatchProgress] {
        guard let all = try? await entries() else { return [] }
        let ids = all.filter { $0.key == key || ($0.key?.seriesKey == key && key.isSeries) }.map(\.itemID)
        guard !ids.isEmpty else { return [] }
        var fresh: [String: UserState] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let q = ["userId": credentials.userID, "ids": chunk.joined(separator: ","), "enableImages": "false",
                     "enableUserData": "true"]
            var req = URLRequest(url: url("Items", q, includeKey: false))
            authorize(&req)
            guard let result: ItemsResult = try? await Self.send(req, http: http) else { return [] }
            for item in result.Items { fresh[item.Id] = item.UserData.map(UserState.init) }
        }
        var updated = items ?? all
        for i in updated.indices { if let u = fresh[updated[i].itemID] { updated[i].userData = u } }
        items = updated
        return Self.progress(from: updated.filter { fresh[$0.itemID] != nil })
    }

    /// Marks every copy of a movie or episode played or unplayed on the server.
    public func setPlayed(_ key: MediaKey, _ played: Bool) async {
        guard let all = try? await entries() else { return }
        for i in all.indices where all[i].key == key {
            let itemID = all[i].itemID
            var ok = await sendPlayed(path: "Users/\(credentials.userID)/PlayedItems/\(itemID)", played: played, query: [:])
            if !ok, flavour == .jellyfin {
                // Jellyfin 10.9 moved it; the old route may be gone in later versions.
                ok = await sendPlayed(path: "UserPlayedItems/\(itemID)", played: played, query: ["userId": credentials.userID])
            } else if !ok, !played {
                // Emby also takes a POST for servers behind proxies that refuse DELETE.
                ok = await sendPlayed(path: "Users/\(credentials.userID)/PlayedItems/\(itemID)/Delete", played: true, query: [:])
            }
            if ok, let j = items?.firstIndex(where: { $0.itemID == itemID }) {
                items?[j].userData = UserState(position: 0, played: played, lastPlayed: played ? Date() : nil)
            }
        }
    }

    private func sendPlayed(path: String, played: Bool, query: [String: String]) async -> Bool {
        var req = URLRequest(url: url(path, query, includeKey: false))
        authorize(&req)
        req.httpMethod = played ? "POST" : "DELETE"
        req.timeoutInterval = 20
        guard let (_, response) = try? await http.send(req) else { return false }
        return (200..<300).contains(response.statusCode)
    }

    static func progress(from entries: [Entry]) -> [WatchProgress] {
        var out: [MediaKey: WatchProgress] = [:]
        for e in entries {
            guard let key = e.key, let p = progress(e.userData, key: key, duration: e.duration) else { continue }
            if let old = out[key] { out[key] = ProgressMerge.merge(old, p) } else { out[key] = p }
        }
        return Array(out.values)
    }

    /// The server's state as a progress record. A resume point needs the date
    /// it was set to merge by; a played item without one (marked by an import,
    /// say) still counts, dated so anything Bluebox knows wins over it.
    static func progress(_ u: UserState?, key: MediaKey, duration: TimeInterval?) -> WatchProgress? {
        guard let u else { return nil }
        if u.played {
            return WatchProgress(key: key, position: duration ?? u.position, duration: duration, isCompleted: true,
                                 updatedAt: u.lastPlayed ?? Date(timeIntervalSince1970: 0), deviceID: "server")
        }
        guard u.position > 0, let date = u.lastPlayed else { return nil }
        return ProgressPolicy.standard.record(key: key, position: u.position, duration: duration, at: date, deviceID: "server")
    }

    /// Whether the server's record should be stored over what Bluebox has:
    /// only when it wins the usual merge and says something different (the
    /// server echoing back Bluebox's own report a moment later doesn't count).
    public static func shouldApply(_ remote: WatchProgress, over local: WatchProgress?) -> Bool {
        guard let local else { return true }
        guard ProgressMerge.merge(local, remote) == remote else { return false }
        if local.isCompleted != remote.isCompleted { return true }
        return !local.isCompleted && abs(local.position - remote.position) >= 10
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
                             subtitles: subs, userData: v.UserData.map(UserState.init)))
        }
        items = out
        loadedAt = Date()
        if let progressHandler { let p = Self.progress(from: out); Task { await progressHandler(p) } }
        return out
    }

    private func fetchAll(types: String, fields: String) async throws -> [Item] {
        var all: [Item] = []
        let page = 500
        while true {
            let q = ["userId": credentials.userID, "recursive": "true", "includeItemTypes": types, "fields": fields,
                     "startIndex": String(all.count), "limit": String(page), "enableImages": "false",
                     "enableUserData": types == "Series" ? "false" : "true"]
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
    /// token as a query parameter (`ApiKey` on Jellyfin, `api_key` on Emby).
    /// API calls use the header.
    func url(_ path: String, _ query: [String: String], includeKey: Bool = true) -> URL {
        var c = URLComponents(url: credentials.server.appending(path: path), resolvingAgainstBaseURL: false)!
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if includeKey { items.append(URLQueryItem(name: flavour.tokenParameter, value: credentials.accessToken)) }
        c.queryItems = items.isEmpty ? nil : items
        return c.url!
    }

    private func authorize(_ req: inout URLRequest) {
        Self.authorize(&req, deviceID: deviceID, token: credentials.accessToken, flavour: flavour)
    }

    /// Jellyfin reads `Authorization`; Emby reads `X-Emby-Authorization`, and
    /// the token alone from `X-Emby-Token`.
    static func authorize(_ req: inout URLRequest, deviceID: String, token: String?, flavour: Flavour) {
        let header = authHeader(deviceID: deviceID, token: token)
        switch flavour {
        case .jellyfin:
            req.setValue(header, forHTTPHeaderField: "Authorization")
        case .emby:
            req.setValue(header, forHTTPHeaderField: "X-Emby-Authorization")
            if let token { req.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
        }
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

    private func request(_ path: String) -> URLRequest {
        Self.request(credentials.server, path, deviceID: deviceID, token: credentials.accessToken, flavour: flavour)
    }

    static func request(_ server: URL, _ path: String, deviceID: String, token: String? = nil,
                        flavour: Flavour = .jellyfin) -> URLRequest {
        var r = URLRequest(url: server.appending(path: path))
        authorize(&r, deviceID: deviceID, token: token, flavour: flavour)
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

    // MARK: Wire format (field names as Jellyfin and Emby send them)

    struct PublicInfo: Decodable { let ServerName: String?; let Version: String?; let ProductName: String? }
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
        let UserData: UserData?
        var tmdbID: Int? { (ProviderIds?["Tmdb"] ?? ProviderIds?["tmdb"]).flatMap(Int.init) }

        enum CodingKeys: String, CodingKey {
            case Id, Name, ProductionYear, ProviderIds, SeriesId, SeriesName, ParentIndexNumber, IndexNumber, RunTimeTicks, MediaSources
            case UserData
            case type = "Type"
        }
    }
    struct UserData: Decodable {
        let PlaybackPositionTicks: Int64?
        let Played: Bool?
        let LastPlayedDate: String?
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

extension JellyfinSource.UserState {
    init(_ d: JellyfinSource.UserData) {
        self.init(position: TimeInterval(d.PlaybackPositionTicks ?? 0) / 10_000_000, played: d.Played ?? false,
                  lastPlayed: d.LastPlayedDate.flatMap(Self.parseDate))
    }

    /// Both servers send .NET dates with seven fractional digits
    /// ("2024-05-01T20:15:03.1234567Z"), more than ISO8601DateFormatter reads.
    static func parseDate(_ s: String) -> Date? {
        var base = s, fraction = 0.0
        if let dot = s.firstIndex(of: ".") {
            let digits = s[s.index(after: dot)...].prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            base = String(s[..<dot]) + String(s[s.index(after: dot)...].dropFirst(digits.count))
        }
        if !base.hasSuffix("Z"), base.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) == nil { base += "Z" }
        guard let date = ISO8601DateFormatter().date(from: base) else { return nil }
        return date.addingTimeInterval(fraction)
    }
}

/// Mixed-type JSON body values.
struct AnyEncodable: Encodable, Sendable {
    let encode: @Sendable (Encoder) throws -> Void
    init<T: Encodable & Sendable>(_ v: T) { encode = { try v.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}
