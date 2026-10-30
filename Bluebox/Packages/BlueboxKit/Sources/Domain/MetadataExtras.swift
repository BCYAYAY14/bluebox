import Foundation

// Catalog data beyond titles: trailers and extras, airing schedules, and
// people. Providers that can't answer (the sample catalog, Cinemeta for most
// of it) throw `MetadataError.notFound` through the default implementations.

// MARK: - Trailers and extras

/// One video about a title: a trailer, teaser, featurette… Only YouTube
/// videos are kept, since that's what the player can show.
public struct TitleVideo: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case trailer, teaser, featurette, behindTheScenes, clip, other

        public var label: String {
            switch self {
            case .trailer: "Trailer"
            case .teaser: "Teaser"
            case .featurette: "Featurette"
            case .behindTheScenes: "Behind the Scenes"
            case .clip: "Clip"
            case .other: "Extra"
            }
        }

        /// TMDB's `type` strings.
        public init(tmdbType: String?) {
            switch tmdbType?.lowercased() {
            case "trailer": self = .trailer
            case "teaser": self = .teaser
            case "featurette": self = .featurette
            case "behind the scenes": self = .behindTheScenes
            case "clip": self = .clip
            default: self = .other
            }
        }
    }

    public let id: String
    /// YouTube video ID.
    public let youtubeKey: String
    public let name: String
    public let kind: Kind
    public let isOfficial: Bool
    /// ISO 639-1, or nil when the video has no language.
    public let language: String?
    public let publishedAt: Date?
    /// Vertical resolution TMDB reports (1080, 720…).
    public let size: Int?
    /// Season number for a season's videos.
    public let season: Int?

    public init(id: String, youtubeKey: String, name: String, kind: Kind, isOfficial: Bool = true, language: String? = nil,
                publishedAt: Date? = nil, size: Int? = nil, season: Int? = nil) {
        self.id = id; self.youtubeKey = youtubeKey; self.name = name; self.kind = kind; self.isOfficial = isOfficial
        self.language = language; self.publishedAt = publishedAt; self.size = size; self.season = season
    }

    /// YouTube's 480×360 thumbnail (always exists, unlike maxres).
    public var thumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(youtubeKey)/hqdefault.jpg") }
    /// Opens the video on YouTube (share, open in browser).
    public var watchURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(youtubeKey)") }
}

/// Orders videos the way a title page wants them.
public enum VideoRanking {
    /// Trailers, then teasers, featurettes, behind the scenes, clips and the
    /// rest. Within a kind: official first, the user's language first (then
    /// language-neutral, then English), bigger first, newest first.
    public static func sorted(_ videos: [TitleVideo], language: String) -> [TitleVideo] {
        let lang = String(language.prefix(2)).lowercased()
        func langRank(_ v: TitleVideo) -> Int {
            switch v.language?.lowercased() {
            case lang: 0
            case nil: 1
            case "en": 2
            default: 3
            }
        }
        let kindOrder = Dictionary(uniqueKeysWithValues: TitleVideo.Kind.allCases.enumerated().map { ($1, $0) })
        var seen = Set<String>()
        return videos.filter { seen.insert($0.youtubeKey).inserted }.sorted { a, b in
            if a.kind != b.kind { return kindOrder[a.kind]! < kindOrder[b.kind]! }
            if a.isOfficial != b.isOfficial { return a.isOfficial }
            if langRank(a) != langRank(b) { return langRank(a) < langRank(b) }
            if (a.size ?? 0) != (b.size ?? 0) { return (a.size ?? 0) > (b.size ?? 0) }
            return (a.publishedAt ?? .distantPast) > (b.publishedAt ?? .distantPast)
        }
    }

    /// The video for a muted hero: the best trailer, else the best teaser.
    /// Videos in another language don't qualify unless nothing else does.
    public static func heroTrailer(_ videos: [TitleVideo], language: String) -> TitleVideo? {
        let lang = String(language.prefix(2)).lowercased()
        let candidates = sorted(videos, language: language).filter { $0.kind == .trailer || $0.kind == .teaser }
        return candidates.first { $0.language == nil || $0.language == lang || $0.language == "en" } ?? candidates.first
    }
}

