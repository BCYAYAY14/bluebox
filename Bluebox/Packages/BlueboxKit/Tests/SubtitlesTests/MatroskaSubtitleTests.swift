import Foundation
@testable import Subtitles
import Testing

/// An MKV built in memory: a video track (1), a SubRip track (2) and an ASS
/// track (3, header-stripped), in three 5-second clusters.
enum TestMKV {
    static func id(_ id: UInt32) -> [UInt8] {
        let width = id > 0xFF_FFFF ? 4 : id > 0xFFFF ? 3 : id > 0xFF ? 2 : 1
        return (0..<width).reversed().map { UInt8((id >> (8 * UInt32($0))) & 0xFF) }
    }
    /// Always an 8-byte size, so offsets are easy to work out.
    static func size(_ n: Int) -> [UInt8] { [0x01] + (0..<7).reversed().map { UInt8((UInt64(n) >> (8 * UInt64($0))) & 0xFF) } }
    static func el(_ i: UInt32, _ body: [UInt8]) -> [UInt8] { id(i) + size(body.count) + body }
    static func uint(_ i: UInt32, _ v: UInt64, width: Int? = nil) -> [UInt8] {
        let w = width ?? max(1, (64 - v.leadingZeroBitCount + 7) / 8)
        return el(i, (0..<w).reversed().map { UInt8((v >> (8 * UInt64($0))) & 0xFF) })
    }
    static func str(_ i: UInt32, _ s: String) -> [UInt8] { el(i, Array(s.utf8)) }

    static func blockBody(track: UInt8, rel: Int16, payload: [UInt8], flags: UInt8 = 0) -> [UInt8] {
        [0x80 | track, UInt8(UInt16(bitPattern: rel) >> 8), UInt8(UInt16(bitPattern: rel) & 0xFF), flags] + payload
    }
    static func group(track: UInt8, rel: Int16, duration: UInt64, _ text: String, strip: Int = 0) -> [UInt8] {
        el(0xA0, el(0xA1, blockBody(track: track, rel: rel, payload: Array(Array(text.utf8).dropFirst(strip)))) + uint(0x9B, duration))
    }

    struct Line { var track: UInt8; var ms: Int; var duration: UInt64; var text: String }

    static let lines: [Line] = [
        Line(track: 2, ms: 1000, duration: 2000, text: "Hello"),
        Line(track: 3, ms: 2000, duration: 1000, text: "1,0,Default,,0,0,0,,Plain {\\i1}line{\\i0}"),
        Line(track: 2, ms: 6500, duration: 1500, text: "<i>World</i>"),
        Line(track: 2, ms: 12000, duration: 2000, text: "Third\r\nline"),
        Line(track: 3, ms: 11000, duration: 1000, text: "1,0,Default,,0,0,0,,{\\pos(10,10)}Sign"),
    ]
    static let assPrefix = "1,0,Default"

    /// - Parameter indexSubtitles: Cues entries for every subtitle block (with CueRelativePosition), as mkvmerge writes.
    /// - Parameter styled: include the ASS track's positioned sign at 11 s.
    static func make(indexSubtitles: Bool, styled: Bool = true) -> Data {
        let ebml = el(0x1A45_DFA3, str(0x4282, "matroska") + uint(0x4287, 4))
        let info = el(0x1549_A966, uint(0x2AD7B1, 1_000_000) + el(0x4489, withUnsafeBytes(of: Double(15000).bitPattern.bigEndian) { Array($0) }))
        let strip = Array(assPrefix.utf8)
        let tracks = el(0x1654_AE6B,
            el(0xAE, uint(0xD7, 1) + uint(0x83, 1) + str(0x86, "V_MPEG4/ISO/AVC")) +
            el(0xAE, uint(0xD7, 2) + uint(0x83, 0x11) + str(0x86, "S_TEXT/UTF8") + str(0x22B59C, "fre") + str(0x536E, "Français")) +
            el(0xAE, uint(0xD7, 3) + uint(0x83, 0x11) + str(0x86, "S_TEXT/ASS") + el(0x63A2, Array("[Script Info]".utf8)) +
               el(0x6D80, el(0x6240, el(0x5034, uint(0x4254, 3) + el(0x4255, strip))))))

        // Clusters, noting where each subtitle block sits inside its cluster's data.
        var clusters: [[UInt8]] = []
        var subtitlePositions: [(time: Int, track: UInt8, cluster: Int, relative: Int)] = []
        for k in 0..<3 {
            var body = uint(0xE7, UInt64(k * 5000))
            body += el(0xA3, blockBody(track: 1, rel: 0, payload: [UInt8](repeating: 0xAB, count: 100_000), flags: 0x80))
            for line in lines where line.ms / 5000 == k && (styled || !line.text.contains("\\pos")) {
                subtitlePositions.append((line.ms, line.track, k, body.count))
                body += group(track: line.track, rel: Int16(line.ms - k * 5000), duration: line.duration, line.text,
                              strip: line.track == 3 ? strip.count : 0)
            }
            clusters.append(el(0x1F43_B675, body))
        }
        func seekHead(cues: UInt64) -> [UInt8] {
            el(0x114D_9B74, el(0x4DBB, el(0x53AB, id(0x1C53_BB6B)) + uint(0x53AC, cues, width: 8)))
        }
        let headerLength = seekHead(cues: 0).count + info.count + tracks.count
        var clusterOffsets: [Int] = []
        var at = headerLength
        for c in clusters { clusterOffsets.append(at); at += c.count }
        var cuePoints: [UInt8] = []
        var entries: [(time: Int, track: UInt8, cluster: Int, relative: Int?)] = (0..<3).map { (time: $0 * 5000, track: 1, cluster: $0, relative: nil) }
        if indexSubtitles { entries += subtitlePositions.map { (time: $0.time, track: $0.track, cluster: $0.cluster, relative: $0.relative) } }
        for e in entries.sorted(by: { $0.time < $1.time }) {
            var positions = uint(0xF7, UInt64(e.track)) + uint(0xF1, UInt64(clusterOffsets[e.cluster]))
            if let rel = e.relative { positions += uint(0xF0, UInt64(rel)) }
            cuePoints += el(0xBB, uint(0xB3, UInt64(e.time)) + el(0xB7, positions))
        }
        let cues = el(0x1C53_BB6B, cuePoints)
        let segmentBody = seekHead(cues: UInt64(at)) + info + tracks + clusters.flatMap { $0 } + cues
        return Data(ebml + el(0x1853_8067, segmentBody))
    }
}

