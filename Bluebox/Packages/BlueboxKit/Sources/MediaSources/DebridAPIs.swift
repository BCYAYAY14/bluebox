import Domain
import Foundation
import Metadata

// Clients for the cloud libraries of debrid services: what you've added to
// your account, and fresh links to play it. The API key is sent only to the
// service itself and never logged or shown.

/// Debrid services whose library Bluebox can browse.
public enum DebridService: String, Codable, Sendable, CaseIterable {
    case realDebrid, premiumize, torBox, allDebrid, debridLink

    public var title: String {
        switch self {
        case .realDebrid: "Real-Debrid"
        case .premiumize: "Premiumize"
        case .torBox: "TorBox"
        case .allDebrid: "AllDebrid"
        case .debridLink: "Debrid-Link"
        }
    }
}

/// Who the key belongs to and how long their plan runs.
public struct DebridAccount: Hashable, Codable, Sendable {
    public let name: String
    /// When the paid plan ends; nil when the service didn't say or there is none.
    public let premiumUntil: Date?
    /// False for a free account or a plan that has run out.
    public let isPremium: Bool

    public init(name: String, premiumUntil: Date?, isPremium: Bool) {
        self.name = name; self.premiumUntil = premiumUntil; self.isPremium = isPremium
    }

    /// Whole days left on the plan (0 on its last day); nil without an end date.
    public func daysLeft(now: Date = Date()) -> Int? {
        guard let premiumUntil else { return nil }
        return max(0, Int(premiumUntil.timeIntervalSince(now) / 86_400))
    }
}

/// One video file in the user's debrid cloud.
public struct DebridFile: Hashable, Codable, Sendable, Identifiable {
    /// Stable within the service: "rd:t:<torrent>:<n>", "rd:d:<download>", "pm:<id>", "tb:<torrent>:<file>",
    /// "ad:<magnet>:<n>", "dl:<torrent>:<file>".
    public let id: String
    /// The file's own name (no folders).
    public let filename: String
    /// The torrent or folder it came from, used when the file name alone is too bare to match.
    public let parentName: String?
    public let sizeBytes: Int64?
    public let addedAt: Date?
    /// What `link(for:)` needs: a restricted link (Real-Debrid, AllDebrid), a
    /// direct link (Premiumize, Debrid-Link), or "<torrent>:<file>" (TorBox). Not a secret by itself.
    let reference: String

    public init(id: String, filename: String, parentName: String?, sizeBytes: Int64?, addedAt: Date?, reference: String) {
        self.id = id; self.filename = filename; self.parentName = parentName; self.sizeBytes = sizeBytes
        self.addedAt = addedAt; self.reference = reference
    }

    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts", "wmv", "mpg"]

    /// Video files only, and not the sample clips releases include.
    static func isVideo(_ name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        guard videoExtensions.contains(ext) else { return false }
        let base = (lower as NSString).deletingPathExtension
        return !(base.hasSuffix("sample") || base.hasPrefix("sample") || lower.contains("/sample/") || base.contains(".sample"))
    }
}

/// A debrid service's library API.
public protocol DebridLibraryAPI: Sendable {
    var service: DebridService { get }
    /// Every finished video file in the account.
    func files() async throws -> [DebridFile]
    /// A fresh, playable HTTPS link for a file.
    func link(for file: DebridFile) async throws -> URL
    /// The account's name and plan, to show the connection works and when it ends.
    func accountInfo() async throws -> DebridAccount
}

extension DebridLibraryAPI {
    /// The account name, to show the connection works.
    public func accountName() async throws -> String { try await accountInfo().name }
}

public enum DebridAPIs {
    public static func make(_ service: DebridService, key: String, http: any HTTPClient) -> any DebridLibraryAPI {
        switch service {
        case .realDebrid: RealDebridAPI(key: key, http: http)
        case .premiumize: PremiumizeAPI(key: key, http: http)
        case .torBox: TorBoxAPI(key: key, http: http)
        case .allDebrid: AllDebridAPI(key: key, http: http)
        case .debridLink: DebridLinkAPI(key: key, http: http)
        }
    }
}

