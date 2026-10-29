import Domain
import Foundation

// Wire formats for TMDB v3. Only fields Bluebox uses are decoded; everything
// is optional because TMDB omits or nulls fields freely.

struct TMDBPage<T: Decodable>: Decodable {
    let page: Int
    let results: [T]
    let totalPages: Int?
}

struct TMDBListItem: Decodable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let overview: String?
    let releaseDate: String?
    let firstAirDate: String?
    let genreIds: [Int]?
    let voteAverage: Double?
    let posterPath: String?
    let backdropPath: String?
}

struct TMDBGenreList: Decodable { let genres: [TMDBGenre] }
struct TMDBGenre: Decodable { let id: Int; let name: String }

struct TMDBCredits: Decodable {
    struct Cast: Decodable { let id: Int; let name: String; let character: String?; let profilePath: String?; let order: Int? }
    struct Crew: Decodable { let id: Int; let name: String; let job: String?; let profilePath: String? }
    let cast: [Cast]?
    let crew: [Crew]?
}

struct TMDBImages: Decodable {
    // With .convertFromSnakeCase, "iso_639_1" decodes as "iso6391".
    struct Image: Decodable { let filePath: String; let iso6391: String?; let voteAverage: Double? }
    let logos: [Image]?
}

struct TMDBReleaseDates: Decodable {
    struct Country: Decodable {
        struct Entry: Decodable { let certification: String? }
        let iso31661: String
        let releaseDates: [Entry]
    }
    let results: [Country]
}

struct TMDBContentRatings: Decodable {
    struct Entry: Decodable { let iso31661: String; let rating: String? }
    let results: [Entry]
}

struct TMDBMovieDetail: Decodable {
    let id: Int
    let title: String
    let overview: String?
    let tagline: String?
    let releaseDate: String?
    let runtime: Int?
    let imdbId: String?
    let genres: [TMDBGenre]?
    let voteAverage: Double?
    let posterPath: String?
    let backdropPath: String?
    let credits: TMDBCredits?
    let images: TMDBImages?
    let recommendations: TMDBPage<TMDBListItem>?
    let releaseDates: TMDBReleaseDates?
}

struct TMDBSeriesDetail: Decodable {
    struct SeasonDTO: Decodable { let seasonNumber: Int; let name: String?; let episodeCount: Int?; let posterPath: String? }
    let id: Int
    let name: String
    let overview: String?
    let tagline: String?
    let firstAirDate: String?
    let episodeRunTime: [Int]?
    let genres: [TMDBGenre]?
    let voteAverage: Double?
    let posterPath: String?
    let backdropPath: String?
    let seasons: [SeasonDTO]?
    let credits: TMDBCredits?
    let images: TMDBImages?
    let recommendations: TMDBPage<TMDBListItem>?
    let contentRatings: TMDBContentRatings?
    let externalIds: TMDBExternalIDs?
}

struct TMDBSeasonDetail: Decodable {
    struct EpisodeDTO: Decodable {
        let episodeNumber: Int
        let seasonNumber: Int
        let name: String?
        let overview: String?
        let airDate: String?
        let runtime: Int?
        let stillPath: String?
    }
    let seasonNumber: Int
    let name: String?
    let overview: String?
    let episodes: [EpisodeDTO]?
}

enum TMDBMapping {
    /// Keeps only well-formed IMDb IDs (`tt` followed by digits).
    static func imdbID(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("tt"), raw.count > 2, raw.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return raw
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return dateFormatter.date(from: s)
    }

    static func art(_ kind: Artwork.Kind, _ path: String?) -> Artwork? {
        guard let path, !path.isEmpty else { return nil }
        return Artwork(kind, path: path)
    }

    /// `fallbackKind` is used by endpoints that don't include `media_type`.
    static func title(_ item: TMDBListItem, fallbackKind: TitleKind?) -> Title? {
        let kind: TitleKind
        switch item.mediaType {
        case "movie": kind = .movie
        case "tv": kind = .series
        case nil: guard let fallbackKind else { return nil }; kind = fallbackKind
        default: return nil // "person" and anything new
        }
        guard let name = item.title ?? item.name else { return nil }
        return Title(
            key: kind == .movie ? .movie(tmdbID: item.id) : .series(tmdbID: item.id),
            kind: kind, name: name, overview: item.overview ?? "",
            releaseDate: date(item.releaseDate ?? item.firstAirDate), genreIDs: item.genreIds ?? [],
            voteAverage: item.voteAverage, poster: art(.poster, item.posterPath), backdrop: art(.backdrop, item.backdropPath)
        )
    }

    static func people(_ credits: TMDBCredits?) -> (cast: [CreditPerson], crew: [CreditPerson]) {
        let cast = (credits?.cast ?? [])
            .sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            .prefix(20)
            .map { CreditPerson(id: $0.id, name: $0.name, role: $0.character ?? "", profile: art(.profile, $0.profilePath)) }
        let keyJobs: Set<String> = ["Director", "Screenplay", "Writer", "Creator", "Executive Producer", "Original Music Composer"]
        var seen = Set<String>()
        let crew = (credits?.crew ?? []).filter { keyJobs.contains($0.job ?? "") }.compactMap { c -> CreditPerson? in
            guard seen.insert("\(c.id)-\(c.job ?? "")").inserted else { return nil }
            return CreditPerson(id: c.id, name: c.name, role: c.job ?? "", profile: art(.profile, c.profilePath))
        }
        return (Array(cast), Array(crew.prefix(8)))
    }

    /// Prefers an English logo, then a language-neutral one, then any.
    static func logo(_ images: TMDBImages?, language: String) -> Artwork? {
        let logos = images?.logos ?? []
        let pick = logos.first { $0.iso6391 == language } ?? logos.first { $0.iso6391 == nil } ?? logos.first
        return art(.logo, pick?.filePath)
    }
}

struct TMDBExternalIDs: Decodable {
    let imdbId: String?
}