/// A file in memory that counts what's read.
final class MemorySource: ByteSource, @unchecked Sendable {
    let data: Data
    private let lock = NSLock()
    private var _read = 0
    var bytesRead: Int { lock.withLock { _read } }
    init(_ data: Data) { self.data = data }
    func length() async throws -> Int64 { Int64(data.count) }
    func read(_ range: Range<Int64>) async throws -> Data {
        let lo = Int(max(0, range.lowerBound)), hi = min(data.count, Int(range.upperBound))
        guard lo < hi else { return Data() }
        lock.withLock { _read += hi - lo }
        return data.subdata(in: lo..<hi)
    }
}

@Suite struct MatroskaSubtitleReaderTests {
    @Test func readsSubtitleTracks() async throws {
        let reader = MatroskaSubtitleReader(source: MemorySource(TestMKV.make(indexSubtitles: false)))
        let tracks = try await reader.subtitleTracks()
        #expect(tracks.map(\.number) == [2, 3])
        #expect(tracks[0].textCodec == .srt)
        #expect(tracks[0].language == "fre")
        #expect(tracks[0].name == "Français")
        #expect(tracks[1].textCodec == .ass)
        #expect(tracks[1].compression == .headerStripping(Data(TestMKV.assPrefix.utf8)))
    }

    @Test(arguments: [false, true]) func blocksInASpan(indexed: Bool) async throws {
        let reader = MatroskaSubtitleReader(source: MemorySource(TestMKV.make(indexSubtitles: indexed)))
        let all = try await reader.blocks(track: 2, from: 0, to: 20)
        #expect(all.map(\.start) == [1, 6.5, 12])
        #expect(all.map(\.duration) == [2, 1.5, 2])
        let middle = try await reader.blocks(track: 2, from: 5, to: 10)
        #expect(middle.count == 1)
        #expect(EmbeddedTextCodec.srt.text(middle[0].payload) == "World")
        // Header stripping puts the prefix back.
        let ass = try await reader.blocks(track: 3, from: 0, to: 5)
        #expect(EmbeddedTextCodec.ass.text(try #require(ass.first).payload) == "Plain line")
    }

    @Test func indexedSubtitlesSkipTheVideo() async throws {
        let scanned = MemorySource(TestMKV.make(indexSubtitles: false))
        let indexed = MemorySource(TestMKV.make(indexSubtitles: true))
        _ = try await MatroskaSubtitleReader(source: scanned).blocks(track: 2, from: 10, to: 15)
        _ = try await MatroskaSubtitleReader(source: indexed).blocks(track: 2, from: 10, to: 15)
        // Both read the head (index); only the scan reads the cluster's 100 KB video block.
        #expect(scanned.bytesRead - indexed.bytesRead > 50_000)
    }

    @Test func notMatroska() async {
        let reader = MatroskaSubtitleReader(source: MemorySource(Data(repeating: 0, count: 1000)))
        await #expect(throws: MatroskaError.notMatroska) { try await reader.subtitleTracks() }
    }

