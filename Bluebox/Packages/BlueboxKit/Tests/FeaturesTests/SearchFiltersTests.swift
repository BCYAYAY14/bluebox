import Addons
import Domain
@testable import Features
import Foundation
import Testing

private func date(_ year: Int) -> Date {
    Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 6, day: 1))!
}

private func movie(_ id: Int, _ name: String, _ year: Int) -> Title {
    Title(key: .movie(tmdbID: id), kind: .movie, name: name, releaseDate: date(year),
          poster: Artwork(.poster, path: "/\(id).jpg"))
}

private func show(_ id: Int, _ name: String, _ year: Int) -> Title {
    Title(key: .series(tmdbID: id), kind: .series, name: name, releaseDate: date(year))
}

private func person(_ id: Int, _ name: String) -> Person {
    Person(id: id, name: name, profile: nil, department: "Acting", biography: "", birthday: nil, deathday: nil,
           placeOfBirth: nil, popularity: nil)
}

@Suite struct SearchFilterTests {
    let titles = [movie(1, "Dune", 2021), show(2, "Dune: Prophecy", 2024), movie(3, "Dune", 1984), movie(4, "Dune Drifter", 2020)]
    let people = [person(9, "Denis Villeneuve")]

    @Test func allKeepsEverything() {
        let s = SearchFilter().sections(query: "dune", titles: titles, people: people, availability: .init())
        #expect(s.top == .title(titles[0]))
        #expect(s.films.map(\.name) == ["Dune", "Dune Drifter"])
        #expect(s.shows.map(\.name) == ["Dune: Prophecy"])
        #expect(s.people.map(\.name) == ["Denis Villeneuve"])
    }

    @Test func tvLeadsWithAShowAndDropsFilmsAndPeople() {
        let s = SearchFilter(scope: .shows).sections(query: "dune", titles: titles, people: people, availability: .init())
        #expect(s.top == .title(titles[1]))
        #expect(s.films.isEmpty && s.shows.isEmpty && s.people.isEmpty)
    }

    @Test func peopleOnly() {
        let s = SearchFilter(scope: .people).sections(query: "dune", titles: titles, people: people, availability: .init())
        #expect(s.top == .person(people[0]))
        #expect(s.films.isEmpty && s.shows.isEmpty)
    }

    @Test func decadesAndEarlier() {
        let twenties = SearchFilter(decade: 2020)
        #expect(titles.filter { twenties.matches($0, availability: .init()) }.map(\.key) == [titles[0].key, titles[1].key, titles[3].key])
        let eighties = SearchFilter(decade: 1980)
        #expect(titles.filter { eighties.matches($0, availability: .init()) }.map(\.key) == [titles[2].key])
        // "Earlier" is everything before the last decade chip.
        let earlier = SearchFilter(decade: SearchFilter.earlier)
        #expect(earlier.matches(movie(6, "Dune (unmade)", 1975), availability: .init()))
        #expect(!titles.contains { earlier.matches($0, availability: .init()) })
        #expect(SearchFilter.decadeTitle(1990) == "1990s")
        #expect(SearchFilter.decadeTitle(SearchFilter.earlier) == "Earlier")
        // No year, no decade.
        #expect(!twenties.matches(Title(key: .movie(tmdbID: 5), kind: .movie, name: "Undated"), availability: .init()))
    }

    @Test func narrowingByAvailabilityOrYearLeavesPeopleOut() {
        #expect(SearchFilter().includesPeople)
        #expect(!SearchFilter(playableNow: true).includesPeople)
        #expect(!SearchFilter(decade: 2010).includesPeople)
        #expect(!SearchFilter(scope: .films).includesPeople)
        #expect(SearchFilter(uhd: true).needsAvailability)
        #expect(!SearchFilter(decade: 2010).needsAvailability)
    }

    @Test func playableNowAnd4K() {
        let known = SearchAvailability(playable: [titles[0].key, titles[1].key], uhd: [titles[1].key])
        let playable = SearchFilter(playableNow: true).sections(query: "dune", titles: titles, people: people, availability: known)
        #expect(playable.top == .title(titles[0]))
        #expect(playable.shows.map(\.name) == ["Dune: Prophecy"])
        #expect(playable.films.isEmpty && playable.people.isEmpty)
        let both = SearchFilter(playableNow: true, uhd: true)
        #expect(titles.filter { both.matches($0, availability: known) }.map(\.key) == [titles[1].key])
    }

