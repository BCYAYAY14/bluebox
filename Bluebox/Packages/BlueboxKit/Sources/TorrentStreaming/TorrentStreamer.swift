//
//  TorrentStreamer.swift
//  Bluebox
//
//  The one entry point the app uses to stream a torrent: fetch the metadata
//  of a few candidate releases at once, pick the file (the add-on's index,
//  the episode from a pack, or the largest video), serve it from a localhost
//  HTTP server, and return its URL once the player's first reads are on
//  disk. Written for Bluebox.
//
//  Start time is spent in three places, and each is attacked:
//  - Finding peers: one warm libtorrent session for the whole app (DHT
//    table saved between launches), uTP on, fast connects, every tracker
//    announced at once, and several candidates raced in parallel.
//  - The player's first reads: the file's head and its index at the end
//    (MP4 moov, MKV cues) get piece deadlines the moment metadata arrives,
//    ahead of everything else.
//  - The prebuffer: sized from the film's bitrate (read from the container)
//    and the measured speed, not a fixed size; from then on the server keeps
//    deadlines about 30 s of playback ahead of the playhead.
//

import Foundation
#if canImport(LibTorrentEngine)
import LibTorrentEngine
#endif

public struct TorrentStreamSettings: Sendable, Equatable {
    public var maxPeers: Int
    /// Port of the localhost stream server (another is used if it's taken).
    public var port: UInt16
    public var extraTrackers: [URL]
    /// Streams kept on disk between plays; 0 deletes each one when it stops.
    public var cacheLimitBytes: Int64
    /// The least of the start of the file to have before playing.
    public var minimumPrebufferBytes: Int64
    /// The most to wait for, however slow the download.
    public var maximumPrebufferBytes: Int64
    /// Prebuffer enough that, at the current speed, playback runs this long
    /// before catching up with the download.
    public var stallFreeSeconds: Double
    /// Torrents whose metadata is fetched at the same time; the first to answer plays.
    public var raceWidth: Int
    /// How long to wait for any of them to answer.
    public var metadataTimeout: TimeInterval
    /// Upload limit in bytes per second for all torrents; nil is unlimited, 0 is none.
    public var uploadRateLimit: Int64?
    /// When false, nothing is uploaded while the network is expensive (cellular, hotspot).
    public var uploadOnExpensiveNetwork: Bool

    public init(maxPeers: Int = 80, port: UInt16 = 8888, extraTrackers: [URL] = [],
                cacheLimitBytes: Int64 = 5 * 1024 * 1024 * 1024,
                minimumPrebufferBytes: Int64 = 3 * 1024 * 1024,
                maximumPrebufferBytes: Int64 = 16 * 1024 * 1024,
                stallFreeSeconds: Double = 60,
                raceWidth: Int = 3,
                metadataTimeout: TimeInterval = 30,
                uploadRateLimit: Int64? = nil,
                uploadOnExpensiveNetwork: Bool = true) {
        self.maxPeers = maxPeers
        self.port = port
        self.extraTrackers = extraTrackers
        self.cacheLimitBytes = cacheLimitBytes
        self.minimumPrebufferBytes = minimumPrebufferBytes
        self.maximumPrebufferBytes = maximumPrebufferBytes
        self.stallFreeSeconds = stallFreeSeconds
        self.raceWidth = raceWidth
        self.metadataTimeout = metadataTimeout
        self.uploadRateLimit = uploadRateLimit
        self.uploadOnExpensiveNetwork = uploadOnExpensiveNetwork
    }
}

/// One torrent to try.
public struct TorrentCandidate: Sendable, Equatable {
    public var magnet: String
    public var fileIndex: Int?
    /// For season packs without a file index: the episode to play.
    public var episode: EpisodeNumber?

    public init(magnet: String, fileIndex: Int?, episode: EpisodeNumber? = nil) {
        self.magnet = magnet
        self.fileIndex = fileIndex
        self.episode = episode
    }
}

