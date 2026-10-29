import Domain
@testable import Features
import Foundation
import Persistence
import Testing

/// A source with one variant per episode that counts how often it's asked to resolve.
private actor CountingSource: MediaSource {
    nonisolated let id = SourceID("counting")
    nonisolated let kind = SourceKind.directURL
    nonisolated let displayName = "Counting"
    nonisolated let capabilities: SourceCapabilities = [.play]
    private(set) var resolves = 0

    func catalog() async throws -> [MediaVariant] { [] }
    func variants(for key: MediaKey) async throws -> [MediaVariant] {
        [MediaVariant(id: key.rawValue, sourceID: id, mediaKey: key, displayName: "file", container: "mp4", location: .remote)]
    }
    func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        resolves += 1
        return PlaybackResource(variant: variant, url: URL(string: "https://example.invalid/\(resolves).mp4")!)
    }
    func testConnection() async -> SourceHealth { SourceHealth(ok: true, message: "OK") }
}

@MainActor
@Suite struct PlaybackFlowTests {
    func model() throws -> AppModel {
        AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                 prefs: PreferencesStore(defaults: UserDefaults(suiteName: "flow.\(UUID().uuidString)")!), forceSample: true)
    }

    /// Up Next asks for the next episode when the countdown starts and again
    /// when it plays. Resolving twice started an add-on torrent twice: the
    /// second start threw away the stream the first had just buffered.
    @Test func upNextResolvesTheNextEpisodeOnce() async throws {
        let app = try model()
        let source = CountingSource()
        await app.registry.register(source)
        let current = MediaKey.episode(seriesID: 9_100_001, season: 1, episode: 1)

        let first = await app.nextEpisode(after: current)
        let second = await app.nextEpisode(after: current)
        #expect(first?.0.key == .episode(seriesID: 9_100_001, season: 1, episode: 2))
        #expect(second?.1.url == first?.1.url)
        #expect(await source.resolves == 1)

        // Another episode, or a closed player, resolves afresh.
        _ = await app.nextEpisode(after: .episode(seriesID: 9_100_001, season: 1, episode: 2))
        #expect(await source.resolves == 2)
    }
}
