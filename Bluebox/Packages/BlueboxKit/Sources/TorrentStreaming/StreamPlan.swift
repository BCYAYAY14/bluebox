//
//  StreamPlan.swift
//  Bluebox
//
//  Piece arithmetic for streaming one file of a torrent, and the schedule of
//  piece deadlines around the playhead. Pure, so it's unit-tested without
//  libtorrent. Written for Bluebox.
//

import Foundation

/// Where one file sits in its torrent's pieces.
struct FileSpan: Sendable, Equatable {
    /// Byte offset of the file within the torrent.
    var offset: Int64
    var length: Int64
    var pieceLength: Int64
    var pieceCount: Int

    /// The piece holding file byte `position`.
    func piece(at position: Int64) -> Int {
        let p = Int((offset + max(0, min(position, max(0, length - 1)))) / max(1, pieceLength))
        return min(max(0, p), max(0, pieceCount - 1))
    }

    var firstPiece: Int { piece(at: 0) }
    var lastPiece: Int { piece(at: max(0, length - 1)) }

    /// Pieces holding file bytes `range` (empty ranges give the piece at the start).
    func pieces(covering range: Range<Int64>) -> ClosedRange<Int> {
        let a = piece(at: range.lowerBound)
        let b = piece(at: max(range.lowerBound, range.upperBound - 1))
        return a...max(a, b)
    }

    /// The file bytes that piece `index` holds (clipped to the file).
    func fileRange(ofPiece index: Int) -> Range<Int64> {
        let start = Int64(index) * pieceLength - offset
        let end = start + pieceLength
        return max(0, start)..<min(length, max(0, end))
    }

    /// Bytes from `position` that are downloaded with no gap, given the pieces we have.
    func contiguousBytes(from position: Int64, have: (Int) -> Bool) -> Int64 {
        guard position < length else { return 0 }
        var piece = self.piece(at: position)
        var end = position
        while piece <= lastPiece, have(piece) {
            end = fileRange(ofPiece: piece).upperBound
            piece += 1
        }
        return max(0, end - position)
    }

    /// Bytes of `range` that are downloaded.
    func haveBytes(in range: Range<Int64>, have: (Int) -> Bool) -> Int64 {
        guard !range.isEmpty else { return 0 }
        var total: Int64 = 0
        for p in pieces(covering: range) where have(p) {
            let r = fileRange(ofPiece: p).clamped(to: range)
            total += r.upperBound - r.lowerBound
        }
        return total
    }

    /// Downloaded parts of the file, merged into ranges.
    func downloadedRanges(have: (Int) -> Bool) -> [Range<Int64>] {
        guard length > 0 else { return [] }
        var ranges: [Range<Int64>] = []
        for p in firstPiece...lastPiece where have(p) {
            let r = fileRange(ofPiece: p)
            if let last = ranges.last, last.upperBound >= r.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                ranges.append(r)
            }
        }
        return ranges
    }
}

/// Deadlines for the pieces the player needs soon.
enum ReadAheadPlan {
    /// The film's average bytes per second: from its running time when the
    /// container gave one, else a guess from its size (an episode or a film).
    static func bitrate(fileLength: Int64, duration: TimeInterval?) -> Double {
        if let duration, duration > 60 { return max(50_000, Double(fileLength) / duration) }
        let guess: TimeInterval = fileLength < 900 * 1024 * 1024 ? 45 * 60 : 110 * 60
        return max(50_000, Double(fileLength) / guess)
    }

    /// Pieces to request ahead of a reader at `position`, each with a
    /// deadline in milliseconds: when playback would reach it, less a margin.
    /// The window covers `seconds` of playback (at least `minimumBytes`).
    static func deadlines(span: FileSpan, position: Int64, bitrate: Double, seconds: Double,
                          minimumBytes: Int64 = 0, maxPieces: Int = 96,
                          have: (Int) -> Bool) -> [(piece: Int, milliseconds: Int)] {
        guard span.length > 0, position < span.length else { return [] }
        let window = max(minimumBytes, Int64(bitrate * seconds), span.pieceLength)
        let end = min(span.length, position + window)
        let pieces = span.pieces(covering: position..<end)
        var out: [(Int, Int)] = []
        for piece in pieces where !have(piece) {
            let start = max(position, span.fileRange(ofPiece: piece).lowerBound)
            let secondsAway = Double(start - position) / max(1, bitrate)
            // Ask for it by half the time the player takes to get there; the
            // first pieces are wanted now.
            let ms = Int(secondsAway * 500)
            out.append((piece, max(0, ms)))
            if out.count >= maxPieces { break }
        }
        return out
    }
}
