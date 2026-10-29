import Foundation
import Metadata

/// Fetches skip segments from one place.
public protocol SkipSegmentFetching: Sendable {
    var source: SkipSegment.Source { get }
    /// Segments for the query; empty when the service has none. Throws only
    /// for failures worth retrying later (network, rate limit).
    func segments(for query: SkipSegmentQuery) async throws -> [SkipSegment]
}

public enum SkipSegmentError: Error, Equatable, Sendable {
    case rateLimited
    case server(Int)
}

// MARK: - TheIntroDB

/// TheIntroDB, `GET https://api.theintrodb.org/v4/media` (OpenAPI 4.0.0, read
/// 28 October 2026). Anonymous reads; 30 requests per 10 s and 5000 per day per IP.
///
/// Addressed by `tmdb_id` (or `imdb_id`), with `season` and `episode` for TV.
/// `duration_ms` picks the release version closest to this file. Times are
/// milliseconds; a null `start_ms` means the start of the file and a null
/// `end_ms` the end. Each kind is a list (an episode can have two intros).
/// 404 with `code: no_submissions` means nobody has timed it yet.
public struct TheIntroDBClient: SkipSegmentFetching {
    public let source = SkipSegment.Source.theIntroDB
    let http: any HTTPClient
    let base: URL

    public init(http: any HTTPClient, base: URL = URL(string: "https://api.theintrodb.org/v4")!) {
        self.http = http; self.base = base
    }

