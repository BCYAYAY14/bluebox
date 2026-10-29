import Domain
import Foundation
@testable import Metadata
import Testing

/// Counts calls and fails on demand, on top of the sample catalog.
private final class Flaky: MetadataProvider, @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    var failure: Error?
    let sample = SampleMetadataProvider()

    func hit() throws {
        try lock.withLock {
            calls += 1
            if let failure { throw failure }
        }
    }
    func list(_ list: CatalogList, page: Int) async throws -> Page<Title> { try hit(); return try await sample.list(list, page: page) }
    func search(_ query: String, page: Int) async throws -> Page<Title> { try hit(); return try await sample.search(query, page: page) }
    func discover(genre: Genre, kind: TitleKind, page: Int) async throws -> Page<Title> {
        try hit(); return try await sample.discover(genre: genre, kind: kind, page: page)
    }
    func genres() async throws -> [Genre] { try hit(); return try await sample.genres() }
    func detail(for key: MediaKey) async throws -> TitleDetail {
        try hit()
        try await Task.sleep(for: .milliseconds(20))
        return try await sample.detail(for: key)
    }
    func season(_ number: Int, of seriesKey: MediaKey) async throws -> Season { try hit(); return try await sample.season(number, of: seriesKey) }
    func imageURL(for artwork: Artwork, width: Int) -> URL? { nil }
}

private final class Clock: @unchecked Sendable {
    let lock = NSLock()
    var date = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ s: TimeInterval) { lock.withLock { date += s } }
    var now: Date { lock.withLock { date } }
}

@Suite struct CachedMetadataProviderTests {
    let key = MediaKey.series(tmdbID: 9_100_001)

    @Test func repeatsAndConcurrentCallersShareOneRequest() async throws {
        let base = Flaky()
        let cached = CachedMetadataProvider(base)
        async let a = cached.detail(for: key)
        async let b = cached.detail(for: key)
        let (x, y) = try await (a, b)
        _ = try await cached.detail(for: key)
        #expect(x.title.key == key && y.title.key == key)
        #expect(base.calls == 1)
    }

    @Test func expiresAfterItsLifetime() async throws {
        let base = Flaky(), clock = Clock()
        let cached = CachedMetadataProvider(base, now: { clock.now })
        _ = try await cached.season(1, of: key)
        clock.advance(31 * 60)
        _ = try await cached.season(1, of: key)
        #expect(base.calls == 2)
    }

    @Test func offlineFallsBackToAnOldAnswer() async throws {
        let base = Flaky(), clock = Clock()
        let cached = CachedMetadataProvider(base, now: { clock.now })
        let fresh = try await cached.list(.trending, page: 1)
        clock.advance(3600)
        base.failure = MetadataError.offline
        let stale = try await cached.list(.trending, page: 1)
        #expect(stale.items.map(\.key) == fresh.items.map(\.key))

        // Not a connectivity problem: the error is real and shown.
        base.failure = MetadataError.unauthorized
        await #expect(throws: MetadataError.unauthorized) { try await cached.list(.trending, page: 1) }
        // Never fetched: nothing to fall back on.
        base.failure = MetadataError.offline
        await #expect(throws: MetadataError.offline) { try await cached.list(.popularMovies, page: 1) }
    }

    @Test func staysWithinCapacity() async throws {
        let base = Flaky()
        let cached = CachedMetadataProvider(base, capacity: 2)
        _ = try await cached.search("a", page: 1)
        _ = try await cached.search("b", page: 1)
        _ = try await cached.search("c", page: 1)
        _ = try await cached.search("c", page: 1)
        #expect(base.calls == 3)
        _ = try await cached.search("a", page: 1)  // evicted, fetched again
        #expect(base.calls == 4)
    }

    @Test func cancellingTheOnlyCallerCancelsTheRequest() async throws {
        let base = SlowSearch()
        let cached = CachedMetadataProvider(base)
        let task = Task { try await cached.search("dune", page: 1) }
        try await base.started.wait()
        let started = Date()
        task.cancel()
        _ = await task.result
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(await base.wasCancelled.value)
        // The next search for it asks again instead of joining the cancelled request.
        base.delay = 0
        let page = try await cached.search("dune", page: 1)
        #expect(page.items.first?.name == "dune")
    }

    @Test func aSharedRequestKeepsGoingForTheCallersLeft() async throws {
        let base = SlowSearch(delay: 0.3)
        let cached = CachedMetadataProvider(base)
        let quitter = Task { try await cached.search("dune", page: 1) }
        try await base.started.wait()
        async let stayer = cached.search("dune", page: 1)
        try await Task.sleep(for: .milliseconds(50))
        quitter.cancel()
        let page = try await stayer
        #expect(page.items.first?.name == "dune")
        #expect(await !base.wasCancelled.value)
        #expect(await cached.cachedSearch("Dune ")?.items.first?.name == "dune")
        #expect(await cached.cachedSearch("dune", page: 2) == nil)
    }
}

/// A search that takes `delay` seconds and notes whether it was cancelled.
private final class SlowSearch: MetadataProvider, @unchecked Sendable {
    let lock = NSLock()
    private var _delay: Double
    var delay: Double { get { lock.withLock { _delay } } set { lock.withLock { _delay = newValue } } }
    let started = Signal()
    let wasCancelled = Flag()
    let sample = SampleMetadataProvider()

    init(delay: Double = 10) { _delay = delay }

    func search(_ query: String, page: Int) async throws -> Page<Title> {
        await started.fire()
        do { try await Task.sleep(for: .seconds(delay)) } catch { await wasCancelled.set(); throw error }
        return Page(items: [Title(key: .movie(tmdbID: 1), kind: .movie, name: query)], page: page, totalPages: 1)
    }
    func list(_ list: CatalogList, page: Int) async throws -> Page<Title> { try await sample.list(list, page: page) }
    func discover(genre: Genre, kind: TitleKind, page: Int) async throws -> Page<Title> {
        try await sample.discover(genre: genre, kind: kind, page: page)
    }
    func genres() async throws -> [Genre] { try await sample.genres() }
    func detail(for key: MediaKey) async throws -> TitleDetail { try await sample.detail(for: key) }
    func season(_ number: Int, of seriesKey: MediaKey) async throws -> Season { try await sample.season(number, of: seriesKey) }
    func imageURL(for artwork: Artwork, width: Int) -> URL? { nil }
}

private actor Flag {
    var value = false
    func set() { value = true }
}

/// Fires once; `wait` returns once it has (or throws after 5 s).
private actor Signal {
    private var fired = false
    func fire() { fired = true }
    func wait() async throws {
        for _ in 0..<2500 where !fired { try await Task.sleep(for: .milliseconds(2)) }
        if !fired { throw CancellationError() }
    }
}
