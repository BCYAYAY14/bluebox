//
//  TorrentStream.swift
//  Bluebox
//
//  One file of a torrent being streamed: turns the server's byte reads into
//  piece requests. Pieces the player is about to need get deadlines
//  proportional to the film's bitrate (libtorrent fetches them first, from
//  the fastest peers); the rest downloads in order from the playhead. A seek
//  re-plans at once. A read that can't be served waits, nudges the swarm
//  (re-announce, extra trackers) when it stalls, and gives up with a clear
//  error rather than blocking the player forever. Written for Bluebox.
//

import Foundation

#if canImport(LibTorrentEngine)
import LibTorrentEngine

final class TorrentStream: StreamableFile, @unchecked Sendable {
    let handle: BBTorrentHandle
    let key: String
    let fileIndex: Int
    let fileName: String
    let span: FileSpan
    var length: Int64 { span.length }
    /// Path inside the torrent.
    let filePath: String
    /// Where the (partial) file is on disk now.
    var fileURL: URL { URL(fileURLWithPath: handle.savePath, isDirectory: true).appending(path: filePath) }

    /// Seconds of playback to keep requested ahead of each reader.
    static let readAheadSeconds: Double = 30
    /// How long one read waits for its piece before giving up.
    static let readTimeout: TimeInterval = 60
    /// After this long without the piece, the swarm is nudged.
    static let nudgeAfter: TimeInterval = 8

    private let lock = NSLock()
    private var waiters: [Int: [UUID: CheckedContinuation<Void, Error>]] = [:]
    private var readers: [UUID: Int64] = [:]
    private var readerPieces: [UUID: Int] = [:]
    private var bitrate: Double
    private var cache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private let cacheLimit: Int
    private var observer: UUID?
    private var lastNudge = Date.distantPast
    private var mainReaderPiece: Int?
    // Metrics
    private(set) var stalls = 0
    private(set) var stallSeconds: Double = 0
    private var servedAnything = false
    var onFirstByte: (@Sendable () -> Void)?
    /// Set once the stream has been handed to the player; waits after that count as stalls.
    var playing = false
    /// Subtitle files bundled with this video, and where each starts in the torrent.
    var subtitleFiles: [(entry: TorrentFileEntry, offset: Int64)] = []

    init(handle: BBTorrentHandle, file: TorrentFileEntry, offset: Int64) {
        self.handle = handle
        key = handle.infoHash
        fileIndex = file.index
        fileName = file.name
        filePath = file.path
        span = FileSpan(offset: offset, length: file.size, pieceLength: Int64(max(1, handle.pieceLength)),
                        pieceCount: handle.pieceCount)
        bitrate = ReadAheadPlan.bitrate(fileLength: file.size, duration: nil)
        #if os(iOS)
        cacheLimit = max(3 * Int(span.pieceLength), 24 * 1024 * 1024)
        #else
        cacheLimit = max(3 * Int(span.pieceLength), 64 * 1024 * 1024)
        #endif
        observer = handle.addPieceObserver { [weak self] piece in self?.pieceArrived(Int(piece)) }
    }

    deinit {
        if let observer { handle.removePieceObserver(observer) }
    }

    func setBitrate(_ value: Double) {
        lock.withLock { bitrate = max(50_000, value) }
    }

    var currentBitrate: Double { lock.withLock { bitrate } }

    // MARK: Pieces

    func have(_ piece: Int) -> Bool { handle.havePiece(piece) }

    /// A snapshot of which pieces are in, for counting many at once.
    func pieceSnapshot() -> (Int) -> Bool {
        let map = handle.pieceMap()
        return { piece in piece >= 0 && piece < map.count && map[piece] != 0 }
    }

    private func pieceArrived(_ piece: Int) {
        let resumed = lock.withLock { waiters.removeValue(forKey: piece) }
        resumed?.values.forEach { $0.resume() }
    }

