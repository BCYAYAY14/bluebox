import Foundation
import Testing
@testable import TorrentStreaming

@Suite struct MagnetLinkTests {
    let hex = "08ada5a7a6183aae1e09d831df6748d566095a10"

    @Test func parsesAV1MagnetWithNameTrackersAndSelection() throws {
        let link = try #require(MagnetLink(string:
            "magnet:?xt=urn:btih:\(hex.uppercased())&dn=Sintel+2010&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"
            + "&tr=http://bt1.archive.org:6969/announce&so=0,2,4-6&xl=129241752&x.pe=10.0.0.1:6881"))
        #expect(link.key == hex)
        #expect(link.displayName == "Sintel 2010")
        #expect(link.trackers.map(\.absoluteString) == ["udp://tracker.opentrackr.org:1337/announce", "http://bt1.archive.org:6969/announce"])
        #expect(link.selectedFiles == IndexSet([0, 2, 4, 5, 6]))
        #expect(link.exactLength == 129_241_752)
        #expect(link.peers == ["10.0.0.1:6881"])
        #expect(link.infoHashV2 == nil)
    }

    @Test func parsesBase32Hashes() throws {
        // The same 20 bytes as `hex`, base32-encoded.
        let link = try #require(MagnetLink(string: "magnet:?xt=urn:btih:BCW2LJ5GDA5K4HQJ3AY56Z2I2VTASWQQ"))
        #expect(link.key == hex)
    }

    @Test func parsesV2AndHybridLinks() throws {
        let v2 = String(repeating: "ab", count: 32)
        let only = try #require(MagnetLink(string: "magnet:?xt=urn:btmh:1220\(v2)&dn=x"))
        #expect(only.infoHashV1 == nil)
        #expect(only.key == v2)

        let hybrid = try #require(MagnetLink(string: "magnet:?xt=urn:btih:\(hex)&xt=urn:btmh:1220\(v2)"))
        #expect(hybrid.key == hex)
        #expect(hybrid.infoHashV2?.count == 32)
        #expect(hybrid.uri.contains("xt=urn:btmh:1220\(v2)"))
    }

    @Test func acceptsBareHashesAndRejectsJunk() {
        #expect(MagnetLink(string: hex)?.key == hex)
        #expect(MagnetLink(string: "  \(hex)\n")?.key == hex)
        #expect(MagnetLink(string: "magnet:?dn=nothing") == nil)
        #expect(MagnetLink(string: "magnet:?xt=urn:btih:1234") == nil)
        #expect(MagnetLink(string: "magnet:?xt=urn:btmh:1114\(String(repeating: "0", count: 64))") == nil)
        #expect(MagnetLink(string: "https://example.com") == nil)
    }

    @Test func roundTripsThroughItsURI() throws {
        let link = try #require(MagnetLink(string: "magnet:?xt=urn:btih:\(hex)&dn=A%20%26%20B&tr=udp://t.example:80/announce&so=1-3"))
        let again = try #require(MagnetLink(string: link.uri))
        #expect(again == link)
    }
}

@Suite struct HTTPRangeTests {
    @Test func resolvesTheForms() {
        #expect(HTTPRangeResult.resolve(nil, length: 1000) == .whole)
        #expect(HTTPRangeResult.resolve("bytes=0-", length: 1000) == .partial(0...999))
        #expect(HTTPRangeResult.resolve("bytes=100-199", length: 1000) == .partial(100...199))
        #expect(HTTPRangeResult.resolve("bytes=900-5000", length: 1000) == .partial(900...999))
        #expect(HTTPRangeResult.resolve("bytes=-100", length: 1000) == .partial(900...999))
        #expect(HTTPRangeResult.resolve("bytes=-5000", length: 1000) == .partial(0...999))
        #expect(HTTPRangeResult.resolve("Bytes = 10-20", length: 1000) == .whole)  // malformed unit: ignored
        #expect(HTTPRangeResult.resolve("bytes=10-20, 30-40", length: 1000) == .partial(10...20))
    }

    @Test func unsatisfiableAndIgnoredRanges() {
        #expect(HTTPRangeResult.resolve("bytes=1000-", length: 1000) == .unsatisfiable)
        #expect(HTTPRangeResult.resolve("bytes=-0", length: 1000) == .unsatisfiable)
        #expect(HTTPRangeResult.resolve("bytes=0-", length: 0) == .unsatisfiable)
        #expect(HTTPRangeResult.resolve("bytes=20-10", length: 1000) == .whole)
        #expect(HTTPRangeResult.resolve("items=0-1", length: 1000) == .whole)
        #expect(HTTPRangeResult.resolve("bytes=abc-", length: 1000) == .whole)
    }

