import CryptoKit
import Foundation
import Network
@testable import Torrent
import Testing

// MARK: - Helpers

/// Builds a torrent over deterministic pseudo-random data.
struct TestTorrent {
    let files: [(path: [String], data: Data)]
    let pieceLength: Int
    let infoRaw: Data
    let hash: InfoHash
    var all: Data { files.reduce(into: Data()) { $0.append($1.data) } }

    init(files: [(path: [String], size: Int)], pieceLength: Int = 16 * 1024, name: String = "Sample") {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func bytes(_ n: Int) -> Data {
            var d = Data(count: n)
            for i in 0..<n { seed = seed &* 6364136223846793005 &+ 1442695040888963407; d[i] = UInt8(truncatingIfNeeded: seed >> 33) }
            return d
        }
        self.files = files.map { ($0.path, bytes($0.size)) }
        self.pieceLength = pieceLength
        let all = self.files.reduce(into: Data()) { $0.append($1.data) }
        var hashes = Data()
        var i = 0
        while i < all.count {
            hashes.append(Data(Insecure.SHA1.hash(data: all.subdata(in: i..<min(i + pieceLength, all.count)))))
            i += pieceLength
        }
        var info: [String: BValue] = ["name": .str(name), "piece length": .int(Int64(pieceLength)), "pieces": .bytes(hashes)]
        if files.count == 1 && files[0].path.count == 1 {
            info["length"] = .int(Int64(files[0].size))
            info["name"] = .str(files[0].path[0])
        } else {
            info["files"] = .list(self.files.map { .dict(["length": .int(Int64($0.data.count)), "path": .list($0.path.map(BValue.str))]) })
        }
        infoRaw = Bencode.encode(.dict(info))
        hash = InfoHash.of(info: infoRaw)
    }

