import CryptoKit
import Foundation

/// Which pieces a side has, in wire order (high bit of byte 0 is piece 0).
public struct Bitfield: Equatable, Sendable {
    public private(set) var bytes: [UInt8]
    public let count: Int

    public init(count: Int) {
        self.count = count
        bytes = [UInt8](repeating: 0, count: (count + 7) / 8)
    }

    /// From a peer's bitfield message; spare bits must be zero.
    public init?(bytes: [UInt8], count: Int) {
        guard bytes.count == (count + 7) / 8 else { return nil }
        self.bytes = bytes; self.count = count
        let spare = bytes.count * 8 - count
        if spare > 0, bytes[bytes.count - 1] & UInt8((1 << spare) - 1) != 0 { return nil }
    }

    public subscript(i: Int) -> Bool {
        get { i >= 0 && i < count && bytes[i >> 3] & (0x80 >> UInt8(i & 7)) != 0 }
        set {
            guard i >= 0 && i < count else { return }
            if newValue { bytes[i >> 3] |= 0x80 >> UInt8(i & 7) } else { bytes[i >> 3] &= ~(0x80 >> UInt8(i & 7)) }
        }
    }

    public var setCount: Int { bytes.reduce(0) { $0 + $1.nonzeroBitCount } }
    public var isComplete: Bool { setCount == count }

    public static func full(_ count: Int) -> Bitfield {
        var b = Bitfield(count: count)
        for i in 0..<count { b[i] = true }
        return b
    }
}

/// Writes verified pieces into the torrent's files and reads them back.
/// Owned by one `TorrentSession`; not thread-safe on its own.
final class PieceStorage {
    let root: URL
    let info: TorrentInfo
    private(set) var have: Bitfield
    private var handles: [Int: FileHandle] = [:]
    private var stateURL: URL { root.appending(path: ".bluebox-pieces") }
    private var unsavedPieces = 0

    init(root: URL, info: TorrentInfo) throws {
        self.root = root; self.info = info
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: root.appending(path: ".bluebox-pieces")),
           let saved = Bitfield(bytes: [UInt8](data), count: info.pieceCount) {
            have = saved
        } else {
            have = Bitfield(count: info.pieceCount)
        }
    }

    deinit { handles.values.forEach { try? $0.close() } }

    func url(ofFile index: Int) -> URL {
        let f = info.files[index]
        var u = info.isSingleFile ? root : root.appending(path: info.name, directoryHint: .isDirectory)
        for c in f.path { u = u.appending(path: c) }
        return u
    }

    static func verify(_ data: Data, against hash: Data) -> Bool {
        Data(Insecure.SHA1.hash(data: data)) == hash
    }

    /// Verifies and stores a whole piece. Returns false if the hash doesn't match.
    func store(piece i: Int, data: Data) throws -> Bool {
        guard i >= 0, i < info.pieceCount, data.count == info.length(ofPiece: i),
              Self.verify(data, against: info.pieceHashes[i]) else { return false }
        if have[i] { return true }
        var cursor = Int64(i) * Int64(info.pieceLength)
        var remaining = data[...]
        for (fi, f) in info.files.enumerated() where f.offset + f.length > cursor && !remaining.isEmpty {
            if f.offset > cursor {  // skip a padding gap (BEP 47)
                let gap = Int(min(f.offset - cursor, Int64(remaining.count)))
                remaining = remaining.dropFirst(gap); cursor += Int64(gap)
                if remaining.isEmpty { break }
            }
            let within = cursor - f.offset
            let n = Int(min(Int64(remaining.count), f.length - within))
            guard n > 0 else { continue }
            let h = try handle(fi)
            try h.seek(toOffset: UInt64(within))
            try h.write(contentsOf: remaining.prefix(n))
            remaining = remaining.dropFirst(n)
            cursor += Int64(n)
        }
        have[i] = true
        unsavedPieces += 1
        if unsavedPieces >= 8 || have.isComplete { saveState() }
        return true
    }

    /// Reads a torrent-wide byte range. Callers check `have` first.
    func read(offset: Int64, length: Int) throws -> Data {
        var out = Data(capacity: length)
        var cursor = offset
        let end = offset + Int64(length)
        for (fi, f) in info.files.enumerated() where f.offset + f.length > cursor && f.offset < end {
            // Padding gaps (BEP 47) read as zeros.
            if f.offset > cursor { out.append(Data(count: Int(f.offset - cursor))); cursor = f.offset }
            let n = Int(min(end, f.offset + f.length) - cursor)
            let h = try handle(fi)
            try h.seek(toOffset: UInt64(cursor - f.offset))
            let chunk = try h.read(upToCount: n) ?? Data()
            out.append(chunk)
            if chunk.count < n { out.append(Data(count: n - chunk.count)) }
            cursor += Int64(n)
        }
        if out.count < length { out.append(Data(count: length - out.count)) }
        return out
    }

    func readPiece(_ i: Int) throws -> Data {
        try read(offset: Int64(i) * Int64(info.pieceLength), length: info.length(ofPiece: i))
    }

    func saveState() {
        unsavedPieces = 0
        try? Data(have.bytes).write(to: stateURL, options: .atomic)
    }

    private func handle(_ index: Int) throws -> FileHandle {
        if let h = handles[index] { return h }
        let u = url(ofFile: index)
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: u.path) {
                guard FileManager.default.createFile(atPath: u.path, contents: nil) else { throw TorrentError.storage("can't create \(u.lastPathComponent)") }
            }
            let h = try FileHandle(forUpdating: u)
            handles[index] = h
            return h
        } catch let e as TorrentError { throw e }
        catch { throw TorrentError.storage(error.localizedDescription) }
    }
}
