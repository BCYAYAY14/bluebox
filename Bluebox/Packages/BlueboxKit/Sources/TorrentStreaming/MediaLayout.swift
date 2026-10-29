//
//  MediaLayout.swift
//  Bluebox
//
//  Reads just enough of a video file's first bytes to know what a player
//  will ask for before it can show a frame: where an MP4's index (moov) is,
//  and how long the film runs (so the prebuffer can be sized by bitrate).
//  Pure Swift so it's testable without libtorrent.
//

import Foundation

nonisolated public struct MediaLayout: Sendable, Equatable {
    public enum Container: Sendable, Equatable { case mp4, matroska, other }

    public var container: Container
    /// Running time read from the container header, when it's in the head.
    public var duration: TimeInterval?
    /// File-relative byte range the player reads before playing that isn't at
    /// the start: an MP4's moov after the media data, or the last bytes of
    /// other containers (MKV cues, AVI index). Nil when nothing is needed.
    public var tail: Range<Int64>?
    /// Bytes from the start the player reads before playing (an MP4 moov that
    /// precedes the media data); 0 when unknown.
    public var headIndexEnd: Int64 = 0

    /// Average bytes per second of media, when the duration is known.
    public func bitrate(fileLength: Int64) -> Double? {
        guard let duration, duration > 1 else { return nil }
        return Double(fileLength) / duration
    }

    /// Default guess before the head has arrived: the last `fallbackTail` bytes.
    public static func unknown(fileLength: Int64, fallbackTail: Int64 = 2 * 1024 * 1024) -> MediaLayout {
        MediaLayout(container: .other, duration: nil, tail: tailRange(fileLength: fileLength, bytes: fallbackTail))
    }

    static func tailRange(fileLength: Int64, bytes: Int64) -> Range<Int64>? {
        guard fileLength > 0, bytes > 0 else { return nil }
        return max(0, fileLength - bytes)..<fileLength
    }

    /// Reads the layout from the first bytes of the file (`head` starts at
    /// file offset 0; 64 KB to a few MB is plenty).
    public static func sniff(head: Data, fileLength: Int64, fileExtension: String) -> MediaLayout {
        let bytes = [UInt8](head)
        if bytes.count >= 8, String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp" {
            return sniffMP4(bytes, fileLength: fileLength)
        }
        if bytes.count >= 4, bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 {
            return MediaLayout(container: .matroska, duration: matroskaDuration(bytes),
                               tail: tailRange(fileLength: fileLength, bytes: 1024 * 1024))
        }
        _ = fileExtension
        return MediaLayout(container: .other, duration: nil, tail: tailRange(fileLength: fileLength, bytes: 1024 * 1024))
    }

    // MARK: MP4

    private static func sniffMP4(_ bytes: [UInt8], fileLength: Int64) -> MediaLayout {
        var offset: Int64 = 0
        var layout = MediaLayout(container: .mp4, duration: nil, tail: nil)
        while offset + 8 <= fileLength {
            guard let header = boxHeader(bytes, at: offset, fileLength: fileLength) else {
                // The next box header is past what we have: the player reads it
                // (usually the moov after mdat) before it can play.
                layout.tail = offset..<fileLength
                return layout
            }
            switch header.type {
            case "moov":
                // moov before the media data (faststart): nothing needed from the
                // end; any of it past `head` arrives with the head window.
                layout.duration = movieDuration(bytes, moovStart: offset, size: header.size)
                layout.headIndexEnd = min(fileLength, offset + header.size)
                return layout
            case "mdat":
                let next = offset + header.size
                guard next < fileLength else { return layout }  // mdat runs to the end; no moov after it
                offset = next
                continue
            default:
                guard header.size >= 8 else { return layout }
                offset += header.size
            }
        }
        return layout
    }

    private struct BoxHeader { let type: String; let size: Int64 }

    private static func boxHeader(_ bytes: [UInt8], at offset: Int64, fileLength: Int64) -> BoxHeader? {
        guard offset >= 0, offset + 8 <= Int64(bytes.count) else { return nil }
        let i = Int(offset)
        let size32 = be32(bytes, i)
        let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
        var size = Int64(size32)
        if size32 == 1 {
            guard i + 16 <= bytes.count else { return nil }
            size = Int64(bitPattern: be64(bytes, i + 8))
        } else if size32 == 0 {
            size = fileLength - offset
        }
        guard size >= 8 else { return BoxHeader(type: type, size: 0) }
        return BoxHeader(type: type, size: size)
    }

    /// Duration from the mvhd inside a moov that starts at `moovStart`.
    static func movieDuration(_ bytes: [UInt8], moovStart: Int64, size: Int64) -> TimeInterval? {
        var offset = moovStart + 8
        let end = min(moovStart + size, Int64(bytes.count))
        while offset + 8 <= end {
            let i = Int(offset)
            let boxSize = Int64(be32(bytes, i))
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            if type == "mvhd" {
                let v = i + 8
                guard v + 4 <= bytes.count else { return nil }
                let version = bytes[v]
                let timescale: UInt32
                let duration: UInt64
                if version == 1 {
                    guard v + 4 + 28 <= bytes.count else { return nil }
                    timescale = be32(bytes, v + 4 + 16)
                    duration = be64(bytes, v + 4 + 20)
                } else {
                    guard v + 4 + 16 <= bytes.count else { return nil }
                    timescale = be32(bytes, v + 4 + 8)
                    duration = UInt64(be32(bytes, v + 4 + 12))
                }
                guard timescale > 0, duration > 0, duration != UInt64(UInt32.max), duration != UInt64.max else { return nil }
                let seconds = Double(duration) / Double(timescale)
                return seconds.isFinite && seconds > 0 ? seconds : nil
            }
            guard boxSize >= 8 else { return nil }
            offset += boxSize
        }
        return nil
    }

    /// Duration from an MP4 moov found anywhere in `data` (e.g. a tail read).
    public static func movieDuration(searching data: Data) -> TimeInterval? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else { return nil }
        var i = 4
        while i + 4 <= bytes.count {
            if bytes[i] == 0x6D, bytes[i + 1] == 0x6F, bytes[i + 2] == 0x6F, bytes[i + 3] == 0x76 {  // "moov"
                let start = Int64(i - 4)
                let size = Int64(be32(bytes, i - 4))
                if size >= 8, let d = movieDuration(bytes, moovStart: start, size: size) { return d }
            }
            i += 1
        }
        return nil
    }

    // MARK: Matroska

    /// Segment Info's Duration (0x4489) scaled by TimecodeScale (0x2AD7B1), from
    /// the first 256 KB. Segment Info sits near the start of every muxer's output.
    static func matroskaDuration(_ bytes: [UInt8]) -> TimeInterval? {
        let limit = min(bytes.count, 256 * 1024)
        var scale: Double = 1_000_000
        var raw: Double?
        var i = 0
        while i + 3 < limit {
            if bytes[i] == 0x2A, bytes[i + 1] == 0xD7, bytes[i + 2] == 0xB1,
               let (length, width) = vint(bytes, i + 3), length > 0, length <= 8, i + 3 + width + length <= limit {
                var value: UInt64 = 0
                for b in bytes[(i + 3 + width)..<(i + 3 + width + length)] { value = value << 8 | UInt64(b) }
                if value > 0 { scale = Double(value) }
            } else if bytes[i] == 0x44, bytes[i + 1] == 0x89, raw == nil,
                      let (length, width) = vint(bytes, i + 2), length == 4 || length == 8,
                      i + 2 + width + length <= limit {
                let start = i + 2 + width
                if length == 4 {
                    raw = Double(Float(bitPattern: be32(bytes, start)))
                } else {
                    raw = Double(bitPattern: be64(bytes, start))
                }
            }
            i += 1
        }
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        let seconds = raw * scale / 1_000_000_000
        // Sanity: a few seconds to a day.
        return (1...86_400).contains(seconds) ? seconds : nil
    }

    /// EBML variable-length size: (value, bytes used).
    private static func vint(_ bytes: [UInt8], _ i: Int) -> (Int, Int)? {
        guard i < bytes.count else { return nil }
        let first = bytes[i]
        guard first != 0 else { return nil }
        let width = first.leadingZeroBitCount + 1
        guard width <= 8, i + width <= bytes.count else { return nil }
        var value = UInt64(first & (0xFF >> width))
        for b in bytes[(i + 1)..<(i + width)] { value = value << 8 | UInt64(b) }
        return value > UInt64(Int.max) ? nil : (Int(value), width)
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(be32(b, i)) << 32 | UInt64(be32(b, i + 4))
    }
}

