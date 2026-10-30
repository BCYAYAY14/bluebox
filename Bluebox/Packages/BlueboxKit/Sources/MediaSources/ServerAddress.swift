import CryptoKit
import Foundation

/// A server address the user typed: https by default, plain http only on the
/// local network (the same rule as direct links).
enum ServerAddress {
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), let host = u.host(), !host.isEmpty else { return nil }
        if scheme == "https" { return u }
        if scheme == "http", DirectURLSource.isLocalNetworkHost(host) { return u }
        return nil
    }
}

/// HTTP authentication for servers that use a username and password (WebDAV).
/// Basic is sent up front; a server that answers with a Digest challenge gets
/// Digest from then on (RFC 7616, MD5 or SHA-256, qop "auth").
struct HTTPLogin: Sendable {
    let username: String
    let password: String

    var basicHeader: String { "Basic " + Data("\(username):\(password)".utf8).base64EncodedString() }

    struct DigestChallenge: Sendable, Equatable {
        var realm: String
        var nonce: String
        var opaque: String?
        var algorithm: String
        var qop: String?
    }

    /// The Digest challenge in a `WWW-Authenticate` header, which may also offer Basic.
    static func digestChallenge(in header: String) -> DigestChallenge? {
        guard let r = header.range(of: "digest ", options: .caseInsensitive) else { return nil }
        let params = parameters(String(header[r.upperBound...]))
        guard let realm = params["realm"], let nonce = params["nonce"] else { return nil }
        let qop = params["qop"].flatMap { list in
            list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.contains("auth") ? "auth" : nil
        }
        return DigestChallenge(realm: realm, nonce: nonce, opaque: params["opaque"],
                               algorithm: params["algorithm"]?.uppercased() ?? "MD5", qop: qop)
    }

    /// `key=value, key="quoted, value"` pairs, keys lowercased.
    static func parameters(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i] == " " || s[i] == "," { i = s.index(after: i) }
            guard let eq = s[i...].firstIndex(of: "=") else { break }
            let key = s[i..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            i = s.index(after: eq)
            var value = ""
            if i < s.endIndex, s[i] == "\"" {
                i = s.index(after: i)
                while i < s.endIndex, s[i] != "\"" {
                    if s[i] == "\\", s.index(after: i) < s.endIndex { i = s.index(after: i) }
                    value.append(s[i]); i = s.index(after: i)
                }
                if i < s.endIndex { i = s.index(after: i) }
            } else {
                let end = s[i...].firstIndex(of: ",") ?? s.endIndex
                value = s[i..<end].trimmingCharacters(in: .whitespaces)
                i = end
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    func digestHeader(_ c: DigestChallenge, method: String, uri: String, count: Int, cnonce: String) -> String? {
        let hash: (String) -> String
        switch c.algorithm {
        case "MD5": hash = { Insecure.MD5.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        case "SHA-256": hash = { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        default: return nil  // -sess variants and others aren't used by common servers
        }
        let ha1 = hash("\(username):\(c.realm):\(password)")
        let ha2 = hash("\(method):\(uri)")
        let nc = String(format: "%08x", count)
        let response = c.qop == nil ? hash("\(ha1):\(c.nonce):\(ha2)") : hash("\(ha1):\(c.nonce):\(nc):\(cnonce):auth:\(ha2)")
        var h = #"Digest username="\#(username)", realm="\#(c.realm)", nonce="\#(c.nonce)", uri="\#(uri)", algorithm=\#(c.algorithm), response="\#(response)""#
        if c.qop != nil { h += #", qop=auth, nc=\#(nc), cnonce="\#(cnonce)""# }
        if let o = c.opaque { h += #", opaque="\#(o)""# }
        return h
    }
}
