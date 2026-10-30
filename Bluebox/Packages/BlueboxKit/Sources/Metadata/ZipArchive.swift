import Compression
import Foundation

/// Reads the files out of a ZIP archive (stored or deflated), which is how
/// Subdl and Podnapisi hand out subtitles. Small archives only: everything
/// is in memory.
public enum ZipArchive {
    public struct Entry: Equatable, Sendable {
        public var path: String
        public var data: Data
    }

    /// Every file in the archive, from its central directory (so sizes are
    /// right even when the local headers leave them out).
    public static func entries(_ zip: Data) -> [Entry] {
        let bytes = [UInt8](zip)
        guard let end = endOfCentralDirectory(bytes) else { return [] }
        let count = Int(u16(bytes, end + 10))
        var p = Int(u32(bytes, end + 16))
        var out: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(bytes, p) == 0x0201_4B50 else { break }
            let method = u16(bytes, p + 10)
            let compressed = Int(u32(bytes, p + 20)), size = Int(u32(bytes, p + 24))
            let nameLength = Int(u16(bytes, p + 28)), extra = Int(u16(bytes, p + 30)), comment = Int(u16(bytes, p + 32))
            let local = Int(u32(bytes, p + 42))
            guard p + 46 + nameLength <= bytes.count else { break }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extra + comment
            guard !name.hasSuffix("/"), local + 30 <= bytes.count, u32(bytes, local) == 0x0403_4B50 else { continue }
            let start = local + 30 + Int(u16(bytes, local + 26)) + Int(u16(bytes, local + 28))
            guard start + compressed <= bytes.count, size < 50_000_000 else { continue }
            let body = Data(bytes[start..<(start + compressed)])
            switch method {
            case 0: out.append(Entry(path: name, data: body))
            case 8: if let d = inflate(body, size: size) { out.append(Entry(path: name, data: d)) }
            default: continue
            }
        }
        return out
    }

    /// True when the data starts like a ZIP archive.
    public static func isZip(_ data: Data) -> Bool { data.starts(with: [0x50, 0x4B, 0x03, 0x04]) }

    static func endOfCentralDirectory(_ b: [UInt8]) -> Int? {
        guard b.count >= 22 else { return nil }
        var i = b.count - 22
        let stop = max(0, b.count - 22 - 65_535)
        while i >= stop {
            if u32(b, i) == 0x0605_4B50 { return i }
            i -= 1
        }
        return nil
    }

    static func inflate(_ data: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? out : nil
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { i + 2 <= b.count ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : 0 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        i + 4 <= b.count ? UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 : 0
    }
}