// MARK: - Shared plumbing

enum DebridHTTP {
    /// 401 is a key the service doesn't know (`SourceError.unauthorized`); 403 is
    /// a known account that may not do this: expired, not premium, or locked.
    static func send(_ request: URLRequest, http: any HTTPClient, service: DebridService? = nil) async throws -> Data {
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw SourceError.timedOut
            case .cancelled: throw CancellationError()
            default: throw SourceError.unreachable(e.localizedDescription)
            }
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401: throw SourceError.unauthorized
        case 403: throw DebridLinkError(.planExpired, service: service?.title)
        case 404: throw SourceError.notFound
        case 429: throw SourceError.unreachable("The service is rate limiting requests. Try again in a minute.")
        case 503: throw SourceError.unreachable("The service is temporarily unavailable.")
        default: throw SourceError.unreachable("The service returned an error (\(response.statusCode)).")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw SourceError.unreachable("The service sent data Bluebox couldn't read.") }
    }

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func lastPathComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// A Unix time; nil for 0 or below (the services' "no plan").
    static func unixDate(_ seconds: Double?) -> Date? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// A number the services send as a number, a string of one, or `false` for none.
struct LooseNumber: Decodable, Sendable {
    let value: Double?
    /// As sent, for IDs: "1234567".
    let text: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d; text = String(Int64(d)) }
        else if let s = try? c.decode(String.self) { value = Double(s); text = s }
        else { value = nil; text = nil }
    }
}

// MARK: - Real-Debrid

/// https://api.real-debrid.com/rest/1.0/ with the API token as a Bearer header.
public struct RealDebridAPI: DebridLibraryAPI {
    public let service = DebridService.realDebrid
    let key: String
    let http: any HTTPClient
    let base: URL
    /// Multi-file torrents need one extra request each; capped to stay well
    /// under Real-Debrid's 250 requests a minute.
    static let maxInfoLookups = 60

    public init(key: String, http: any HTTPClient, base: URL = URL(string: "https://api.real-debrid.com/rest/1.0/")!) {
        self.key = key; self.http = http; self.base = base
    }

    struct Torrent: Decodable, Sendable {
        let id: String
        let filename: String?
        let bytes: Int64?
        let status: String?
        let added: String?
        let links: [String]?
    }

    struct TorrentInfo: Decodable, Sendable {
        struct File: Decodable, Sendable { let id: Int; let path: String; let bytes: Int64?; let selected: Int? }
        let id: String
        let filename: String?
        let files: [File]?
        let links: [String]?
    }

    struct Download: Decodable, Sendable {
        let id: String
        let filename: String?
        let filesize: Int64?
        let link: String?
        let download: String?
        let generated: String?
        let streamable: Int?
    }