    @Test func parsesRequestHeads() throws {
        let head = try #require(HTTPRequestHead(Data("GET /stream/abc/Film.mkv HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=5-\r\nConnection: close".utf8)))
        #expect(head.method == "GET")
        #expect(head.path == "/stream/abc/Film.mkv")
        #expect(head.range == "bytes=5-")
        #expect(head.wantsClose)
    }

    @Test func contentTypes() {
        #expect(MediaContentType.forFile("a.mp4") == "video/mp4")
        #expect(MediaContentType.forFile("a.M4V") == "video/mp4")
        #expect(MediaContentType.forFile("a.mkv") == "video/x-matroska")
        #expect(MediaContentType.forFile("a.webm") == "video/webm")
        #expect(MediaContentType.forFile("a.avi") == "video/x-msvideo")
        #expect(MediaContentType.forFile("a.bin") == "application/octet-stream")
    }
}

@Suite struct StreamCacheTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "bb-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fill(_ root: URL, _ key: String, bytes: Int, usedAt: Date) throws {
        StreamCache.touch(key, root: root, now: usedAt)
        try Data(repeating: 1, count: bytes).write(to: StreamCache.folder(for: key, root: root).appending(path: "film.mkv"))
    }

    @Test func prunesLeastRecentlyUsedFirst() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try fill(root, "old", bytes: 300_000, usedAt: now.addingTimeInterval(-3000))
        try fill(root, "mid", bytes: 300_000, usedAt: now.addingTimeInterval(-2000))
        try fill(root, "new", bytes: 300_000, usedAt: now.addingTimeInterval(-1000))
        let total = StreamCache.totalBytes(root: root)
        #expect(total >= 900_000)

        let removed = StreamCache.prune(root: root, toBytes: total - 100_000, keeping: [])
        #expect(removed == ["old"])
        #expect(StreamCache.prune(root: root, toBytes: 1, keeping: ["mid"]) == ["new"])
        #expect(StreamCache.entries(root: root).map(\.key) == ["mid"])
    }

    @Test func nothingHappensUnderTheLimit() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try fill(root, "a", bytes: 10_000, usedAt: Date())
        #expect(StreamCache.prune(root: root, toBytes: 10_000_000, keeping: []).isEmpty)
        #expect(StreamCache.entries(root: root).count == 1)
    }

    @Test func touchingMakesAStreamRecent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try fill(root, "a", bytes: 200_000, usedAt: now.addingTimeInterval(-500))
        try fill(root, "b", bytes: 200_000, usedAt: now.addingTimeInterval(-100))
        StreamCache.touch("a", root: root, now: now)
        #expect(StreamCache.prune(root: root, toBytes: 250_000, keeping: []) == ["b"])
    }
}

@Suite struct PlanningTests {
    let mb: Int64 = 1024 * 1024

