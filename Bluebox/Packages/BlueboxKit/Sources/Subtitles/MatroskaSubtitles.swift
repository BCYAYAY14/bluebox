import Compression
import Foundation

// Reads subtitle blocks from a Matroska (MKV, WebM) file near a point in
// time, so text tracks inside the video can be drawn by Bluebox's overlay
// instead of the player. Only what that needs: the segment's Info, Tracks
// and Cues, and the clusters (or, when the muxer indexed subtitle blocks,
// just the blocks) around the playhead. Written from the Matroska spec
// (RFC 9559) and the EBML spec (RFC 8794).

/// A subtitle track's codec, for the text formats Bluebox can draw.
public enum EmbeddedTextCodec: String, Sendable, Equatable {
    case srt, webVTT, ass, ssa

    public init?(matroskaCodecID id: String) {
        switch id {
        case "S_TEXT/UTF8", "S_TEXT/ASCII": self = .srt
        case "S_TEXT/WEBVTT", "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS", "D_WEBVTT/DESCRIPTIONS": self = .webVTT
        case "S_TEXT/ASS", "S_ASS": self = .ass
        case "S_TEXT/SSA", "S_SSA": self = .ssa
        default: return nil
        }
    }

    /// True for ASS/SSA, which are only drawn by Bluebox when their lines carry no override tags.
    public var isASS: Bool { self == .ass || self == .ssa }

    /// The text to show for one block's payload, nil when there's none.
    public func text(_ payload: Data) -> String? {
        guard var s = SubtitleParser.decode(payload) else { return nil }
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let body: String
        switch self {
        case .srt, .webVTT:
            body = s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { SubtitleParser.stripTags(String($0)) }.joined(separator: "\n")
        case .ass, .ssa:
            guard let field = Self.assTextField(s) else { return nil }
            body = SubtitleParser.plainASSText(field)
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Matroska stores an ASS/SSA event as `ReadOrder, Layer, Style, Name,
    /// MarginL, MarginR, MarginV, Effect, Text`: the text is after the eighth comma.
    static func assTextField(_ line: String) -> String? {
        let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        return fields.count == 9 ? String(fields[8]) : nil
    }

    /// True when an ASS/SSA block styles or places its line itself (`{\pos(…)}`,
    /// `{\an8}`, `{\fad(…)}`, colours, fonts, karaoke, drawings): VLC's libass
    /// draws those. Italic, bold, underline and strike-out toggles (`{\i1}`)
    /// don't count; they're dropped like an SRT's `<i>`.
    public static func hasOverrideTags(_ payload: Data) -> Bool {
        guard let s = SubtitleParser.decode(payload), let field = assTextField(s) else { return false }
        var rest = Substring(field)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { return false }
            let tags = rest[rest.index(after: open)..<close].split(separator: "\\").map { $0.trimmingCharacters(in: .whitespaces) }
            let blockHasTags = rest[open...close].contains("\\")
            if blockHasTags, tags.contains(where: { !$0.isEmpty && !Self.isSimpleToggle($0) }) { return true }
            rest = rest[rest.index(after: close)...]
        }
        return false
    }

    private static func isSimpleToggle(_ tag: String) -> Bool {
        guard let first = tag.first, "ibus".contains(first) else { return false }
        return tag.dropFirst().allSatisfy(\.isNumber)
    }
}

public struct MatroskaTrack: Sendable, Equatable {
    public enum Compression: Sendable, Equatable { case zlib, headerStripping(Data) }
    public var number: Int
    /// 1 video, 2 audio, 0x11 subtitle.
    public var type: Int
    public var codecID: String
    public var codecPrivate: Data?
    public var language: String?
    public var name: String?
    public var compression: Compression?
    /// Encrypted (or otherwise unreadable) blocks.
    public var unreadable = false

    public var isSubtitle: Bool { type == 0x11 }
    public var textCodec: EmbeddedTextCodec? { unreadable ? nil : EmbeddedTextCodec(matroskaCodecID: codecID) }

