import CryptoKit
import Foundation

public enum TorrentError: Error, Equatable, Sendable, LocalizedError {
    case invalidMagnet
    case invalidTorrent(String)
    case noTrackers
    case metadataUnavailable
    case noPeers
    case cancelled
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMagnet: "That isn't a valid magnet link."
        case .invalidTorrent(let d): "That torrent file couldn't be read (\(d))."
        case .noTrackers: "This magnet link lists no trackers or web seeds, so Bluebox can't find anyone sharing it."
        case .metadataUnavailable: "Couldn't get the torrent's file list from anyone sharing it. Try again later."
        case .noPeers: "Nobody sharing this torrent could be reached right now."
        case .cancelled: "Cancelled."
        case .storage(let d): "Couldn't save the download: \(d)"
        }
    }
}

/// A v1 info hash: SHA-1 of the bencoded `info` dictionary.
public struct InfoHash: Hashable, Codable, Sendable, CustomStringConvertible {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 20 else { return nil }
        self.bytes = bytes
    }

    public init?(hex: String) {
        guard hex.count == 40 else { return nil }
        var out = Data(capacity: 20)
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let byte = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(byte)
        }
        self.init(bytes: out)
    }

    /// BEP 9 also allows 32-character base32 hashes in magnet links.
    public init?(base32: String) {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        guard base32.count == 32 else { return nil }
        var bits = 0, value = 0
        var out = Data()
        for c in base32.uppercased() {
            guard let idx = alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | idx; bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((value >> bits) & 0xFF)) }
        }
        self.init(bytes: out)
    }

    public static func of(info: Data) -> InfoHash {
        InfoHash(bytes: Data(Insecure.SHA1.hash(data: info)))!
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    public var description: String { hex }
}

/// The parsed `info` dictionary of a v1 (or hybrid) torrent.
public struct TorrentInfo: Sendable, Hashable {
    public struct File: Sendable, Hashable {
        /// Sanitized path components, relative to the torrent's folder.
        public let path: [String]
        public let length: Int64
        /// Byte offset of the file within the torrent's concatenated data.
        public let offset: Int64
        public var name: String { path.last ?? "" }
    }

    public let name: String
    public let pieceLength: Int
    public let pieceHashes: [Data]
    public let files: [File]
    /// True for single-file torrents (the file sits at the top, not in a folder).
    public let isSingleFile: Bool
    /// The bencoded dictionary, exactly as hashed.
    public let raw: Data

    public var totalLength: Int64 { files.last.map { $0.offset + $0.length } ?? 0 }
    public var pieceCount: Int { pieceHashes.count }

    public func length(ofPiece i: Int) -> Int {
        let start = Int64(i) * Int64(pieceLength)
        return Int(min(Int64(pieceLength), totalLength - start))
    }

    /// Pieces that hold any byte of the given torrent-wide range.
    public func pieces(covering offset: Int64, length: Int64) -> ClosedRange<Int>? {
        guard length > 0, offset < totalLength else { return nil }
        let first = Int(offset / Int64(pieceLength))
        let last = Int(min(offset + length - 1, totalLength - 1) / Int64(pieceLength))
        return first...last
    }

    static let maxFiles = 50_000
    /// 1 PiB. Larger totals are nonsense and could overflow offset arithmetic.
    static let maxTotalLength: Int64 = 1 << 50

    public init(raw: Data) throws {
        guard let v = try? Bencode.decode(raw), let d = v.dict else { throw TorrentError.invalidTorrent("info is not a dictionary") }
        guard let pieces = d["pieces"]?.data else { throw TorrentError.invalidTorrent("v2-only torrents aren't supported") }
        guard let pl = d["piece length"]?.int, pl >= 16 * 1024, pl <= 64 * 1024 * 1024 else {
            throw TorrentError.invalidTorrent("piece length")
        }
        guard pieces.count % 20 == 0, !pieces.isEmpty else { throw TorrentError.invalidTorrent("piece hashes") }
        let name = Self.sanitize(d["name.utf-8"]?.string ?? d["name"]?.string ?? "") ?? "download"
        var files: [File] = []
        var offset: Int64 = 0
        if let list = d["files"]?.list {
            guard list.count <= Self.maxFiles else { throw TorrentError.invalidTorrent("too many files") }
            for f in list {
                guard let len = f["length"]?.int, len >= 0, len <= Self.maxTotalLength - offset,
                      let comps = (f["path.utf-8"] ?? f["path"])?.list?.compactMap(\.string), !comps.isEmpty else {
                    throw TorrentError.invalidTorrent("file entry")
                }
                if f["attr"]?.string?.contains("p") == true { offset += len; continue }  // BEP 47 padding
                let path = comps.compactMap(Self.sanitize)
                guard path.count == comps.count else { throw TorrentError.invalidTorrent("unsafe file path") }
                files.append(File(path: path, length: len, offset: offset))
                offset += len
            }
            isSingleFile = false
        } else if let len = d["length"]?.int, len >= 0, len <= Self.maxTotalLength {
            files = [File(path: [name], length: len, offset: 0)]
            offset = len
            isSingleFile = true
        } else {
            throw TorrentError.invalidTorrent("no files")
        }
        let count = pieces.count / 20
        guard Int64(count) == (offset + pl - 1) / pl else { throw TorrentError.invalidTorrent("piece count doesn't match size") }
        self.name = name
        self.pieceLength = Int(pl)
        self.pieceHashes = (0..<count).map { pieces.subdata(in: (pieces.startIndex + $0 * 20)..<(pieces.startIndex + $0 * 20 + 20)) }
        self.files = files
        self.raw = raw
    }

