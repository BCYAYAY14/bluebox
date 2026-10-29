import Foundation

/// A bencoded value (BEP 3).
public indirect enum BValue: Equatable, Sendable {
    case int(Int64)
    case bytes(Data)
    case list([BValue])
    case dict([String: BValue])

    public subscript(key: String) -> BValue? {
        if case .dict(let d) = self { return d[key] }
        return nil
    }

    public var int: Int64? { if case .int(let v) = self { v } else { nil } }
    public var data: Data? { if case .bytes(let v) = self { v } else { nil } }
    public var string: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
    public var list: [BValue]? { if case .list(let v) = self { v } else { nil } }
    public var dict: [String: BValue]? { if case .dict(let v) = self { v } else { nil } }

    public static func str(_ s: String) -> BValue { .bytes(Data(s.utf8)) }
}

public enum BencodeError: Error, Equatable, Sendable {
    case malformed(String)
    case tooDeep
}

public enum Bencode {
    static let maxDepth = 64

    /// Decodes exactly one value spanning all of `data`.
    public static func decode(_ data: Data) throws -> BValue {
        var p = Parser(bytes: [UInt8](data))
        let v = try p.value(depth: 0)
        guard p.i == p.bytes.count else { throw BencodeError.malformed("trailing bytes") }
        return v
    }

    /// Decodes one value at the start of `data`; returns it and how many bytes it used.
    /// (ut_metadata messages carry raw bytes after the dictionary.)
    public static func decodePrefix(_ data: Data) throws -> (BValue, Int) {
        var p = Parser(bytes: [UInt8](data))
        let v = try p.value(depth: 0)
        return (v, p.i)
    }

    /// The exact bytes of the top-level `info` value, which the info hash covers.
    public static func rawInfo(in data: Data) throws -> Data? {
        var p = Parser(bytes: [UInt8](data))
        p.captureKey = "info"
        _ = try p.value(depth: 0)
        return p.captured.map { Data(p.bytes[$0]) }
    }

    public static func encode(_ v: BValue) -> Data {
        var out = Data()
        write(v, into: &out)
        return out
    }

    private static func write(_ v: BValue, into out: inout Data) {
        switch v {
        case .int(let i): out.append(contentsOf: Array("i\(i)e".utf8))
        case .bytes(let d): out.append(contentsOf: Array("\(d.count):".utf8)); out.append(d)
        case .list(let l): out.append(UInt8(ascii: "l")); l.forEach { write($0, into: &out) }; out.append(UInt8(ascii: "e"))
        case .dict(let d):
            out.append(UInt8(ascii: "d"))
            // Keys sort as raw byte strings.
            for k in d.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                write(.str(k), into: &out); write(d[k]!, into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0
        var captureKey: String?
        var captured: Range<Int>?

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func value(depth: Int) throws -> BValue {
            guard depth < Bencode.maxDepth else { throw BencodeError.tooDeep }
            guard i < bytes.count else { throw BencodeError.malformed("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "i"):
                i += 1
                let end = try find(UInt8(ascii: "e"))
                guard let s = String(bytes: bytes[i..<end], encoding: .ascii), let v = Int64(s),
                      s == String(v) else { throw BencodeError.malformed("integer") }
                i = end + 1
                return .int(v)
            case UInt8(ascii: "l"):
                i += 1
                var out: [BValue] = []
                while true {
                    guard i < bytes.count else { throw BencodeError.malformed("unterminated list") }
                    if bytes[i] == UInt8(ascii: "e") { i += 1; return .list(out) }
                    out.append(try value(depth: depth + 1))
                }
            case UInt8(ascii: "d"):
                i += 1
                var out: [String: BValue] = [:]
                while true {
                    guard i < bytes.count else { throw BencodeError.malformed("unterminated dict") }
                    if bytes[i] == UInt8(ascii: "e") { i += 1; return .dict(out) }
                    guard case .bytes(let kd) = try value(depth: depth + 1) else { throw BencodeError.malformed("dict key") }
                    let key = String(decoding: kd, as: UTF8.self)
                    let start = i
                    let v = try value(depth: depth + 1)
                    if depth == 0, key == captureKey { captured = start..<i }
                    out[key] = v
                }
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                let colon = try find(UInt8(ascii: ":"))
                // Compare against what's left rather than adding: a huge length from a peer must not overflow.
                guard let s = String(bytes: bytes[i..<colon], encoding: .ascii), let n = Int(s), n >= 0,
                      n <= bytes.count - colon - 1 else { throw BencodeError.malformed("string length") }
                i = colon + 1 + n
                return .bytes(Data(bytes[(colon + 1)..<i]))
            default:
                throw BencodeError.malformed("unexpected byte \(bytes[i])")
            }
        }

        func find(_ b: UInt8) throws -> Int {
            var j = i
            while j < bytes.count, j - i < 32 { if bytes[j] == b { return j }; j += 1 }
            throw BencodeError.malformed("missing delimiter")
        }
    }
}
