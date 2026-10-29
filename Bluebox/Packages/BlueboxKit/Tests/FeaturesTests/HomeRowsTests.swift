import Domain
@testable import Features
import Foundation
import Testing

/// Home's rows show each title once (`HomeModel.withoutRepeats`).
@MainActor
@Suite struct HomeRowsTests {
    private func movies(_ ids: ClosedRange<Int>) -> [Title] {
        ids.map { Title(key: .movie(tmdbID: $0), kind: .movie, name: "M\($0)") }
    }

    private func ids(_ row: HomeRow) -> [Int] { row.titles.compactMap(\.key.tmdbID) }

    @Test func laterRowsDropTitlesShownAboveOrInATopTen() {
        let rows = [
            HomeRow(id: "trending", title: "Trending Now", titles: movies(1...6)),
            HomeRow(id: "popular", title: "Popular Movies", titles: movies(1...22)),
            HomeRow(id: "top", title: "Top 10 Movies", titles: movies(7...16), style: .topTen),
        ]
        let out = HomeModel.withoutRepeats(rows)
        #expect(out.map(\.id) == ["trending", "popular", "top"])
        #expect(ids(out[0]) == Array(1...6))                 // the first row stays as it is
        #expect(ids(out[1]) == Array(17...22))               // minus Trending and the Top 10
        #expect(ids(out[2]) == Array(7...16))                // Top 10 keeps its ranks
    }

    @Test func aRowLeftTooShortGoes() {
        let rows = [
            HomeRow(id: "trending", title: "Trending Now", titles: movies(1...10)),
            HomeRow(id: "acclaimed", title: "Critically Acclaimed", titles: movies(5...12)),
            HomeRow(id: "short", title: "Short", titles: movies(30...32)),
        ]
        let out = HomeModel.withoutRepeats(rows)
        // Acclaimed would keep only 11 and 12; a short row with no repeats stays.
        #expect(out.map(\.id) == ["trending", "short"])
    }
}