    /// A path component that's safe to create on disk, or nil.
    static func sanitize(_ s: String) -> String? {
        let cleaned = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", cleaned.utf8.count <= 255 else { return nil }
        return cleaned
    }
}

/// What the user added: enough to find peers and, once known, the file list.
public struct TorrentDescriptor: Codable, Sendable, Hashable {
    public var infoHash: InfoHash
    public var displayName: String?
    public var trackers: [URL]
    public var webSeeds: [URL]
    /// Bencoded info dictionary, once known (immediately for .torrent files).
    public var infoData: Data?

    public init(infoHash: InfoHash, displayName: String? = nil, trackers: [URL] = [], webSeeds: [URL] = [], infoData: Data? = nil) {
        self.infoHash = infoHash; self.displayName = displayName; self.trackers = trackers
        self.webSeeds = webSeeds; self.infoData = infoData
    }

    /// Parses `magnet:?xt=urn:btih:…&dn=…&tr=…&ws=…`.
    public init(magnet: String) throws {
        guard let c = URLComponents(string: magnet.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "magnet" else { throw TorrentError.invalidMagnet }
        let items = c.queryItems ?? []
        var hash: InfoHash?
        for x in items where x.name == "xt" {
            guard let v = x.value, v.lowercased().hasPrefix("urn:btih:") else { continue }
            let h = String(v.dropFirst(9))
            hash = InfoHash(hex: h) ?? InfoHash(base32: h)
            if hash != nil { break }
        }
        guard let hash else { throw TorrentError.invalidMagnet }
        self.init(infoHash: hash,
                  displayName: items.first { $0.name == "dn" }?.value,
                  trackers: items.filter { $0.name == "tr" }.compactMap { $0.value.flatMap(URL.init(string:)) }.filter(Self.isTracker),
                  webSeeds: items.filter { $0.name == "ws" }.compactMap { $0.value.flatMap(URL.init(string:)) }.filter(Self.isHTTP))
    }

    /// Parses a .torrent file.
    public init(torrentFile data: Data) throws {
        guard let root = try? Bencode.decode(data), root.dict != nil else { throw TorrentError.invalidTorrent("not a torrent file") }
        guard let raw = try Bencode.rawInfo(in: data) else { throw TorrentError.invalidTorrent("missing info") }
        let info = try TorrentInfo(raw: raw)
        var trackers: [URL] = []
        if let tiers = root["announce-list"]?.list {
            for tier in tiers { trackers += (tier.list ?? []).compactMap { $0.string.flatMap(URL.init(string:)) } }
        }
        if let a = root["announce"]?.string.flatMap(URL.init(string:)), !trackers.contains(a) { trackers.insert(a, at: 0) }
        var seeds: [URL] = []
        if let s = root["url-list"]?.string.flatMap(URL.init(string:)) { seeds = [s] }
        else if let l = root["url-list"]?.list { seeds = l.compactMap { $0.string.flatMap(URL.init(string:)) } }
        self.init(infoHash: InfoHash.of(info: raw), displayName: info.name,
                  trackers: trackers.filter(Self.isTracker), webSeeds: seeds.filter(Self.isHTTP), infoData: raw)
    }

    static func isTracker(_ u: URL) -> Bool { ["http", "https", "udp"].contains(u.scheme?.lowercased() ?? "") }
    static func isHTTP(_ u: URL) -> Bool { ["http", "https"].contains(u.scheme?.lowercased() ?? "") }
}
