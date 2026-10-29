import Domain
@testable import Features
import Foundation
import Persistence
import Testing

@MainActor
@Suite struct ProfileSwitchingTests {
    func model() throws -> AppModel {
        AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                 prefs: PreferencesStore(defaults: UserDefaults(suiteName: "features.\(UUID().uuidString)")!), forceSample: true)
    }

    @Test func eachProfileHasItsOwnLibrary() async throws {
        let app = try model()
        #expect(app.profiles.map(\.id) == [Profile.defaultID])
        let movie = Title(key: .movie(tmdbID: 1), kind: .movie, name: "One")
        await app.toggleWatchlist(movie)
        #expect(try await app.store.watchlist().count == 1)

        let kids = app.addProfile(name: "  Kids  ", symbol: "star.fill", color: 2)
        #expect(app.profiles.map(\.name) == ["Me", "Kids"])
        await app.switchProfile(to: kids.id)
        #expect(app.currentProfile.name == "Kids")
        #expect(try await app.store.watchlist().isEmpty)

        await app.switchProfile(to: Profile.defaultID)
        #expect(try await app.store.watchlist().count == 1)

        await app.switchProfile(to: kids.id)
        await app.deleteProfile(kids.id)
        #expect(app.currentProfileID == Profile.defaultID)
        #expect(app.profiles.count == 1)
    }

    @Test func remembersTheProfileAcrossLaunches() async throws {
        let suite = "features.\(UUID().uuidString)"
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: suite)!)
        let a = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(), prefs: prefs, forceSample: true)
        let p = a.addProfile(name: "Sam", symbol: "moon.fill", color: 1)
        await a.switchProfile(to: p.id)
        let b = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(), prefs: prefs, forceSample: true)
        await b.bootstrap()
        #expect(b.currentProfileID == p.id)
    }
}