    /// Waits until `piece` is downloaded and checked.
    func waitForPiece(_ piece: Int, timeout: TimeInterval) async throws {
        if have(piece) { return }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.cancelWait(piece, id, error: TorrentStreamError.stalled)
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if handle.havePiece(piece) {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[piece, default: [:]][id] = continuation
                lock.unlock()
            }
        } onCancel: { [weak self] in
            self?.cancelWait(piece, id, error: CancellationError())
        }
    }

    private func cancelWait(_ piece: Int, _ id: UUID, error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let c = waiters[piece]?.removeValue(forKey: id)
            if waiters[piece]?.isEmpty == true { waiters[piece] = nil }
            return c
        }
        continuation?.resume(throwing: error)
    }

    /// A downloaded piece's bytes, from the small cache or libtorrent.
    func pieceData(_ piece: Int) async throws -> Data {
        if let hit = lock.withLock({ cache[piece] }) { return hit }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            handle.readPiece(piece) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? TorrentStreamError.stalled) }
            }
        }
        lock.withLock {
            cache[piece] = data
            cacheOrder.removeAll { $0 == piece }
            cacheOrder.append(piece)
            var total = cache.values.reduce(0) { $0 + $1.count }
            while total > cacheLimit, cacheOrder.count > 1 {
                let oldest = cacheOrder.removeFirst()
                total -= cache.removeValue(forKey: oldest)?.count ?? 0
            }
        }
        return data
    }

    // MARK: StreamableFile

    func read(offset: Int64, maxLength: Int, reader: UUID) async throws -> Data {
        guard offset < length, maxLength > 0 else { return Data() }
        let piece = span.piece(at: offset)
        if !have(piece) {
            let began = Date()
            handle.setDeadlines([0], pieces: [NSNumber(value: piece)])
            var waited = false
            while !have(piece) {
                try Task.checkCancellation()
                let elapsed = Date().timeIntervalSince(began)
                guard elapsed < Self.readTimeout else {
                    StreamMetrics.shared.event("read-timeout", ["piece": piece, "offset": offset])
                    throw TorrentStreamError.stalled
                }
                do {
                    try await waitForPiece(piece, timeout: Self.nudgeAfter)
                } catch TorrentStreamError.stalled {
                    nudge(reason: "read waited \(Int(Date().timeIntervalSince(began)))s for piece \(piece)")
                }
                waited = true
            }
            let seconds = Date().timeIntervalSince(began)
            if waited, playing, seconds >= 1 {
                lock.withLock {
                    stalls += 1
                    stallSeconds += seconds
                }
                StreamMetrics.shared.event("stall", ["seconds": (seconds * 100).rounded() / 100, "piece": piece,
                                                     "offsetMB": Int(offset / 1_048_576)])
            }
        }
        let data = try await pieceData(piece)
        let pieceStartInTorrent = Int64(piece) * span.pieceLength
        let start = Int(span.offset + offset - pieceStartInTorrent)
        guard start >= 0, start < data.count else { throw TorrentStreamError.stalled }
        let count = min(maxLength, data.count - start, Int(length - offset))
        let first = lock.withLock { () -> Bool in
            defer { servedAnything = true }
            return !servedAnything
        }
        if first { onFirstByte?() }
        return data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + count))
    }

    func readerStarted(_ reader: UUID, at offset: Int64) {
        noteActivity()
        let piece = span.piece(at: offset)
        let isSeek = lock.withLock { () -> Bool in
            readers[reader] = offset
            readerPieces[reader] = piece
            // A read far from every other reader is a seek (or the index at the end).
            let others = readers.filter { $0.key != reader }.values
            return !others.contains { abs($0 - offset) < 8 * span.pieceLength }
        }
        if isSeek && !isTailRead(offset) {
            let rate = lock.withLock { () -> Double in
                mainReaderPiece = piece
                return bitrate
            }
            handle.clearDeadlines()
            handle.setSequential(from: piece, to: span.lastPiece)
            // Everything into the next few seconds after the seek point first.
            if !have(piece) {
                let window = span.pieces(covering: offset..<min(length, offset + max(span.pieceLength, Int64(rate * 4))))
                handle.focus(on: window.map { NSNumber(value: $0) })
                StreamMetrics.shared.event("seek", ["toMB": Int(offset / 1_048_576)])
            }
        }
        planDeadlines()
    }

    func readerAdvanced(_ reader: UUID, to offset: Int64) {
        let piece = span.piece(at: min(offset, max(0, length - 1)))
        let moved = lock.withLock { () -> Bool in
            readers[reader] = offset
            guard readerPieces[reader] != piece else { return false }
            readerPieces[reader] = piece
            return true
        }
        if moved { planDeadlines() }
    }

    func readerFinished(_ reader: UUID) {
        lock.withLock {
            lastActivity = Date()
            readers[reader] = nil
            readerPieces[reader] = nil
        }
    }

    /// Reads near the end are the container's index, not playback.
    func isTailRead(_ offset: Int64) -> Bool {
        offset > length - max(16 * 1024 * 1024, length / 50)
    }

    /// Where playback is: the furthest-back reader that isn't reading the index.
    var playhead: Int64? {
        lock.withLock {
            let positions = readers.values.filter { !isTailRead($0) }
            return positions.min()
        }
    }

    /// Deadlines for the next `readAheadSeconds` of every reader.
    func planDeadlines() {
        let (positions, rate) = lock.withLock { (Array(readers.values), bitrate) }
        guard !positions.isEmpty else { return }
        let have = pieceSnapshot()
        var best: [Int: Int] = [:]
        for position in positions {
            let tail = isTailRead(position)
            let plan = ReadAheadPlan.deadlines(span: span, position: position, bitrate: rate,
                                               seconds: tail ? 2 : Self.readAheadSeconds,
                                               minimumBytes: tail ? 0 : 4 * span.pieceLength,
                                               have: have)
            for (piece, ms) in plan { best[piece] = min(best[piece] ?? .max, ms) }
        }
        guard !best.isEmpty else { return }
        let sorted = best.sorted { $0.key < $1.key }
        handle.setDeadlines(sorted.map { NSNumber(value: $0.value) }, pieces: sorted.map { NSNumber(value: $0.key) })
    }

    /// Head and tail first: deadlines on the pieces a player reads before its
    /// first frame (the start, and the container's index at the end).
    func requestStart(headBytes: Int64, tail: Range<Int64>?) {
        let have = pieceSnapshot()
        var pieces: [Int] = []
        var deadlines: [Int] = []
        let head = span.pieces(covering: 0..<max(1, min(length, headBytes)))
        for (i, p) in head.enumerated() where !have(p) {
            pieces.append(p)
            deadlines.append(i * 40)
        }
        if let tail, !tail.isEmpty {
            for p in span.pieces(covering: tail) where !have(p) {
                pieces.append(p)
                deadlines.append(100)
            }
        }
        if !pieces.isEmpty {
            handle.setDeadlines(deadlines.map { NSNumber(value: $0) }, pieces: pieces.map { NSNumber(value: $0) })
            // The whole swarm works on these until they're in.
            handle.focus(on: pieces.map { NSNumber(value: $0) })
        }
        handle.setSequential(from: span.firstPiece, to: span.lastPiece)
    }

    /// Re-announces to trackers, the DHT and LSD, and adds fallback trackers;
    /// at most every 15 s.
    func nudge(reason: String) {
        let go = lock.withLock { () -> Bool in
            guard Date().timeIntervalSince(lastNudge) > 15 else { return false }
            lastNudge = Date()
            return true
        }
        guard go else { return }
        torrentLog.notice("stream: recovering (\(reason, privacy: .public)): re-announcing")
        StreamMetrics.shared.event("recovery", ["reason": reason])
        handle.addTrackers(DefaultTrackers.fallback)
        TorrentEngine.shared.allowOutgoingUTP(reason: reason)
        handle.reannounce()
        planDeadlines()
    }

    /// Fails every pending read (the stream is stopping).
    func cancelAll() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            defer { waiters = [:] }
            return waiters.values.flatMap(\.values)
        }
        all.forEach { $0.resume(throwing: CancellationError()) }
    }

    var stallTotals: (count: Int, seconds: Double) { lock.withLock { (stalls, stallSeconds) } }

    // MARK: Idle

    private var lastActivity = Date()
    private var pausedForIdle = false

    private func noteActivity() {
        let resume = lock.withLock { () -> Bool in
            lastActivity = Date()
            defer { pausedForIdle = false }
            return pausedForIdle
        }
        if resume {
            torrentLog.notice("stream: reader back; resuming the torrent")
            handle.resume()
        }
    }

    /// Pauses the torrent when no reader has been active for `seconds`
    /// (the player was left paused); the next read resumes it.
    func checkIdle(after seconds: TimeInterval) {
        let pause = lock.withLock { () -> Bool in
            guard readers.isEmpty, !pausedForIdle, Date().timeIntervalSince(lastActivity) > seconds else { return false }
            pausedForIdle = true
            return true
        }
        if pause {
            torrentLog.notice("stream: idle for \(Int(seconds))s; pausing the torrent")
            StreamMetrics.shared.event("idle-pause")
            handle.pause()
        }
    }
}
#endif
