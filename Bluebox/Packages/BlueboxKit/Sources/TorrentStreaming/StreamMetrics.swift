//
//  StreamMetrics.swift
//  Bluebox
//
//  Per-stream metrics as JSON Lines in Documents/diagnostics/metrics.jsonl,
//  read by Settings › Advanced › Torrent Diagnostics. Two kinds of line:
//
//  - Samples (no "event" key), every 2 s while a stream plays: state, rate,
//    upRate, peers, seeds, conns, candidates, doneMB, wantedMB, playheadMB,
//    dhtNodes, net, expensive, constrained, lowPower, upMB, downMB.
//  - Events ("event": …) with the stream's id and seconds since it started:
//    stream-start, metadata, ready, first-byte, first-frame, stall, seek,
//    recovery, network-change, stream-stop (with totals: stalls, stall
//    seconds, bytes up and down, time to metadata / first byte / first frame).
//
//  The file starts over at about 10 MB. Written for Bluebox.
//

import Foundation

final class StreamMetrics: @unchecked Sendable {
    static let shared = StreamMetrics()

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "diagnostics", directoryHint: .isDirectory)
    }

    static var fileURL: URL { directory.appending(path: "metrics.jsonl") }
    static let maxBytes: UInt64 = 10 * 1024 * 1024

    private let queue = DispatchQueue(label: "app.bluebox.torrent.metrics", qos: .utility)
    private let lock = NSLock()
    private var streamID: String?
    private var streamStarted: Date?
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Starts a stream's records; later events carry its id and elapsed time.
    func beginStream(_ id: String) {
        lock.withLock {
            streamID = id
            streamStarted = Date()
        }
    }

    func endStream() {
        lock.withLock {
            streamID = nil
            streamStarted = nil
        }
    }

    var isStreaming: Bool { lock.withLock { streamID != nil } }

    /// Seconds since the current stream began.
    var elapsed: Double {
        lock.withLock { streamStarted.map { Date().timeIntervalSince($0) } ?? 0 }
    }

    func event(_ name: String, _ fields: [String: Any] = [:]) {
        var row = fields
        row["event"] = name
        write(row)
    }

    func sample(_ fields: [String: Any]) {
        write(fields)
    }

    private func write(_ fields: [String: Any]) {
        var row = fields
        let (id, started) = lock.withLock { (streamID, streamStarted) }
        row["time"] = isoFormatter.string(from: Date())
        if let id { row["stream"] = id }
        if let started { row["t"] = (Date().timeIntervalSince(started) * 100).rounded() / 100 }
        guard JSONSerialization.isValidJSONObject(row),
              var encoded = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        encoded.append(0x0A)
        let line = encoded
        queue.async { Self.append(line) }
    }

    private static func append(_ line: Data) {
        let fm = FileManager.default
        let url = fileURL
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxBytes {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Waits for queued lines to reach the file (tests and shutdown).
    func flush() {
        queue.sync {}
    }
}