    func torrentFile(announce: String? = nil, webSeed: String? = nil) -> Data {
        var root: [String: BValue] = [:]
        if let announce { root["announce"] = .str(announce) }
        if let webSeed { root["url-list"] = .str(webSeed) }
        var data = Bencode.encode(.dict(root))
        // Splice the exact info bytes in so the hash matches.
        data.removeLast()  // trailing "e"
        var out = Data("d".utf8)
        out.append(data.dropFirst())
        out.append(Data("4:info".utf8)); out.append(infoRaw); out.append(Data("e".utf8))
        return root.isEmpty ? Data("d4:info".utf8) + infoRaw + Data("e".utf8) : out
    }
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appending(path: "bluebox-torrent-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// A minimal seeding peer on localhost: handshake, metadata exchange,
/// bitfield, unchoke, and block responses. Optionally corrupts one piece.
final class LocalSeeder: @unchecked Sendable {
    let torrent: TestTorrent
    let listener: NWListener
    let queue = DispatchQueue(label: "seeder")
    var corruptPiece: Int?
    private let lock = NSLock()
    private var _served = 0
    var served: Int { lock.withLock { _served } }

    init(_ t: TestTorrent) throws {
        torrent = t
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        return try await withCheckedThrowingContinuation { cont in
            // State callbacks run serially on `queue`.
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [weak self] s in
                guard !resumed else { return }
                if case .ready = s, let p = self?.listener.port?.rawValue { resumed = true; cont.resume(returning: p) }
                if case .failed(let e) = s { resumed = true; cont.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func read(_ c: NWConnection, _ n: Int, _ done: @escaping (Data?) -> Void) {
        if n == 0 { return done(Data()) }
        c.receive(minimumIncompleteLength: n, maximumLength: n) { d, _, _, e in done(e == nil && d?.count == n ? d : nil) }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, 68) { [self] hs in
            guard let hs, hs.count == 68 else { c.cancel(); return }
            var reply = PeerMessage.handshake(infoHash: torrent.hash, peerID: Data(repeating: 7, count: 20))
            reply.append(PeerMessage.extendedHandshake(metadataSize: torrent.infoRaw.count).encoded())
            let count = (torrent.all.count + torrent.pieceLength - 1) / torrent.pieceLength
            reply.append(PeerMessage.bitfield(Bitfield.full(count).bytes).encoded())
            reply.append(PeerMessage.unchoke.encoded())
            c.send(content: reply, completion: .idempotent)
            loop(c, remoteMetadataID: nil)
        }
    }

    private func loop(_ c: NWConnection, remoteMetadataID: UInt8?) {
        read(c, 4) { [self] h in
            guard let h, let len = h.readBE(UInt32.self, at: 0) else { c.cancel(); return }
            read(c, Int(len)) { [self] body in
                guard let body, let m = try? PeerMessage.decode(body) else { c.cancel(); return }
                var remote = remoteMetadataID
                switch m {
                case .request(let i, let b, let l):
                    let start = i * torrent.pieceLength + b
                    var block = torrent.all.subdata(in: start..<(start + l))
                    if i == corruptPiece { block[0] ^= 0xFF }
                    lock.withLock { _served += 1 }
                    c.send(content: PeerMessage.piece(index: i, begin: b, block: block).encoded(), completion: .idempotent)
                case .extended(0, let p):
                    if let v = try? Bencode.decode(p), let id = v["m"]?["ut_metadata"]?.int { remote = UInt8(id) }
                case .extended(PeerMessage.localMetadataID, let p):
                    if let (d, _) = try? Bencode.decodePrefix(p), let piece = d["piece"]?.int, let remote {
                        let start = Int(piece) * 16384
                        let chunk = torrent.infoRaw.subdata(in: start..<min(start + 16384, torrent.infoRaw.count))
                        c.send(content: PeerMessage.metadataData(remoteID: remote, piece: Int(piece), total: torrent.infoRaw.count,
                                                                 bytes: chunk).encoded(), completion: .idempotent)
                    }
                default: break
                }
                loop(c, remoteMetadataID: remote)
            }
        }
    }
}

/// HTTP tracker + web seed stand-in.
func fakeFetch(peerPort: UInt16?, webSeed: TestTorrent? = nil) -> Tracker.Fetch {
    { req in
        let url = req.url!
        if url.path.hasSuffix("/announce") {
            var peers = Data()
            if let peerPort { peers.append(contentsOf: [127, 0, 0, 1]); peers.appendBE(peerPort) }
            return Bencode.encode(.dict(["interval": .int(1800), "peers": .bytes(peers)]))
        }
        guard let t = webSeed, let range = req.value(forHTTPHeaderField: "Range") else { throw URLError(.badURL) }
        let parts = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
        let file = t.files.first { url.path.hasSuffix($0.path.joined(separator: "/")) }!
        return file.data.subdata(in: parts[0]..<(parts[1] + 1))
    }
}

// MARK: - Tests

@Suite struct BencodeTests {
    @Test func roundTripsAndSortsKeys() throws {
        let v = BValue.dict(["b": .int(-3), "a": .list([.str("spam"), .int(0)])])
        let d = Bencode.encode(v)
        #expect(String(decoding: d, as: UTF8.self) == "d1:al4:spami0ee1:bi-3ee")
        #expect(try Bencode.decode(d) == v)
    }

    @Test(arguments: ["i01e", "i-0e", "5:abc", "d1:a", "l", "x", "i1ei2e", "2147483648:x"])
    func rejectsMalformed(_ s: String) { #expect(throws: (any Error).self) { try Bencode.decode(Data(s.utf8)) } }

    @Test func rejectsDeepNesting() {
        let s = String(repeating: "l", count: 100) + String(repeating: "e", count: 100)
        #expect(throws: BencodeError.tooDeep) { try Bencode.decode(Data(s.utf8)) }
    }

    @Test func prefixDecodeReportsLength() throws {
        let (v, n) = try Bencode.decodePrefix(Data("d1:xi1eeRAW".utf8))
        #expect(v["x"]?.int == 1)
        #expect(n == 8)
    }
}

@Suite struct MetainfoTests {
    @Test func parsesTorrentFileAndHashesInfoExactly() throws {
        let t = TestTorrent(files: [(["a.mp4"], 40_000)])
        let d = try TorrentDescriptor(torrentFile: t.torrentFile(announce: "udp://tracker.example:1337/announce", webSeed: "https://archive.example/dl/"))
        #expect(d.infoHash == t.hash)
        #expect(d.trackers.map(\.absoluteString) == ["udp://tracker.example:1337/announce"])
        #expect(d.webSeeds.count == 1)
        let info = try TorrentInfo(raw: try #require(d.infoData))
        #expect(info.isSingleFile)
        #expect(info.pieceCount == 3)
        #expect(info.length(ofPiece: 2) == 40_000 - 32_768)
    }

    @Test func parsesMagnetLinks() throws {
        let hex = String(repeating: "ab", count: 20)
        let d = try TorrentDescriptor(magnet: "magnet:?xt=urn:btih:\(hex)&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Ft.example%3A80&tr=ftp://nope&ws=https%3A%2F%2Fseed.example%2F")
        #expect(d.infoHash.hex == hex)
        #expect(d.displayName == "Big+Buck+Bunny" || d.displayName == "Big Buck Bunny")
        #expect(d.trackers.map(\.absoluteString) == ["udp://t.example:80"])
        #expect(d.webSeeds.map(\.absoluteString) == ["https://seed.example/"])
        // Base32 of 20 bytes of 0xFF is 32 × "7".
        let b32 = try TorrentDescriptor(magnet: "magnet:?xt=urn:btih:\(String(repeating: "7", count: 32))&tr=http://t.example/announce")
        #expect(b32.infoHash.hex == String(repeating: "ff", count: 20))
        #expect(throws: TorrentError.invalidMagnet) { try TorrentDescriptor(magnet: "https://example.com") }
        #expect(throws: TorrentError.invalidMagnet) { try TorrentDescriptor(magnet: "magnet:?xt=urn:btih:zz") }
    }

    @Test func rejectsUnsafePathsAndBadPieceCounts() throws {
        let hashes = Data(count: 20)
        let traversal = Bencode.encode(.dict(["name": .str("x"), "piece length": .int(16384), "pieces": .bytes(hashes),
                                              "files": .list([.dict(["length": .int(10), "path": .list([.str(".."), .str("evil")])])])]))
        #expect(throws: TorrentError.invalidTorrent("unsafe file path")) { try TorrentInfo(raw: traversal) }
        let wrongCount = Bencode.encode(.dict(["name": .str("x"), "piece length": .int(16384), "pieces": .bytes(hashes), "length": .int(100_000)]))
        #expect(throws: TorrentError.invalidTorrent("piece count doesn't match size")) { try TorrentInfo(raw: wrongCount) }
        // Slashes inside a component are neutralized rather than creating folders.
        #expect(TorrentInfo.sanitize("a/../b") == "a_.._b")
    }
}

@Suite struct StorageTests {
    @Test func storesVerifiedPiecesAcrossFileBoundaries() throws {
        let t = TestTorrent(files: [(["d", "one.mp4"], 20_000), (["two.srt"], 30_000)])
        let info = try TorrentInfo(raw: t.infoRaw)
        let dir = tempDir()
        let s = try PieceStorage(root: dir, info: info)
        let all = t.all
        // Piece 1 spans both files.
        let p1 = all.subdata(in: 16384..<32768)
        var bad = p1; bad[0] ^= 1
        #expect(try s.store(piece: 1, data: bad) == false)
        #expect(try s.store(piece: 1, data: p1))
        #expect(s.have[1] && !s.have[0])
        #expect(try s.read(offset: 18_000, length: 4_000) == all.subdata(in: 18_000..<22_000))
        for i in [0, 2, 3] {
            let start = i * 16384
            #expect(try s.store(piece: i, data: all.subdata(in: start..<min(start + 16384, all.count))))
        }
        #expect(try Data(contentsOf: dir.appending(path: "Sample/d/one.mp4")) == t.files[0].data)
        #expect(try Data(contentsOf: dir.appending(path: "Sample/two.srt")) == t.files[1].data)
        // State survives reopening.
        #expect(try PieceStorage(root: dir, info: info).have.isComplete)
    }

    @Test func bitfieldRejectsSpareBits() {
        #expect(Bitfield(bytes: [0xFF], count: 7) == nil)
        #expect(Bitfield(bytes: [0xFE], count: 7) != nil)
        var b = Bitfield(count: 10); b[9] = true
        #expect(b.bytes == [0, 0x40])
    }
}

@Suite struct TrackerTests {
    @Test func parsesCompactAndDictPeers() throws {
        var compact = Data([10, 0, 0, 1]); compact.appendBE(UInt16(6881))
        let r = try Tracker.parseHTTPResponse(Bencode.encode(.dict(["interval": .int(900), "peers": .bytes(compact)])))
        #expect(r.peers == [PeerAddress(host: "10.0.0.1", port: 6881)])
        #expect(r.interval == 900)
        let r2 = try Tracker.parseHTTPResponse(Bencode.encode(.dict(["peers": .list([.dict(["ip": .str("::1"), "port": .int(51413)])])])))
        #expect(r2.peers == [PeerAddress(host: "::1", port: 51413)])
    }

    @Test func encodesInfoHashBytesInAnnounceURL() throws {
        let hash = InfoHash(hex: "00ff" + String(repeating: "41", count: 18))!
        let url = Tracker.httpURL(URL(string: "https://t.example/announce?key=1")!, AnnounceRequest(infoHash: hash, peerID: Data(repeating: 0x2D, count: 20)))!
        #expect(url.absoluteString.hasPrefix("https://t.example/announce?key=1&info_hash=%00%FFAAAAAAAAAAAAAAAAAA&peer_id=--------------------"))
    }
}

@Suite(.serialized) struct SwarmTests {
    @Test(.timeLimit(.minutes(1))) func downloadsFromAPeerAndStreamsReads() async throws {
        let t = TestTorrent(files: [(["Movie.mp4"], 200_000)])
        let seeder = try LocalSeeder(t)
        let port = try await seeder.start()
        defer { seeder.stop() }
        let client = TorrentClient(directory: tempDir(), fetch: fakeFetch(peerPort: port))
        var d = try TorrentDescriptor(torrentFile: t.torrentFile(announce: "http://tracker.test/announce"))
        d.trackers = [URL(string: "http://tracker.test/announce")!]
        let hash = try await client.add(d)
        let url = TorrentClient.streamURL(hash, file: 0, ext: "mp4")
        #expect(try await client.contentLength(of: url) == 200_000)
        // A read from the middle is served once those pieces arrive.
        #expect(try await client.read(url, offset: 150_000, length: 10_000) == t.all.subdata(in: 150_000..<160_000))
        while await client.status(hash)?.phase != .complete { try await Task.sleep(for: .milliseconds(50)) }
        let file = try #require(await client.completedFileURL(hash, file: 0))
        #expect(try Data(contentsOf: file) == t.all)
        await client.stopAll()
    }

    @Test(.timeLimit(.minutes(1))) func magnetFetchesMetadataFromPeers() async throws {
        let t = TestTorrent(files: [(["Film", "film.mp4"], 50_000), (["Film", "film.en.srt"], 2_000)], name: "Film")
        let seeder = try LocalSeeder(t)
        let port = try await seeder.start()
        defer { seeder.stop() }
        let client = TorrentClient(directory: tempDir(), fetch: fakeFetch(peerPort: port))
        let hash = try await client.add(try TorrentDescriptor(magnet: "magnet:?xt=urn:btih:\(t.hash.hex)&tr=http%3A%2F%2Ftracker.test%2Fannounce"))
        let info = try await client.info(for: hash, timeout: 20)
        #expect(info.name == "Film")
        #expect(info.files.map(\.name) == ["film.mp4", "film.en.srt"])
        // The file list is remembered.
        #expect(await client.knownInfo(for: hash) != nil)
        await client.stopAll()
    }

    @Test(.timeLimit(.minutes(1))) func corruptPeerDataIsRejected() async throws {
        let t = TestTorrent(files: [(["x.mp4"], 64_000)])
        let seeder = try LocalSeeder(t)
        seeder.corruptPiece = 1
        let port = try await seeder.start()
        defer { seeder.stop() }
        let client = TorrentClient(directory: tempDir(), fetch: fakeFetch(peerPort: port))
        var d = try TorrentDescriptor(torrentFile: t.torrentFile())
        d.trackers = [URL(string: "http://tracker.test/announce")!]
        let hash = try await client.add(d)
        // Piece 0 arrives fine; piece 1 never verifies, so it's never stored.
        let url = TorrentClient.streamURL(hash, file: 0, ext: "mp4")
        #expect(try await client.read(url, offset: 0, length: 1000) == t.all.prefix(1000))
        try await Task.sleep(for: .seconds(1))
        let status = try #require(await client.status(hash))
        #expect(status.haveBytes < 64_000)
        #expect(await client.completedFileURL(hash, file: 0) == nil)
        await client.stopAll()
    }

    @Test(.timeLimit(.minutes(1))) func downloadsFromAWebSeed() async throws {
        let t = TestTorrent(files: [(["Show", "ep1.mp4"], 40_000), (["Show", "ep2.mp4"], 30_000)], name: "Show")
        let client = TorrentClient(directory: tempDir(), fetch: fakeFetch(peerPort: nil, webSeed: t))
        let hash = try await client.add(try TorrentDescriptor(torrentFile: t.torrentFile(webSeed: "https://seed.test/files/")))
        while await client.status(hash)?.phase != .complete { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try Data(contentsOf: try #require(await client.completedFileURL(hash, file: 1))) == t.files[1].data)
    }
}
