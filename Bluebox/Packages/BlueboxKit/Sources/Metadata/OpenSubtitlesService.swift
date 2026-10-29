import Domain
import Foundation

/// One subtitle file found online.
public struct SubtitleSearchResult: Identifiable, Hashable, Sendable {
    public let id: Int          // OpenSubtitles file_id
    public let language: String?
    public let release: String
    public let downloadCount: Int
    public let hearingImpaired: Bool
    public let machineTranslated: Bool
}

public enum SubtitleSearchError: Error, Equatable, Sendable, LocalizedError {
    case missingKey
    case unauthorized
    case quotaExceeded(resetsAt: String?)
    case offline
    case server(Int)
    case decoding

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add an OpenSubtitles API key in Settings to search for subtitles."
        case .unauthorized: "OpenSubtitles rejected the API key or sign-in."
        case .quotaExceeded(let r): "You've reached today's OpenSubtitles download limit" + (r.map { " (resets \($0))." } ?? ".") + " Signing in to an OpenSubtitles account raises it."
        case .offline: "You're offline."
        case .server(let s): "OpenSubtitles returned an error (\(s))."
        case .decoding: "OpenSubtitles sent a response Bluebox couldn't read."
        }
    }
}

/// Subtitle search and download through the OpenSubtitles.com REST API.
/// Needs the user's API key; an optional account sign-in raises the daily
/// download quota.
public actor OpenSubtitlesService {
    public struct Session: Codable, Sendable, Equatable { public var token: String; public var baseHost: String? }

    let apiKey: String
    let http: any HTTPClient
    private(set) var session: Session?
    static let defaultHost = "api.opensubtitles.com"
    static let userAgent = "Bluebox v1.0"

    public init(apiKey: String, http: any HTTPClient, session: Session? = nil) {
        self.apiKey = apiKey; self.http = http; self.session = session
    }

    /// Signs in to an OpenSubtitles account. Returns the session to store.
    public func signIn(username: String, password: String) async throws -> Session {
        var req = request("login", method: "POST")
        req.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        struct DTO: Decodable { let token: String; let base_url: String? }
        let dto: DTO = try await send(req)
        let s = Session(token: dto.token, baseHost: dto.base_url)
        session = s
        return s
    }

    public func signOut() { session = nil }

    /// Subtitles for a movie or episode, best first.
    public func search(_ key: MediaKey, languages: [String]) async throws -> [SubtitleSearchResult] {
        var q: [URLQueryItem] = []
        if let series = key.seriesKey?.tmdbID, let n = key.episodeNumbers {
            q += [URLQueryItem(name: "parent_tmdb_id", value: String(series)),
                  URLQueryItem(name: "season_number", value: String(n.season)),
                  URLQueryItem(name: "episode_number", value: String(n.episode))]
        } else if let id = key.tmdbID {
            q.append(URLQueryItem(name: "tmdb_id", value: String(id)))
        } else {
            return []
        }
        let langs = languages.map { $0.lowercased() }.filter { !$0.isEmpty }
        if !langs.isEmpty { q.append(URLQueryItem(name: "languages", value: langs.sorted().joined(separator: ","))) }
        q.append(URLQueryItem(name: "order_by", value: "download_count"))
        let req = request("subtitles", method: "GET", query: q.sorted { $0.name < $1.name })
        let page: SearchPage = try await send(req)
        return page.data.compactMap { item in
            guard let file = item.attributes.files.first else { return nil }
            let a = item.attributes
            return SubtitleSearchResult(id: file.file_id, language: a.language, release: a.release ?? file.file_name ?? "Subtitle",
                                        downloadCount: a.download_count ?? 0, hearingImpaired: a.hearing_impaired ?? false,
                                        machineTranslated: (a.machine_translated ?? false) || (a.ai_translated ?? false))
        }
        .sorted { ($0.machineTranslated ? 1 : 0, -$0.downloadCount) < ($1.machineTranslated ? 1 : 0, -$1.downloadCount) }
    }

    /// Downloads one subtitle as SRT text.
    public func download(_ result: SubtitleSearchResult) async throws -> Data {
        var req = request("download", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": result.id, "sub_format": "srt"])
        struct DTO: Decodable { let link: String?; let reset_time_utc: String?; let remaining: Int? }
        let dto: DTO = try await send(req)
        guard let link = dto.link.flatMap(URL.init(string:)) else { throw SubtitleSearchError.quotaExceeded(resetsAt: dto.reset_time_utc) }
        var fileReq = URLRequest(url: link)
        fileReq.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport(fileReq)
        guard (200..<300).contains(response.statusCode), data.count < 10_000_000 else { throw SubtitleSearchError.server(response.statusCode) }
        return data
    }

    // MARK: Plumbing

    private func request(_ path: String, method: String, query: [URLQueryItem] = []) -> URLRequest {
        let host = session?.baseHost ?? Self.defaultHost
        var c = URLComponents()
        c.scheme = "https"; c.host = host; c.path = "/api/v1/" + path
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token = session?.token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.timeoutInterval = 20
        return r
    }

    private func transport(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await http.send(req) }
        catch { throw SubtitleSearchError.offline }
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await transport(req)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw SubtitleSearchError.unauthorized
        case 406, 429:
            let reset = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reset_time_utc"] as? String
            throw SubtitleSearchError.quotaExceeded(resetsAt: reset)
        default: throw SubtitleSearchError.server(response.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw SubtitleSearchError.decoding }
    }

    struct SearchPage: Decodable {
        struct Item: Decodable { let attributes: Attributes }
        struct Attributes: Decodable {
            let language: String?
            let release: String?
            let download_count: Int?
            let hearing_impaired: Bool?
            let machine_translated: Bool?
            let ai_translated: Bool?
            let files: [File]
        }
        struct File: Decodable { let file_id: Int; let file_name: String? }
        let data: [Item]
    }
}
