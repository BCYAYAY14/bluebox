import Foundation

/// What the UI shows for one torrent.
public struct TorrentStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case fetchingMetadata
        case downloading
        case complete
        case paused
        case failed(String)
    }
    public var phase: Phase
    public var name: String
    /// Bytes of the wanted files already verified.
    public var haveBytes: Int64
    public var wantedBytes: Int64
    public var peers: Int
    public var bytesPerSecond: Double

    public var fraction: Double { wantedBytes > 0 ? min(Double(haveBytes) / Double(wantedBytes), 1) : 0 }
}

/// Downloads one torrent. Pieces are fetched in order starting from where the
/// player is reading, so playback can start before the download finishes.
/// Every piece is checked against its SHA-1 before it's stored or served.
public actor TorrentSession {
    public nonisolated let infoHash: InfoHash
    private(set) var descriptor: TorrentDescriptor
    let directory: URL
    let peerID: Data
    let fetch: Tracker.Fetch
    /// Called (off the actor) when the info dictionary becomes known.
    let onMetadata: @Sendable (TorrentDescriptor) -> Void

    private(set) var info: TorrentInfo?
    private var storage: PieceStorage?
    private var wanted = Bitfield(count: 0)
    private var inFlight: [Int: Int] = [:]
    private var focus = 0
    private var scanHint = 0
    private var waiters: [Int: [UUID: CheckedContinuation<Void, Error>]] = [:]
    private var infoWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    private var metadataSize: Int?
    private var metadataPieces: [Int: Data] = [:]

    private var known: Set<PeerAddress> = []
    private var connected: Set<PeerAddress> = []
    private var failures: [PeerAddress: Int] = [:]
    private var bannedPeers: Set<PeerAddress> = []
    private var workers: [PeerAddress: Task<Void, Never>] = [:]
    private var background: [Task<Void, Never>] = []
    private var running = false
    private var lastError: String?

    private var downloadedBytes: Int64 = 0
    private var rateSamples: [(Date, Int)] = []

    static let maxPeers = 30
    static let pipeline = 24
    /// Bytes ahead of the read position fetched before anything else.
    static let readAhead: Int64 = 24 * 1024 * 1024
    static let streamableExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts", "mp3", "m4a", "ogg", "ogv"]
    static let sidecarExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    init(descriptor: TorrentDescriptor, directory: URL, peerID: Data, fetch: @escaping Tracker.Fetch,
         onMetadata: @escaping @Sendable (TorrentDescriptor) -> Void) {
        infoHash = descriptor.infoHash
        self.descriptor = descriptor; self.directory = directory; self.peerID = peerID
        self.fetch = fetch; self.onMetadata = onMetadata
        if let raw = descriptor.infoData, let i = try? TorrentInfo(raw: raw) { info = i }
    }

    // MARK: Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        lastError = nil
        if let info, storage == nil { try? prepareStorage(info) }
        // Nothing to fetch: don't claim to be running, or a later start() (after
        // more of the torrent becomes wanted) would be a no-op.
        if isComplete { running = false; return }
        guard !descriptor.trackers.isEmpty || !descriptor.webSeeds.isEmpty else {
            lastError = TorrentError.noTrackers.localizedDescription
            running = false
            return
        }
        for tracker in descriptor.trackers {
            background.append(Task { [weak self] in await self?.announceLoop(tracker) })
        }
        for seed in descriptor.webSeeds {
            background.append(Task { [weak self] in await self?.webSeedLoop(seed) })
        }
        background.append(Task { [weak self] in await self?.connectLoop() })
    }

    public func stop() {
        running = false
        background.forEach { $0.cancel() }; background = []
        workers.values.forEach { $0.cancel() }; workers = [:]
        connected = []
        inFlight = [:]
        storage?.saveState()
    }

    public func status() -> TorrentStatus {
        let name = info?.name ?? descriptor.displayName ?? infoHash.hex
        var have: Int64 = 0, want: Int64 = 0
        if let info, let storage {
            for i in 0..<info.pieceCount where wanted[i] {
                let len = Int64(info.length(ofPiece: i))
                want += len
                if storage.have[i] { have += len }
            }
        }
        let phase: TorrentStatus.Phase
        if let lastError { phase = .failed(lastError) }
        else if info == nil { phase = running ? .fetchingMetadata : .paused }
        else if isComplete { phase = .complete }
        else { phase = running ? .downloading : .paused }
        let cutoff = Date().addingTimeInterval(-5)
        let recent = rateSamples.filter { $0.0 > cutoff }.reduce(0) { $0 + $1.1 }
        return TorrentStatus(phase: phase, name: name, haveBytes: have, wantedBytes: want,
                             peers: connected.count, bytesPerSecond: Double(recent) / 5)
    }

    var isComplete: Bool {
        guard let info, let storage else { return false }
        return (0..<info.pieceCount).allSatisfy { !wanted[$0] || storage.have[$0] }
    }

    // MARK: Streaming reads

    /// The file list, waiting for it to arrive from peers if necessary.
    public func waitForInfo(timeout: TimeInterval = 60) async throws -> TorrentInfo {
        if let info { return info }
        start()
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.failInfoWaiter(id, TorrentError.metadataUnavailable)
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if info != nil { c.resume() } else { infoWaiters[id] = c }
            }
        } onCancel: {
            Task { await self.failInfoWaiter(id, CancellationError()) }
        }
        guard let info else { throw TorrentError.metadataUnavailable }
        return info
    }

    private func failInfoWaiter(_ id: UUID, _ error: Error) {
        infoWaiters.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Reads bytes of one file, waiting for (and prioritizing) the pieces they need.
    public func read(file index: Int, offset: Int64, length: Int) async throws -> Data {
        let info = try await waitForInfo()
        guard info.files.indices.contains(index) else { throw TorrentError.storage("no such file") }
        let f = info.files[index]
        let n = Int(min(Int64(length), f.length - offset))
        guard offset >= 0, n > 0 else { return Data() }
        let begin = f.offset + offset
        guard let range = info.pieces(covering: begin, length: Int64(n)) else { return Data() }
        want(file: index)  // before start(), so a finished session sees there's more to fetch
        start()
        setFocus(range.lowerBound)
        for p in range { try await waitForPiece(p) }
        guard let storage else { throw TorrentError.storage("not ready") }
        do { return try storage.read(offset: begin, length: n) }
        catch { throw TorrentError.storage(error.localizedDescription) }
    }

    public func fileLength(_ index: Int) async throws -> Int64 {
        let info = try await waitForInfo()
        guard info.files.indices.contains(index) else { throw TorrentError.storage("no such file") }
        return info.files[index].length
    }

    /// Local URL of a file once every piece of it is downloaded, else nil.
    public func completedFileURL(_ index: Int) -> URL? {
        guard let info, let storage, info.files.indices.contains(index) else { return nil }
        let f = info.files[index]
        guard let r = info.pieces(covering: f.offset, length: f.length) else { return storage.url(ofFile: index) }
        return r.allSatisfy { storage.have[$0] } ? storage.url(ofFile: index) : nil
    }

    private func setFocus(_ piece: Int) {
        if piece != focus { focus = piece; scanHint = piece }
    }

    private func want(file index: Int) {
        guard let info, let r = info.pieces(covering: info.files[index].offset, length: info.files[index].length) else { return }
        for p in r { wanted[p] = true }
    }

    private func waitForPiece(_ p: Int) async throws {
        if storage?.have[p] == true { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if storage?.have[p] == true { c.resume() } else { waiters[p, default: [:]][id] = c }
            }
        } onCancel: {
            Task { await self.cancelWaiter(p, id) }
        }
    }

    private func cancelWaiter(_ p: Int, _ id: UUID) {
        waiters[p]?.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    // MARK: Metadata

    private func prepareStorage(_ info: TorrentInfo) throws {
        storage = try PieceStorage(root: directory, info: info)
        wanted = Bitfield(count: info.pieceCount)
        let media = info.files.indices.filter {
            let ext = (info.files[$0].name as NSString).pathExtension.lowercased()
            return Self.streamableExtensions.contains(ext) || Self.sidecarExtensions.contains(ext)
        }
        if media.isEmpty { for i in 0..<info.pieceCount { wanted[i] = true } }
        else { media.forEach(want(file:)) }
    }

    fileprivate func noteMetadataSize(_ size: Int) {
        guard info == nil, metadataSize == nil, size > 0, size <= 16 * 1024 * 1024 else { return }
        metadataSize = size
    }

    /// A metadata piece this peer should fetch next, if any.
    fileprivate func nextMetadataPiece(excluding asked: Set<Int>) -> Int? {
        guard info == nil, let size = metadataSize else { return nil }
        let count = (size + PeerMessage.blockSize - 1) / PeerMessage.blockSize
        return (0..<count).first { metadataPieces[$0] == nil && !asked.contains($0) }
    }

    fileprivate func addMetadataPiece(_ index: Int, _ data: Data) {
        guard info == nil, let size = metadataSize else { return }
        let count = (size + PeerMessage.blockSize - 1) / PeerMessage.blockSize
        guard (0..<count).contains(index) else { return }
        metadataPieces[index] = data
        guard metadataPieces.count == count else { return }
        let raw = (0..<count).reduce(into: Data()) { $0.append(metadataPieces[$1]!) }
        metadataPieces = [:]
        guard raw.count == size, InfoHash.of(info: raw) == infoHash, let parsed = try? TorrentInfo(raw: raw) else {
            metadataSize = nil  // someone sent garbage; start over with the next peer
            return
        }
        adopt(parsed)
    }

    private func adopt(_ parsed: TorrentInfo) {
        info = parsed
        descriptor.infoData = parsed.raw
        if descriptor.displayName == nil { descriptor.displayName = parsed.name }
        do { try prepareStorage(parsed) } catch { lastError = TorrentError.storage(error.localizedDescription).localizedDescription }
        onMetadata(descriptor)
        let w = infoWaiters; infoWaiters = [:]
        w.values.forEach { $0.resume() }
    }

    // MARK: Piece picking

    /// Claims a piece for a peer (`has` nil means a web seed, which has everything).
    fileprivate func claimPiece(has: Bitfield?) -> Int? {
        guard let info, let storage else { return nil }
        let n = info.pieceCount
        func available(_ i: Int) -> Bool { wanted[i] && !storage.have[i] && (has?[i] ?? true) }
        // From the read position forward, then wrap around to the start.
        var advancedHint = true
        for step in 0..<n {
            let i = (scanHint + step) % n
            if available(i) {
                advancedHint = false
                if inFlight[i] == nil { inFlight[i] = 1; return i }
            } else if advancedHint, wanted[i] == false || storage.have[i] {
                scanHint = (i + 1) % n  // everything before this is done
            } else {
                advancedHint = false
            }
        }
        // Endgame near the read position: double up on slow pieces.
        let window = max(2, Int(Self.readAhead / Int64(info.pieceLength)) / 4)
        for step in 0..<min(window, n) {
            let i = (focus + step) % n
            if available(i), let c = inFlight[i], c < 2 { inFlight[i] = c + 1; return i }
        }
        return nil
    }

    fileprivate func releasePiece(_ i: Int) {
        if let c = inFlight[i] { inFlight[i] = c > 1 ? c - 1 : nil }
    }

    /// Stores a downloaded piece. Returns false if it failed verification.
    fileprivate func finishPiece(_ i: Int, _ data: Data) -> Bool {
        releasePiece(i)
        guard let storage else { return false }
        if storage.have[i] { return true }
        let ok: Bool
        do { ok = try storage.store(piece: i, data: data) }
        catch { lastError = TorrentError.storage(error.localizedDescription).localizedDescription; return false }
        guard ok else { return false }
        downloadedBytes += Int64(data.count)
        rateSamples.append((Date(), data.count))
        if rateSamples.count > 400 { rateSamples.removeFirst(200) }
        let w = waiters.removeValue(forKey: i) ?? [:]
        w.values.forEach { $0.resume() }
        if isComplete { storage.saveState(); finishSwarm() }
        return true
    }

    private func finishSwarm() {
        // Done: stop connecting and close idle peers. Readers are all satisfied.
        background.forEach { $0.cancel() }; background = []
        workers.values.forEach { $0.cancel() }; workers = [:]
        connected = []
        running = false
    }

    fileprivate func haveBitfield() -> [UInt8]? {
        guard let storage, storage.have.setCount > 0 else { return nil }
        return storage.have.bytes
    }

    fileprivate func block(_ index: Int, _ begin: Int, _ length: Int) -> Data? {
        guard let info, let storage, storage.have[index], length > 0, length <= 2 * PeerMessage.blockSize,
              begin >= 0, begin + length <= info.length(ofPiece: index) else { return nil }
        return try? storage.read(offset: Int64(index) * Int64(info.pieceLength) + Int64(begin), length: length)
    }

    fileprivate var metadataForSharing: (Data, Int)? { info.map { ($0.raw, $0.raw.count) } }
    fileprivate var pieceCount: Int? { info?.pieceCount }
    fileprivate var pieceInfo: TorrentInfo? { info }
    fileprivate var isRunning: Bool { running }

    // MARK: Trackers and peers

    private func announceLoop(_ tracker: URL) async {
        var event: String? = "started"
        while !Task.isCancelled && running {
            var interval: TimeInterval = 300
            let req = AnnounceRequest(infoHash: infoHash, peerID: peerID, downloaded: downloadedBytes,
                                      left: max((info?.totalLength ?? 1) - downloadedBytes, 0), event: event)
            do {
                let result = try await Tracker.announce(tracker, req, fetch: fetch)
                event = nil
                interval = result.interval
                for p in result.peers where !bannedPeers.contains(p) { known.insert(p) }
            } catch {
                interval = 120
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func connectLoop() async {
        while !Task.isCancelled && running {
            let candidates = known.subtracting(connected).filter { (failures[$0] ?? 0) < 3 && !bannedPeers.contains($0) }
            for peer in candidates.shuffled().prefix(max(0, Self.maxPeers - connected.count)) {
                connected.insert(peer)
                workers[peer] = Task { [weak self] in
                    await self?.runPeer(peer)
                    await self?.peerEnded(peer)
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func peerEnded(_ peer: PeerAddress) {
        connected.remove(peer)
        workers[peer] = nil
    }

    fileprivate func peerFailed(_ peer: PeerAddress, bad: Bool) {
        failures[peer, default: 0] += 1
        if bad { bannedPeers.insert(peer) }
    }

    // MARK: Peer worker

    private nonisolated func runPeer(_ address: PeerAddress) async {
        let conn = PeerConnection(address)
        defer { conn.close() }
        var worker = PeerWorker(session: self, conn: conn)
        do {
            try await worker.run(infoHash: infoHash, peerID: peerID)
        } catch {
            await peerFailed(address, bad: worker.sentBadData)
        }
        await worker.releaseAll()
    }

    // MARK: Web seeds (BEP 19)

    private func webSeedLoop(_ base: URL) async {
        var failuresInRow = 0
        while !Task.isCancelled && running {
            if info == nil { try? await Task.sleep(for: .seconds(1)); continue }
            guard let piece = claimPiece(has: nil), let info else {
                try? await Task.sleep(for: .seconds(1)); continue
            }
            do {
                let data = try await fetchFromWebSeed(base, info: info, piece: piece)
                if !finishPiece(piece, data) { failuresInRow += 1 } else { failuresInRow = 0 }
            } catch {
                releasePiece(piece)
                failuresInRow += 1
            }
            if failuresInRow >= 5 { try? await Task.sleep(for: .seconds(30)); failuresInRow = 0 }
        }
    }

    private nonisolated func fetchFromWebSeed(_ base: URL, info: TorrentInfo, piece: Int) async throws -> Data {
        var out = Data()
        let start = Int64(piece) * Int64(info.pieceLength)
        let end = start + Int64(info.length(ofPiece: piece))
        var cursor = start
        for f in info.files where f.offset + f.length > cursor && f.offset < end {
            if f.offset > cursor { out.append(Data(count: Int(f.offset - cursor))); cursor = f.offset }
            let from = cursor - f.offset
            let to = min(end, f.offset + f.length) - f.offset
            var url = base
            if base.absoluteString.hasSuffix("/") {
                if !info.isSingleFile { url = url.appending(path: info.name) }
                for c in f.path { url = url.appending(path: c) }
            }
            var req = URLRequest(url: url)
            req.setValue("bytes=\(from)-\(to - 1)", forHTTPHeaderField: "Range")
            req.timeoutInterval = 30
            let data = try await fetch(req)
            guard data.count == Int(to - from) else { throw TorrentError.storage("web seed returned \(data.count) bytes") }
            out.append(data)
            cursor = f.offset + to
        }
        if Int64(out.count) < end - start { out.append(Data(count: Int(end - start) - out.count)) }
        return out
    }
}

/// Talks to one peer: metadata exchange, then downloading claimed pieces.
/// Also answers the peer's requests for pieces Bluebox already has.
private struct PeerWorker {
    let session: TorrentSession
    let conn: PeerConnection
    var sentBadData = false

    private var peerChoking = true
    private var amInterested = false
    private var unchokedPeer = false
    private var peerHas: Bitfield?
    private var pendingHaves: [Int] = []
    private var remoteMetadataID: UInt8?
    private var askedMetadata: Set<Int> = []

    private struct Assignment {
        let index: Int
        let length: Int
        var buffer: Data
        var received = Set<Int>()
        var nextOffset = 0
        var outstanding = 0
    }
    private var assignments: [Int: Assignment] = [:]

    init(session: TorrentSession, conn: PeerConnection) { self.session = session; self.conn = conn }

    mutating func run(infoHash: InfoHash, peerID: Data) async throws {
        let supportsExtensions = try await conn.open(infoHash: infoHash, peerID: peerID)
        var hello: [PeerMessage] = []
        if supportsExtensions { hello.append(PeerMessage.extendedHandshake(metadataSize: await session.metadataForSharing?.1)) }
        if let bits = await session.haveBitfield() { hello.append(.bitfield(bits)) }
        try await conn.send(hello)

        while !Task.isCancelled, await session.isRunning {
            try await pump()
            let message = try await conn.receive()
            try await handle(message)
        }
    }

    /// Sends interest, metadata requests and block requests as state allows.
    private mutating func pump() async throws {
        var out: [PeerMessage] = []
        if let pieceCount = await session.pieceCount {
            if peerHas == nil, !pendingHaves.isEmpty { peerHas = Bitfield(count: pieceCount) }
            if var has = peerHas, !pendingHaves.isEmpty {
                pendingHaves.forEach { has[$0] = true }; pendingHaves = []
                peerHas = has
            }
            if !amInterested, peerHas != nil { amInterested = true; out.append(.interested) }
            if !peerChoking, let has = peerHas, let info = await session.pieceInfo {
                let totalOutstanding = assignments.values.reduce(0) { $0 + $1.outstanding }
                var budget = PeerMessage.pipeline(for: info.pieceLength) - totalOutstanding
                // Keep at most two pieces going per peer.
                while assignments.count < 2, budget > 0, let i = await session.claimPiece(has: has) {
                    let len = info.length(ofPiece: i)
                    assignments[i] = Assignment(index: i, length: len, buffer: Data(count: len))
                }
                for key in assignments.keys.sorted() where budget > 0 {
                    var a = assignments[key]!
                    while budget > 0, a.nextOffset < a.length {
                        let len = min(PeerMessage.blockSize, a.length - a.nextOffset)
                        out.append(.request(index: a.index, begin: a.nextOffset, length: len))
                        a.nextOffset += len; a.outstanding += 1; budget -= 1
                    }
                    assignments[key] = a
                }
            }
        } else if let id = remoteMetadataID, askedMetadata.count < 4,
                  let piece = await session.nextMetadataPiece(excluding: askedMetadata) {
            askedMetadata.insert(piece)
            out.append(PeerMessage.metadataRequest(remoteID: id, piece: piece))
        }
        try await conn.send(out)
    }

    private mutating func handle(_ m: PeerMessage) async throws {
        switch m {
        case .keepAlive, .other, .cancel: break
        case .choke:
            peerChoking = true
            // Requests are dropped by a choking peer; ask again after unchoke.
            for k in assignments.keys {
                assignments[k]!.nextOffset = Self.firstMissingBlock(assignments[k]!)
                assignments[k]!.outstanding = 0
            }
        case .unchoke: peerChoking = false
        case .interested:
            if !unchokedPeer { unchokedPeer = true; try await conn.send(.unchoke) }
        case .notInterested: break
        case .have(let i):
            if var has = peerHas { has[i] = true; peerHas = has } else { pendingHaves.append(i) }
        case .bitfield(let bytes):
            guard let count = await session.pieceCount else { pendingHaves = Self.indices(bytes); return }
            guard let b = Bitfield(bytes: bytes, count: count) else { throw TorrentError.storage("bad bitfield") }
            peerHas = b
        case .request(let index, let begin, let length):
            guard unchokedPeer, let block = await session.block(index, begin, length) else { return }
            try await conn.send(.piece(index: index, begin: begin, block: block))
        case .piece(let index, let begin, let block):
            guard var a = assignments[index], begin % PeerMessage.blockSize == 0, begin + block.count <= a.length,
                  !a.received.contains(begin) else { return }
            a.buffer.replaceSubrange(begin..<(begin + block.count), with: block)
            a.received.insert(begin)
            a.outstanding = max(0, a.outstanding - 1)
            let blocks = (a.length + PeerMessage.blockSize - 1) / PeerMessage.blockSize
            if a.received.count == blocks {
                assignments[index] = nil
                if await !session.finishPiece(index, a.buffer) {
                    sentBadData = true
                    throw TorrentError.storage("piece \(index) failed verification")
                }
            } else {
                assignments[index] = a
            }
        case .extended(let id, let payload):
            try await handleExtended(id, payload)
        }
    }

    private mutating func handleExtended(_ id: UInt8, _ payload: Data) async throws {
        if id == 0 {
            guard let hs = try? Bencode.decode(payload) else { return }
            if let remote = hs["m"]?["ut_metadata"]?.int, (1...255).contains(remote) { remoteMetadataID = UInt8(remote) }
            if let size = hs["metadata_size"]?.int { await session.noteMetadataSize(Int(size)) }
            return
        }
        guard id == PeerMessage.localMetadataID, let (dict, used) = try? Bencode.decodePrefix(payload),
              let type = dict["msg_type"]?.int, let piece = dict["piece"]?.int else { return }
        switch type {
        case 0:  // they want our metadata
            guard let remote = remoteMetadataID else { return }
            // `piece` comes from the peer: anything out of range gets a reject, never a crash.
            let index = Int(clamping: piece)
            if let (raw, total) = await session.metadataForSharing, let chunk = PeerMessage.metadataChunk(raw, piece: piece) {
                try await conn.send(PeerMessage.metadataData(remoteID: remote, piece: index, total: total, bytes: chunk))
            } else {
                try await conn.send(PeerMessage.metadataReject(remoteID: remote, piece: index))
            }
        case 1:
            askedMetadata.remove(Int(piece))
            await session.addMetadataPiece(Int(piece), Data(payload.dropFirst(used)))
        default:
            askedMetadata.remove(Int(piece))
            remoteMetadataID = nil  // peer won't share; stop asking
        }
    }

    func releaseAll() async {
        for k in assignments.keys { await session.releasePiece(k) }
    }

    private static func firstMissingBlock(_ a: Assignment) -> Int {
        var o = 0
        while o < a.length, a.received.contains(o) { o += PeerMessage.blockSize }
        return o
    }

    static func indices(_ bytes: [UInt8]) -> [Int] {
        bytes.enumerated().flatMap { (i, b) in (0..<8).compactMap { b & (0x80 >> UInt8($0)) != 0 ? i * 8 + $0 : nil } }
    }
}

extension PeerMessage {
    /// Outstanding block requests per peer: deeper for big pieces.
    static func pipeline(for pieceLength: Int) -> Int { min(TorrentSession.pipeline, max(8, pieceLength / blockSize)) }
}
