import Domain
import Foundation
import Testing
import TestingSupport

@Suite struct MediaSourceRegistryTests {
    let key = MediaKey.movie(tmdbID: 42)

    @Test func registersAndPreservesOrder() async {
        let registry = MediaSourceRegistry()
        await registry.register(MockMediaSource(id: "a"))
        await registry.register(MockMediaSource(id: "b"))
        await registry.register(MockMediaSource(id: "a"))   // re-register replaces, keeps position
        #expect(await registry.all().map(\.id.rawValue) == ["a", "b"])
        await registry.unregister(SourceID("a"))
        #expect(await registry.all().map(\.id.rawValue) == ["b"])
    }

    @Test func filtersByCapabilityAndEnabledState() async {
        let registry = MediaSourceRegistry(sources: [
            MockMediaSource(id: "browse-only", capabilities: [.browse]),
            MockMediaSource(id: "player", capabilities: [.browse, .play]),
            MockMediaSource(id: "downloader", capabilities: [.play, .download]),
        ])
        #expect(await registry.enabled(with: .play).map(\.id.rawValue) == ["player", "downloader"])
        #expect(await registry.enabled(with: [.play, .download]).map(\.id.rawValue) == ["downloader"])
        await registry.setEnabled(false, for: SourceID("player"))
        #expect(await registry.enabled(with: .play).map(\.id.rawValue) == ["downloader"])
        #expect(await !registry.isEnabled(SourceID("player")))
    }

    @Test func availabilityAggregatesInRegistrationOrderAndReportsFailures() async {
        let v1 = MockMediaSource.variant("1", source: "slow", key: key)
        let v2 = MockMediaSource.variant("2", source: "fast", key: key)
        let registry = MediaSourceRegistry(sources: [
            MockMediaSource(id: "slow", variantsByKey: [key: [v1]], delay: .milliseconds(50)),
            MockMediaSource(id: "fast", variantsByKey: [key: [v2]]),
            MockMediaSource(id: "broken", failure: .timedOut),
            MockMediaSource(id: "metadata-only", capabilities: [.browse], variantsByKey: [key: [v1]]),
        ])
        let a = await registry.availability(for: key)
        #expect(a.variants.map(\.id) == ["1", "2"])
        #expect(a.failures == [SourceID("broken"): .timedOut])
        #expect(a.isPlayable)
    }

    @Test func noSourceMeansNotPlayable() async {
        let registry = MediaSourceRegistry(sources: [MockMediaSource(id: "empty")])
        #expect(await !registry.availability(for: key).isPlayable)
    }

    @Test func resolveRespectsDisabledAndCapabilities() async throws {
        let v = MockMediaSource.variant("x", source: "s", key: key)
        let registry = MediaSourceRegistry(sources: [MockMediaSource(id: "s", variantsByKey: [key: [v]])])
        let r = try await registry.resolve(v)
        #expect(r.url.lastPathComponent == "x.mp4")

        await registry.setEnabled(false, for: SourceID("s"))
        await #expect(throws: SourceError.notConfigured) { try await registry.resolve(v) }

        let orphan = MockMediaSource.variant("y", source: "missing", key: key)
        await #expect(throws: SourceError.notFound) { try await registry.resolve(orphan) }
    }

    @Test func transientErrorClassification() {
        #expect(SourceError.timedOut.isTransient)
        #expect(SourceError.expired.isTransient)
        #expect(!SourceError.unauthorized.isTransient)
        #expect(!SourceError.unsupportedFormat("mkv").isTransient)
    }
}

@Suite struct VariantChooserTests {
    func v(_ id: String, _ source: String, _ container: String = "mp4") -> MediaVariant {
        MediaVariant(id: id, sourceID: SourceID(source), mediaKey: nil, displayName: id, container: container, location: .remote, isDownloadable: false)
    }
    let ok: (MediaVariant) -> Bool = { $0.container != "mkv" }
    func last(_ source: String, _ id: String) -> LastPlayedSource { LastPlayedSource(sourceID: SourceID(source), variantID: id, playedAt: .now) }

    @Test func prefersExactThenSameSourceThenSeriesThenOrder() {
        let all = [v("a1", "A"), v("b1", "B"), v("b2", "B"), v("c1", "C")]
        #expect(VariantChooser.choose(from: all, item: nil, canAttempt: ok)?.id == "a1")
        #expect(VariantChooser.choose(from: all, item: last("B", "b2"), canAttempt: ok)?.id == "b2")
        #expect(VariantChooser.choose(from: all, item: last("B", "gone"), canAttempt: ok)?.id == "b1")
        #expect(VariantChooser.choose(from: all, item: nil, series: last("C", "x"), canAttempt: ok)?.id == "c1")
        #expect(VariantChooser.choose(from: all, item: last("Z", "z"), series: last("C", "x"), canAttempt: ok)?.id == "c1")
    }

    @Test func skipsVariantsTheEngineCantPlay() {
        let all = [v("a1", "A", "mkv"), v("b1", "B")]
        #expect(VariantChooser.choose(from: all, item: last("A", "a1"), canAttempt: ok)?.id == "b1")
        #expect(VariantChooser.choose(from: [v("a1", "A", "mkv")], item: nil, canAttempt: ok)?.id == "a1")  // explains failure later
        #expect(VariantChooser.choose(from: [], item: nil, canAttempt: ok) == nil)
    }
}