    @Test func prebufferIsSizedBySpeedAndBitrate() {
        // Faster than the film: the minimum (or a few seconds of video, whichever is more).
        #expect(PrebufferPlan.targetBytes(bitrate: 500_000, downloadRate: 5_000_000, fileLength: 2000 * mb,
                                          minimum: 3 * mb, maximum: 16 * mb, stallFreeSeconds: 60) == 3 * mb)
        #expect(PrebufferPlan.targetBytes(bitrate: 2_000_000, downloadRate: 5_000_000, fileLength: 2000 * mb,
                                          minimum: 3 * mb, maximum: 16 * mb, stallFreeSeconds: 60) == 6_000_000)
        // Slower than the film: the deficit for 60 s, capped.
        #expect(PrebufferPlan.targetBytes(bitrate: 300_000, downloadRate: 200_000, fileLength: 2000 * mb,
                                          minimum: 3 * mb, maximum: 16 * mb, stallFreeSeconds: 60) == 6_000_000)
        #expect(PrebufferPlan.targetBytes(bitrate: 3_000_000, downloadRate: 100_000, fileLength: 2000 * mb,
                                          minimum: 3 * mb, maximum: 16 * mb, stallFreeSeconds: 60) == 16 * mb)
    }

    @Test func fileSpanMapsBytesToPieces() {
        // A file starting 100 bytes into piece 2 of 1000-byte pieces.
        let span = FileSpan(offset: 2100, length: 5000, pieceLength: 1000, pieceCount: 10)
        #expect(span.firstPiece == 2)
        #expect(span.lastPiece == 7)
        #expect(span.piece(at: 899) == 2)
        #expect(span.piece(at: 900) == 3)
        #expect(span.pieces(covering: 0..<1000) == 2...3)
        #expect(span.fileRange(ofPiece: 2) == 0..<900)
        #expect(span.fileRange(ofPiece: 7) == 4900..<5000)
        let have: (Int) -> Bool = { [2, 3, 5].contains($0) }
        #expect(span.contiguousBytes(from: 0, have: have) == 1900)
        #expect(span.haveBytes(in: 4000..<5000, have: have) == 0)
        #expect(span.downloadedRanges(have: have) == [0..<1900, 2900..<3900])
    }

    @Test func deadlinesFollowTheBitrate() {
        let span = FileSpan(offset: 0, length: 100 * mb, pieceLength: mb, pieceCount: 100)
        // 1 MB/s film, 10 s window: ten pieces, a piece every 500 ms.
        let plan = ReadAheadPlan.deadlines(span: span, position: 20 * mb, bitrate: Double(mb), seconds: 10) { _ in false }
        #expect(plan.map(\.piece) == Array(20..<30))
        #expect(plan.first?.milliseconds == 0)
        #expect(plan[4].milliseconds == 2000)
        // Pieces already in are skipped.
        let fewer = ReadAheadPlan.deadlines(span: span, position: 20 * mb, bitrate: Double(mb), seconds: 10) { $0 < 25 }
        #expect(fewer.map(\.piece) == Array(25..<30))
        // Past the end: nothing.
        #expect(ReadAheadPlan.deadlines(span: span, position: 100 * mb, bitrate: Double(mb), seconds: 10) { _ in false }.isEmpty)
    }

    @Test func bitrateComesFromTheDurationOrASizeGuess() {
        #expect(ReadAheadPlan.bitrate(fileLength: 734 * 1_000_000, duration: 734) == 1_000_000)
        let guess = ReadAheadPlan.bitrate(fileLength: 4_000 * mb, duration: nil)
        #expect(guess > 500_000 && guess < 1_000_000)
    }
}

@Suite struct FileSelectionTests {
    private func file(_ i: Int, _ path: String, _ mb: Int64) -> TorrentFileEntry {
        TorrentFileEntry(index: i, path: path, size: mb * 1024 * 1024)
    }

    @Test func readsEpisodeNames() {
        func ep(_ s: Int, _ e: Int) -> EpisodeNumber { EpisodeNumber(season: s, episode: e) }
        #expect(FileSelection.episodeNumbers(in: "Show.S01E03.1080p.mkv") == [ep(1, 3)])
        #expect(FileSelection.episodeNumbers(in: "Show - s2e10 - Title.mp4") == [ep(2, 10)])
        #expect(FileSelection.episodeNumbers(in: "Show.S01E01E02.mkv") == [ep(1, 1), ep(1, 2)])
        #expect(FileSelection.episodeNumbers(in: "Show.S01E01-E03.mkv") == [ep(1, 1), ep(1, 2), ep(1, 3)])
        #expect(FileSelection.episodeNumbers(in: "Show 1x03 Title.avi") == [ep(1, 3)])
        #expect(FileSelection.episodeNumbers(in: "Show/Season 2/Episode 4.mkv") == [ep(2, 4)])
        #expect(FileSelection.episodeNumbers(in: "Show/Season 3/05 - Title.mkv") == [ep(3, 5)])
        #expect(FileSelection.episodeNumbers(in: "Show.S04/Show.E06.720p.mkv") == [ep(4, 6)])
        #expect(FileSelection.episodeNumbers(in: "Movie.2010.1080p.x264.mkv") == nil)
        #expect(FileSelection.episodeNumbers(in: "Movie.1920x1080.mkv") == nil)
    }