    struct Unrestricted: Decodable { let download: String? }
    /// `expiration` is the plan's end; `type` is "premium" or "free".
    struct User: Decodable { let username: String?; let type: String?; let expiration: String? }

    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", form: [String: String]? = nil) -> URLRequest {
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        if let form {
            var body = URLComponents()
            body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            r.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// Pages through a list endpoint (100 per page, at most 10 pages).
    func pages<T: Decodable & Sendable>(_ path: String, _ type: T.Type) async throws -> [T] {
        var all: [T] = []
        for page in 1...10 {
            let data = try await DebridHTTP.send(request(path, query: [.init(name: "limit", value: "100"), .init(name: "page", value: "\(page)")]), http: http, service: service)
            if data.isEmpty { break }  // 204 past the end
            let batch = try DebridHTTP.decode([T].self, data)
            all += batch
            if batch.count < 100 { break }
        }
        return all
    }

    public func files() async throws -> [DebridFile] {
        async let torrentList = pages("torrents", Torrent.self)
        async let downloadList = pages("downloads", Download.self)
        let torrents = try await torrentList.filter { $0.status == "downloaded" && !($0.links ?? []).isEmpty }
        var out: [DebridFile] = []
        var knownLinks = Set<String>()

        // Single-file torrents: the torrent's name is the file's name.
        for t in torrents where t.links?.count == 1 {
            let link = t.links![0]
            knownLinks.insert(link)
            guard let name = t.filename, DebridFile.isVideo(name) else { continue }
            out.append(DebridFile(id: "rd:t:\(t.id):0", filename: name, parentName: nil, sizeBytes: t.bytes,
                                  addedAt: DebridHTTP.date(t.added), reference: link))
        }
        // Packs: links follow the selected files in order.
        let packs = torrents.filter { ($0.links?.count ?? 0) > 1 }
        for t in packs { t.links?.forEach { knownLinks.insert($0) } }
        let infos = try await withThrowingTaskGroup(of: TorrentInfo?.self) { group in
            var results: [TorrentInfo] = []
            var iterator = packs.prefix(Self.maxInfoLookups).makeIterator()
            for _ in 0..<4 {
                guard let t = iterator.next() else { break }
                group.addTask { try? await self.info(t.id) }
            }
            while let next = try await group.next() {
                if let next { results.append(next) }
                if let t = iterator.next() { group.addTask { try? await self.info(t.id) } }
            }
            return results
        }
        let addedByID = Dictionary(packs.map { ($0.id, DebridHTTP.date($0.added)) }, uniquingKeysWith: { a, _ in a })
        for info in infos {
            let selected = (info.files ?? []).filter { $0.selected == 1 }.sorted { $0.id < $1.id }
            let links = info.links ?? []
            for (i, file) in selected.enumerated() where i < links.count {
                let name = DebridHTTP.lastPathComponent(file.path)
                guard DebridFile.isVideo(file.path) else { continue }
                out.append(DebridFile(id: "rd:t:\(info.id):\(file.id)", filename: name, parentName: info.filename,
                                      sizeBytes: file.bytes, addedAt: addedByID[info.id] ?? nil, reference: links[i]))
            }
        }
        // Links unrestricted by hand (hosters), not already listed as torrent files.
        for d in try await downloadList {
            guard let link = d.link, !knownLinks.contains(link), let name = d.filename, DebridFile.isVideo(name) else { continue }
            knownLinks.insert(link)
            out.append(DebridFile(id: "rd:d:\(d.id)", filename: name, parentName: nil, sizeBytes: d.filesize,
                                  addedAt: DebridHTTP.date(d.generated), reference: link))
        }
        return out
    }

    func info(_ id: String) async throws -> TorrentInfo {
        try DebridHTTP.decode(TorrentInfo.self, try await DebridHTTP.send(request("torrents/info/\(id)"), http: http, service: service))
    }

    public func link(for file: DebridFile) async throws -> URL {
        let data = try await DebridHTTP.send(request("unrestrict/link", method: "POST", form: ["link": file.reference]), http: http, service: service)
        guard let s = try DebridHTTP.decode(Unrestricted.self, data).download, let url = URL(string: s),
              url.scheme?.lowercased() == "https" else { throw SourceError.notFound }
        return url
    }

    public func accountInfo() async throws -> DebridAccount {
        let user = try DebridHTTP.decode(User.self, try await DebridHTTP.send(request("user"), http: http, service: service))
        let until = DebridHTTP.date(user.expiration)
        return DebridAccount(name: user.username ?? "Real-Debrid", premiumUntil: until,
                             isPremium: user.type == "premium" && (until.map { $0 > Date() } ?? true))
    }
}

// MARK: - Premiumize

/// https://www.premiumize.me/api/ — the cloud's files carry direct links. The
/// API key goes in the `apikey` query item, as Premiumize requires.
public struct PremiumizeAPI: DebridLibraryAPI {
    public let service = DebridService.premiumize
    let key: String
    let http: any HTTPClient
    let base: URL

