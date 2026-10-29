import Foundation

/// Stable, source-independent identifier for something the user can watch or track.
///
/// Keys are plain strings so they round-trip through SwiftData, JSON, and the
/// Supabase `media_key` column unchanged. Format:
///
///     tmdb:movie:<id>
///     tmdb:tv:<id>
///     tmdb:tv:<id>:s<season>e<episode>
///     imdb:movie:<tt…>            (Cinemeta catalog, used without a TMDB key)
///     imdb:tv:<tt…>
///     imdb:tv:<tt…>:s<season>e<episode>
///     local:<sha-prefix>          (unmatched local files)
///     url:<sha-prefix>            (unmatched direct URLs)
public struct MediaKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static func movie(tmdbID: Int) -> MediaKey { .init(rawValue: "tmdb:movie:\(tmdbID)") }
    public static func series(tmdbID: Int) -> MediaKey { .init(rawValue: "tmdb:tv:\(tmdbID)") }
    public static func episode(seriesID: Int, season: Int, episode: Int) -> MediaKey {
        .init(rawValue: "tmdb:tv:\(seriesID):s\(season)e\(episode)")
    }

    /// IMDb-keyed titles, used by the Cinemeta catalog when there's no TMDB key.
    public static func movie(imdbID: String) -> MediaKey { .init(rawValue: "imdb:movie:\(imdbID)") }
    public static func series(imdbID: String) -> MediaKey { .init(rawValue: "imdb:tv:\(imdbID)") }
    public static func episode(imdbSeriesID: String, season: Int, episode: Int) -> MediaKey {
        .init(rawValue: "imdb:tv:\(imdbSeriesID):s\(season)e\(episode)")
    }

    /// For an episode key, the key of its parent series; otherwise `nil`.
    public var seriesKey: MediaKey? {
        let parts = rawValue.split(separator: ":")
        guard parts.count == 4, parts[1] == "tv" else { return nil }
        if parts[0] == "tmdb", let id = Int(parts[2]) { return .series(tmdbID: id) }
        if parts[0] == "imdb" { return .series(imdbID: String(parts[2])) }
        return nil
    }

    /// For a series key (TMDB or IMDb), the key of one of its episodes.
    public func episode(season: Int, episode: Int) -> MediaKey? {
        guard isSeries else { return nil }
        return MediaKey(rawValue: "\(rawValue):s\(season)e\(episode)")
    }

    /// The IMDb ID of an `imdb:` key (the series' ID for an episode).
    public var imdbID: String? {
        let parts = rawValue.split(separator: ":")
        guard parts.count >= 3, parts[0] == "imdb" else { return nil }
        return String(parts[2])
    }

    /// True for a movie key from either catalog.
    public var isMovie: Bool {
        let p = rawValue.split(separator: ":")
        return p.count == 3 && p[1] == "movie"
    }

    /// True for a series key (not an episode) from either catalog.
    public var isSeries: Bool {
        let p = rawValue.split(separator: ":")
        return p.count == 3 && p[1] == "tv"
    }

    /// Season/episode numbers for an episode key.
    public var episodeNumbers: (season: Int, episode: Int)? {
        guard seriesKey != nil, let last = rawValue.split(separator: ":").last else { return nil }
        let scanner = Scanner(string: String(last))
        guard scanner.scanString("s") != nil, let s = scanner.scanInt(),
              scanner.scanString("e") != nil, let e = scanner.scanInt(), scanner.isAtEnd else { return nil }
        return (s, e)
    }

    public var tmdbID: Int? {
        let parts = rawValue.split(separator: ":")
        guard parts.count >= 3, parts[0] == "tmdb" else { return nil }
        return Int(parts[2])
    }

    public var description: String { rawValue }
    public static func < (lhs: MediaKey, rhs: MediaKey) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
