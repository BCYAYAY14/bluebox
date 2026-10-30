import Domain
import Foundation

/// Where Search Online looks for subtitles. Each can be turned off in
/// Settings › Subtitles.
public enum SubtitleSite: String, CaseIterable, Codable, Sendable, Identifiable {
    case openSubtitles, subdl, podnapisi, jellyfin

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openSubtitles: "OpenSubtitles"
        case .subdl: "Subdl"
        case .podnapisi: "Podnapisi"
        case .jellyfin: "Jellyfin"
        }
    }
}

/// One subtitle found on any site, in the one list Search Online shows.
public struct OnlineSubtitle: Identifiable, Hashable, Sendable {
    /// How to fetch it.
    public enum Source: Hashable, Sendable {
        case openSubtitles(SubtitleSearchResult)
        /// A ZIP (Subdl, Podnapisi) or a plain file (Jellyfin).
        case url(URL, headers: [String: String])
    }

    public let site: SubtitleSite
    public let source: Source
    public let language: String?
    /// The release it was made for ("Movie.2019.1080p.WEB.h264-GROUP"), or its name.
    public let release: String
    public let downloadCount: Int
    public let hearingImpaired: Bool
    public let machineTranslated: Bool
    /// For packs: the episode wanted, to pick the right file from a ZIP.
    public let episode: (season: Int, episode: Int)?
    /// "srt", "ass", "vtt".
    public let format: String

    public var id: String {
        switch source {
        case .openSubtitles(let r): "\(site.rawValue)-\(r.id)"
        case .url(let u, _): "\(site.rawValue)-\(u.absoluteString)"
        }
    }

    public init(site: SubtitleSite, source: Source, language: String?, release: String, downloadCount: Int = 0,
                hearingImpaired: Bool = false, machineTranslated: Bool = false, episode: (season: Int, episode: Int)? = nil,
                format: String = "srt") {
        self.site = site; self.source = source; self.language = language; self.release = release
        self.downloadCount = downloadCount; self.hearingImpaired = hearingImpaired; self.machineTranslated = machineTranslated
        self.episode = episode; self.format = format
    }

    public init(_ r: SubtitleSearchResult) {
        self.init(site: .openSubtitles, source: .openSubtitles(r), language: r.language, release: r.release,
                  downloadCount: r.downloadCount, hearingImpaired: r.hearingImpaired, machineTranslated: r.machineTranslated)
    }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// Puts every site's answers in one list: the best match for the release
/// playing first, then your languages in order, then the most downloaded.
/// Machine translations go last.
public enum SubtitleSearchMerge {
    public static func merge(_ lists: [[OnlineSubtitle]], release: String?, languages: [String]) -> [OnlineSubtitle] {
        var seen = Set<String>()
        let all = lists.flatMap { $0 }.filter { seen.insert($0.id).inserted }
        let langs = languages.map { $0.lowercased() }
        func languageRank(_ s: OnlineSubtitle) -> Int {
            guard let l = s.language?.lowercased() else { return langs.count }
            return langs.firstIndex { l == $0 || l.hasPrefix($0 + "-") } ?? langs.count
        }
        let scored = all.map { s in (s, release.map { matchScore(s.release, $0) } ?? 0) }
        return scored.sorted { a, b in
            if a.0.machineTranslated != b.0.machineTranslated { return !a.0.machineTranslated }
            // A clear match for this release beats everything else.
            let ma = a.1 >= exactThreshold, mb = b.1 >= exactThreshold
            if ma != mb { return ma }
            if ma, a.1 != b.1 { return a.1 > b.1 }
            let la = languageRank(a.0), lb = languageRank(b.0)
            if la != lb { return la < lb }
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.downloadCount != b.0.downloadCount { return a.0.downloadCount > b.0.downloadCount }
            return a.0.site.rank < b.0.site.rank
        }.map(\.0)
    }