/// Prebuffer progress for the buffering overlay.
public struct TorrentBufferProgress: Sendable, Equatable {
    /// 0…1 of what's needed before playback starts.
    public var fraction: Double
    public var peers: Int
    public var bytesPerSecond: Double
    /// Bytes in of `targetBytes` (head plus the index at the end).
    public var bufferedBytes: Int64
    public var targetBytes: Int64
    /// Still fetching the file's index from its end (MP4 moov / MKV cues).
    public var waitingForIndex: Bool

    public init(fraction: Double, peers: Int, bytesPerSecond: Double, bufferedBytes: Int64 = 0,
                targetBytes: Int64 = 0, waitingForIndex: Bool = false) {
        self.fraction = fraction
        self.peers = peers
        self.bytesPerSecond = bytesPerSecond
        self.bufferedBytes = bufferedBytes
        self.targetBytes = targetBytes
        self.waitingForIndex = waitingForIndex
    }
}

/// What the player shows while a torrent gets ready.
public enum TorrentStreamStatus: Sendable, Equatable {
    /// Asking peers for the file list of `candidates` torrents at once.
    case findingPeers(peers: Int, candidates: Int)
    /// Candidate `chosen` answered; opening its file.
    case starting(chosen: Int)
    case buffering(TorrentBufferProgress)
}

public enum TorrentStreamError: LocalizedError, Sendable, Equatable {
    case unavailableOnThisPlatform
    case invalidMagnet
    case noPeers
    case noPlayableFile
    case stalled
    /// The disk is nearly full; `free` bytes are left.
    case insufficientSpace(free: Int64)

    /// Below this, a stream doesn't start: libtorrent would fail to write and
    /// playback would stall with no explanation.
    public static let minimumFreeBytes: Int64 = 500_000_000

    public var errorDescription: String? {
        switch self {
        case .unavailableOnThisPlatform:
            "Torrent streaming isn't available on this device yet. Use a debrid source instead."
        case .invalidMagnet: "That torrent link isn't valid."
        case .noPeers: "Nobody is sharing this release right now. Try another one."
        case .noPlayableFile: "This torrent doesn't contain a video file."
        case .stalled: "The download stopped before playback could start. Try another release."
        case .insufficientSpace(let free):
            "Only \(ByteCountFormatter.string(fromByteCount: max(free, 0), countStyle: .file)) is free, not enough to stream. "
                + "Delete some downloads, or lower the stream cache in Settings › Storage."
        }
    }

    /// Worth silently trying the next release.
    public var suggestsFallback: Bool { self == .noPeers || self == .stalled }
}

