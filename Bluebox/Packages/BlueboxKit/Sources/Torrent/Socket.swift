import Foundation
import Network

/// Async wrapper over `NWConnection` for TCP streams and UDP datagrams.
final class Socket: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "bluebox.torrent.socket")
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var finished = false

    init(host: String, port: UInt16, udp: Bool = false) {
        let params: NWParameters = udp ? .udp : .tcp
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 6881, using: params)
    }

    /// Connects, failing after `timeout` seconds.
    func open(timeout: TimeInterval) async throws {
        try await withTimeout(timeout, onTimeout: { self.close() }) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let closed = self.lock.withLock { () -> Bool in
                    if !self.finished { self.readyContinuation = c }
                    return self.finished
                }
                if closed { c.resume(throwing: TorrentError.cancelled); return }
                self.conn.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.resumeReady(nil)
                    case .failed(let e): self.resumeReady(e)
                    case .waiting(let e): self.resumeReady(e)
                    case .cancelled: self.resumeReady(TorrentError.cancelled)
                    default: break
                    }
                }
                self.conn.start(queue: self.queue)
            }
        }
    }

    private func resumeReady(_ error: Error?) {
        let c: CheckedContinuation<Void, Error>? = lock.withLock {
            defer { readyContinuation = nil }
            return readyContinuation
        }
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    /// Reads exactly `count` bytes from a TCP stream.
    func receive(exactly count: Int) async throws -> Data {
        if count == 0 { return Data() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
                if let error { c.resume(throwing: error) }
                else if let data, data.count == count { c.resume(returning: data) }
                else if complete { c.resume(throwing: TorrentError.cancelled) }
                else { c.resume(throwing: TorrentError.cancelled) }
            }
        }
    }

    /// Reads one UDP datagram.
    func receiveDatagram() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            conn.receiveMessage { data, _, _, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data ?? Data()) }
            }
        }
    }

    func close() {
        let already = lock.withLock { defer { finished = true }; return finished }
        guard !already else { return }
        conn.cancel()
        resumeReady(TorrentError.cancelled)
    }

    deinit { conn.cancel() }
}

struct TimeoutError: Error {}

/// Runs `body`, throwing `TimeoutError` if it takes longer than `seconds`.
/// `onTimeout` must make `body` return (e.g. close its socket): the group
/// waits for every child before it can throw.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void = {},
                              _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            onTimeout()
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Big-endian integer packing for wire formats.
extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }

    func readBE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return nil }
        var v: T = 0
        for b in self[(startIndex + offset)..<(startIndex + offset + size)] { v = (v << 8) | T(b) }
        return v
    }
}
