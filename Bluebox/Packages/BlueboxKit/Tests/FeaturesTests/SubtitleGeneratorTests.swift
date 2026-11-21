import Domain
@testable import Features
import Foundation
import Subtitles
import Testing

@Suite struct SubtitleGeneratorPlanTests {
    let all: (ClosedRange<TimeInterval>) -> Bool = { _ in true }

    @Test func startsJustBeforeThePlayhead() {
        let next = SubtitleGenerator.nextChunk(position: 600, duration: 3600, covered: CoveredTime(), available: all)
        #expect(next == 598...628)
    }

    @Test func keepsAheadThenFillsInFromTheStart() {
        var covered = CoveredTime([598...700])
        #expect(SubtitleGenerator.nextChunk(position: 610, duration: 3600, covered: covered, available: all)?.lowerBound ?? 0 > 700)
        covered.insert(700...3600)
        // Everything after the playhead is written: back to the beginning.
        #expect(SubtitleGenerator.nextChunk(position: 610, duration: 3600, covered: covered, available: all) == 0...30)
        covered.insert(0...598)
        #expect(SubtitleGenerator.nextChunk(position: 610, duration: 3600, covered: covered, available: all) == nil)
    }

    @Test func aChunkStopsWhereWrittenLinesBegin() {
        let covered = CoveredTime([615...700])
        #expect(SubtitleGenerator.nextChunk(position: 602, duration: 3600, covered: covered, available: all) == 600...615)
    }

    @Test func aTorrentOnlyGivesWhatHasDownloaded() {
        // Downloaded: the first ten minutes and 30–35 minutes in.
        let downloaded: (ClosedRange<TimeInterval>) -> Bool = { r in r.upperBound <= 600 || (r.lowerBound >= 1800 && r.upperBound <= 2100) }
        let next = SubtitleGenerator.nextChunk(position: 1200, duration: 3600, covered: CoveredTime(), available: downloaded)
        #expect(next.map { $0.lowerBound >= 1800 && $0.upperBound <= 2100 } == true)
        // Nothing downloaded anywhere: wait.
        #expect(SubtitleGenerator.nextChunk(position: 0, duration: 3600, covered: CoveredTime(), available: { _ in false }) == nil)
    }
}

@Suite struct GeneratedSubtitleStoreTests {
    func store() -> GeneratedSubtitleStore {
        GeneratedSubtitleStore(folder: FileManager.default.temporaryDirectory.appending(path: "bluebox-gen-\(UUID().uuidString)"))
    }

    @Test func savesAndFindsATrackForTheSameLengthOnly() throws {
        let store = store()
        defer { store.deleteAll() }
        let key = MediaKey.movie(tmdbID: 42)
        let cues = [SubtitleCue(start: 1, end: 3, text: "One"), SubtitleCue(start: 4, end: 6, text: "Two")]
        let note = GeneratedSubtitleStore.Note(spoken: "ja", language: "en", duration: 6000, covered: CoveredTime([0...600]),
                                               engine: "apple", title: "Film", written: .now)
        try store.save(cues, note: note, for: key)
        let saved = store.saved(for: key, duration: 6002)
        #expect(saved.count == 1)
        #expect(saved.first?.note.covered == CoveredTime([0...600]))
        #expect(saved.first?.complete == false)
        #expect(store.cues(saved[0]).map(\.text) == ["One", "Two"])
        // Another release, cut differently.
        #expect(store.saved(for: key, duration: 5400).isEmpty)
        #expect(store.usage().titles == 1)
        store.delete(key)
        #expect(store.saved(for: key, duration: nil).isEmpty)
    }
}
