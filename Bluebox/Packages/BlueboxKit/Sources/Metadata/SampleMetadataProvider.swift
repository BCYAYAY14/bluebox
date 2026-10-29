import Domain
import Foundation

/// Offline catalog used when no TMDB credential is configured, in previews,
/// and in UI tests. Real open-movie titles keep their real TMDB IDs so they
/// line up with `PublicCatalogSource`; fictional sample titles use IDs above
/// 9,000,000 so they can never collide with real TMDB entries.
public struct SampleMetadataProvider: MetadataProvider {
    public init() {}

    public func list(_ list: CatalogList, page: Int) async throws -> Page<Title> {
        let items: [Title] = switch list {
        case .trending: Self.titles.sorted { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
        case .popularMovies: Self.titles.filter { $0.kind == .movie }
        case .popularSeries: Self.titles.filter { $0.kind == .series }
        case .topRated: Self.titles.filter { ($0.voteAverage ?? 0) >= 7 }
        }
        return Page(items: items, page: 1, totalPages: 1)
    }

    public func search(_ query: String, page: Int) async throws -> Page<Title> {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Page(items: [], page: 1, totalPages: 1) }
        let hits = Self.titles.filter { $0.name.lowercased().contains(q) || $0.overview.lowercased().contains(q) }
        return Page(items: hits, page: 1, totalPages: 1)
    }

    public func discover(genre: Genre, kind: TitleKind, page: Int) async throws -> Page<Title> {
        Page(items: Self.titles.filter { $0.kind == kind && $0.genreIDs.contains(genre.id) }, page: 1, totalPages: 1)
    }

    public func genres() async throws -> [Genre] { Self.genres }

    /// The real open movies' IMDb IDs, so add-on sources can find their (Creative Commons) torrents.
    static let imdbIDs: [MediaKey: String] = [
        .movie(tmdbID: 133701): "tt2285752",   // Tears of Steel
        .movie(tmdbID: 9761): "tt0807840",     // Elephants Dream
        .movie(tmdbID: 45745): "tt1727587",    // Sintel
    ]

    public func detail(for key: MediaKey) async throws -> TitleDetail {
        guard let t = Self.titles.first(where: { $0.key == key }) else { throw MetadataError.notFound }
        let related = Self.titles.filter { $0.key != key && !Set($0.genreIDs).isDisjoint(with: t.genreIDs) }
        let seasons: [SeasonSummary] = t.kind == .series
            ? (1...Self.seasonCount(t)).map { SeasonSummary(number: $0, name: "Season \($0)", episodeCount: Self.episodesPerSeason) }
            : []
        return TitleDetail(
            title: t, tagline: Self.taglines[t.key], runtimeMinutes: Self.runtimes[t.key] ?? (t.kind == .series ? 48 : 104),
            genres: Self.genres.filter { t.genreIDs.contains($0.id) },
            // Real open movies get only verified facts (director); invented cast and
            // ratings are limited to the fictional sample titles.
            cast: Self.isFictional(t) ? Self.cast(for: t) : [],
            crew: [CreditPerson(id: 1, name: Self.directors[t.key] ?? "Mara Ellison", role: t.kind == .movie ? "Director" : "Creator")],
            seasons: seasons, related: related, certification: Self.isFictional(t) ? (t.kind == .movie ? "PG-13" : "TV-14") : nil,
            imdbID: Self.imdbIDs[t.key]
        )
    }