    /// From here a release name counts as made for this release ("✓ Exact").
    public static let exactThreshold = 60

    /// How well a subtitle's release name fits the one playing, 0…100:
    /// the same name is 100; the same group and source (WEB, BluRay) count most.
    public static func matchScore(_ candidate: String, _ playing: String) -> Int {
        let a = tokens(candidate), b = tokens(playing)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 100 }
        var score = 0
        if let ga = group(candidate), let gb = group(playing), ga == gb { score += 40 }
        let sa = Set(a), sb = Set(b)
        if let source = sources.first(where: { sb.contains($0) }), sa.contains(source) { score += 20 }
        if let res = ["2160p", "1080p", "720p", "480p"].first(where: { sb.contains($0) }), sa.contains(res) { score += 5 }
        let overlap = Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
        score += Int(overlap * 35)
        return min(score, 99)
    }

    static let sources = ["web", "webrip", "webdl", "bluray", "bdrip", "brrip", "hdtv", "dvdrip", "remux", "amzn", "nf", "dsnp", "hmax", "atvp"]

    static func tokens(_ s: String) -> [String] {
        let lower = s.lowercased().replacingOccurrences(of: "web-dl", with: "webdl")
        let stem = SubtitleFileName.isSubtitle(lower) ? (lower as NSString).deletingPathExtension : lower
        return stem.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// "-ETHEL" at the end of a scene name.
    static func group(_ s: String) -> String? {
        let stem = SubtitleFileName.isSubtitle(s) ? (s as NSString).deletingPathExtension : s
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let g = stem[stem.index(after: dash)...].lowercased()
        return g.count >= 2 && g.count <= 15 && g.allSatisfy({ $0.isLetter || $0.isNumber }) ? g : nil
    }
}

extension SubtitleSite {
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

// MARK: - Subdl

/// Subtitle search on subdl.com (needs the user's free API key). Files come as ZIPs.
public struct SubdlService: Sendable {
    let apiKey: String
    let http: any HTTPClient

    public init(apiKey: String, http: any HTTPClient) { self.apiKey = apiKey; self.http = http }

    public func search(imdbID: String, episode: (season: Int, episode: Int)?, languages: [String]) async throws -> [OnlineSubtitle] {
        var c = URLComponents(string: "https://api.subdl.com/api/v1/subtitles")!
        var q = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "imdb_id", value: imdbID),
                 URLQueryItem(name: "subs_per_page", value: "30"), URLQueryItem(name: "type", value: episode == nil ? "movie" : "tv")]
        if let episode {
            q += [URLQueryItem(name: "season_number", value: String(episode.season)),
                  URLQueryItem(name: "episode_number", value: String(episode.episode))]
        }
        let langs = languages.map { $0.uppercased() }.filter { !$0.isEmpty }
        if !langs.isEmpty { q.append(URLQueryItem(name: "languages", value: langs.joined(separator: ","))) }
        c.queryItems = q
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 15
        let (data, response) = try await send(req)
        if response.statusCode == 401 || response.statusCode == 403 { throw SubtitleSearchError.unauthorized }
        guard (200..<300).contains(response.statusCode) else { throw SubtitleSearchError.server(response.statusCode) }
        struct Page: Decodable {
            struct Sub: Decodable {
                let release_name: String?, name: String?, language: String?, url: String?, hi: Bool?
                let season: Int?, episode: Int?
            }
            let status: Bool?
            let subtitles: [Sub]?
        }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw SubtitleSearchError.decoding }
        return (page.subtitles ?? []).compactMap { s in
            guard let path = s.url, let url = URL(string: "https://dl.subdl.com" + (path.hasPrefix("/") ? path : "/" + path)) else { return nil }
            return OnlineSubtitle(site: .subdl, source: .url(url, headers: [:]), language: s.language?.lowercased(),
                                  release: s.release_name ?? s.name ?? "Subtitle", hearingImpaired: s.hi ?? false, episode: episode)
        }
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await http.send(req) } catch { throw SubtitleSearchError.offline }
    }
}