    @Test func zlibBlocksInflate() throws {
        let text = Data(String(repeating: "Bonjour tout le monde. ", count: 40).utf8)
        let deflated = try (text as NSData).compressed(using: .zlib) as Data  // raw deflate
        var adler = (a: UInt32(1), b: UInt32(0))
        for byte in text { adler.a = (adler.a + UInt32(byte)) % 65521; adler.b = (adler.b + adler.a) % 65521 }
        let checksum = (adler.b << 16) | adler.a
        let zlib = Data([0x78, 0x9C]) + deflated + withUnsafeBytes(of: checksum.bigEndian) { Data($0) }
        #expect(MatroskaSubtitleReader.decompress(zlib, .zlib) == text)
    }
}

@Suite struct EmbeddedTextCodecTests {
    @Test func codecIDs() {
        #expect(EmbeddedTextCodec(matroskaCodecID: "S_TEXT/UTF8") == .srt)
        #expect(EmbeddedTextCodec(matroskaCodecID: "D_WEBVTT/SUBTITLES") == .webVTT)
        #expect(EmbeddedTextCodec(matroskaCodecID: "S_TEXT/SSA") == .ssa)
        #expect(EmbeddedTextCodec(matroskaCodecID: "S_HDMV/PGS") == nil)
        #expect(EmbeddedTextCodec(matroskaCodecID: "S_VOBSUB") == nil)
    }

    @Test func text() {
        #expect(EmbeddedTextCodec.srt.text(Data("<i>Hi</i>\r\n<b>there</b>".utf8)) == "Hi\nthere")
        #expect(EmbeddedTextCodec.webVTT.text(Data("<v Bob>Hello &amp; bye".utf8)) == "Hello & bye")
        #expect(EmbeddedTextCodec.ass.text(Data("3,0,Default,,0,0,0,,Line one\\NLine, two".utf8)) == "Line one\nLine, two")
        #expect(EmbeddedTextCodec.srt.text(Data("  ".utf8)) == nil)
    }

    @Test func overrideTags() {
        func tagged(_ s: String) -> Bool { EmbeddedTextCodec.hasOverrideTags(Data("1,0,Default,,0,0,0,,\(s)".utf8)) }
        #expect(!tagged("Plain line"))
        #expect(!tagged("{\\i1}Italic{\\i0} and {\\b1}bold{\\b0}"))
        #expect(!tagged("{Translator's note}"))
        #expect(tagged("{\\an8}Top"))
        #expect(tagged("{\\pos(320,50)}Sign"))
        #expect(tagged("{\\i1\\fad(200,200)}Fading"))
        #expect(tagged("{\\c&H00FFFF&}Yellow"))
    }
}

@Suite @MainActor struct EmbeddedTextFeedTests {
    func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func followsThePlayhead() async throws {
        let feed = EmbeddedTextFeed(source: MemorySource(TestMKV.make(indexSubtitles: true)))
        feed.start()
        await feed.ready()
        #expect(feed.tracks.map(\.number) == [2, 3])
        #expect(feed.verdict(track: 2) == .bluebox)
        #expect(feed.verdict(track: 3) == .pending)

        feed.follow(tracks: [2], at: 0)
        await waitFor { feed.text(track: 2, at: 1.5) != nil }
        #expect(feed.text(track: 2, at: 1.5) == "Hello")
        #expect(feed.text(track: 2, at: 3.5) == nil)
        #expect(feed.text(track: 2, at: 7) == "World")
        #expect(feed.text(track: 2, at: 13) == "Third\nline")
    }

    @Test func plainASSIsDrawnByBluebox() async throws {
        let feed = EmbeddedTextFeed(source: MemorySource(TestMKV.make(indexSubtitles: false, styled: false)))
        feed.start()
        await feed.ready()
        feed.follow(tracks: [3], at: 0)
        await waitFor { feed.verdict(track: 3) != .pending }
        #expect(feed.verdict(track: 3) == .bluebox)
        #expect(feed.text(track: 3, at: 2.5) == "Plain line")
    }

    @Test func styledASSStaysWithThePlayer() async throws {
        let feed = EmbeddedTextFeed(source: MemorySource(TestMKV.make(indexSubtitles: false)))
        feed.start()
        await feed.ready()
        feed.follow(tracks: [3], at: 0)
        await waitFor { feed.verdict(track: 3) != .pending }
        #expect(feed.verdict(track: 3) == .player)
    }

    @Test func notMatroskaFails() async {
        let feed = EmbeddedTextFeed(source: MemorySource(Data(repeating: 1, count: 100)))
        feed.start()
        await feed.ready()
        #expect(feed.failed)
        #expect(feed.verdict(track: 2) == .player)
    }

    @Test func coveredStretchesMerge() {
        let merged = EmbeddedTextFeed.merging(10..<40, into: [0..<12, 50..<60])
        #expect(merged == [0..<40, 50..<60])
    }
}