// MARK: - Airing

/// Where a series stands: its last and next episodes.
public struct AiringInfo: Hashable, Codable, Sendable {
    public let seriesKey: MediaKey
    /// "Returning Series", "Ended", "Canceled", "In Production"…
    public let status: String?
    public let lastEpisode: Episode?
    public let nextEpisode: Episode?

    public init(seriesKey: MediaKey, status: String?, lastEpisode: Episode?, nextEpisode: Episode?) {
        self.seriesKey = seriesKey; self.status = status; self.lastEpisode = lastEpisode; self.nextEpisode = nextEpisode
    }

    /// Still making episodes.
    public var isOngoing: Bool {
        guard let status = status?.lowercased() else { return nextEpisode != nil }
        return !(status.contains("ended") || status.contains("cancel"))
    }
}

// MARK: - People

/// Someone in the cast or crew.
public struct Person: Hashable, Codable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let profile: Artwork?
    /// "Acting", "Directing", "Writing"…
    public let department: String?
    public let biography: String
    public let birthday: Date?
    public let deathday: Date?
    public let placeOfBirth: String?
    public let popularity: Double?
    public let imdbID: String?

    public init(id: Int, name: String, profile: Artwork? = nil, department: String? = nil, biography: String = "",
                birthday: Date? = nil, deathday: Date? = nil, placeOfBirth: String? = nil, popularity: Double? = nil,
                imdbID: String? = nil) {
        self.id = id; self.name = name; self.profile = profile; self.department = department; self.biography = biography
        self.birthday = birthday; self.deathday = deathday; self.placeOfBirth = placeOfBirth; self.popularity = popularity
        self.imdbID = imdbID
    }

    /// Age today, or at death.
    public func age(on date: Date = Date()) -> Int? {
        guard let birthday else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.year], from: birthday, to: deathday ?? date).year
    }
}

/// One title someone worked on, with every role they had in it.
public struct Credit: Hashable, Codable, Sendable, Identifiable {
    public let title: Title
    /// Characters played and jobs done, e.g. ["Neo"] or ["Director", "Writer"].
    public let roles: [String]
    /// "Acting", "Directing"… The first department this credit was found in.
    public let department: String
    public let episodeCount: Int?
    public let popularity: Double
    public let voteCount: Int

    public var id: MediaKey { title.key }
    /// "Neo", "Director, Writer", "Self (12 episodes)"
    public var roleText: String {
        let base = roles.filter { !$0.isEmpty }.joined(separator: ", ")
        guard let n = episodeCount, n > 0, title.kind == .series else { return base }
        let eps = n == 1 ? "1 episode" : "\(n) episodes"
        return base.isEmpty ? eps : "\(base) · \(eps)"
    }

    public init(title: Title, roles: [String], department: String, episodeCount: Int? = nil, popularity: Double = 0,
                voteCount: Int = 0) {
        self.title = title; self.roles = roles; self.department = department; self.episodeCount = episodeCount
        self.popularity = popularity; self.voteCount = voteCount
    }
}

/// A person's work: what they're known for, then movies and shows by year.
public struct Filmography: Hashable, Codable, Sendable {
    public let knownFor: [Credit]
    /// Newest first; unreleased (no date) first of all.
    public let movies: [Credit]
    public let shows: [Credit]

    public init(knownFor: [Credit], movies: [Credit], shows: [Credit]) {
        self.knownFor = knownFor; self.movies = movies; self.shows = shows
    }

    public static let empty = Filmography(knownFor: [], movies: [], shows: [])