    @Test func picksTheEpisodeFromAPack() {
        let files = [
            file(0, "Show.S01/Show.S01E01.mkv", 900), file(1, "Show.S01/Show.S01E02.mkv", 950),
            file(2, "Show.S01/Show.S01E03.mkv", 920), file(3, "Show.S01/Sample/Show.S01E03.sample.mkv", 40),
            file(4, "Show.S01/Show.S01E03.en.srt", 1),
        ]
        #expect(FileSelection.choose(files, preferred: nil, episode: EpisodeNumber(season: 1, episode: 3))?.index == 2)
        // The add-on's index wins unless its name says another episode.
        #expect(FileSelection.choose(files, preferred: 1, episode: nil)?.index == 1)
        #expect(FileSelection.choose(files, preferred: 0, episode: EpisodeNumber(season: 1, episode: 2))?.index == 1)
        // An index that isn't a video is ignored.
        #expect(FileSelection.choose(files, preferred: 4, episode: nil)?.index == 1)
    }

    @Test func picksTheLargestVideoAndSkipsSamples() {
        let files = [file(0, "Film/Film.sample.mkv", 2000), file(1, "Film/Film.mkv", 1500), file(2, "Film/Film.nfo", 0)]
        #expect(FileSelection.choose(files, preferred: nil, episode: nil)?.index == 1)
        #expect(FileSelection.choose([file(0, "notes.txt", 1)], preferred: nil, episode: nil) == nil)
    }
}

@Suite struct DefaultTrackerTests {
    @Test func mergesWithoutDuplicatesOrHTTPS() {
        let merged = DefaultTrackers.merged(["https://secure.example/announce", "udp://tracker.opentrackr.org:1337/announce",
                                             "udp://mine.example:80/announce"])
        #expect(merged.first == "udp://tracker.opentrackr.org:1337/announce")
        #expect(merged.contains("udp://mine.example:80/announce"))
        #expect(!merged.contains { $0.hasPrefix("https://") })
        #expect(Set(merged).count == merged.count)
    }
}

@Suite struct TorrentSubtitleFileTests {
    private func file(_ i: Int, _ path: String, _ kb: Int64 = 60) -> TorrentFileEntry {
        TorrentFileEntry(index: i, path: path, size: kb * 1024)
    }

    @Test func movieWithSubsFolder() {
        let files = [file(0, "Movie.2019.1080p/Movie.2019.1080p.mkv", 4_000_000), file(1, "Movie.2019.1080p/Subs/English.srt"),
                     file(2, "Movie.2019.1080p/Subs/Spanish.srt"), file(3, "Movie.2019.1080p/RARBG.txt"),
                     file(4, "Movie.2019.1080p/Sample/sample.mkv", 20_000)]
        let subs = FileSelection.subtitles(for: files[0], in: files).map(\.index)
        #expect(subs == [1, 2])
    }

    @Test func besideTheVideoWithItsName() {
        let files = [file(0, "Movie.mkv", 2_000_000), file(1, "Movie.en.srt"), file(2, "Movie.fr.ass"), file(3, "Other.srt")]
        #expect(FileSelection.subtitles(for: files[0], in: files).map(\.index) == [1, 2, 3])
        // A video with company in its folder: only files with its name.
        let pack = [file(0, "A.mkv", 2_000_000), file(1, "B.mkv", 2_000_000), file(2, "A.en.srt"), file(3, "B.en.srt")]
        #expect(FileSelection.subtitles(for: pack[0], in: pack).map(\.index) == [2])
    }

    @Test func seasonPackPicksTheEpisodesFolderOrName() {
        let files = [file(0, "Show.S01/Show.S01E01.1080p.mkv", 1_000_000), file(1, "Show.S01/Show.S01E02.1080p.mkv", 1_000_000),
                     file(2, "Show.S01/Subs/Show.S01E01.1080p/2_English.srt"), file(3, "Show.S01/Subs/Show.S01E02.1080p/2_English.srt"),
                     file(4, "Show.S01/Subs/S01E02.French.srt"), file(5, "Show.S01/Subs/S01E01.French.srt")]
        #expect(FileSelection.subtitles(for: files[1], in: files).map(\.index) == [4, 3])
        #expect(FileSelection.subtitles(for: files[0], in: files).map(\.index) == [5, 2])
    }

    @Test func skipsPaddingAndHugeFiles() {
        var pad = file(2, ".pad/1.srt"); pad.isPadding = true
        let files = [file(0, "M.mkv", 2_000_000), file(1, "Subs/English.srt", 30_000), pad]
        #expect(FileSelection.subtitles(for: files[0], in: files).isEmpty)
    }
}