    public init(key: String, http: any HTTPClient, base: URL = URL(string: "https://www.premiumize.me/api/")!) {
        self.key = key; self.http = http; self.base = base
    }

    struct ListAll: Decodable {
        struct File: Decodable { let id: String; let name: String?; let size: Int64?; let createdAt: Double?; let path: String?; let link: String?; let streamLink: String?
            enum CodingKeys: String, CodingKey { case id, name, size, createdAt = "created_at", path, link, streamLink = "stream_link" }
        }
        let status: String?
        let message: String?
        let files: [File]?
    }

    /// `premium_until` is a Unix time, or `false` without a plan.
    struct Account: Decodable { let status: String?; let customerId: LooseNumber?; let premiumUntil: LooseNumber?
        enum CodingKeys: String, CodingKey { case status, customerId = "customer_id", premiumUntil = "premium_until" }
    }

    func request(_ path: String) -> URLRequest {
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "apikey", value: key)]
        var r = URLRequest(url: c.url!)
        r.timeoutInterval = 20
        return r
    }

    public func files() async throws -> [DebridFile] {
        let list = try DebridHTTP.decode(ListAll.self, try await DebridHTTP.send(request("item/listall"), http: http, service: service))
        guard list.status == "success" else { throw SourceError.unauthorized }
        return (list.files ?? []).compactMap { f in
            let path = f.path ?? f.name ?? ""
            guard let link = f.link, DebridFile.isVideo(path) else { return nil }
            let parts = path.split(separator: "/")
            return DebridFile(id: "pm:\(f.id)", filename: f.name ?? DebridHTTP.lastPathComponent(path),
                              parentName: parts.count > 1 ? String(parts[parts.count - 2]) : nil, sizeBytes: f.size,
                              addedAt: f.createdAt.map { Date(timeIntervalSince1970: $0) }, reference: link)
        }
    }

    public func link(for file: DebridFile) async throws -> URL {
        // Premiumize's links are direct and long-lived.
        guard let url = URL(string: file.reference), url.scheme?.lowercased() == "https" else { throw SourceError.notFound }
        return url
    }

    public func accountInfo() async throws -> DebridAccount {
        let a = try DebridHTTP.decode(Account.self, try await DebridHTTP.send(request("account/info"), http: http, service: service))
        guard a.status == "success" else { throw SourceError.unauthorized }
        let until = DebridHTTP.unixDate(a.premiumUntil?.value)
        return DebridAccount(name: a.customerId?.text.map { "Customer \($0)" } ?? "Premiumize",
                             premiumUntil: until, isPremium: until.map { $0 > Date() } ?? false)
    }
}

// MARK: - TorBox

/// https://api.torbox.app/v1/api/ with a Bearer key. Download links come from
/// `torrents/requestdl`, which takes the key as a `token` query item.
public struct TorBoxAPI: DebridLibraryAPI {
    public let service = DebridService.torBox
    let key: String
    let http: any HTTPClient
    let base: URL

    public init(key: String, http: any HTTPClient, base: URL = URL(string: "https://api.torbox.app/v1/api/")!) {
        self.key = key; self.http = http; self.base = base
    }

    struct List: Decodable {
        struct Torrent: Decodable {
            struct File: Decodable { let id: Int; let name: String?; let shortName: String?; let size: Int64?
                enum CodingKeys: String, CodingKey { case id, name, shortName = "short_name", size }
            }
            let id: Int; let name: String?; let createdAt: String?; let downloadFinished: Bool?; let files: [File]?
            enum CodingKeys: String, CodingKey { case id, name, createdAt = "created_at", downloadFinished = "download_finished", files }
        }
        let success: Bool?
        let data: [Torrent]?
    }

