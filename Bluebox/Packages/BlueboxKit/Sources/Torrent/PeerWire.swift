import Foundation

/// BitTorrent peer wire messages (BEP 3) plus the extension protocol (BEP 10).
enum PeerMessage: Equatable, Sendable {
    case keepAlive
    case choke, unchoke, interested, notInterested
    case have(Int)
    case bitfield([UInt8])
    case request(index: Int, begin: Int, length: Int)
    case piece(index: Int, begin: Int, block: Data)
    case cancel(index: Int, begin: Int, length: Int)
    case extended(id: UInt8, payload: Data)
    case other(UInt8)

    static let blockSize = 16 * 1024
    /// Largest frame accepted: a 16 KiB block or a big bitfield/metadata message.
    static let maxFrame = 4 * 1024 * 1024

    func encoded() -> Data {
        var body = Data()
        switch self {
        case .keepAlive: break
        case .choke: body.append(0)
        case .unchoke: body.append(1)
        case .interested: body.append(2)
        case .notInterested: body.append(3)
        case .have(let i): body.append(4); body.appendBE(UInt32(i))
        case .bitfield(let b): body.append(5); body.append(contentsOf: b)
        case .request(let i, let b, let l): body.append(6); body.appendBE(UInt32(i)); body.appendBE(UInt32(b)); body.appendBE(UInt32(l))
        case .piece(let i, let b, let block): body.append(7); body.appendBE(UInt32(i)); body.appendBE(UInt32(b)); body.append(block)
        case .cancel(let i, let b, let l): body.append(8); body.appendBE(UInt32(i)); body.appendBE(UInt32(b)); body.appendBE(UInt32(l))
        case .extended(let id, let p): body.append(20); body.append(id); body.append(p)
        case .other(let id): body.append(id)
        }
        var out = Data()
        out.appendBE(UInt32(body.count))
        out.append(body)
        return out
    }

    /// Decodes a frame body (without its length prefix).
    static func decode(_ body: Data) throws -> PeerMessage {
        guard let id = body.first else { return .keepAlive }
        let p = body.dropFirst()
        func u32(_ at: Int) throws -> Int {
            guard let v = p.readBE(UInt32.self, at: at) else { throw TorrentError.storage("short peer message") }
            return Int(v)
        }
        switch id {
        case 0: return .choke
        case 1: return .unchoke
        case 2: return .interested
        case 3: return .notInterested
        case 4: return .have(try u32(0))
        case 5: return .bitfield([UInt8](p))
        case 6: return .request(index: try u32(0), begin: try u32(4), length: try u32(8))
        case 7: guard p.count >= 8 else { throw TorrentError.storage("short piece") }
            return .piece(index: try u32(0), begin: try u32(4), block: Data(p.dropFirst(8)))
        case 8: return .cancel(index: try u32(0), begin: try u32(4), length: try u32(8))
        case 20: guard let ext = p.first else { throw TorrentError.storage("short extended") }
            return .extended(id: ext, payload: Data(p.dropFirst()))
        default: return .other(id)
        }
    }

    // MARK: Handshake

    static let protocolName = Data("BitTorrent protocol".utf8)

    static func handshake(infoHash: InfoHash, peerID: Data) -> Data {
        var d = Data([19])
        d.append(protocolName)
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[5] |= 0x10  // extension protocol
        d.append(contentsOf: reserved)
        d.append(infoHash.bytes)
        d.append(peerID)
        return d
    }

    /// Validates a 68-byte handshake; returns whether the peer speaks BEP 10.
    static func parseHandshake(_ d: Data, expecting hash: InfoHash) throws -> Bool {
        let b = [UInt8](d)
        guard b.count == 68, b[0] == 19, Data(b[1..<20]) == protocolName else { throw TorrentError.storage("bad handshake") }
        guard Data(b[28..<48]) == hash.bytes else { throw TorrentError.storage("wrong torrent") }
        return b[25] & 0x10 != 0
    }

    // MARK: Extension protocol

    static let localMetadataID: UInt8 = 1

    static func extendedHandshake(metadataSize: Int?) -> PeerMessage {
        var d: [String: BValue] = ["m": .dict(["ut_metadata": .int(Int64(localMetadataID))]), "v": .str("Bluebox"), "reqq": .int(250)]
        if let metadataSize { d["metadata_size"] = .int(Int64(metadataSize)) }
        return .extended(id: 0, payload: Bencode.encode(.dict(d)))
    }

    static func metadataRequest(remoteID: UInt8, piece: Int) -> PeerMessage {
        .extended(id: remoteID, payload: Bencode.encode(.dict(["msg_type": .int(0), "piece": .int(Int64(piece))])))
    }

    static func metadataData(remoteID: UInt8, piece: Int, total: Int, bytes: Data) -> PeerMessage {
        var p = Bencode.encode(.dict(["msg_type": .int(1), "piece": .int(Int64(piece)), "total_size": .int(Int64(total))]))
        p.append(bytes)
        return .extended(id: remoteID, payload: p)
    }

    /// The bytes of metadata piece `piece` (a value a peer sent), or nil when it's out of range.
    static func metadataChunk(_ raw: Data, piece: Int64) -> Data? {
        let count = (raw.count + blockSize - 1) / blockSize
        guard piece >= 0, piece < Int64(count) else { return nil }
        let start = Int(piece) * blockSize
        return raw.subdata(in: (raw.startIndex + start)..<(raw.startIndex + min(start + blockSize, raw.count)))
    }

    static func metadataReject(remoteID: UInt8, piece: Int) -> PeerMessage {
        .extended(id: remoteID, payload: Bencode.encode(.dict(["msg_type": .int(2), "piece": .int(Int64(piece))])))
    }
}

/// One TCP connection to a peer, framing messages.
final class PeerConnection: @unchecked Sendable {
    let address: PeerAddress
    private let socket: Socket

    init(_ address: PeerAddress) {
        self.address = address
        socket = Socket(host: address.host, port: address.port)
    }

    /// Connects and swaps handshakes. Returns whether the peer supports BEP 10.
    func open(infoHash: InfoHash, peerID: Data) async throws -> Bool {
        try await socket.open(timeout: 8)
        try await socket.send(PeerMessage.handshake(infoHash: infoHash, peerID: peerID))
        let reply = try await withTimeout(10, onTimeout: { [socket] in socket.close() }) { [socket] in
            try await socket.receive(exactly: 68)
        }
        return try PeerMessage.parseHandshake(reply, expecting: infoHash)
    }

    func send(_ m: PeerMessage) async throws { try await socket.send(m.encoded()) }

    func send(_ ms: [PeerMessage]) async throws {
        guard !ms.isEmpty else { return }
        try await socket.send(ms.reduce(into: Data()) { $0.append($1.encoded()) })
    }

    /// Next message, or a timeout error after `timeout` seconds of silence.
    func receive(timeout: TimeInterval = 120) async throws -> PeerMessage {
        try await withTimeout(timeout, onTimeout: { [socket] in socket.close() }) { [socket] in
            let header = try await socket.receive(exactly: 4)
            let length = Int(header.readBE(UInt32.self, at: 0) ?? 0)
            guard length <= PeerMessage.maxFrame else { throw TorrentError.storage("oversized message") }
            return try PeerMessage.decode(try await socket.receive(exactly: length))
        }
    }

    func close() { socket.close() }
}