    func request(for q: SkipSegmentQuery) -> URLRequest? {
        var items: [URLQueryItem] = []
        if let tmdb = q.tmdbID { items.append(URLQueryItem(name: "tmdb_id", value: String(tmdb))) }
        else if let imdb = q.imdbID, imdb.hasPrefix("tt") { items.append(URLQueryItem(name: "imdb_id", value: imdb)) }
        else { return nil }
        if let s = q.season, let e = q.episode {
            items.append(URLQueryItem(name: "season", value: String(s)))
            items.append(URLQueryItem(name: "episode", value: String(e)))
        }
        if let d = q.duration, d > 0 { items.append(URLQueryItem(name: "duration_ms", value: String(Int(d * 1000)))) }
        var comps = URLComponents(url: base.appending(path: "media"), resolvingAgainstBaseURL: false)!
        comps.queryItems = items
        var req = URLRequest(url: comps.url!, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    public func segments(for query: SkipSegmentQuery) async throws -> [SkipSegment] {
        guard let req = request(for: query) else { return [] }
        let (data, response) = try await http.send(req)
        switch response.statusCode {
        case 200: return try Self.parse(data)
        case 404, 400, 422: return []  // not timed yet, or not a known episode
        case 429: throw SkipSegmentError.rateLimited
        default: throw SkipSegmentError.server(response.statusCode)
        }
    }

    struct Response: Decodable {
        struct Stamp: Decodable { let start_ms: Double?; let end_ms: Double? }
        let intro: [Stamp]?
        let recap: [Stamp]?
        let credits: [Stamp]?
        let preview: [Stamp]?
    }

    static func parse(_ data: Data) throws -> [SkipSegment] {
        let r = try JSONDecoder().decode(Response.self, from: data)
        let lists: [(SkipSegment.Kind, [Response.Stamp]?)] = [(.intro, r.intro), (.recap, r.recap), (.credits, r.credits), (.preview, r.preview)]
        return lists.flatMap { kind, stamps in
            (stamps ?? []).compactMap { s -> SkipSegment? in
                // A stamp with neither end says nothing.
                guard s.start_ms != nil || s.end_ms != nil else { return nil }
                let start = (s.start_ms ?? 0) / 1000
                let end = s.end_ms.map { $0 / 1000 }
                if let end, end <= start { return nil }
                return SkipSegment(kind: kind, start: start, end: end, source: .theIntroDB)
            }
        }
    }
}

// MARK: - IntroDB

/// IntroDB, `GET https://api.introdb.app/segments?imdb_id=&season=&episode=`
/// (docs at introdb.app/docs, read 28 October 2026). Anonymous reads, rate
/// limited (429 with `limit` and `reset_at`).
///
/// One object per kind (`intro`, `recap`, `outro`, `post_credits`), each with
/// `start_ms`/`end_ms` (and `start_sec`/`end_sec`); null means not timed yet.
/// `outro` is the end credits. IMDb IDs only.
public struct IntroDBClient: SkipSegmentFetching {
    public let source = SkipSegment.Source.introDB
    let http: any HTTPClient
    let base: URL

    public init(http: any HTTPClient, base: URL = URL(string: "https://api.introdb.app")!) {
        self.http = http; self.base = base
    }

    func request(for q: SkipSegmentQuery) -> URLRequest? {
        guard let imdb = q.imdbID, imdb.hasPrefix("tt") else { return nil }
        var items = [URLQueryItem(name: "imdb_id", value: imdb)]
        if let s = q.season, let e = q.episode {
            items.append(URLQueryItem(name: "season", value: String(s)))
            items.append(URLQueryItem(name: "episode", value: String(e)))
        }
        var comps = URLComponents(url: base.appending(path: "segments"), resolvingAgainstBaseURL: false)!
        comps.queryItems = items
        var req = URLRequest(url: comps.url!, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    public func segments(for query: SkipSegmentQuery) async throws -> [SkipSegment] {
        guard let req = request(for: query) else { return [] }
        let (data, response) = try await http.send(req)
        switch response.statusCode {
        case 200: return try Self.parse(data)
        case 404, 400: return []
        case 429: throw SkipSegmentError.rateLimited
        default: throw SkipSegmentError.server(response.statusCode)
        }
    }

    struct Response: Decodable {
        struct Stamp: Decodable {
            let start_ms: Double?; let end_ms: Double?
            let start_sec: Double?; let end_sec: Double?
            var start: Double? { start_ms.map { $0 / 1000 } ?? start_sec }
            var end: Double? { end_ms.map { $0 / 1000 } ?? end_sec }
        }
        let intro: Stamp?
        let recap: Stamp?
        let outro: Stamp?
        let post_credits: Stamp?
    }

    static func parse(_ data: Data) throws -> [SkipSegment] {
        let r = try JSONDecoder().decode(Response.self, from: data)
        let pairs: [(SkipSegment.Kind, Response.Stamp?)] = [(.intro, r.intro), (.recap, r.recap), (.credits, r.outro)]
        return pairs.compactMap { kind, stamp in
            guard let stamp, let start = stamp.start else { return nil }
            if let end = stamp.end, end <= start { return nil }
            return SkipSegment(kind: kind, start: start, end: stamp.end, source: .introDB)
        }
    }
}

// MARK: - Jellyfin

/// Jellyfin 10.10+ media segments: `GET /MediaSegments/{itemId}` returns
/// `{ "Items": [{ "Type": "Intro", "StartTicks": …, "EndTicks": … }] }`, in
/// 100-nanosecond ticks. Types: Intro, Outro, Recap, Preview, Commercial, Unknown.
/// Servers without segments (older, or no plugin) answer 404 or an empty list.
public struct JellyfinSegmentsClient: SkipSegmentFetching {
    public let source = SkipSegment.Source.jellyfin
    let http: any HTTPClient

    public init(http: any HTTPClient) { self.http = http }

    func request(for ref: JellyfinItemRef) -> URLRequest {
        var req = URLRequest(url: ref.server.appending(path: "MediaSegments/\(ref.itemID)"), timeoutInterval: 6)
        req.setValue(#"MediaBrowser Client="Bluebox", Token="\#(ref.token)""#, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    public func segments(for query: SkipSegmentQuery) async throws -> [SkipSegment] {
        guard let ref = query.jellyfin else { return [] }
        let (data, response) = try await http.send(request(for: ref))
        guard response.statusCode == 200 else { return [] }
        return try Self.parse(data)
    }

    struct Response: Decodable {
        struct Item: Decodable {
            let kind: String; let startTicks: Double; let endTicks: Double
            enum CodingKeys: String, CodingKey { case kind = "Type", startTicks = "StartTicks", endTicks = "EndTicks" }
        }
        let Items: [Item]
    }

    static func parse(_ data: Data) throws -> [SkipSegment] {
        try JSONDecoder().decode(Response.self, from: data).Items.compactMap { item in
            let kind: SkipSegment.Kind
            switch item.kind.lowercased() {
            case "intro": kind = .intro
            case "outro": kind = .credits
            case "recap": kind = .recap
            case "preview": kind = .preview
            default: return nil
            }
            let start = item.startTicks / 10_000_000, end = item.endTicks / 10_000_000
            guard end > start else { return nil }
            return SkipSegment(kind: kind, start: start, end: end, source: .jellyfin)
        }
    }
}