/// How much of the start of a file to have before handing it to the player.
nonisolated public enum PrebufferPlan {
    /// Bytes from the start of the file to have on disk before playback.
    ///
    /// Enough that, at the current download speed, playback runs
    /// `stallFreeSeconds` before it would catch up with the download; never
    /// less than `minimum` (the player's first reads) nor more than `maximum`.
    /// Without a known bitrate it waits for the midpoint unless the download
    /// is plainly fast.
    public static func targetBytes(bitrate: Double?, downloadRate: Double, fileLength: Int64,
                                   minimum: Int64, maximum: Int64, stallFreeSeconds: Double) -> Int64 {
        let lower = min(max(0, minimum), fileLength)
        let upper = min(max(lower, maximum), fileLength)
        guard let bitrate, bitrate > 0 else {
            return downloadRate >= 2 * 1024 * 1024 ? lower : min(upper, max(lower, (lower + upper) / 2))
        }
        // A few seconds of video is the floor regardless of speed.
        let floor = max(lower, Int64(bitrate * 3))
        let deficit = bitrate - downloadRate
        guard deficit > 0 else { return min(upper, floor) }
        let needed = Int64(deficit * stallFreeSeconds)
        return min(upper, max(floor, needed))
    }
}

/// What's on disk of what the player reads first.
nonisolated struct StreamReadiness: Sendable {
    /// Bytes from the start of the file with no gaps.
    var contiguousHeadBytes: Int64
    /// Bytes needed from the end (MP4 moov, MKV cues), and how many are in.
    var tailBytes: Int64
    var tailHaveBytes: Int64
    /// The container was read from the head (the tail is final).
    var layoutKnown: Bool
    var layout: MediaLayout
    var fileLength: Int64
    var pieceLength: Int64
}