    @Test func availabilityByTitleFromDownloadsCloudAndFoundReleases() {
        let episode = MediaKey.series(tmdbID: 2).episode(season: 1, episode: 3)!
        let known = SearchAvailability.make(
            downloads: [(episode, "1080p")],
            cloud: [(.movie(tmdbID: 1), "4K")],
            offers: [.movie(tmdbID: 3): ReleaseOffer(instant: false, uhd: true),
                     .movie(tmdbID: 4): ReleaseOffer(instant: true, uhd: false)])
        // An episode counts for its show.
        #expect(known.playable == [.series(tmdbID: 2), .movie(tmdbID: 1), .movie(tmdbID: 4)])
        #expect(known.uhd == [.movie(tmdbID: 1), .movie(tmdbID: 3)])
        #expect(SearchAvailability.isUHD("2160p") && SearchAvailability.isUHD("4K") && !SearchAvailability.isUHD("1080p"))
    }
}

@MainActor
@Suite(.serialized) struct RecentSearchesTests {
    @Test func newestFirstOncePerQueryWhateverItsCase() {
        var r = RecentSearches()
        r.add("dune")
        r.add("Severance")
        r.add("DUNE ")
        #expect(r.items.map(\.query) == ["DUNE", "Severance"])
        r.add("x")  // too short to be worth keeping
        #expect(r.items.count == 2)
    }

    @Test func keepsAtMostTheLimit() {
        var r = RecentSearches()
        for i in 0..<(RecentSearches.limit + 3) { r.add("query \(i)") }
        #expect(r.items.count == RecentSearches.limit)
        #expect(r.items.first?.query == "query \(RecentSearches.limit + 2)")
    }

    @Test func searchingAgainKeepsThePicture() {
        var r = RecentSearches()
        let art = Artwork(.poster, path: "/dune.jpg")
        r.add("dune", artwork: art, detail: "Dune · Movie · 2021")
        r.add("other")
        r.add("Dune")
        #expect(r.items.first?.artwork == art)
        #expect(r.items.first?.detail == "Dune · Movie · 2021")
    }

    @Test func fillsAMissingPictureWithoutMovingIt() {
        var r = RecentSearches()
        r.add("dune")
        r.add("severance")
        let art = Artwork(.poster, path: "/dune.jpg")
        let filled = r.fillArtwork(for: "DUNE", artwork: art, detail: "Dune")
        #expect(filled)
        #expect(r.items.map(\.query) == ["severance", "dune"])
        #expect(r.items[1].artwork == art)
        // One already there stays.
        let replaced = r.fillArtwork(for: "dune", artwork: Artwork(.poster, path: "/other.jpg"), detail: nil)
        let missing = r.fillArtwork(for: "missing", artwork: art, detail: nil)
        #expect(!replaced && !missing)
    }

    @Test func removeOneOrAll() {
        var r = RecentSearches()
        r.add("dune"); r.add("severance"); r.add("andor")
        r.remove("SEVERANCE")
        #expect(r.items.map(\.query) == ["andor", "dune"])
        r.removeAll()
        #expect(r.isEmpty)
    }

    @Test func savedPerProfile() {
        let a = "test-recents-\(UUID().uuidString)", b = "test-recents-\(UUID().uuidString)"
        defer { RecentSearches().save(profile: a); RecentSearches().save(profile: b) }
        var r = RecentSearches()
        r.add("dune", artwork: Artwork(.poster, path: "/dune.jpg"), detail: "Dune · Movie")
        r.add("andor")
        r.save(profile: a)
        #expect(RecentSearches.load(profile: a) == r)
        #expect(RecentSearches.load(profile: b).isEmpty)
        RecentSearches().save(profile: a)
        #expect(RecentSearches.load(profile: a).isEmpty)
    }

    @Test func readsTheOldNewlineList() {
        let p = "test-recents-\(UUID().uuidString)"
        defer { RecentSearches().save(profile: p) }
        ViewMemory.set("dune\nandor", RecentSearches.oldMemoryKey, profile: p)
        let r = RecentSearches.load(profile: p)
        #expect(r.items.map(\.query) == ["dune", "andor"])
        #expect(r.items.allSatisfy { $0.artwork == nil })
        // Moved to the new format.
        #expect(ViewMemory.string(RecentSearches.oldMemoryKey, profile: p) == nil)
        #expect(RecentSearches.load(profile: p) == r)
    }
}

@Suite struct SearchDebounceTests {
    @Test func trimsSpacesOnly() {
        #expect(SearchDebounce.trimmed("  dune 2 ") == "dune 2")
        #expect(SearchDebounce.trimmed("   ").isEmpty)
    }
}
