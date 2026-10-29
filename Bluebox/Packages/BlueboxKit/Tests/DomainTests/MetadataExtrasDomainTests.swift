import Domain
import Foundation
import Testing

@Suite struct IMDbKeyTests {
    @Test func imdbKeysParseLikeTMDBOnes() {
        let series = MediaKey.series(imdbID: "tt0903747")
        let ep = MediaKey.episode(imdbSeriesID: "tt0903747", season: 2, episode: 5)
        #expect(ep.rawValue == "imdb:tv:tt0903747:s2e5")
        #expect(ep.seriesKey == series)
        #expect(ep.episodeNumbers! == (2, 5))
        #expect(ep.imdbID == "tt0903747" && ep.tmdbID == nil)
        #expect(series.isSeries && !series.isMovie && !ep.isSeries)
        #expect(MediaKey.movie(imdbID: "tt1").isMovie)
        #expect(series.episode(season: 2, episode: 5) == ep)
        #expect(MediaKey.series(tmdbID: 7).episode(season: 1, episode: 2) == .episode(seriesID: 7, season: 1, episode: 2))
        #expect(ep.episode(season: 1, episode: 1) == nil)
        #expect(MediaKey.movie(tmdbID: 3).isMovie && MediaKey.movie(tmdbID: 3).imdbID == nil)
    }
}

@Suite struct VideoRankingTests {
    func v(_ key: String, _ kind: TitleVideo.Kind, official: Bool = true, lang: String? = "en", size: Int = 1080) -> TitleVideo {
        TitleVideo(id: key, youtubeKey: key, name: key, kind: kind, isOfficial: official, language: lang, size: size)
    }

    @Test func heroPrefersAnOfficialTrailerAndSkipsForeignOnesWhenItCan() {
        let list = [v("clip", .clip), v("teaser", .teaser), v("fr", .trailer, lang: "fr"), v("fan", .trailer, official: false)]
        #expect(VideoRanking.heroTrailer(list, language: "en")?.youtubeKey == "fan")  // English beats French
        #expect(VideoRanking.heroTrailer(list, language: "fr")?.youtubeKey == "fr")
        #expect(VideoRanking.heroTrailer([v("clip", .clip)], language: "en") == nil)
        #expect(VideoRanking.sorted([v("a", .trailer), v("a", .trailer)], language: "en").count == 1)  // duplicates dropped
    }
}

@Suite struct FilmographyTests {
    func credit(_ id: Int, _ kind: TitleKind, year: Int?, role: String, dept: String, votes: Int = 0, genres: [Int] = []) -> Credit {
        let date = year.flatMap { DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt, year: $0, month: 6, day: 1).date }
        let key: MediaKey = kind == .movie ? .movie(tmdbID: id) : .series(tmdbID: id)
        return Credit(title: Title(key: key, kind: kind, name: "T\(id)", releaseDate: date, genreIDs: genres), roles: [role],
                      department: dept, voteCount: votes)
    }

    @Test func knownForUsesTheirDepartmentAndSkipsTalkShowsAndSelf() {
        let f = Filmography.build(from: [
            credit(1, .movie, year: 2001, role: "Hero", dept: "Acting", votes: 10),
            credit(2, .series, year: 2010, role: "Self", dept: "Acting", votes: 99_999),
            credit(3, .series, year: 2012, role: "Host", dept: "Acting", votes: 50_000, genres: [10767]),
            credit(4, .movie, year: 2020, role: "Villain", dept: "Acting", votes: 500),
            credit(5, .movie, year: 2019, role: "Director", dept: "Directing", votes: 100_000),
        ], department: "Acting")
        #expect(f.knownFor.map(\.title.key) == [.movie(tmdbID: 4), .movie(tmdbID: 1)])
        #expect(f.movies.map(\.title.key) == [.movie(tmdbID: 4), .movie(tmdbID: 5), .movie(tmdbID: 1)])
        #expect(f.shows.count == 2)
    }
}