    public func season(_ number: Int, of seriesKey: MediaKey) async throws -> Season {
        guard let t = Self.titles.first(where: { $0.key == seriesKey }), let id = seriesKey.tmdbID,
              (1...Self.seasonCount(t)).contains(number) else { throw MetadataError.notFound }
        let names = Self.episodeNames[seriesKey] ?? []
        let episodes = (1...Self.episodesPerSeason).map { n in
            let idx = (number - 1) * Self.episodesPerSeason + (n - 1)
            return Episode(
                key: .episode(seriesID: id, season: number, episode: n), seasonNumber: number, number: n,
                name: idx < names.count ? names[idx] : "Chapter \(n)",
                overview: "The crew faces a new problem as the story of \(t.name) moves forward.",
                airDate: t.releaseDate.map { $0.addingTimeInterval(Double(idx) * 7 * 86_400) }, runtimeMinutes: 44 + (n % 3) * 5
            )
        }
        return Season(seriesKey: seriesKey, number: number, name: "Season \(number)", episodes: episodes)
    }

    public func imageURL(for artwork: Artwork, width: Int) -> URL? {
        artwork.path.hasPrefix("http") ? URL(string: artwork.path) : nil
    }

    // MARK: Data

    static let episodesPerSeason = 8
    static func isFictional(_ t: Title) -> Bool { (t.key.tmdbID ?? 0) >= 9_000_000 }
    static func seasonCount(_ t: Title) -> Int { t.key == .series(tmdbID: 9_100_001) ? 2 : 1 }

    static func date(_ y: Int, _ m: Int = 6, _ d: Int = 1) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    public static let genres: [Genre] = [
        Genre(id: 28, name: "Action"), Genre(id: 16, name: "Animation"), Genre(id: 35, name: "Comedy"),
        Genre(id: 18, name: "Drama"), Genre(id: 14, name: "Fantasy"), Genre(id: 9648, name: "Mystery"),
        Genre(id: 878, name: "Science Fiction"), Genre(id: 53, name: "Thriller"), Genre(id: 99, name: "Documentary"),
    ]

    public static let titles: [Title] = [
        Title(key: .movie(tmdbID: 133701), kind: .movie, name: "Tears of Steel",
              overview: "In a future Amsterdam, a group of warriors and scientists gather at the Oude Kerk to stage a desperate attempt to save the world from destructive robots.",
              releaseDate: date(2012, 9, 26), genreIDs: [878, 28]),
        Title(key: .movie(tmdbID: 9761), kind: .movie, name: "Elephants Dream",
              overview: "Two men explore the strange, ever-shifting machine world of the Machine, where one of them insists everything is perfectly safe.",
              releaseDate: date(2006, 3, 24), genreIDs: [16, 878, 14]),
        Title(key: .movie(tmdbID: 45745), kind: .movie, name: "Sintel",
              overview: "A lonely young woman searches the cold wilderness for the baby dragon she once rescued and raised.",
              releaseDate: date(2010, 9, 27), genreIDs: [16, 14, 28]),
        Title(key: .movie(tmdbID: 10378), kind: .movie, name: "Big Buck Bunny",
              overview: "A gentle giant rabbit is pushed too far by three bullying rodents and plans a comic, elaborate revenge.",
              releaseDate: date(2008, 5, 30), genreIDs: [16, 35]),
        Title(key: .movie(tmdbID: 9_000_001), kind: .movie, name: "Low Tide at Kestrel Point",
              overview: "When a lighthouse keeper's logbook surfaces forty years late, a marine biologist starts to doubt everything her island remembers.",
              releaseDate: date(2024, 10, 4), genreIDs: [9648, 18], voteAverage: 7.8),
        Title(key: .movie(tmdbID: 9_000_002), kind: .movie, name: "Night Shift Cartography",
              overview: "A courier who maps the city after dark discovers a street that only exists between 3 and 4 a.m.",
              releaseDate: date(2023, 2, 17), genreIDs: [53, 878], voteAverage: 7.1),
        Title(key: .movie(tmdbID: 9_000_003), kind: .movie, name: "The Glass Orchard",
              overview: "Three estranged sisters return to their family's greenhouse farm to find it growing something none of them planted.",
              releaseDate: date(2022, 11, 11), genreIDs: [18, 14], voteAverage: 7.3),
        Title(key: .movie(tmdbID: 9_000_004), kind: .movie, name: "Velocity Ward",
              overview: "An ER surgeon with a racing past has one night to get a stolen organ across a city in gridlock.",
              releaseDate: date(2025, 6, 20), genreIDs: [28, 53], voteAverage: 6.9),
        Title(key: .movie(tmdbID: 9_000_005), kind: .movie, name: "Small Hours",
              overview: "A late-night radio host and a caller who never gives her name build an unlikely friendship over one winter.",
              releaseDate: date(2021, 1, 15), genreIDs: [18, 35], voteAverage: 7.6),
        Title(key: .movie(tmdbID: 9_000_006), kind: .movie, name: "Under Blue Ice",
              overview: "A documentary following a research team that spends a polar winter beneath the Antarctic sea ice.",
              releaseDate: date(2024, 4, 22), genreIDs: [99], voteAverage: 8.1),
        Title(key: .series(tmdbID: 9_100_001), kind: .series, name: "Harbor Lights",
              overview: "In a fog-bound port town, a disgraced detective and a young harbor pilot unravel the smuggling ring that runs the docks.",
              releaseDate: date(2023, 9, 8), genreIDs: [9648, 18, 53], voteAverage: 8.2),
        Title(key: .series(tmdbID: 9_100_002), kind: .series, name: "The Long Orbit",
              overview: "The six-person crew of a cargo ship on a nine-year run to Saturn learns their mission was never what they were told.",
              releaseDate: date(2025, 2, 14), genreIDs: [878, 18], voteAverage: 7.9),
        Title(key: .series(tmdbID: 9_100_003), kind: .series, name: "Second Service",
              overview: "A burned-out chef reopens her late father's diner and inherits his regulars, his debts, and his secrets.",
              releaseDate: date(2024, 3, 1), genreIDs: [35, 18], voteAverage: 7.7),
    ]