    /// Builds a filmography from raw credits: one entry per title (roles
    /// merged), talk shows and news left out of Known For and self-appearances
    /// ranked last, Known For by votes and popularity in the person's own
    /// department.
    public static func build(from credits: [Credit], department: String?) -> Filmography {
        var merged: [MediaKey: Credit] = [:]
        var departments: [MediaKey: Set<String>] = [:]
        var order: [MediaKey] = []
        for c in credits {
            departments[c.title.key, default: []].insert(c.department)
            if let existing = merged[c.title.key] {
                var roles = existing.roles
                for r in c.roles where !r.isEmpty && !roles.contains(r) { roles.append(r) }
                merged[c.title.key] = Credit(title: existing.title, roles: roles, department: existing.department,
                                             episodeCount: max(existing.episodeCount ?? 0, c.episodeCount ?? 0).nonZero,
                                             popularity: max(existing.popularity, c.popularity),
                                             voteCount: max(existing.voteCount, c.voteCount))
            } else {
                merged[c.title.key] = c
                order.append(c.title.key)
            }
        }
        let all = order.compactMap { merged[$0] }
        let byYear: (Credit, Credit) -> Bool = { a, b in
            switch (a.title.releaseDate, b.title.releaseDate) {
            case (nil, nil): return a.popularity > b.popularity
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x != y ? x > y : a.popularity > b.popularity
            }
        }
        let nonPerformance: Set<Int> = [10767, 10763]  // talk, news
        func isSelf(_ c: Credit) -> Bool {
            c.roles.contains { r in ["self", "himself", "herself", "themselves", "narrator"].contains { r.lowercased().hasPrefix($0) } }
        }
        let preferred = department.flatMap { d in departments.values.contains { $0.contains(d) } ? d : nil }
        let known = all
            .filter { c in preferred.map { departments[c.title.key]?.contains($0) ?? false } ?? true }
            .filter { $0.title.genreIDs.allSatisfy { !nonPerformance.contains($0) } && !isSelf($0) && $0.title.releaseDate != nil }
            .sorted { score($0) > score($1) }
            .prefix(10)
        return Filmography(knownFor: Array(known),
                           movies: all.filter { $0.title.kind == .movie }.sorted(by: byYear),
                           shows: all.filter { $0.title.kind == .series }.sorted(by: byYear))
    }