    struct Link: Decodable { let success: Bool?; let data: String? }
    /// `plan` 0 is free; `premium_expires_at` is the paid plan's end.
    struct User: Decodable {
        struct D: Decodable { let email: String?; let plan: Int?; let premiumExpiresAt: String?
            enum CodingKeys: String, CodingKey { case email, plan, premiumExpiresAt = "premium_expires_at" }
        }
        let data: D?
    }

    func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        return r
    }

    public func files() async throws -> [DebridFile] {
        let list = try DebridHTTP.decode(List.self, try await DebridHTTP.send(request("torrents/mylist", query: [.init(name: "bypass_cache", value: "true")]), http: http, service: service))
        var out: [DebridFile] = []
        for t in list.data ?? [] where t.downloadFinished == true {
            for f in t.files ?? [] {
                let name = f.shortName ?? DebridHTTP.lastPathComponent(f.name ?? "")
                guard DebridFile.isVideo(f.name ?? name) else { continue }
                out.append(DebridFile(id: "tb:\(t.id):\(f.id)", filename: name, parentName: t.name, sizeBytes: f.size,
                                      addedAt: DebridHTTP.date(t.createdAt), reference: "\(t.id):\(f.id)"))
            }
        }
        return out
    }

    public func link(for file: DebridFile) async throws -> URL {
        let parts = file.reference.split(separator: ":")
        guard parts.count == 2 else { throw SourceError.notFound }
        let req = request("torrents/requestdl", query: [
            .init(name: "token", value: key), .init(name: "torrent_id", value: String(parts[0])),
            .init(name: "file_id", value: String(parts[1])), .init(name: "redirect", value: "false"),
        ])
        let link = try DebridHTTP.decode(Link.self, try await DebridHTTP.send(req, http: http, service: service))
        guard let s = link.data, let url = URL(string: s), url.scheme?.lowercased() == "https" else { throw SourceError.notFound }
        return url
    }

    public func accountInfo() async throws -> DebridAccount {
        let user = try DebridHTTP.decode(User.self, try await DebridHTTP.send(request("user/me"), http: http, service: service)).data
        let until = DebridHTTP.date(user?.premiumExpiresAt)
        return DebridAccount(name: user?.email ?? "TorBox", premiumUntil: until,
                             isPremium: (user?.plan ?? 0) > 0 && (until.map { $0 > Date() } ?? true))
    }
}

// MARK: - AllDebrid

/// https://api.alldebrid.com/ with a Bearer key. Ready magnets come from
/// `v4.1/magnet/status`, their files (a tree) from `v4/magnet/files`, and each
/// file's link is unlocked by `v4/link/unlock`. Answers wrap their `data` in
/// `{"status": "success"}`, or `{"status": "error", "error": {"code": …}}`.
public struct AllDebridAPI: DebridLibraryAPI {
    public let service = DebridService.allDebrid
    let key: String
    let http: any HTTPClient
    let base: URL

    public init(key: String, http: any HTTPClient, base: URL = URL(string: "https://api.alldebrid.com/")!) {
        self.key = key; self.http = http; self.base = base
    }

    struct Envelope<T: Decodable>: Decodable {
        struct Failure: Decodable { let code: String? }
        let status: String?
        let data: T?
        let error: Failure?
    }

    struct Magnets: Decodable {
        struct Magnet: Decodable { let id: LooseNumber; let filename: String?; let statusCode: Int?; let uploadDate: Double?; let completionDate: Double? }
        let magnets: [Magnet]?
    }

    /// Folders carry `e` (entries); files carry `s` (size) and `l` (link).
    struct Entry: Decodable { let n: String?; let s: Int64?; let l: String?; let e: [Entry]? }
    struct Files: Decodable {
        struct Magnet: Decodable { let id: LooseNumber; let files: [Entry]? }
        let magnets: [Magnet]?
    }

