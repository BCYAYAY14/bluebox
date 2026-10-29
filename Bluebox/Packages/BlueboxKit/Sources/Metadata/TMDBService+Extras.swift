import Domain
import Foundation

// Trailers and extras, airing schedules, credits and people from TMDB.

extension TMDBService: MetadataExtras {
    /// Two-letter language of the catalog ("en" for "en-US").
    var languageCode: String { String(language.prefix(2)).lowercased() }

    public func videos(for key: MediaKey, season: Int?) async throws -> [TitleVideo] {
        guard let id = (key.seriesKey ?? key).tmdbID else { throw MetadataError.notFound }
        let path: String
        if key.isMovie {
            path = "movie/\(id)/videos"
        } else if let season {
            path = "tv/\(id)/season/\(season)/videos"
        } else {
            path = "tv/\(id)/videos"
        }
        // Videos in the catalog language, English, and ones without a language.
        let langs = Array(Set([languageCode, "en"])).sorted().joined(separator: ",") + ",null"
        let list = try await get(TMDBVideoList.self, path, query: ["include_video_language": langs])
        return VideoRanking.sorted(list.results.compactMap { TMDBMapping.video($0, season: season) }, language: languageCode)
    }

    public func airing(for seriesKey: MediaKey) async throws -> AiringInfo {
        guard let id = seriesKey.tmdbID, seriesKey.isSeries else { throw MetadataError.notFound }
        let d = try await get(TMDBAiring.self, "tv/\(id)")
        return AiringInfo(seriesKey: seriesKey, status: d.status,
                          lastEpisode: d.lastEpisodeToAir.map { TMDBMapping.episode($0, seriesID: id) },
                          nextEpisode: d.nextEpisodeToAir.map { TMDBMapping.episode($0, seriesID: id) })
    }

    public func upcomingMovies(page: Int) async throws -> Page<Title> {
        let p = try await get(TMDBPage<TMDBListItem>.self, "movie/upcoming", query: ["page": "\(page)", "region": region])
        return Page(items: p.results.compactMap { TMDBMapping.title($0, fallbackKind: .movie) },
                    page: p.page, totalPages: min(p.totalPages ?? p.page, 500))
    }

    public func credits(for key: MediaKey) async throws -> TitleCredits {
        guard let id = key.tmdbID else { throw MetadataError.notFound }
        if key.isMovie {
            let c = try await get(TMDBCredits.self, "movie/\(id)/credits")
            return TMDBMapping.titleCredits(movie: c)
        }
        guard key.isSeries else { throw MetadataError.notFound }
        async let aggregate = get(TMDBAggregateCredits.self, "tv/\(id)/aggregate_credits")
        async let show = get(TMDBCreators.self, "tv/\(id)")
        return try await TMDBMapping.titleCredits(series: aggregate, creators: show.createdBy ?? [])
    }

    public func person(id: Int) async throws -> Person {
        let p = try await get(TMDBPerson.self, "person/\(id)")
        var bio = p.biography ?? ""
        if bio.isEmpty, languageCode != "en" {
            // TMDB has no translation: show the English one rather than nothing.
            let english = TMDBService(credential: credential, http: http, language: "en-US", region: region,
                                      maxRetries: maxRetries, sleep: sleep)
            bio = (try? await english.get(TMDBPerson.self, "person/\(id)").biography) ?? ""
        }
        return Person(id: p.id, name: p.name, profile: TMDBMapping.art(.profile, p.profilePath),
                      department: p.knownForDepartment, biography: bio,
                      birthday: TMDBMapping.date(p.birthday), deathday: TMDBMapping.date(p.deathday),
                      placeOfBirth: p.placeOfBirth.flatMap { $0.isEmpty ? nil : $0 }, popularity: p.popularity,
                      imdbID: TMDBMapping.imdbID(p.imdbId))
    }

    public func searchPeople(_ query: String) async throws -> [Person] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let page = try await get(TMDBPage<TMDBPersonResult>.self, "search/person",
                                 query: ["query": q, "page": "1", "include_adult": "false"])
        return page.results.map {
            Person(id: $0.id, name: $0.name, profile: TMDBMapping.art(.profile, $0.profilePath),
                   department: $0.knownForDepartment, popularity: $0.popularity)
        }
    }

    public func filmography(personID: Int) async throws -> Filmography {
        async let combined = get(TMDBCombinedCredits.self, "person/\(personID)/combined_credits")
        async let person = get(TMDBPerson.self, "person/\(personID)")
        let department = try? await person.knownForDepartment
        return try await TMDBMapping.filmography(combined, department: department)
    }
}