// MARK: - Podnapisi

/// Subtitle search on podnapisi.net (no key), through its XML search. Files come as ZIPs.
public struct PodnapisiService: Sendable {
    let http: any HTTPClient
    static let base = "https://www.podnapisi.net/subtitles/"

    public init(http: any HTTPClient) { self.http = http }

    public func search(title: String, year: Int?, episode: (season: Int, episode: Int)?, languages: [String]) async throws -> [OnlineSubtitle] {
        let langs = languages.isEmpty ? [""] : languages.map { $0.lowercased() }
        var out: [OnlineSubtitle] = []
        for lang in langs.prefix(3) {
            var c = URLComponents(string: Self.base + "search/old")!
            var q = [URLQueryItem(name: "sXML", value: "1"), URLQueryItem(name: "sK", value: title)]
            if !lang.isEmpty { q.append(URLQueryItem(name: "sL", value: lang)) }
            if let year { q.append(URLQueryItem(name: "sY", value: String(year))) }
            if let episode {
                q += [URLQueryItem(name: "sTS", value: String(episode.season)), URLQueryItem(name: "sTE", value: String(episode.episode))]
            }
            c.queryItems = q
            var req = URLRequest(url: c.url!)
            req.timeoutInterval = 15
            let (data, response): (Data, HTTPURLResponse)
            do { (data, response) = try await http.send(req) } catch { throw SubtitleSearchError.offline }
            guard (200..<300).contains(response.statusCode) else { throw SubtitleSearchError.server(response.statusCode) }
            out += Self.parse(data, episode: episode)
        }
        return out
    }

    static func parse(_ xml: Data, episode: (season: Int, episode: Int)?) -> [OnlineSubtitle] {
        let parser = PodnapisiXML()
        let p = XMLParser(data: xml)
        p.delegate = parser
        p.parse()
        return parser.items.compactMap { item in
            guard let pid = item["pid"], !pid.isEmpty, let url = URL(string: base + pid + "/download?container=zip") else { return nil }
            let releases = (item["release"] ?? "").split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            let name = releases.first ?? [item["title"], item["year"]].compactMap { $0 }.joined(separator: " ")
            return OnlineSubtitle(site: .podnapisi, source: .url(url, headers: [:]), language: item["language"],
                                  release: name.isEmpty ? "Subtitle" : name, downloadCount: Int(item["downloads"] ?? "") ?? 0,
                                  hearingImpaired: (item["flags"] ?? "").contains("n"), episode: episode)
        }
    }

    private final class PodnapisiXML: NSObject, XMLParserDelegate {
        var items: [[String: String]] = []
        private var current: [String: String]?
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if name == "subtitle" { current = [:] }
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "subtitle", let c = current { items.append(c); current = nil }
            else if current != nil { current?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}

// MARK: - Fetching

public enum OnlineSubtitleFile {
    /// The subtitle file inside what a site sent: the data itself, or the
    /// right file from a ZIP (the episode's, else the largest subtitle).
    public static func extract(_ data: Data, episode: (season: Int, episode: Int)?) -> (data: Data, format: String)? {
        guard ZipArchive.isZip(data) else { return (data, "srt") }
        let subs = ZipArchive.entries(data).filter { SubtitleFileName.isSubtitle($0.path) }
        guard !subs.isEmpty else { return nil }
        var pick = subs.max { $0.data.count < $1.data.count }!
        if let episode, subs.count > 1 {
            let tags = [String(format: "s%02de%02d", episode.season, episode.episode), "\(episode.season)x\(String(format: "%02d", episode.episode))"]
            if let match = subs.first(where: { s in tags.contains { s.path.lowercased().contains($0) } }) { pick = match }
        }
        return (pick.data, (pick.path as NSString).pathExtension.lowercased())
    }
}