public actor TorrentStreamer {
    public static var isAvailable: Bool {
        #if canImport(LibTorrentEngine)
        true
        #else
        false
        #endif
    }

    /// Where per-stream metrics are written (JSON Lines), for Settings › Advanced.
    public static var metricsFileURL: URL { StreamMetrics.fileURL }

    /// Stops every torrent and destroys libtorrent's session. Call before the
    /// process exits (the app does this itself on terminate); blocks for up
    /// to about four seconds while trackers hear that we stopped.
    public static func shutdownEngine() {
        #if canImport(LibTorrentEngine)
        TorrentEngine.shared.shutdown(terminating: true)
        StreamMetrics.shared.flush()
        #endif
    }

    /// Writes resume data for every running torrent, blocking for at most
    /// `timeout` seconds. For when iOS is about to suspend the app.
    public static func saveResumeData(timeout: TimeInterval) {
        #if canImport(LibTorrentEngine)
        guard TorrentEngine.shared.isRunning else { return }
        TorrentEngine.shared.saveAllResumeData(timeout: timeout)
        #endif
    }

    /// Whether torrents may upload while the network is expensive (cellular,
    /// a hotspot). Off means nothing is uploaded there; Wi‑Fi is unaffected.
    public static func setUploadOnMobileData(_ allowed: Bool) {
        #if canImport(LibTorrentEngine)
        TorrentEngine.shared.setUploadOnExpensiveNetwork(allowed)
        #endif
    }

    /// Bytes the engine has moved since launch (all torrents, overhead included).
    public static func transferTotals() -> TorrentTransferTotals {
        #if canImport(LibTorrentEngine)
        TorrentEngine.shared.isRunning ? TorrentEngine.shared.transferTotals : TorrentTransferTotals()
        #else
        TorrentTransferTotals()
        #endif
    }

    /// Which bytes of the file behind a stream URL are downloaded, for the
    /// player's scrub bar. Nil when `url` isn't a stream that's playing.
    public static func downloadedRanges(for url: URL) -> TorrentFileRanges? {
        #if canImport(LibTorrentEngine)
        guard let stream = StreamServer.shared.file(for: url) as? TorrentStream else { return nil }
        return TorrentFileRanges(length: stream.length, ranges: stream.span.downloadedRanges(have: stream.pieceSnapshot()))
        #else
        nil
        #endif
    }

    private var settings: TorrentStreamSettings
    private let user = "stream:\(UUID().uuidString.prefix(8))"

    #if canImport(LibTorrentEngine)
    private var active: ActiveStream?

    private struct ActiveStream {
        var stream: TorrentStream
        var url: URL
        var started: Date
        var metadataAt: Double?
        var readyAt: Double?
        var sampler: Task<Void, Never>?
    }
    #endif

    public init(settings: TorrentStreamSettings) {
        self.settings = settings
        #if canImport(LibTorrentEngine)
        TorrentEngine.shared.update(EngineSettings(settings))
        #endif
    }

    /// Applies to the session now and to the next stream.
    public func update(settings: TorrentStreamSettings) {
        self.settings = settings
        #if canImport(LibTorrentEngine)
        TorrentEngine.shared.update(EngineSettings(settings))
        #endif
    }

    /// Starts streaming and returns a localhost URL once playback can begin.
    /// Calling again replaces the current stream.
    public func start(magnet: String, fileIndex: Int?,
                      status: @escaping @Sendable (TorrentStreamStatus) -> Void) async throws -> URL {
        try await start(candidates: [TorrentCandidate(magnet: magnet, fileIndex: fileIndex)], status: status).url
    }

    /// Fetches the candidates' metadata at the same time and streams the first
    /// that answers (preferring earlier ones that answer within a moment of it).
    /// Returns the URL and the index of the candidate that plays.
    public func start(candidates: [TorrentCandidate],
                      status: @escaping @Sendable (TorrentStreamStatus) -> Void) async throws -> (url: URL, chosen: Int) {
        #if canImport(LibTorrentEngine)
        var parsed: [Entry] = []
        var seen = Set<String>()
        for (i, candidate) in candidates.enumerated() {
            guard let magnet = MagnetLink(string: candidate.magnet), seen.insert(magnet.key).inserted else { continue }
            parsed.append(Entry(index: i, magnet: magnet, fileIndex: candidate.fileIndex, episode: candidate.episode))
        }
        guard !parsed.isEmpty else { throw TorrentStreamError.invalidMagnet }
        await stop()

        let settings = self.settings
        let keys = Set(parsed.map(\.magnet.key))
        if settings.cacheLimitBytes > 0 {
            StreamCache.prune(toBytes: settings.cacheLimitBytes, keeping: keys)
        }
        if let free = StreamCache.availableBytes(), free < TorrentStreamError.minimumFreeBytes {
            // Make room from older streams before giving up.
            StreamCache.prune(toBytes: 0, keeping: keys)
            if let after = StreamCache.availableBytes(), after < TorrentStreamError.minimumFreeBytes {
                throw TorrentStreamError.insufficientSpace(free: after)
            }
        }
        let metrics = StreamMetrics.shared
        metrics.beginStream(String(UUID().uuidString.prefix(8)).lowercased())
        metrics.event("stream-start", ["candidates": parsed.count, "keys": parsed.map(\.magnet.key)])
        let began = Date()
        status(.findingPeers(peers: 0, candidates: parsed.count))

        let port = try await StreamServer.shared.start(preferredPort: settings.port)
        _ = port
        let (winner, stream) = try await race(parsed, settings: settings, status: status)
        let metadataAt = Date().timeIntervalSince(began)
        metrics.event("metadata", ["seconds": Self.round(metadataAt), "candidate": winner, "file": stream.fileName,
                                   "sizeMB": Int(stream.length / 1_048_576), "pieceKB": Int(stream.span.pieceLength / 1024)])
        torrentLog.notice("stream: metadata after \(Self.round(metadataAt))s (candidate \(winner)): \(stream.fileName, privacy: .public)")

        stream.onFirstByte = {
            metrics.event("first-byte", ["seconds": Self.round(Date().timeIntervalSince(began))])
        }
        let url = StreamServer.shared.register(stream)
        // From here a cancel (or failure) goes through stop(), which releases the torrent.
        active = ActiveStream(stream: stream, url: url, started: began, metadataAt: metadataAt)
        StreamAvailability.register(token: url.lastPathComponent, stream: StreamAvailability.Stream(
            fileURL: stream.fileURL, fileLength: stream.length,
            check: { [weak stream] range in
                guard let stream else { return false }
                return stream.span.haveBytes(in: range, have: stream.pieceSnapshot()) >= Int64(range.count)
            }))
        do {
            try Task.checkCancellation()
            status(.starting(chosen: winner))
            try await prebuffer(stream, settings: settings, status: status)
            try Task.checkCancellation()
        } catch {
            await stop()
            throw error
        }
        let readyAt = Date().timeIntervalSince(began)
        active?.readyAt = readyAt
        stream.playing = true
        metrics.event("ready", ["seconds": Self.round(readyAt)])
        torrentLog.notice("stream: ready after \(Self.round(readyAt))s")
        active?.sampler = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.sampleLoop()
        }
        return (url, winner)
        #else
        throw TorrentStreamError.unavailableOnThisPlatform
        #endif
    }

    /// The player showed the stream's first frame: records the time to first
    /// frame in the diagnostics (players call this; it needs no streamer).
    public static func noteFirstFrame() {
        let metrics = StreamMetrics.shared
        guard metrics.isStreaming else { return }
        metrics.event("first-frame", ["seconds": Self.round(metrics.elapsed)])
    }

    /// The player waited for data mid-playback (a stall it saw), for the diagnostics.
    public static func notePlayerStall(seconds: Double) {
        let metrics = StreamMetrics.shared
        guard metrics.isStreaming else { return }
        metrics.event("player-stall", ["seconds": Self.round(seconds)])
    }

    /// Stops the current stream, keeping or deleting its files per the cache
    /// limit. Resume data for a kept stream is always saved before this
    /// returns; `waitForTeardown` is accepted for callers that quit right after.
    public func stop(waitForTeardown: Bool = false) async {
        #if canImport(LibTorrentEngine)
        guard let current = active else { return }
        active = nil
        current.sampler?.cancel()
        let stream = current.stream
        StreamAvailability.unregister(token: current.url.lastPathComponent)
        StreamServer.shared.unregister(current.url)
        stream.cancelAll()
        let keep = settings.cacheLimitBytes > 0
        if keep { await TorrentEngine.shared.saveResumeData(stream.handle) }
        let status = stream.handle.status()
        let (stalls, stallSeconds) = stream.stallTotals
        StreamMetrics.shared.event("stream-stop", [
            "seconds": Self.round(Date().timeIntervalSince(current.started)),
            "metadataSeconds": Self.round(current.metadataAt ?? -1),
            "readySeconds": Self.round(current.readyAt ?? -1),
            "stalls": stalls, "stallSeconds": Self.round(stallSeconds),
            "downMB": Int(status.downloadedBytes / 1_048_576), "upMB": Int(status.uploadedBytes / 1_048_576),
            "hashFails": status.hashFailures,
        ])
        StreamMetrics.shared.endStream()
        let removed = TorrentEngine.shared.release(stream.handle, user: user, deleteFiles: !keep)
        if keep {
            StreamCache.touch(stream.key)
        } else if removed {
            // libtorrent deletes the files; the folder (resume data, marker) goes too.
            try? FileManager.default.removeItem(at: StreamCache.folder(for: stream.key))
        }
        #endif
    }

    public func stats() async -> SwarmStats {
        #if canImport(LibTorrentEngine)
        guard let stream = active?.stream else { return SwarmStats() }
        return Self.stats(stream)
        #else
        SwarmStats()
        #endif
    }

    private static func round(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    #if canImport(LibTorrentEngine)
    private struct Entry {
        var index: Int
        var magnet: MagnetLink
        var fileIndex: Int?
        var episode: EpisodeNumber?
    }

    private static func stats(_ stream: TorrentStream) -> SwarmStats {
        let s = stream.handle.status()
        let progress = stream.handle.fileProgress()
        let done = progress.indices.contains(stream.fileIndex) ? progress[stream.fileIndex].int64Value : 0
        return SwarmStats(connectedPeers: s.peers, seeds: s.seeds, knownPeers: s.knownPeers,
                          downloadRate: Double(s.downloadRate), uploadRate: Double(s.uploadRate),
                          downloadedBytes: s.downloadedBytes, uploadedBytes: s.uploadedBytes,
                          fileProgress: stream.length > 0 ? Double(done) / Double(stream.length) : 0)
    }

    /// The streamed file's priority: high, but below libtorrent's top (7),
    /// whose pieces are fetched in availability order rather than in sequence.
    static let streamPriority = 6

    /// How long a better-ranked candidate gets to catch up once a worse one has answered.
    private static let raceGrace: TimeInterval = 1.0

    /// Adds every candidate, waits for metadata, keeps the winner's chosen
    /// file and releases the rest.
    private func race(_ entries: [Entry], settings: TorrentStreamSettings,
                      status: @Sendable (TorrentStreamStatus) -> Void) async throws -> (Int, TorrentStream) {
        let engine = TorrentEngine.shared
        let extra = settings.extraTrackers.map(\.absoluteString)
        var running: [(entry: Entry, handle: BBTorrentHandle)] = []
        func release(_ handle: BBTorrentHandle) {
            let key = handle.infoHash
            // Kept, not deleted: it may be a cached stream (the cache's LRU trims the rest).
            if engine.release(handle, user: user, deleteFiles: false) {
                // Nothing of it was downloaded; drop the empty folder unless it holds a cached stream.
                let folder = StreamCache.folder(for: key)
                if StreamCache.allocatedSize(folder) == 0 { try? FileManager.default.removeItem(at: folder) }
            }
        }
        for entry in entries {
            do {
                // When the add-on named the file, ask for it now: peers see we're
                // interested the moment metadata arrives.
                let handle = try engine.acquire(entry.magnet, user: user,
                                                savePath: StreamCache.folder(for: entry.magnet.key),
                                                extraTrackers: extra,
                                                priorities: entry.fileIndex.map { [$0: Self.streamPriority] })
                running.append((entry, handle))
            } catch {
                torrentLog.notice("stream: couldn't add candidate \(entry.index): \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !running.isEmpty else { throw TorrentStreamError.invalidMagnet }

        do {
            let began = Date()
            var firstAnswer: Date?
            var lastNudge = Date()
            while true {
                try Task.checkCancellation()
                if let best = running.first(where: { $0.handle.hasMetadata }) {
                    firstAnswer = firstAnswer ?? Date()
                    let isTop = best.entry.index == running.first?.entry.index
                    if isTop || Date().timeIntervalSince(firstAnswer!) >= Self.raceGrace {
                        guard let stream = open(best.handle, entry: best.entry, settings: settings) else {
                            release(best.handle)
                            running.removeAll { $0.handle === best.handle }
                            if running.isEmpty { throw TorrentStreamError.noPlayableFile }
                            continue
                        }
                        for other in running where other.handle !== best.handle { release(other.handle) }
                        return (best.entry.index, stream)
                    }
                }
                let peers = running.reduce(0) { $0 + $1.handle.status().peers }
                status(.findingPeers(peers: peers, candidates: running.count))
                if peers < 2, Date().timeIntervalSince(began) > 4 {
                    engine.allowOutgoingUTP(reason: "\(peers) peers after 4 s")
                }
                if Date().timeIntervalSince(began) > settings.metadataTimeout { throw TorrentStreamError.noPeers }
                if Date().timeIntervalSince(lastNudge) >= 10 {
                    running.forEach { $0.handle.reannounce() }
                    lastNudge = Date()
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            for entry in running { release(entry.handle) }
            throw error
        }
    }

    /// Picks the file, asks for it alone, and starts the head and tail.
    private func open(_ handle: BBTorrentHandle, entry: Entry, settings: TorrentStreamSettings) -> TorrentStream? {
        let files = handle.files.map {
            TorrentFileEntry(index: $0.index, path: $0.path, size: $0.size, isPadding: $0.isPadding)
        }
        let preferred = entry.fileIndex ?? entry.magnet.selectedFiles.flatMap { $0.count == 1 ? $0.first : nil }
        guard let file = FileSelection.choose(files, preferred: preferred, episode: entry.episode),
              let offset = handle.files.first(where: { $0.index == file.index })?.offset else { return nil }
        handle.setFilePriorities([NSNumber(value: file.index): NSNumber(value: Self.streamPriority)], user: user)
        let stream = TorrentStream(handle: handle, file: file, offset: offset)
        let head = max(settings.minimumPrebufferBytes, stream.span.pieceLength)
        stream.requestStart(headBytes: head, tail: MediaLayout.unknown(fileLength: file.size, fallbackTail: 1024 * 1024).tail)
        StreamCache.touch(handle.infoHash)
        return stream
    }

    /// Waits until the player's first reads are on disk: the head, sized from
    /// bitrate and speed, plus the container's index at the end. A dead swarm
    /// gives up instead of spinning forever.
    private func prebuffer(_ stream: TorrentStream, settings: TorrentStreamSettings,
                           status: @Sendable (TorrentStreamStatus) -> Void) async throws {
        let length = stream.length
        let pieceLength = stream.span.pieceLength
        let fileExtension = (stream.fileName as NSString).pathExtension
        var layout = MediaLayout.unknown(fileLength: length, fallbackTail: 1024 * 1024)
        var layoutKnown = false
        var durationFromTail = false
        let started = Date()
        var lastBytes: Int64 = 0
        var lastProgress = Date()
        var lastSample = Date.distantPast

        while true {
            try Task.checkCancellation()
            let have = stream.pieceSnapshot()
            // Read the container header as soon as its first piece is in.
            let contiguous = stream.span.contiguousBytes(from: 0, have: have)
            if !layoutKnown, contiguous >= min(length, 256 * 1024) {
                let headLength = Int(min(length, 1024 * 1024, contiguous))
                if let head = try? await readBytes(stream, from: 0, count: headLength, have: have) {
                    layout = MediaLayout.sniff(head: head, fileLength: length, fileExtension: fileExtension)
                    layoutKnown = true
                    if let duration = layout.duration {
                        stream.setBitrate(ReadAheadPlan.bitrate(fileLength: length, duration: duration))
                    }
                    let headBytes = max(settings.minimumPrebufferBytes, layout.headIndexEnd, pieceLength)
                    stream.requestStart(headBytes: headBytes, tail: layout.tail)
                }
            }
            // An MP4 index at the end gives the running time once it's in.
            if layoutKnown, layout.duration == nil, !durationFromTail, layout.container == .mp4, let tail = layout.tail,
               stream.span.haveBytes(in: tail, have: have) >= Int64(tail.count) {
                durationFromTail = true
                if let data = try? await readBytes(stream, from: tail.lowerBound, count: Int(min(Int64(tail.count), 64 * 1024 * 1024)), have: have),
                   let duration = MediaLayout.movieDuration(searching: data) {
                    layout.duration = duration
                    stream.setBitrate(ReadAheadPlan.bitrate(fileLength: length, duration: duration))
                }
            }

            let s = stream.handle.status()
            let floor = max(settings.minimumPrebufferBytes, layout.headIndexEnd, pieceLength)
            let target = PrebufferPlan.targetBytes(
                bitrate: layout.bitrate(fileLength: length), downloadRate: Double(s.downloadRate),
                fileLength: length, minimum: floor, maximum: max(floor, settings.maximumPrebufferBytes),
                stallFreeSeconds: settings.stallFreeSeconds)
            let head = min(stream.span.contiguousBytes(from: 0, have: have), target)
            let tailBytes = Int64(layout.tail?.count ?? 0)
            let tailHave = layout.tail.map { stream.span.haveBytes(in: $0, have: have) } ?? 0
            let tailDone = tailHave >= tailBytes
            let wanted = target + tailBytes
            let haveTotal = head + tailHave
            status(.buffering(TorrentBufferProgress(
                fraction: wanted > 0 ? min(1, Double(haveTotal) / Double(wanted)) : 0,
                peers: s.peers, bytesPerSecond: Double(s.downloadRate),
                bufferedBytes: haveTotal, targetBytes: wanted, waitingForIndex: head >= target && !tailDone)))
            if layoutKnown && head >= target && tailDone { return }
            if Date().timeIntervalSince(lastSample) >= 1 {
                lastSample = Date()
                StreamMetrics.shared.sample([
                    "phase": "prebuffer", "rate": s.downloadRate, "peers": s.peers, "seeds": s.seeds,
                    "headKB": Int(head / 1024), "targetKB": Int(target / 1024), "tailKB": Int(tailHave / 1024),
                    "tailWantKB": Int(tailBytes / 1024), "downMB": Int(s.downloadedBytes / 1_048_576),
                    "hashFails": s.hashFailures, "layout": layoutKnown,
                ])
            }

            if s.downloadedBytes > lastBytes {
                lastBytes = s.downloadedBytes
                lastProgress = Date()
            }
            let elapsed = Date().timeIntervalSince(started)
            let idle = Date().timeIntervalSince(lastProgress)
            if let error = s.errorMessage {
                torrentLog.error("stream: torrent error: \(error, privacy: .public)")
                StreamMetrics.shared.event("error", ["message": error])
                throw TorrentStreamError.stalled
            }
            if idle > 8 { stream.nudge(reason: "prebuffer idle \(Int(idle))s, \(s.peers) peers") }
            if lastBytes == 0 {
                if elapsed > 30 && s.peers == 0 { throw TorrentStreamError.noPeers }
                if elapsed > 45 { throw TorrentStreamError.stalled }
            } else if idle > 45 {
                throw TorrentStreamError.stalled
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Bytes from the file once their pieces are in.
    private func readBytes(_ stream: TorrentStream, from offset: Int64, count: Int, have: (Int) -> Bool) async throws -> Data {
        var out = Data()
        var position = offset
        let end = min(stream.length, offset + Int64(count))
        let reader = UUID()
        while position < end {
            guard have(stream.span.piece(at: position)) else { break }
            let chunk = try await stream.read(offset: position, maxLength: Int(end - position), reader: reader)
            guard !chunk.isEmpty else { break }
            out.append(chunk)
            position += Int64(chunk.count)
        }
        return out
    }

    /// Writes a metrics sample every 2 s while the stream plays, and pauses
    /// the torrent after ten minutes with no reader (resumed on the next read).
    private func sampleLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard let current = active, !Task.isCancelled else { return }
            let stream = current.stream
            let s = stream.handle.status()
            let stats = Self.stats(stream)
            let net = TorrentEngine.shared.currentNetwork
            let session = TorrentEngine.shared.session?.stats()
            let state = switch s.state {
            case .checkingFiles, .checkingResumeData: "checking"
            case .downloadingMetadata: "metadata"
            case .downloading: s.isPaused ? "paused" : "downloading"
            case .finished, .seeding: "complete"
            @unknown default: "unknown"
            }
            let playhead = stream.playhead
            StreamMetrics.shared.sample([
                "state": state, "rate": s.downloadRate, "upRate": s.uploadRate,
                "peers": s.peers, "seeds": s.seeds, "conns": s.peers, "candidates": s.connectCandidates,
                "doneMB": Int(Double(stream.length) * stats.fileProgress / 1_048_576),
                "wantedMB": Int(stream.length / 1_048_576),
                "playheadMB": playhead.map { Int($0 / 1_048_576) } ?? -1,
                "dhtNodes": session?.dhtNodes ?? 0,
                "net": net.kind, "expensive": net.isExpensive, "constrained": net.isConstrained,
                "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "downMB": Int(s.downloadedBytes / 1_048_576), "upMB": Int(s.uploadedBytes / 1_048_576),
                "bitrateKB": Int(stream.currentBitrate / 1024),
            ])
            stream.checkIdle(after: 600)
        }
    }
    #endif
}