// MARK: Wire formats

struct TMDBVideoList: Decodable {
    struct Video: Decodable {
        let id: String
        let key: String?
        let name: String?
        let site: String?
        let type: String?
        let official: Bool?
        let iso6391: String?
        let size: Int?
        let publishedAt: String?
    }
    let results: [Video]
}

struct TMDBEpisodeDTO: Decodable {
    let name: String?
    let overview: String?
    let airDate: String?
    let episodeNumber: Int
    let seasonNumber: Int
    let runtime: Int?
    let stillPath: String?
}

struct TMDBAiring: Decodable {
    let status: String?
    let lastEpisodeToAir: TMDBEpisodeDTO?
    let nextEpisodeToAir: TMDBEpisodeDTO?
}

struct TMDBCreators: Decodable {
    struct Creator: Decodable { let id: Int; let name: String; let profilePath: String? }
    let createdBy: [Creator]?
}

struct TMDBAggregateCredits: Decodable {
    struct Cast: Decodable {
        struct Role: Decodable { let character: String?; let episodeCount: Int? }
        let id: Int; let name: String; let profilePath: String?; let roles: [Role]?
        let totalEpisodeCount: Int?; let order: Int?
    }
    struct Crew: Decodable {
        struct Job: Decodable { let job: String?; let episodeCount: Int? }
        let id: Int; let name: String; let profilePath: String?; let department: String?; let jobs: [Job]?
        let totalEpisodeCount: Int?
    }
    let cast: [Cast]?
    let crew: [Crew]?
}

/// One `search/person` hit.
struct TMDBPersonResult: Decodable {
    let id: Int
    let name: String
    let profilePath: String?
    let knownForDepartment: String?
    let popularity: Double?
}

struct TMDBPerson: Decodable {
    let id: Int
    let name: String
    let biography: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let profilePath: String?
    let knownForDepartment: String?
    let popularity: Double?
    let imdbId: String?
}

struct TMDBCombinedCredits: Decodable {
    struct Entry: Decodable {
        let id: Int
        let mediaType: String?
        let title: String?
        let name: String?
        let overview: String?
        let releaseDate: String?
        let firstAirDate: String?
        let genreIds: [Int]?
        let voteAverage: Double?
        let voteCount: Int?
        let popularity: Double?
        let posterPath: String?
        let backdropPath: String?
        let character: String?
        let job: String?
        let department: String?
        let episodeCount: Int?
    }
    let cast: [Entry]?
    let crew: [Entry]?
}

// MARK: Mapping