    static let taglines: [MediaKey: String] = [
        .movie(tmdbID: 9_000_001): "Some tides take forty years to turn.",
        .series(tmdbID: 9_100_001): "Every ship leaves a wake.",
    ]

    static let runtimes: [MediaKey: Int] = [
        .movie(tmdbID: 133701): 12, .movie(tmdbID: 9761): 11, .movie(tmdbID: 45745): 15, .movie(tmdbID: 10378): 10,
    ]

    static let directors: [MediaKey: String] = [
        .movie(tmdbID: 133701): "Ian Hubert", .movie(tmdbID: 9761): "Bassam Kurdali",
        .movie(tmdbID: 45745): "Colin Levy", .movie(tmdbID: 10378): "Sacha Goedegebure",
    ]

    static let episodeNames: [MediaKey: [String]] = [
        .series(tmdbID: 9_100_001): [
            "Fog Bell", "The Pilot's Daughter", "Bill of Lading", "Slack Water", "Dead Reckoning", "Ballast",
            "The Breakwater", "Harbor Lights", "Return Tide", "Customs", "Neap", "Salvage Rights", "Night Crossing",
            "The Lantern Room", "Bearing", "Landfall",
        ],
        .series(tmdbID: 9_100_002): [
            "Burn", "Mass Budget", "Coast Phase", "The Second Manifest", "Perihelion", "Silence Protocol",
            "Gravity Assist", "Ring Plane",
        ],
    ]

    static func cast(for t: Title) -> [CreditPerson] {
        let names = ["Ada Okafor", "Luis Herrera", "Mina Sato", "Theo Lindqvist", "Priya Raman", "Jonah Weiss", "Clara Dufort", "Sam Adeyemi"]
        let roles = ["Lead", "Detective", "Pilot", "Engineer", "Captain", "Doctor", "Courier", "Narrator"]
        let seed = abs(t.key.rawValue.hashValue % 3)
        return (0..<6).map { i in
            let j = (i + seed) % names.count
            return CreditPerson(id: 100 + j, name: names[j], role: roles[(i + j) % roles.count])
        }
    }
}