    public init(number: Int, type: Int, codecID: String, codecPrivate: Data? = nil, language: String? = nil, name: String? = nil,
                compression: Compression? = nil) {
        self.number = number; self.type = type; self.codecID = codecID; self.codecPrivate = codecPrivate
        self.language = language; self.name = name; self.compression = compression
    }
}

/// One subtitle block: when it starts, how long it shows, and its (decompressed) payload.
public struct MatroskaBlock: Sendable, Equatable {
    public var track: Int
    public var start: TimeInterval
    public var duration: TimeInterval?
    public var payload: Data
}

public enum MatroskaError: Error, Equatable, Sendable {
    case notMatroska
    case malformed
}

/// Reads a Matroska file's subtitle blocks on demand. The index (tracks and
/// cues) is read once; each `blocks` call reads only what that time span needs.
public actor MatroskaSubtitleReader {
    struct CuePosition: Sendable, Equatable {
        var track: Int
        /// Cluster offset from the segment's data start.
        var cluster: Int64
        /// The block's offset from the cluster's data start, when the muxer wrote it.
        var relative: Int64?
    }
    struct CuePoint: Sendable, Equatable {
        var time: Int64
        var positions: [CuePosition]
    }
    struct Index: Sendable {
        var segmentStart: Int64 = 0
        var segmentEnd: Int64 = 0
        /// Nanoseconds per tick.
        var scale: Double = 1_000_000
        var duration: TimeInterval?
        var tracks: [MatroskaTrack] = []
        var cues: [CuePoint] = []
        var firstCluster: Int64?
        func seconds(_ ticks: Int64) -> TimeInterval { Double(ticks) * scale / 1_000_000_000 }
        func ticks(_ seconds: TimeInterval) -> Int64 { Int64((seconds * 1_000_000_000 / scale).rounded(.down)) }
    }

    private let source: any ByteSource
    private var index: Index?
    private var indexTask: Task<Index, Error>?
    /// Cluster timestamps by absolute offset, for blocks read on their own.
    private var clusterTimes: [Int64: (time: Int64, dataStart: Int64, end: Int64?)] = [:]
    /// The most a time span reads from clusters (when the subtitles aren't indexed).
    static let clusterBudget = 96 * 1024 * 1024

    public init(source: any ByteSource) { self.source = source }

    /// The file's subtitle tracks, in the order they're declared.
    public func subtitleTracks() async throws -> [MatroskaTrack] {
        try await loadIndex().tracks.filter(\.isSubtitle)
    }

    /// Blocks of `track` starting in `from..<to` (seconds), in time order.
    public func blocks(track: Int, from: TimeInterval, to: TimeInterval) async throws -> [MatroskaBlock] {
        let index = try await loadIndex()
        guard let entry = index.tracks.first(where: { $0.number == track }), to > from else { return [] }
        let lo = index.ticks(max(0, from)), hi = index.ticks(to)
        var out: [MatroskaBlock] = []
        let indexed = index.cues.contains { $0.positions.contains { $0.track == track } }
        if indexed {
            // The muxer indexed every subtitle block: read just those.
            for point in index.cues where point.time >= lo && point.time < hi {
                for pos in point.positions where pos.track == track {
                    try Task.checkCancellation()
                    let cluster = index.segmentStart + pos.cluster
                    if let rel = pos.relative {
                        if let block = try await readIndexedBlock(cluster: cluster, relative: rel, track: entry, index: index) {
                            out.append(block)
                        }
                    } else {
                        out += try await readCluster(at: cluster, track: entry, index: index).blocks
                    }
                }
            }
        } else {
            var position = try await clusterStart(before: lo, index: index)
            var budget = Self.clusterBudget
            while let at = position, at < index.segmentEnd, budget > 0 {
                try Task.checkCancellation()
                let cluster = try await readCluster(at: at, track: entry, index: index, endTick: hi)
                guard let end = cluster.end else { break }
                out += cluster.blocks
                if cluster.time >= hi { break }
                budget -= Int(end - at)
                position = end
            }
        }
        var seen = Set<Data>()
        return out.filter { $0.start >= index.seconds(lo) && $0.start < index.seconds(hi) }
            .sorted { $0.start < $1.start }
            .filter { seen.insert(Self.key($0)).inserted }
    }

    private static func key(_ b: MatroskaBlock) -> Data {
        withUnsafeBytes(of: b.start.bitPattern) { Data($0) } + b.payload
    }

    // MARK: Index

    private func loadIndex() async throws -> Index {
        if let index { return index }
        if let indexTask { return try await indexTask.value }
        let source = source
        let task = Task { try await Self.readIndex(source) }
        indexTask = task
        do {
            let made = try await task.value
            index = made
            return made
        } catch {
            indexTask = nil
            throw error
        }
    }

    static let headChunk: Int64 = 256 * 1024

    static func readIndex(_ source: any ByteSource) async throws -> Index {
        let length = try await source.length()
        var window = try await Window(source: source, start: 0, count: min(length, headChunk))
        guard let ebml = window.element(at: 0), ebml.id == ID.ebml, let ebmlEnd = ebml.end,
              let segment = try await window.element(at: ebmlEnd, source: source), segment.id == ID.segment else {
            throw MatroskaError.notMatroska
        }
        var index = Index()
        index.segmentStart = segment.dataStart
        index.segmentEnd = segment.end.map { min($0, length) } ?? length
        var seeks: [UInt32: Int64] = [:]
        var haveTracks = false, haveCues = false, haveInfo = false
        var pos = segment.dataStart
        while pos < index.segmentEnd {
            guard let el = try await window.element(at: pos, source: source) else { break }
            if el.id == ID.cluster { index.firstCluster = pos; break }
            guard let end = el.end else { break }
            switch el.id {
            case ID.seekHead:
                let body = try await window.bytes(el.dataStart..<end, source: source)
                for (id, at) in parseSeekHead(body) where seeks[id] == nil { seeks[id] = at }
            case ID.info:
                parseInfo(try await window.bytes(el.dataStart..<end, source: source), into: &index); haveInfo = true
            case ID.tracks:
                index.tracks = parseTracks(try await window.bytes(el.dataStart..<end, source: source)); haveTracks = true
            case ID.cues:
                index.cues = parseCues(try await window.bytes(el.dataStart..<end, source: source)); haveCues = true
            default: break
            }
            pos = end
        }
        // What wasn't before the first cluster (Cues usually sit at the end), from the SeekHead.
        for (id, done) in [(ID.info, haveInfo), (ID.tracks, haveTracks), (ID.cues, haveCues)] where !done {
            guard let rel = seeks[id] else { continue }
            let at = index.segmentStart + rel
            guard at < index.segmentEnd else { continue }
            let w = try await Window(source: source, start: at, count: min(64, length - at))
            guard let el = w.element(at: at), el.id == id, let end = el.end else { continue }
            let body = try await w.bytes(el.dataStart..<min(end, length), source: source)
            switch id {
            case ID.info: parseInfo(body, into: &index)
            case ID.tracks: index.tracks = parseTracks(body)
            default: index.cues = parseCues(body)
            }
        }
        index.cues.sort { $0.time < $1.time }
        return index
    }

    // MARK: Clusters and blocks

    private func clusterHeader(at offset: Int64) async throws -> (time: Int64, dataStart: Int64, end: Int64?)? {
        if let known = clusterTimes[offset] { return known }
        let w = try await Window(source: source, start: offset, count: 64)
        guard let el = w.element(at: offset), el.id == ID.cluster else { return nil }
        var time: Int64 = 0
        // The Timestamp is the cluster's first child in practice (after a CRC-32 at most).
        var pos = el.dataStart
        for _ in 0..<3 {
            guard let child = w.element(at: pos), let end = child.end, end <= w.end else { break }
            if child.id == ID.timestamp { time = Int64(bitPattern: Self.uint(w.slice(child.dataStart..<end))); break }
            pos = end
        }
        let header = (time, el.dataStart, el.end)
        clusterTimes[offset] = header
        return header
    }

    private func readIndexedBlock(cluster: Int64, relative: Int64, track: MatroskaTrack, index: Index) async throws -> MatroskaBlock? {
        guard let header = try await clusterHeader(at: cluster) else { return nil }
        let at = header.dataStart + relative
        var w = try await Window(source: source, start: at, count: 4096)
        guard let el = try await w.element(at: at, source: source), let end = el.end else { return nil }
        let body = try await w.bytes(el.dataStart..<end, source: source)
        return Self.blocks(in: body, id: el.id, clusterTime: header.time, track: track, index: index).first
    }

    private func readCluster(at offset: Int64, track: MatroskaTrack, index: Index,
                             endTick: Int64? = nil) async throws -> (blocks: [MatroskaBlock], time: Int64, end: Int64?) {
        guard let header = try await clusterHeader(at: offset) else { return ([], 0, nil) }
        if let endTick, header.time >= endTick { return ([], header.time, header.end) }
        guard let end = header.end else { return ([], header.time, nil) }  // unknown-size clusters aren't read
        let body = try await source.read(header.dataStart..<end)
        var blocks: [MatroskaBlock] = []
        var pos = 0
        let bytes = [UInt8](body)
        while pos < bytes.count {
            guard let (id, idWidth) = Self.readID(bytes, pos), let (size, sizeWidth) = Self.readSize(bytes, pos + idWidth),
                  let size else { break }
            let start = pos + idWidth + sizeWidth
            let stop = start + Int(size)
            guard stop <= bytes.count else { break }
            if id == ID.simpleBlock || id == ID.blockGroup {
                blocks += Self.blocks(in: Array(bytes[start..<stop]), id: id, clusterTime: header.time, track: track, index: index)
            }
            pos = stop
        }
        return (blocks, header.time, end)
    }

    /// Where to start reading clusters for a time: the last cue point at or
    /// before it, else a guess from the duration, found by the Cluster ID.
    private func clusterStart(before tick: Int64, index: Index) async throws -> Int64? {
        if let point = index.cues.last(where: { $0.time <= tick }) ?? index.cues.first,
           let pos = point.positions.first {
            return index.segmentStart + pos.cluster
        }
        guard let first = index.firstCluster else { return nil }
        guard let duration = index.duration, duration > 0 else { return first }
        let span = Double(index.segmentEnd - first)
        var fraction = min(max(index.seconds(tick) / duration - 0.01, 0), 1)
        for _ in 0..<8 {
            let guess = first + Int64(span * fraction)
            guard let found = try await findCluster(from: guess, limit: index.segmentEnd) else { return first }
            if let header = try await clusterHeader(at: found), header.time <= tick || fraction == 0 { return found }
            fraction = max(0, fraction - 0.02)
        }
        return first
    }

    private func findCluster(from offset: Int64, limit: Int64) async throws -> Int64? {
        var at = offset
        let chunk: Int64 = 512 * 1024
        for _ in 0..<16 where at < limit {
            let data = [UInt8](try await source.read(at..<min(limit, at + chunk)))
            guard data.count >= 4 else { return nil }
            var i = 0
            while i + 4 <= data.count {
                if data[i] == 0x1F, data[i + 1] == 0x43, data[i + 2] == 0xB6, data[i + 3] == 0x75,
                   let header = try await clusterHeader(at: at + Int64(i)), header.end != nil {
                    return at + Int64(i)
                }
                i += 1
            }
            at += Int64(data.count) - 3
        }
        return nil
    }

    /// The blocks of `track` in a SimpleBlock or BlockGroup body.
    static func blocks(in body: [UInt8], id: UInt32, clusterTime: Int64, track: MatroskaTrack, index: Index) -> [MatroskaBlock] {
        var blockBytes: ArraySlice<UInt8>?
        var duration: Int64?
        if id == ID.simpleBlock {
            blockBytes = body[...]
        } else if id == ID.blockGroup {
            var pos = 0
            while pos < body.count {
                guard let (cid, w1) = readID(body, pos), let (size, w2) = readSize(body, pos + w1), let size else { break }
                let start = pos + w1 + w2, stop = start + Int(size)
                guard stop <= body.count else { break }
                if cid == ID.block { blockBytes = body[start..<stop] }
                if cid == ID.blockDuration { duration = Int64(bitPattern: uint(body[start..<stop])) }
                pos = stop
            }
        } else {
            return []
        }
        guard let raw = blockBytes, let block = parseBlock(Array(raw)), block.track == track.number,
              let payload = decompress(block.payload, track.compression) else { return [] }
        let start = index.seconds(clusterTime + Int64(block.relativeTime))
        return [MatroskaBlock(track: track.number, start: start, duration: duration.map { index.seconds($0) }, payload: payload)]
    }

    /// Track number, timestamp relative to the cluster, payload. Laced blocks
    /// (never used for subtitles) are skipped.
    static func parseBlock(_ b: [UInt8]) -> (track: Int, relativeTime: Int16, payload: Data)? {
        guard let (number, width) = readVInt(b, 0), b.count >= width + 3 else { return nil }
        let time = Int16(bitPattern: UInt16(b[width]) << 8 | UInt16(b[width + 1]))
        let flags = b[width + 2]
        guard (flags >> 1) & 0x03 == 0 else { return nil }
        return (Int(number), time, Data(b[(width + 3)...]))
    }

    static func decompress(_ data: Data, _ compression: MatroskaTrack.Compression?) -> Data? {
        switch compression {
        case nil: return data
        case .headerStripping(let prefix): return prefix + data
        case .zlib: return inflate(data)
        }
    }

    /// zlib (RFC 1950) data: Apple's ZLIB decoder takes the raw deflate stream inside it.
    static func inflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let deflate = data.dropFirst(2)
        var capacity = max(4096, deflate.count * 8)
        while capacity <= 16 * 1024 * 1024 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst in
                deflate.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, deflate.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written == 0 { return nil }
            if written < capacity { return out.prefix(written) }
            capacity *= 4
        }
        return nil
    }

    // MARK: Element parsing

    enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let seekHead: UInt32 = 0x114D_9B74
        static let seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB
        static let seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549_A966
        static let timestampScale: UInt32 = 0x2AD7B1
        static let duration: UInt32 = 0x4489
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let language: UInt32 = 0x22B59C
        static let languageBCP47: UInt32 = 0x22B59D
        static let name: UInt32 = 0x536E
        static let contentEncodings: UInt32 = 0x6D80
        static let contentEncoding: UInt32 = 0x6240
        static let contentEncodingScope: UInt32 = 0x5032
        static let contentEncodingType: UInt32 = 0x5033
        static let contentCompression: UInt32 = 0x5034
        static let contentCompAlgo: UInt32 = 0x4254
        static let contentCompSettings: UInt32 = 0x4255
        static let cues: UInt32 = 0x1C53_BB6B
        static let cuePoint: UInt32 = 0xBB
        static let cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7
        static let cueTrack: UInt32 = 0xF7
        static let cueClusterPosition: UInt32 = 0xF1
        static let cueRelativePosition: UInt32 = 0xF0
        static let cluster: UInt32 = 0x1F43_B675
        static let timestamp: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let blockDuration: UInt32 = 0x9B
    }

    /// Children of a master element's body: (id, body).
    static func children(_ b: [UInt8]) -> [(UInt32, ArraySlice<UInt8>)] {
        var out: [(UInt32, ArraySlice<UInt8>)] = []
        var pos = 0
        while pos < b.count {
            guard let (id, w1) = readID(b, pos), let (size, w2) = readSize(b, pos + w1), let size else { break }
            let start = pos + w1 + w2, stop = start + Int(size)
            guard stop <= b.count else { break }
            out.append((id, b[start..<stop]))
            pos = stop
        }
        return out
    }

    static func parseSeekHead(_ b: [UInt8]) -> [(UInt32, Int64)] {
        children(b).compactMap { id, body in
            guard id == ID.seek else { return nil }
            var seekID: UInt32?, position: Int64?
            for (cid, value) in children(Array(body)) {
                if cid == ID.seekID { seekID = UInt32(truncatingIfNeeded: uint(value)) }
                if cid == ID.seekPosition { position = Int64(bitPattern: uint(value)) }
            }
            guard let seekID, let position else { return nil }
            return (seekID, position)
        }
    }

    static func parseInfo(_ b: [UInt8], into index: inout Index) {
        var raw: Double?
        for (id, value) in children(b) {
            if id == ID.timestampScale, uint(value) > 0 { index.scale = Double(uint(value)) }
            if id == ID.duration { raw = float(value) }
        }
        if let raw, raw.isFinite, raw > 0 { index.duration = raw * index.scale / 1_000_000_000 }
    }

    static func parseTracks(_ b: [UInt8]) -> [MatroskaTrack] {
        children(b).compactMap { id, body in
            guard id == ID.trackEntry else { return nil }
            var track = MatroskaTrack(number: 0, type: 0, codecID: "")
            var language: String? = "eng"  // the spec's default
            var bcp47: String?
            var privateScope = false
            for (cid, value) in children(Array(body)) {
                switch cid {
                case ID.trackNumber: track.number = Int(uint(value))
                case ID.trackType: track.type = Int(uint(value))
                case ID.codecID: track.codecID = string(value)
                case ID.codecPrivate: track.codecPrivate = Data(value)
                case ID.language: language = string(value)
                case ID.languageBCP47: bcp47 = string(value)
                case ID.name: track.name = string(value)
                case ID.contentEncodings:
                    for (eid, encoding) in children(Array(value)) where eid == ID.contentEncoding {
                        var scope: UInt64 = 1, type: UInt64 = 0
                        var algo: UInt64 = 0, settings = Data()
                        for (fid, field) in children(Array(encoding)) {
                            switch fid {
                            case ID.contentEncodingScope: scope = uint(field)
                            case ID.contentEncodingType: type = uint(field)
                            case ID.contentCompression:
                                for (kid, k) in children(Array(field)) {
                                    if kid == ID.contentCompAlgo { algo = uint(k) }
                                    if kid == ID.contentCompSettings { settings = Data(k) }
                                }
                            default: break
                            }
                        }
                        guard type == 0 else { track.unreadable = true; continue }
                        switch algo {
                        case 0: if scope & 1 != 0 { track.compression = .zlib }; privateScope = scope & 2 != 0
                        case 3: if scope & 1 != 0 { track.compression = .headerStripping(settings) }
                        default: track.unreadable = true
                        }
                    }
                default: break
                }
            }
            if privateScope, let p = track.codecPrivate { track.codecPrivate = inflate(p) }
            track.language = bcp47 ?? language
            return track.number > 0 ? track : nil
        }
    }

    static func parseCues(_ b: [UInt8]) -> [CuePoint] {
        children(b).compactMap { id, body in
            guard id == ID.cuePoint else { return nil }
            var point = CuePoint(time: 0, positions: [])
            for (cid, value) in children(Array(body)) {
                if cid == ID.cueTime { point.time = Int64(bitPattern: uint(value)) }
                if cid == ID.cueTrackPositions {
                    var pos = CuePosition(track: 0, cluster: 0, relative: nil)
                    for (pid, p) in children(Array(value)) {
                        switch pid {
                        case ID.cueTrack: pos.track = Int(uint(p))
                        case ID.cueClusterPosition: pos.cluster = Int64(bitPattern: uint(p))
                        case ID.cueRelativePosition: pos.relative = Int64(bitPattern: uint(p))
                        default: break
                        }
                    }
                    point.positions.append(pos)
                }
            }
            return point
        }
    }

    // MARK: EBML primitives

    /// An element ID, marker bits kept (as the spec writes IDs): (id, width).
    static func readID(_ b: [UInt8], _ i: Int) -> (UInt32, Int)? {
        guard i < b.count, b[i] != 0 else { return nil }
        let width = b[i].leadingZeroBitCount + 1
        guard width <= 4, i + width <= b.count else { return nil }
        var id: UInt32 = 0
        for byte in b[i..<(i + width)] { id = id << 8 | UInt32(byte) }
        return (id, width)
    }

    /// A data size: (nil for "unknown", width).
    static func readSize(_ b: [UInt8], _ i: Int) -> (Int64?, Int)? {
        guard let (value, width) = readVInt(b, i) else { return nil }
        let allOnes: UInt64 = (1 << (7 * UInt64(width))) - 1
        return (value == allOnes ? nil : Int64(value), width)
    }

    /// A variable-length integer with its length marker removed: (value, width).
    static func readVInt(_ b: [UInt8], _ i: Int) -> (UInt64, Int)? {
        guard i < b.count, b[i] != 0 else { return nil }
        let width = b[i].leadingZeroBitCount + 1
        guard i + width <= b.count else { return nil }
        var value = UInt64(b[i] & (0xFF >> width))
        for byte in b[(i + 1)..<(i + width)] { value = value << 8 | UInt64(byte) }
        return (value, width)
    }

    static func uint(_ b: ArraySlice<UInt8>) -> UInt64 {
        b.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func float(_ b: ArraySlice<UInt8>) -> Double? {
        switch b.count {
        case 4: Double(Float(bitPattern: UInt32(truncatingIfNeeded: uint(b))))
        case 8: Double(bitPattern: uint(b))
        default: nil
        }
    }

    static func string(_ b: ArraySlice<UInt8>) -> String {
        String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Bytes read from a source at an absolute offset, read further on demand.
struct Window {
    private(set) var start: Int64
    private(set) var data: [UInt8]
    var end: Int64 { start + Int64(data.count) }

    init(source: any ByteSource, start: Int64, count: Int64) async throws {
        self.start = start
        data = count > 0 ? [UInt8](try await source.read(start..<(start + count))) : []
    }

    func slice(_ range: Range<Int64>) -> ArraySlice<UInt8> {
        data[Int(range.lowerBound - start)..<Int(range.upperBound - start)]
    }

    struct Element { var id: UInt32; var dataStart: Int64; var size: Int64?; var end: Int64? { size.map { dataStart + $0 } } }

    /// The element header at `offset`, if it's in the window.
    func element(at offset: Int64) -> Element? {
        guard offset >= start, offset < end else { return nil }
        let i = Int(offset - start)
        guard let (id, w1) = MatroskaSubtitleReader.readID(data, i),
              let (size, w2) = MatroskaSubtitleReader.readSize(data, i + w1) else { return nil }
        return Element(id: id, dataStart: offset + Int64(w1 + w2), size: size)
    }

    /// The element header at `offset`, reading there first when it's outside the window.
    mutating func element(at offset: Int64, source: any ByteSource) async throws -> Element? {
        if offset < start || offset + 12 > end {
            self = try await Window(source: source, start: offset, count: MatroskaSubtitleReader.headChunk)
        }
        return element(at: offset)
    }

    /// The bytes in `range`, from the window or read.
    func bytes(_ range: Range<Int64>, source: any ByteSource) async throws -> [UInt8] {
        if range.lowerBound >= start, range.upperBound <= end { return Array(slice(range)) }
        return [UInt8](try await source.read(range))
    }
}
