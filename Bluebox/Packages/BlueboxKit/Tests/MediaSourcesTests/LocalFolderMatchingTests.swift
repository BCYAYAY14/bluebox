import Domain
import Foundation
@testable import MediaSources
import Testing

final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var _on = false
    private var _calls = 0
    private var _now = Date(timeIntervalSince1970: 1_000_000)
    var on: Bool { get { lock.withLock { _on } } set { lock.withLock { _on = newValue } } }
    var calls: Int { lock.withLock { _calls } }
    func called() { lock.withLock { _calls += 1 } }
    var now: Date { get { lock.withLock { _now } } set { lock.withLock { _now = newValue } } }
}

@Suite struct LocalFolderMatchingTests {
    @Test func filesScannedOfflineAreMatchedOnceTheNetworkIsBack() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bluebox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appending(path: "Tears.of.Steel.2012.mov"))
        try Data("x".utf8).write(to: dir.appending(path: "Holiday.2019.mp4"))
        let online = Switch()
        let source = LocalFolderSource(id: SourceID("local"), name: "Movies", folderURL: dir, usesSecurityScope: false) { parsed in
            online.called()
            // Offline: the TMDB search fails, so nothing matches.
            guard online.on, parsed.title == "Tears of Steel" else { return nil }
            return .movie(tmdbID: 133701)
        }
        await source.setClock { online.now }
        #expect(try await source.variants(for: .movie(tmdbID: 133701)).isEmpty)
        online.on = true
        // Within the retry window the scan is reused (no lookup per title page).
        let before = online.calls
        #expect(try await source.variants(for: .movie(tmdbID: 133701)).isEmpty)
        #expect(online.calls == before)
        online.now = online.now.addingTimeInterval(LocalFolderSource.unmatchedRetryInterval + 1)
        #expect(try await source.variants(for: .movie(tmdbID: 133701)).count == 1)
        // Matched files aren't looked up again; only the unmatched one is.
        let after = online.calls
        online.now = online.now.addingTimeInterval(LocalFolderSource.unmatchedRetryInterval + 1)
        _ = try await source.catalog()
        #expect(online.calls == after + 1)
    }
}
