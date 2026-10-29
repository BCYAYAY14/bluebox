import Foundation

public struct PeerAddress: Hashable, Sendable {
    public let host: String
    public let port: UInt16
}

public struct AnnounceResult: Sendable, Equatable {
    public var peers: [PeerAddress]
    public var interval: TimeInterval
}

public struct AnnounceRequest: Sendable {
    public var infoHash: InfoHash
    public var peerID: Data
    public var port: UInt16 = 6881
    public var downloaded: Int64 = 0
    public var left: Int64 = 0
    public var uploaded: Int64 = 0
    public var event: String? = "started"
}

/// HTTP(S) and UDP (BEP 15) tracker announces.
public enum Tracker {
    public typealias Fetch = @Sendable (URLRequest) async throws -> Data

    public static func announce(_ url: URL, _ req: AnnounceRequest, fetch: Fetch) async throws -> AnnounceResult {
        switch url.scheme?.lowercased() {
        case "udp": return try await announceUDP(url, req)
        case "http", "https": return try await announceHTTP(url, req, fetch: fetch)
        default: throw TorrentError.noTrackers
        }
    }

    // MARK: HTTP

    static func httpURL(_ url: URL, _ r: AnnounceRequest) -> URL? {
        func enc(_ d: Data) -> String {
            d.map { b in
                let c = Character(UnicodeScalar(b))
                return (c.isASCII && (c.isLetter || c.isNumber) || "-_.~".contains(c)) ? String(c) : String(format: "%%%02X", b)
            }.joined()
        }
        var q = "info_hash=\(enc(r.infoHash.bytes))&peer_id=\(enc(r.peerID))&port=\(r.port)"
            + "&uploaded=\(r.uploaded)&downloaded=\(r.downloaded)&left=\(r.left)&compact=1&numwant=80"
        if let e = r.event { q += "&event=\(e)" }
        let s = url.absoluteString
        return URL(string: s + (s.contains("?") ? "&" : "?") + q)
    }

    static func announceHTTP(_ url: URL, _ r: AnnounceRequest, fetch: Fetch) async throws -> AnnounceResult {
        guard let u = httpURL(url, r) else { throw TorrentError.noTrackers }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        return try parseHTTPResponse(try await fetch(req))
    }

    static func parseHTTPResponse(_ data: Data) throws -> AnnounceResult {
        let v = try Bencode.decode(data)
        if let reason = v["failure reason"]?.string { throw TorrentError.storage("tracker: \(reason)") }
        var peers: [PeerAddress] = []
        if let compact = v["peers"]?.data { peers += compactPeers(compact, ipv6: false) }
        if let list = v["peers"]?.list {
            peers += list.compactMap { p in
                guard let ip = p["ip"]?.string, let port = p["port"]?.int, (1...65535).contains(port) else { return nil }
                return PeerAddress(host: ip, port: UInt16(port))
            }
        }
        if let six = v["peers6"]?.data { peers += compactPeers(six, ipv6: true) }
        let interval = TimeInterval(v["interval"]?.int ?? 1800)
        return AnnounceResult(peers: peers, interval: min(max(interval, 60), 3600))
    }

    static func compactPeers(_ d: Data, ipv6: Bool) -> [PeerAddress] {
        let stride = ipv6 ? 18 : 6
        let bytes = [UInt8](d)
        var out: [PeerAddress] = []
        var i = 0
        while i + stride <= bytes.count {
            let ipBytes = bytes[i..<(i + stride - 2)]
            let host: String
            if ipv6 {
                host = Swift.stride(from: 0, to: 16, by: 2).map { String(format: "%x", UInt16(ipBytes[ipBytes.startIndex + $0]) << 8 | UInt16(ipBytes[ipBytes.startIndex + $0 + 1])) }.joined(separator: ":")
            } else {
                host = ipBytes.map(String.init).joined(separator: ".")
            }
            let port = UInt16(bytes[i + stride - 2]) << 8 | UInt16(bytes[i + stride - 1])
            if port > 0 { out.append(PeerAddress(host: host, port: port)) }
            i += stride
        }
        return out
    }

    // MARK: UDP (BEP 15)

    static func announceUDP(_ url: URL, _ r: AnnounceRequest) async throws -> AnnounceResult {
        guard let host = url.host(), let port = url.port, (1...65535).contains(port) else { throw TorrentError.noTrackers }
        let sock = Socket(host: host, port: UInt16(port), udp: true)
        defer { sock.close() }
        try await sock.open(timeout: 10)

        let tx1 = UInt32.random(in: .min ... .max)
        var connect = Data()
        connect.appendBE(UInt64(0x41727101980)); connect.appendBE(UInt32(0)); connect.appendBE(tx1)
        try await sock.send(connect)
        let cr = try await withTimeout(10, onTimeout: { sock.close() }) { try await sock.receiveDatagram() }
        guard cr.readBE(UInt32.self, at: 0) == 0, cr.readBE(UInt32.self, at: 4) == tx1,
              let connID = cr.readBE(UInt64.self, at: 8) else { throw TorrentError.noPeers }

        let tx2 = UInt32.random(in: .min ... .max)
        var a = Data()
        a.appendBE(connID); a.appendBE(UInt32(1)); a.appendBE(tx2)
        a.append(r.infoHash.bytes); a.append(r.peerID)
        a.appendBE(r.downloaded); a.appendBE(r.left); a.appendBE(r.uploaded)
        a.appendBE(UInt32(r.event == "started" ? 2 : r.event == "completed" ? 1 : r.event == "stopped" ? 3 : 0))
        a.appendBE(UInt32(0)); a.appendBE(UInt32.random(in: .min ... .max)); a.appendBE(Int32(-1)); a.appendBE(r.port)
        try await sock.send(a)
        let ar = try await withTimeout(10, onTimeout: { sock.close() }) { try await sock.receiveDatagram() }
        guard ar.readBE(UInt32.self, at: 0) == 1, ar.readBE(UInt32.self, at: 4) == tx2,
              let interval = ar.readBE(UInt32.self, at: 8) else { throw TorrentError.noPeers }
        return AnnounceResult(peers: compactPeers(ar.dropFirst(20), ipv6: false),
                              interval: min(max(TimeInterval(interval), 60), 3600))
    }
}
