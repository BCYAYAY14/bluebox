import Domain
@testable import Features
import Foundation
import Persistence
import Testing
import TestingSupport

private func day(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "T00:00:00Z")! }

private func film(_ id: Int, _ name: String, _ date: String?) -> Title {
    Title(key: .movie(tmdbID: id), kind: .movie, name: name, releaseDate: date.map(day))
}

@Suite struct CollectionPlanTests {
    let alien = film(348, "Alien", "1979-05-25")
    let aliens = film(679, "Aliens", "1986-07-18")
    let sameDay = film(680, "Aliens (Special Edition)", "1986-07-18")
    let announced = film(9_999_001, "Alien: Next", nil)
    let dated = film(9_999_002, "Alien: Later", "2030-01-01")
    let now = day("2026-10-31")

    @Test func partsAreInReleaseOrderWithUndatedLastAndTiesAsGiven() {
        let c = FilmCollection(id: 1, name: "Alien Collection", parts: [announced, dated, sameDay, alien, aliens])
        #expect(c.parts.map(\.name) == ["Alien", "Aliens (Special Edition)", "Aliens", "Alien: Later", "Alien: Next"])
        #expect(FilmCollection.ordered([]).isEmpty)
    }

    @Test func playAndDownloadSkipFilmsNotOutYet() {
        let parts = [alien, aliens, dated, announced]
        #expect(CollectionPlan.released(parts, now: now).map(\.name) == ["Alien", "Aliens"])
        #expect(CollectionPlan.toDownload(parts, now: now) { $0 == alien.key }.map(\.name) == ["Aliens"])
        #expect(CollectionPlan.toDownload(parts, now: now) { _ in true }.isEmpty)
    }

    @Test func addAllTakesEveryFilmNotOnMyList() {
        let parts = [alien, aliens, announced]
        #expect(CollectionPlan.toAdd(parts, onList: [aliens.key]).map(\.name) == ["Alien", "Alien: Next"])
        #expect(CollectionPlan.toAdd(parts, onList: Set(parts.map(\.key))).isEmpty)
    }

    @Test func summaryLine() {
        #expect(CollectionPlan.summary(count: 4, minutes: 470) == "4 films · 7 h 50 min")
        #expect(CollectionPlan.summary(count: 1, minutes: 0) == "1 film")
        #expect(CollectionPlan.summary(count: 2, minutes: 45) == "2 films · 45 min")
    }
}

@MainActor
@Suite struct CollectionActionsTests {
    func app() throws -> AppModel {
        AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                 prefs: PreferencesStore(defaults: UserDefaults(suiteName: "collection.\(UUID().uuidString)")!), forceSample: true)
    }

    let alien = film(348, "Alien", "1979-05-25")
    let aliens = film(679, "Aliens", "1986-07-18")
    let announced = film(9_999_001, "Alien: Next", nil)
    var collection: FilmCollection { FilmCollection(id: 8091, name: "Alien Collection", parts: [alien, aliens, announced]) }

    @Test func addAllPutsTheRestOnMyListOnceWithUndo() async throws {
        let app = try app()
        try await app.store.setWatchlisted(aliens, true)
        let before = app.libraryRevision
        let added = await app.addCollectionToMyList(collection)
        #expect(added.map(\.name) == ["Alien", "Alien: Next"])
        #expect(Set(try await app.store.watchlist().map(\.key)) == Set(collection.parts.map(\.key)))
        #expect(app.libraryRevision > before)
        #expect(app.toast?.title == "Added 2 films to My List" && app.toast?.actionTitle == "Undo")

        // Again: nothing to add, and it says so.
        #expect(await app.addCollectionToMyList(collection).isEmpty)
        #expect(app.toast?.title == "Already on My List")
    }

    @Test func downloadAllMarksTheReleasedFilmsPreparingAtOnce() throws {
        let app = try app()
        let asked = app.downloadCollection(collection)
        // Synchronously, before any lookup has run; the announced film isn't asked for.
        #expect(asked.map(\.name) == ["Alien", "Aliens"])
        #expect(app.preparingDownloads == [alien.key, aliens.key])
    }

    @Test func downloadAllWithNothingOutSaysSo() throws {
        let app = try app()
        let upcoming = FilmCollection(id: 2, name: "Upcoming", parts: [announced])
        #expect(app.downloadCollection(upcoming).isEmpty)
        #expect(app.preparingDownloads.isEmpty)
        #expect(app.toast?.title == "Nothing more to download")
    }
}
