//
//  MagnetLink.swift
//  Bluebox
//
//  Magnet URIs as BitTorrent uses them. Written for Bluebox from the public
//  specifications: BEP 9 (magnet links: xt=urn:btih, dn, tr, x.pe), BEP 53
//  (select-only: so=0,2,4-6), BEP 52 (v2 hashes as xt=urn:btmh multihash),
//  BEP 19 (ws web seeds) and RFC 4648 (base32).
//

import Foundation

public struct MagnetLink: Sendable, Equatable {
    /// SHA-1 info hash (v1), 20 bytes.
    public var infoHashV1: Data?
    /// SHA-256 info hash (v2), 32 bytes.
    public var infoHashV2: Data?
    /// `dn`: a name to show until the metadata arrives.
    public var displayName: String?
    /// `tr`: tracker announce URLs.
    public var trackers: [URL]
    /// `ws`: web seeds.
    public var webSeeds: [URL]
    /// `x.pe`: peer addresses ("host:port").
    public var peers: [String]
    /// `so` (BEP 53): the file indices to download, when the link narrows them.
    public var selectedFiles: IndexSet?
    /// `xl`: total size, when given.
    public var exactLength: Int64?

    /// Parses a magnet URI, or a bare info hash (40 hex or 32 base32
    /// characters for v1, 64 hex for v2). Nil if there's no valid hash.
    public init?(string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        trackers = []
        webSeeds = []
        peers = []
        if !text.lowercased().hasPrefix("magnet:") {
            if let v1 = Self.v1Hash(text) {
                infoHashV1 = v1
            } else if text.count == 64, let v2 = Data(hex: text) {
                infoHashV2 = v2
            } else {
                return nil
            }
            return
        }
        guard let query = text.firstIndex(of: "?").map({ text[text.index(after: $0)...] }) else { return nil }
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let rawKey = String(parts[0]).lowercased()
            let value = Self.decode(String(parts[1]))
            // Repeated parameters may carry a ".N" suffix (xt.1, tr.2).
            let key = rawKey.split(separator: ".", maxSplits: 1).first.map(String.init) == "x"
                ? rawKey
                : String(rawKey.split(separator: ".").first ?? "")
            switch key {
            case "xt":
                let lower = value.lowercased()
                if lower.hasPrefix("urn:btih:") {
                    if infoHashV1 == nil { infoHashV1 = Self.v1Hash(String(value.dropFirst(9))) }
                } else if lower.hasPrefix("urn:btmh:") {
                    // Multihash: 0x12 (sha2-256), 0x20 (32 bytes), then the digest.
                    let hex = String(value.dropFirst(9))
                    if hex.count == 68, hex.lowercased().hasPrefix("1220"), let digest = Data(hex: String(hex.dropFirst(4))) {
                        infoHashV2 = infoHashV2 ?? digest
                    }
                }
            case "dn":
                if !value.isEmpty { displayName = value }
            case "tr":
                if let url = URL(string: value), url.scheme != nil, !trackers.contains(url) { trackers.append(url) }
            case "ws":
                if let url = URL(string: value), url.scheme != nil { webSeeds.append(url) }
            case "x.pe":
                if !value.isEmpty { peers.append(value) }
            case "so":
                selectedFiles = Self.indexSet(value)
            case "xl":
                exactLength = Int64(value)
            default:
                continue
            }
        }
        guard infoHashV1 != nil || infoHashV2 != nil else { return nil }
    }

    /// Bluebox's key for a torrent (and its stream cache folder): the v1 hash
    /// in lowercase hex, or the v2 hash for v2-only torrents. Matches the
    /// engine's `BBTorrentHandle.infoHash`.
    public var key: String {
        if let infoHashV1 { return infoHashV1.hexString }
        return infoHashV2?.hexString ?? ""
    }

    /// A canonical magnet URI with everything this link carries.
    public var uri: String {
        var items: [String] = []
        if let infoHashV1 { items.append("xt=urn:btih:\(infoHashV1.hexString)") }
        if let infoHashV2 { items.append("xt=urn:btmh:1220\(infoHashV2.hexString)") }
        if let displayName { items.append("dn=\(Self.encode(displayName))") }
        if let exactLength { items.append("xl=\(exactLength)") }
        items += trackers.map { "tr=\(Self.encode($0.absoluteString))" }
        items += webSeeds.map { "ws=\(Self.encode($0.absoluteString))" }
        items += peers.map { "x.pe=\(Self.encode($0))" }
        if let selectedFiles, !selectedFiles.isEmpty {
            let ranges = selectedFiles.rangeView.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound - 1)" }
            items.append("so=\(ranges.joined(separator: ","))")
        }
        return "magnet:?" + items.joined(separator: "&")
    }

    // MARK: Parsing helpers

    /// 40 hex characters, or 32 base32 characters (RFC 4648 alphabet).
    static func v1Hash(_ text: String) -> Data? {
        if text.count == 40 { return Data(hex: text) }
        if text.count == 32 { return base32Decode(text) }
        return nil
    }

    static func base32Decode(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt32] = [:]
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt32(i) }
        var buffer: UInt32 = 0
        var bits = 0
        var out = Data()
        for c in text.uppercased() where c != "=" {
            guard let v = lookup[c] else { return nil }
            buffer = (buffer << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return out.count == 20 ? out : nil
    }

    /// "0,2,4-6" → {0, 2, 4, 5, 6}. Invalid parts are skipped.
    static func indexSet(_ text: String) -> IndexSet? {
        var set = IndexSet()
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: "-", maxSplits: 1)
            if bounds.count == 2, let a = Int(bounds[0]), let b = Int(bounds[1]), a >= 0, b >= a, b - a < 100_000 {
                set.insert(integersIn: a...b)
            } else if bounds.count == 1, let a = Int(bounds[0]), a >= 0 {
                set.insert(a)
            }
        }
        return set.isEmpty ? nil : set
    }

    /// Percent-decoding that also treats "+" as a space (as form encoding does).
    static func decode(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    static func encode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

extension Data {
    /// Lowercase hex.
    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var chars = [UInt8]()
        chars.reserveCapacity(count * 2)
        for b in self {
            chars.append(digits[Int(b >> 4)])
            chars.append(digits[Int(b & 15)])
        }
        return String(decoding: chars, as: UTF8.self)
    }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var high: UInt8?
        for c in hex.utf8 {
            let v: UInt8
            switch c {
            case 48...57: v = c - 48
            case 65...70: v = c - 55
            case 97...102: v = c - 87
            default: return nil
            }
            if let h = high {
                out.append(h << 4 | v)
                high = nil
            } else {
                high = v
            }
        }
        self = out
    }
}
