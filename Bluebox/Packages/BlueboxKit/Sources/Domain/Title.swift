import Foundation

public enum TitleKind: String, Codable, Sendable, Hashable {
    case movie
    case series
}

public struct Genre: Hashable, Codable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public init(id: Int, name: String) { self.id = id; self.name = name }
}

/// Reference to a piece of artwork. `path` is provider-relative (a TMDB file path
/// such as `/abc.jpg`) or an absolute URL string; the image pipeline resolves it.
public struct Artwork: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case poster, backdrop, logo, still, profile }
    public let kind: Kind
    public let path: String
    public init(_ kind: Kind, path: String) { self.kind = kind; self.path = path }
}

/// Lightweight catalog entry used in rows, grids, and search results.
///
/// A `Title` describes *metadata only*. It never implies that a playable source
/// exists; availability comes from `MediaSourceRegistry`.
public struct Title: Hashable, Codable, Sendable, Identifiable {
    public let key: MediaKey
    public let kind: TitleKind
    public let name: String
    public let overview: String
    public let releaseDate: Date?
    public let genreIDs: [Int]
    public let voteAverage: Double?
    public let poster: Artwork?
    public let backdrop: Artwork?

    public var id: MediaKey { key }
    public var year: Int? { releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) } }

    public init(
        key: MediaKey, kind: TitleKind, name: String, overview: String = "", releaseDate: Date? = nil,
        genreIDs: [Int] = [], voteAverage: Double? = nil, poster: Artwork? = nil, backdrop: Artwork? = nil
    ) {
        self.key = key; self.kind = kind; self.name = name; self.overview = overview
        self.releaseDate = releaseDate; self.genreIDs = genreIDs; self.voteAverage = voteAverage
        self.poster = poster; self.backdrop = backdrop
    }
}

public struct CreditPerson: Hashable, Codable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let role: String   // character for cast, job for crew
    public let profile: Artwork?
    public init(id: Int, name: String, role: String, profile: Artwork? = nil) {
        self.id = id; self.name = name; self.role = role; self.profile = profile
    }
}

public struct SeasonSummary: Hashable, Codable, Sendable, Identifiable {
    public let number: Int
    public let name: String
    public let episodeCount: Int
    public let poster: Artwork?
    public var id: Int { number }
    public init(number: Int, name: String, episodeCount: Int, poster: Artwork? = nil) {
        self.number = number; self.name = name; self.episodeCount = episodeCount; self.poster = poster
    }
}

public struct Episode: Hashable, Codable, Sendable, Identifiable {
    public let key: MediaKey
    public let seasonNumber: Int
    public let number: Int
    public let name: String
    public let overview: String
    public let airDate: Date?
    public let runtimeMinutes: Int?
    public let still: Artwork?
    public var id: MediaKey { key }
    public init(
        key: MediaKey, seasonNumber: Int, number: Int, name: String, overview: String = "",
        airDate: Date? = nil, runtimeMinutes: Int? = nil, still: Artwork? = nil
    ) {
        self.key = key; self.seasonNumber = seasonNumber; self.number = number; self.name = name
        self.overview = overview; self.airDate = airDate; self.runtimeMinutes = runtimeMinutes; self.still = still
    }
    public var code: String { "S\(seasonNumber)·E\(number)" }
}

public struct Season: Hashable, Codable, Sendable {
    public let seriesKey: MediaKey
    public let number: Int
    public let name: String
    public let overview: String
    public let episodes: [Episode]
    public init(seriesKey: MediaKey, number: Int, name: String, overview: String = "", episodes: [Episode]) {
        self.seriesKey = seriesKey; self.number = number; self.name = name; self.overview = overview; self.episodes = episodes
    }
}

/// Full detail for a movie or series.
public struct TitleDetail: Hashable, Codable, Sendable {
    public let title: Title
    public let tagline: String?
    public let runtimeMinutes: Int?
    public let genres: [Genre]
    public let cast: [CreditPerson]
    public let crew: [CreditPerson]
    public let logo: Artwork?
    public let seasons: [SeasonSummary]   // empty for movies
    public let related: [Title]
    public let certification: String?
    /// IMDb ID (`tt…`), used to look up external ratings.
    public let imdbID: String?
    /// The franchise a film belongs to (TMDB only).
    public let collection: CollectionRef?

    public init(
        title: Title, tagline: String? = nil, runtimeMinutes: Int? = nil, genres: [Genre] = [],
        cast: [CreditPerson] = [], crew: [CreditPerson] = [], logo: Artwork? = nil,
        seasons: [SeasonSummary] = [], related: [Title] = [], certification: String? = nil, imdbID: String? = nil,
        collection: CollectionRef? = nil
    ) {
        self.title = title; self.tagline = tagline; self.runtimeMinutes = runtimeMinutes; self.genres = genres
        self.cast = cast; self.crew = crew; self.logo = logo; self.seasons = seasons; self.related = related
        self.certification = certification; self.imdbID = imdbID; self.collection = collection
    }
}

/// A film's franchise as its page names it: "Part of the Alien Collection".
public struct CollectionRef: Hashable, Codable, Sendable, Identifiable {
    /// TMDB collection ID.
    public let id: Int
    public let name: String
    public let poster: Artwork?
    public let backdrop: Artwork?

    public init(id: Int, name: String, poster: Artwork? = nil, backdrop: Artwork? = nil) {
        self.id = id; self.name = name; self.poster = poster; self.backdrop = backdrop
    }
}

public struct Page<Item: Sendable & Hashable>: Sendable, Hashable {
    public let items: [Item]
    public let page: Int
    public let totalPages: Int
    public init(items: [Item], page: Int, totalPages: Int) {
        self.items = items; self.page = page; self.totalPages = totalPages
    }
    public var hasMore: Bool { page < totalPages }
}
