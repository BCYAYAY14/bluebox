import Foundation
import Testing
@testable import TorrentStreaming
#if canImport(LibTorrentEngine)
import LibTorrentEngine

/// A live probe of the engine: adds a torrent by hash, asks for its largest
/// file with head deadlines, and prints what happens each second.
/// BLUEBOX_PROBE_HASH=<info hash> swift test --filter EngineProbeTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_PROBE_HASH"] != nil))
struct EngineProbeTests {
    @Test(.timeLimit(.minutes(3))) func probe() async throws {
        let hash = ProcessInfo.processInfo.environment["BLUEBOX_PROBE_HASH"]!
        let link = try #require(MagnetLink(string: hash))
        let folder = FileManager.default.temporaryDirectory.appending(path: "bb-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = TorrentEngine.shared
        if let tuning = ProcessInfo.processInfo.environment["BLUEBOX_PROBE_SETTINGS"], let session = engine.session {
            for pair in tuning.split(separator: ",") {
                let kv = pair.split(separator: "=")
                guard kv.count == 2, let v = Int(kv[1]) else { continue }
                let ok = session.setSetting(String(kv[0]), integer: v) || session.setSetting(String(kv[0]), boolean: v != 0)
                print("PROBE setting \(kv[0])=\(v) \(ok ? "ok" : "unknown")")
            }
        }
        let began = Date()
        let handle = try engine.acquire(link, user: "probe", savePath: folder)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            handle.waitForMetadata(timeout: 60) { e in if let e { c.resume(throwing: e) } else { c.resume() } }
        }
        print("PROBE metadata after \(Date().timeIntervalSince(began))s pieces=\(handle.pieceCount) len=\(handle.pieceLength)")
        let files = handle.files
        let file = try #require(files.max { $0.size < $1.size })
        let prio = Int(ProcessInfo.processInfo.environment["BLUEBOX_PROBE_PRIO"] ?? "7") ?? 7
        handle.setFilePriorities([NSNumber(value: file.index): NSNumber(value: prio)], user: "probe")
        let entry = TorrentFileEntry(index: file.index, path: file.path, size: file.size)
        let stream = TorrentStream(handle: handle, file: entry, offset: file.offset)
        if ProcessInfo.processInfo.environment["BLUEBOX_PROBE_NODEADLINE"] == nil {
            stream.requestStart(headBytes: 3 * 1024 * 1024, tail: (file.size - 1_048_576)..<file.size)
        }
        for _ in 0..<40 {
            try await Task.sleep(for: .seconds(1))
            let s = handle.status()
            let map = handle.pieceMap()
            let count = map.reduce(0) { $0 + Int($1) }
            let first = stream.span.firstPiece
            print(String(format: "PROBE t=%.0f peers=%d seeds=%d rate=%dKB/s down=%lldMB havePieces=%d p0=%d p1=%d last=%d state=%d",
                         Date().timeIntervalSince(began), s.peers, s.seeds, s.downloadRate / 1024, s.downloadedBytes / 1_048_576,
                         count, handle.havePiece(first) ? 1 : 0, handle.havePiece(first + 1) ? 1 : 0,
                         handle.havePiece(stream.span.lastPiece) ? 1 : 0, s.state.rawValue))
            if handle.havePiece(first) && handle.havePiece(first + 1) && handle.havePiece(stream.span.lastPiece) { break }
        }
        engine.release(handle, user: "probe", deleteFiles: true)
        TorrentEngine.shared.shutdown()
    }
}
#endif