    /// Votes say what people have seen; popularity says what's current.
    static func score(_ c: Credit) -> Double {
        Double(c.voteCount) + c.popularity * 10
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

/// Who made a title, for its page.
public struct TitleCredits: Hashable, Codable, Sendable {
    /// Directors of a movie.
    public let directors: [CreditPerson]
    /// Creators of a series.
    public let creators: [CreditPerson]
    public let writers: [CreditPerson]
    /// In billing order; `role` is the character.
    public let cast: [CreditPerson]
    /// Producers, composer, cinematographer, editor…; `role` is the job.
    public let crew: [CreditPerson]
    /// False when people have no pages (Cinemeta only knows names).
    public let hasPersonPages: Bool

    public init(directors: [CreditPerson] = [], creators: [CreditPerson] = [], writers: [CreditPerson] = [],
                cast: [CreditPerson] = [], crew: [CreditPerson] = [], hasPersonPages: Bool = true) {
        self.directors = directors; self.creators = creators; self.writers = writers; self.cast = cast
        self.crew = crew; self.hasPersonPages = hasPersonPages
    }

    public static let empty = TitleCredits()

    public var isEmpty: Bool { directors.isEmpty && creators.isEmpty && writers.isEmpty && cast.isEmpty && crew.isEmpty }

    /// Everyone grouped by department for the full Cast & Crew page, in order.
    public var departments: [(name: String, people: [CreditPerson])] {
        var out: [(String, [CreditPerson])] = []
        if !directors.isEmpty { out.append((directors.count == 1 ? "Director" : "Directors", directors)) }
        if !creators.isEmpty { out.append((creators.count == 1 ? "Creator" : "Creators", creators)) }
        if !cast.isEmpty { out.append(("Cast", cast)) }
        if !writers.isEmpty { out.append(("Writing", writers)) }
        let groups = Dictionary(grouping: crew) { TitleCredits.department(forJob: $0.role) }
        for name in ["Production", "Sound", "Camera", "Editing", "Art", "Costume & Make-Up", "Visual Effects", "Crew"] {
            if let people = groups[name], !people.isEmpty { out.append((name, people)) }
        }
        return out
    }

    static func department(forJob job: String) -> String {
        let j = job.lowercased()
        if j.contains("producer") || j.contains("casting") { return "Production" }
        if j.contains("music") || j.contains("composer") || j.contains("sound") { return "Sound" }
        if j.contains("photography") || j.contains("camera") || j.contains("cinematograph") { return "Camera" }
        if j.contains("editor") { return "Editing" }
        if j.contains("design") || j.contains("art direction") || j.contains("set decoration") { return "Art" }
        if j.contains("costume") || j.contains("makeup") || j.contains("make-up") || j.contains("hair") { return "Costume & Make-Up" }
        if j.contains("visual effects") || j.contains("vfx") { return "Visual Effects" }
        return "Crew"
    }
}

// MARK: - Collections

/// A film franchise (TMDB's collections): its films in release order.
public struct FilmCollection: Hashable, Codable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let overview: String
    public let poster: Artwork?
    public let backdrop: Artwork?
    /// Oldest first; films without a date (announced, not dated) last.
    public let parts: [Title]

    public init(id: Int, name: String, overview: String = "", poster: Artwork? = nil, backdrop: Artwork? = nil, parts: [Title]) {
        self.id = id; self.name = name; self.overview = overview; self.poster = poster; self.backdrop = backdrop
        self.parts = Self.ordered(parts)
    }

    public var ref: CollectionRef { CollectionRef(id: id, name: name, poster: poster, backdrop: backdrop) }

    /// Release order; undated films last, in the order given.
    public static func ordered(_ parts: [Title]) -> [Title] {
        parts.enumerated().sorted { a, b in
            switch (a.element.releaseDate, b.element.releaseDate) {
            case let (x?, y?) where x != y: x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }
}

// MARK: - Provider

/// Optional catalog extras. `MetadataProvider`s adopt this when their
/// service can answer; callers check with `as? MetadataExtras`.
public protocol MetadataExtras: Sendable {
    /// Videos for a movie or series, or for one season when `season` is set.
    func videos(for key: MediaKey, season: Int?) async throws -> [TitleVideo]
    /// A series' last and next episodes.
    func airing(for seriesKey: MediaKey) async throws -> AiringInfo
    /// Upcoming films (wide releases) for Coming Soon.
    func upcomingMovies(page: Int) async throws -> Page<Title>
    func credits(for key: MediaKey) async throws -> TitleCredits
    func person(id: Int) async throws -> Person
    func filmography(personID: Int) async throws -> Filmography
    /// People whose name matches `query`, most popular first (Search's People row).
    func searchPeople(_ query: String) async throws -> [Person]
    /// A film collection by its TMDB ID.
    func collection(id: Int) async throws -> FilmCollection
}

public extension MetadataExtras {
    func videos(for key: MediaKey, season: Int?) async throws -> [TitleVideo] { throw MetadataError.notFound }
    func airing(for seriesKey: MediaKey) async throws -> AiringInfo { throw MetadataError.notFound }
    func upcomingMovies(page: Int) async throws -> Page<Title> { Page(items: [], page: 1, totalPages: 1) }
    func credits(for key: MediaKey) async throws -> TitleCredits { throw MetadataError.notFound }
    func person(id: Int) async throws -> Person { throw MetadataError.notFound }
    func filmography(personID: Int) async throws -> Filmography { throw MetadataError.notFound }
    /// No people search: an empty answer, not a failure.
    func searchPeople(_ query: String) async throws -> [Person] { [] }
    func collection(id: Int) async throws -> FilmCollection { throw MetadataError.notFound }
}