extension TMDBMapping {
    /// Read-only after creation; ISO8601DateFormatter is thread-safe for parsing.
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func video(_ v: TMDBVideoList.Video, season: Int?) -> TitleVideo? {
        guard v.site?.lowercased() == "youtube", let key = v.key, !key.isEmpty else { return nil }
        let published = v.publishedAt.flatMap { s in
            isoFormatter.date(from: s.replacingOccurrences(of: #"\.\d+Z$"#, with: "Z", options: .regularExpression))
        }
        return TitleVideo(id: v.id, youtubeKey: key, name: v.name ?? "Video", kind: TitleVideo.Kind(tmdbType: v.type),
                          isOfficial: v.official ?? false, language: v.iso6391?.lowercased(), publishedAt: published,
                          size: v.size, season: season)
    }

    static func episode(_ e: TMDBEpisodeDTO, seriesID: Int) -> Episode {
        Episode(key: .episode(seriesID: seriesID, season: e.seasonNumber, episode: e.episodeNumber),
                seasonNumber: e.seasonNumber, number: e.episodeNumber, name: e.name ?? "Episode \(e.episodeNumber)",
                overview: e.overview ?? "", airDate: date(e.airDate), runtimeMinutes: e.runtime,
                still: art(.still, e.stillPath))
    }

    static let writerJobs: Set<String> = ["Screenplay", "Writer", "Story", "Novel", "Author", "Teleplay", "Characters"]
    static let topCrewJobs: [String] = [
        "Producer", "Executive Producer", "Original Music Composer", "Music", "Director of Photography",
        "Editor", "Production Design", "Casting", "Costume Design",
    ]

    static func titleCredits(movie c: TMDBCredits) -> TitleCredits {
        let cast = (c.cast ?? []).sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            .map { CreditPerson(id: $0.id, name: $0.name, role: $0.character ?? "", profile: art(.profile, $0.profilePath)) }
        let crew = c.crew ?? []
        func people(_ match: (String) -> Bool) -> [CreditPerson] {
            var seen = Set<Int>()
            return crew.filter { match($0.job ?? "") && seen.insert($0.id).inserted }
                .map { CreditPerson(id: $0.id, name: $0.name, role: $0.job ?? "", profile: art(.profile, $0.profilePath)) }
        }
        return TitleCredits(directors: people { $0 == "Director" }, writers: people { writerJobs.contains($0) },
                            cast: cast, crew: topCrew(crew.map { ($0.id, $0.name, $0.job ?? "", $0.profilePath) }))
    }

    static func titleCredits(series a: TMDBAggregateCredits, creators: [TMDBCreators.Creator]) -> TitleCredits {
        let cast = (a.cast ?? []).sorted { ($0.order ?? .max) < ($1.order ?? .max) }.map { c in
            // The role with the most episodes is the one people know.
            let role = (c.roles ?? []).max { ($0.episodeCount ?? 0) < ($1.episodeCount ?? 0) }?.character ?? ""
            return CreditPerson(id: c.id, name: c.name, role: role, profile: art(.profile, c.profilePath))
        }
        let crewJobs: [(Int, String, String, String?)] = (a.crew ?? [])
            .sorted { ($0.totalEpisodeCount ?? 0) > ($1.totalEpisodeCount ?? 0) }
            .flatMap { c in (c.jobs ?? []).map { (c.id, c.name, $0.job ?? "", c.profilePath) } }
        var seen = Set<Int>()
        let writers = crewJobs.filter { writerJobs.contains($0.2) && seen.insert($0.0).inserted }
            .prefix(10).map { CreditPerson(id: $0.0, name: $0.1, role: $0.2, profile: art(.profile, $0.3)) }
        return TitleCredits(creators: creators.map { CreditPerson(id: $0.id, name: $0.name, role: "Creator", profile: art(.profile, $0.profilePath)) },
                            writers: Array(writers), cast: cast, crew: topCrew(crewJobs))
    }

    /// Key jobs, each person once, in `topCrewJobs` order.
    /// `crew` is (id, name, job, profile path).
    static func topCrew(_ crew: [(Int, String, String, String?)]) -> [CreditPerson] {
        var seen = Set<Int>()
        var out: [CreditPerson] = []
        for job in topCrewJobs {
            var count = 0
            for c in crew where c.2 == job && count < 4 && seen.insert(c.0).inserted {
                out.append(CreditPerson(id: c.0, name: c.1, role: c.2, profile: art(.profile, c.3)))
                count += 1
            }
        }
        return out
    }

    static func filmography(_ c: TMDBCombinedCredits, department: String?) -> Filmography {
        func credit(_ e: TMDBCombinedCredits.Entry, role: String?, department: String) -> Credit? {
            let item = TMDBListItem(id: e.id, mediaType: e.mediaType, title: e.title, name: e.name, overview: e.overview,
                                    releaseDate: e.releaseDate, firstAirDate: e.firstAirDate, genreIds: e.genreIds,
                                    voteAverage: e.voteAverage, posterPath: e.posterPath, backdropPath: e.backdropPath)
            guard let title = title(item, fallbackKind: nil) else { return nil }
            return Credit(title: title, roles: role.map { [$0] } ?? [], department: department,
                          episodeCount: e.episodeCount, popularity: e.popularity ?? 0, voteCount: e.voteCount ?? 0)
        }
        let cast = (c.cast ?? []).compactMap { credit($0, role: $0.character, department: "Acting") }
        let crew = (c.crew ?? []).compactMap { credit($0, role: $0.job, department: $0.department ?? "Crew") }
        return Filmography.build(from: cast + crew, department: department)
    }
}
