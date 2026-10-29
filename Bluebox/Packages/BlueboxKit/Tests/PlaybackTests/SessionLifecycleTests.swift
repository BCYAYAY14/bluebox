import Domain
import Foundation
@testable import Playback
import Subtitles
import Testing

/// A progress store that takes a moment to answer, like the real one on a busy disk.
final class SlowProgress: ProgressRepository, @unchecked Sendable {
    let inner = MemoryProgress()
    func progress(for key: MediaKey) async throws -> WatchProgress? {
        try? await Task.sleep(for: .milliseconds(150))
        return try await inner.progress(for: key)
    }
    func progress(forSeries seriesKey: MediaKey) async throws -> [WatchProgress] { [] }
    func continueWatching(limit: Int) async throws -> [WatchProgress] { [] }
    func recent(limit: Int) async throws -> [WatchProgress] { [] }
    func save(_ p: WatchProgress) async throws -> WatchProgress { try await inner.save(p) }
    func delete(_ key: MediaKey) async throws {}
}

@MainActor
@Suite struct SessionLifecycleTests {
    let movie = NowPlayingItem(key: .movie(tmdbID: 7), title: "Seven")

    /// Esc while the video was still opening: it used to load and play with no player on screen.
    @Test func closingWhileOpeningNeverPlays() async throws {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: SlowProgress(), deviceID: "test")
        let opening = Task { await s.start(movie, resource: resource()) }
        try await Task.sleep(for: .milliseconds(40))
        await s.end()
        await opening.value
        #expect(engine.loads == 0)
        #expect(engine.snapshot.status != .playing)
    }

    @Test func aNewerStartWinsOverOneStillOpening() async throws {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: SlowProgress(), deviceID: "test")
        let first = Task { await s.start(movie, resource: resource("a")) }
        try await Task.sleep(for: .milliseconds(40))
        let other = NowPlayingItem(key: .movie(tmdbID: 8), title: "Eight")
        await s.start(other, resource: resource("b"))
        await first.value
        #expect(engine.loads == 1)
        #expect(s.item == other)
    }

    /// A timing fix belongs to one subtitle file, not the next episode's.
    @Test func subtitleTimingStartsFreshOnTheNextItem() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), deviceID: "test")
        await s.start(movie, resource: resource())
        s.nudgeSubtitles(by: 1.5)
        s.setSubtitleSpeed(0.96)
        await s.start(NowPlayingItem(key: .movie(tmdbID: 8), title: "Eight"), resource: resource("b"))
        #expect(s.subtitleOffset.isDefault)
    }

    @Test func speedChosenInTheSessionIsRemembered() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), deviceID: "test")
        #expect(s.chosenRate == nil)
        s.setRate(1.25)
        #expect(s.chosenRate == 1.25)
    }

    @Test func importedFilesWithTheSameNameStaySeparateAndKeepTheirLanguage() async throws {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), deviceID: "test")
        await s.start(movie, resource: resource())
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for sub in ["a", "b"] {
            try FileManager.default.createDirectory(at: dir.appending(path: sub), withIntermediateDirectories: true)
            try Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8).write(to: dir.appending(path: "\(sub)/Movie.2019.en.srt"))
        }
        s.importSubtitle(dir.appending(path: "a/Movie.2019.en.srt"))
        s.importSubtitle(dir.appending(path: "b/Movie.2019.en.srt"))
        #expect(s.externalSubtitles.count == 2)
        #expect(s.externalSubtitles.allSatisfy { $0.languageCode == "en" && $0.format == "SRT" })
    }

    @Test func languageTagsInFileNames() {
        #expect(PlayerSession.languageCode(inFileName: "Movie.2019.en") == "en")
        #expect(PlayerSession.languageCode(inFileName: "Movie.2019.eng") == "en")
        #expect(PlayerSession.languageCode(inFileName: "Movie.2019.und") == nil)
        #expect(PlayerSession.languageCode(inFileName: "Movie.2019") == nil)
        #expect(PlayerSession.languageCode(inFileName: "Movie") == nil)
    }
}