    struct Unlocked: Decodable { let link: String? }
    struct UserData: Decodable {
        struct User: Decodable { let username: String?; let isPremium: Bool?; let premiumUntil: LooseNumber? }
        let user: User?
    }

    func request(_ path: String, form: [URLQueryItem]? = nil) -> URLRequest {
        var r = URLRequest(url: base.appending(path: path))
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        if let form {
            var body = URLComponents()
            body.queryItems = form
            r.httpMethod = "POST"
            r.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// The `data` of a successful answer; a rejected key or a lapsed plan as the usual errors.
    func send<T: Decodable>(_ request: URLRequest, _ type: T.Type) async throws -> T {
        let envelope = try DebridHTTP.decode(Envelope<T>.self, try await DebridHTTP.send(request, http: http, service: service))
        if envelope.status == "success", let data = envelope.data { return data }
        throw Self.error(envelope.error?.code)
    }

    static func error(_ code: String?) -> any Error {
        switch code ?? "" {
        case "AUTH_MISSING_APIKEY", "AUTH_BAD_APIKEY", "AUTH_MISSING_AGENT", "AUTH_BAD_AGENT": SourceError.unauthorized
        case "AUTH_BLOCKED", "AUTH_USER_BANNED", "MUST_BE_PREMIUM", "FREE_TRIAL_LIMIT_REACHED":
            DebridLinkError(.planExpired, service: DebridService.allDebrid.title)
        case "MAGNET_NO_URI", "LINK_HOST_NOT_SUPPORTED", "LINK_DOWN": SourceError.notFound
        default: SourceError.unreachable("AllDebrid returned an error (\(code ?? "unknown")).")
        }
    }

    public func files() async throws -> [DebridFile] {
        // 4 is "Ready".
        let ready = try await send(request("v4.1/magnet/status", form: [.init(name: "status", value: "ready")]), Magnets.self)
            .magnets?.filter { ($0.statusCode ?? 4) == 4 } ?? []
        let byID = Dictionary(ready.compactMap { m in m.id.text.map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        var out: [DebridFile] = []
        // `magnet/files` takes a batch of IDs at a time.
        let ids = ready.compactMap(\.id.text)
        for start in stride(from: 0, to: ids.count, by: 50) {
            let chunk = ids[start..<min(start + 50, ids.count)]
            let files = try await send(request("v4/magnet/files", form: chunk.map { .init(name: "id[]", value: $0) }), Files.self)
            for magnet in files.magnets ?? [] {
                guard let id = magnet.id.text else { continue }
                let parent = byID[id]
                var index = 0
                func walk(_ entries: [Entry], folder: String) {
                    for entry in entries {
                        let name = entry.n ?? ""
                        if let children = entry.e { walk(children, folder: folder + name + "/"); continue }
                        defer { index += 1 }
                        guard let link = entry.l, DebridFile.isVideo(folder + name) else { continue }
                        out.append(DebridFile(id: "ad:\(id):\(index)", filename: name, parentName: parent?.filename, sizeBytes: entry.s,
                                              addedAt: DebridHTTP.unixDate(parent?.completionDate ?? parent?.uploadDate), reference: link))
                    }
                }
                walk(magnet.files ?? [], folder: "")
            }
        }
        return out
    }

    public func link(for file: DebridFile) async throws -> URL {
        let unlocked = try await send(request("v4/link/unlock", form: [.init(name: "link", value: file.reference)]), Unlocked.self)
        // A link still being prepared ("delayed") has none yet.
        guard let s = unlocked.link, let url = URL(string: s), url.scheme?.lowercased() == "https" else { throw SourceError.notFound }
        return url
    }

    public func accountInfo() async throws -> DebridAccount {
        let user = try await send(request("v4/user"), UserData.self).user
        let until = DebridHTTP.unixDate(user?.premiumUntil?.value)
        return DebridAccount(name: user?.username ?? "AllDebrid", premiumUntil: until,
                             isPremium: user?.isPremium ?? (until.map { $0 > Date() } ?? false))
    }
}

// MARK: - Debrid-Link

/// https://debrid-link.com/api/v2/ with a Bearer key. The seedbox lists
/// torrents with each file's direct `downloadUrl`. Answers are
/// `{"success": true, "value": …}`, or `{"success": false, "error": "badToken"}`.
public struct DebridLinkAPI: DebridLibraryAPI {
    public let service = DebridService.debridLink
    let key: String
    let http: any HTTPClient
    let base: URL

    public init(key: String, http: any HTTPClient, base: URL = URL(string: "https://debrid-link.com/api/v2/")!) {
        self.key = key; self.http = http; self.base = base
    }

    struct Envelope<T: Decodable>: Decodable {
        struct Pagination: Decodable { let next: Int?; let pages: Int? }
        let success: Bool?
        let value: T?
        let error: String?
        let pagination: Pagination?
    }

    struct Torrent: Decodable {
        struct File: Decodable { let id: String?; let name: String?; let size: Int64?; let downloadPercent: Double?; let downloadUrl: String? }
        let id: String
        let name: String?
        let created: Double?
        let files: [File]?
    }

    /// `premiumLeft` is seconds of plan left; `accountType` 0 is free.
    struct Info: Decodable { let pseudo: String?; let email: String?; let accountType: Int?; let premiumLeft: Double? }

    func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        return r
    }

    func send<T: Decodable>(_ request: URLRequest, _ type: T.Type) async throws -> Envelope<T> {
        let envelope = try DebridHTTP.decode(Envelope<T>.self, try await DebridHTTP.send(request, http: http, service: service))
        guard envelope.success == true else { throw Self.error(envelope.error) }
        return envelope
    }

    static func error(_ code: String?) -> any Error {
        switch code ?? "" {
        case "badToken", "hidedToken", "notToken", "unauthorized_client": SourceError.unauthorized
        case "notDebrid", "accountLocked", "disabledServerHost": DebridLinkError(.planExpired, service: DebridService.debridLink.title)
        case "notFound", "fileNotFound": SourceError.notFound
        default: SourceError.unreachable("Debrid-Link returned an error (\(code ?? "unknown")).")
        }
    }

    public func files() async throws -> [DebridFile] {
        var out: [DebridFile] = []
        var page = 0
        // 50 a page, at most 20 pages.
        while page < 20 {
            let answer = try await send(request("seedbox/list", query: [.init(name: "page", value: "\(page)"), .init(name: "perPage", value: "50")]),
                                        [Torrent].self)
            for t in answer.value ?? [] {
                for f in t.files ?? [] where (f.downloadPercent ?? 0) >= 100 {
                    guard let name = f.name, let link = f.downloadUrl, DebridFile.isVideo(name) else { continue }
                    out.append(DebridFile(id: "dl:\(t.id):\(f.id ?? name)", filename: DebridHTTP.lastPathComponent(name),
                                          parentName: t.name, sizeBytes: f.size, addedAt: DebridHTTP.unixDate(t.created), reference: link))
                }
            }
            guard let next = answer.pagination?.next, next > page else { break }
            page = next
        }
        return out
    }

    public func link(for file: DebridFile) async throws -> URL {
        // The seedbox's links are direct.
        guard let url = URL(string: file.reference), url.scheme?.lowercased() == "https" else { throw SourceError.notFound }
        return url
    }

    public func accountInfo() async throws -> DebridAccount {
        let info = try await send(request("account/infos"), Info.self).value
        let left = info?.premiumLeft ?? 0
        return DebridAccount(name: info?.pseudo ?? info?.email ?? "Debrid-Link",
                             premiumUntil: left > 0 ? Date().addingTimeInterval(left) : nil,
                             isPremium: (info?.accountType ?? 0) > 0 && left > 0)
    }
}
