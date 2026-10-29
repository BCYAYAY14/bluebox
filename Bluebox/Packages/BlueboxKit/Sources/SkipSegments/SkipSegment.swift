import Foundation

/// A part of an episode or film the viewer may want to skip.
public struct SkipSegment: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Opening titles or theme song.
        case intro
        /// "Previously on…".
        case recap
        /// End credits (and an outro song).
        case credits
        /// A preview of the next episode after the credits.
        case preview
    }

    public enum Source: String, Codable, Sendable, Comparable {
        /// Chapter markers in the file. Exact for this release.
        case chapters
        /// The Jellyfin server's media segments for this item.
        case jellyfin
        /// TheIntroDB (theintrodb.org), crowd-sourced.
        case theIntroDB
        /// IntroDB (introdb.app), crowd-sourced.
        case introDB

        /// Lower is preferred.
        var rank: Int {
            switch self {
            case .chapters: 0
            case .jellyfin: 1
            case .theIntroDB: 2
            case .introDB: 3
            }
        }

        public static func < (a: Source, b: Source) -> Bool { a.rank < b.rank }

        /// Crowd timestamps were timed on someone else's copy and can be off for this release.
        public var isCrowdSourced: Bool { self == .theIntroDB || self == .introDB }

        public var displayName: String {
            switch self {
            case .chapters: "Chapter markers in the file"
            case .jellyfin: "Jellyfin"
            case .theIntroDB: "TheIntroDB"
            case .introDB: "IntroDB"
            }
        }
    }

    public var kind: Kind
    /// Seconds from the start of the file.
    public var start: TimeInterval
    /// nil runs to the end of the file.
    public var end: TimeInterval?
    public var source: Source

    public init(kind: Kind, start: TimeInterval, end: TimeInterval?, source: Source) {
        self.kind = kind; self.start = start; self.end = end; self.source = source
    }

    /// The end, with "to the end of the file" resolved against `duration`.
    public func resolvedEnd(duration: TimeInterval?) -> TimeInterval? { end ?? duration }

    /// True while `position` is inside the segment.
    public func contains(_ position: TimeInterval, duration: TimeInterval?) -> Bool {
        guard position >= start else { return false }
        guard let end = resolvedEnd(duration: duration) else { return true }
        return position < end
    }
}

/// What a lookup needs to know about the item that's playing.
public struct SkipSegmentQuery: Hashable, Sendable {
    /// Chapter titles and start times from the file.
    public var chapters: [ChapterMark]
    /// Length of the file, when known. Used to sanity-check crowd timestamps
    /// and, for TheIntroDB, to pick the closest release version.
    public var duration: TimeInterval?
    public var tmdbID: Int?
    public var imdbID: String?
    /// Season and episode for TV; nil for films.
    public var season: Int?
    public var episode: Int?
    /// Set when the item plays from a Jellyfin server.
    public var jellyfin: JellyfinItemRef?
    /// False when the viewer said crowd timestamps are wrong for this show.
    public var allowsCrowdSources: Bool

    public init(chapters: [ChapterMark] = [], duration: TimeInterval? = nil, tmdbID: Int? = nil, imdbID: String? = nil,
                season: Int? = nil, episode: Int? = nil, jellyfin: JellyfinItemRef? = nil, allowsCrowdSources: Bool = true) {
        self.chapters = chapters; self.duration = duration; self.tmdbID = tmdbID; self.imdbID = imdbID
        self.season = season; self.episode = episode; self.jellyfin = jellyfin; self.allowsCrowdSources = allowsCrowdSources
    }

    /// Key for the crowd-source cache: the same title and episode (not the release).
    var crowdCacheKey: String? {
        let id = tmdbID.map { "tmdb\($0)" } ?? imdbID
        guard let id else { return nil }
        if let season, let episode { return "\(id).s\(season)e\(episode)" }
        return id
    }
}

/// A chapter as the engine reports it.
public struct ChapterMark: Hashable, Sendable {
    public var title: String
    public var start: TimeInterval
    public init(title: String, start: TimeInterval) { self.title = title; self.start = start }
}

/// Where a Jellyfin item lives, for its `/MediaSegments` call.
public struct JellyfinItemRef: Hashable, Sendable {
    public var server: URL
    public var itemID: String
    public var token: String
    public init(server: URL, itemID: String, token: String) { self.server = server; self.itemID = itemID; self.token = token }

    /// Reads server, item and token from a Jellyfin stream URL
    /// (`<server>/Videos/<id>/stream.mp4?static=true&ApiKey=<token>` or `…/master.m3u8?…`).
    public init?(streamURL url: URL, itemID: String) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = comps.queryItems?.first(where: { $0.name.lowercased() == "apikey" || $0.name.lowercased() == "api_key" })?.value,
              let range = url.path.range(of: "/Videos/", options: .caseInsensitive) else { return nil }
        var base = comps
        base.query = nil
        base.path = String(url.path[..<range.lowerBound])
        guard let server = base.url else { return nil }
        self.init(server: server, itemID: itemID, token: token)
    }
}
