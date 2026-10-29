//
//  StreamServer.swift
//  Bluebox
//
//  A small HTTP/1.1 server on 127.0.0.1 that serves streaming files to the
//  player (AVPlayer and VLC both read it like any web video). Written for
//  Bluebox with Network.framework from RFC 9110/9112: GET and HEAD, single
//  byte ranges with 206 and 416, keep-alive, and any number of concurrent
//  connections (players open several: one for the picture, one for the
//  index at the end). A read waits for the torrent to deliver, never
//  forever: the file's read throws after its timeout and the connection
//  closes, which players treat as a network error and retry.
//

import Foundation
import Network

/// Something the server can serve: a file whose bytes may still be arriving.
protocol StreamableFile: AnyObject, Sendable {
    var length: Int64 { get }
    var fileName: String { get }
    /// Up to `maxLength` bytes at `offset`, waiting for them if needed. May
    /// return fewer (up to the end of a piece) but never zero before the end.
    func read(offset: Int64, maxLength: Int, reader: UUID) async throws -> Data
    /// A connection started reading at `offset` (a new request or a seek).
    func readerStarted(_ reader: UUID, at offset: Int64)
    /// A connection has sent everything before `offset`.
    func readerAdvanced(_ reader: UUID, to offset: Int64)
    func readerFinished(_ reader: UUID)
}

final class StreamServer: @unchecked Sendable {
    static let shared = StreamServer()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.bluebox.stream-server")
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var files: [String: any StreamableFile] = [:]
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    var port: UInt16 { lock.withLock { boundPort } }

    /// Starts listening (once) on 127.0.0.1, on `preferredPort` if it's free,
    /// else on any port. Returns the port.
    @discardableResult
    func start(preferredPort: UInt16) async throws -> UInt16 {
        if let port = lock.withLock({ listener != nil ? boundPort : nil }) { return port }
        do {
            return try await listen(on: preferredPort)
        } catch {
            torrentLog.notice("stream server: port \(preferredPort) unavailable; using any port")
            return try await listen(on: 0)
        }
    }

    private func listen(on port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? port) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) } else { self?.listenerFailed(listener) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock {
            self.listener = listener
            boundPort = ready
        }
        torrentLog.notice("stream server: listening on 127.0.0.1:\(ready)")
        return ready
    }

    private func listenerFailed(_ failed: NWListener) {
        lock.withLock {
            if listener === failed { listener = nil }
        }
        failed.cancel()
    }

    /// Serves `file` and returns its URL, `/stream/<token>.<ext>`: the
    /// extension lets players tell the container from the URL.
    func register(_ file: any StreamableFile) -> URL {
        let token = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))
        let port = lock.withLock {
            files[token] = file
            return boundPort
        }
        let ext = (file.fileName as NSString).pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        return URL(string: "http://127.0.0.1:\(port)/stream/\(token)\(ext.isEmpty ? "" : ".\(ext)")")!
    }

    /// Stops serving the file at `url`; its open connections close.
    func unregister(_ url: URL) {
        guard let token = Self.token(in: url) else { return }
        let closing: [HTTPConnection] = lock.withLock {
            guard let file = files.removeValue(forKey: token) else { return [] }
            return connections.values.filter { $0.serving === file }
        }
        closing.forEach { $0.close() }
    }

    func file(for url: URL) -> (any StreamableFile)? {
        guard let token = Self.token(in: url) else { return nil }
        return lock.withLock { files[token] }
    }

    func file(token: String) -> (any StreamableFile)? {
        lock.withLock { files[token] }
    }

    static func token(in url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "stream" else { return nil }
        return String(parts[1].split(separator: ".").first ?? parts[1])
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let http = HTTPConnection(connection: connection, server: self)
        lock.withLock { connections[ObjectIdentifier(http)] = http }
        http.start(queue: queue)
    }

    fileprivate func finished(_ http: HTTPConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(http)) }
    }

    var openConnections: Int { lock.withLock { connections.count } }
}

/// Resumes a continuation once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// One client connection: reads requests and answers them in turn.
private final class HTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    weak var server: StreamServer?
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var buffer = Data()
    private var _serving: (any StreamableFile)?

    var serving: (any StreamableFile)? { lock.withLock { _serving } }

    init(connection: NWConnection, server: StreamServer) {
        self.connection = connection
        self.server = server
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.run()
        }
        lock.withLock { self.task = task }
    }

    func close() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            defer { self.task = nil }
            return self.task
        }
        task?.cancel()
        connection.cancel()
        server?.finished(self)
    }

    private func run() async {
        defer { close() }
        while !Task.isCancelled {
            guard let head = await readRequestHead() else { return }
            guard let request = HTTPRequestHead(head) else {
                await sendHead(status: "400 Bad Request", headers: ["Content-Length": "0", "Connection": "close"])
                return
            }
            let keepAlive = await respond(to: request)
            if !keepAlive || request.wantsClose { return }
        }
    }

    /// Bytes up to the blank line after the headers; nil when the client closed.
    private func readRequestHead() async -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let end = buffer.range(of: separator) {
                let head = buffer[buffer.startIndex..<end.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                return Data(head)
            }
            guard buffer.count < 32 * 1024 else { return nil }
            guard let chunk = await receive() else { return nil }
            buffer.append(chunk)
        }
    }

    private func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    @discardableResult
    private func sendHead(status: String, headers: [(String, String)]) async -> Bool {
        var text = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return await send(Data(text.utf8))
    }

    private func sendHead(status: String, headers: [String: String]) async {
        await sendHead(status: status, headers: headers.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    /// Answers one request. Returns whether the connection can be reused.
    private func respond(to request: HTTPRequestHead) async -> Bool {
        guard request.method == "GET" || request.method == "HEAD" else {
            await sendHead(status: "405 Method Not Allowed", headers: ["Allow": "GET, HEAD", "Content-Length": "0"])
            return true
        }
        guard let url = URL(string: "http://127.0.0.1\(request.path)"), let token = StreamServer.token(in: url),
              let file = server?.file(token: token) else {
            await sendHead(status: "404 Not Found", headers: ["Content-Length": "0"])
            return true
        }
        lock.withLock { _serving = file }
        let length = file.length
        let type = MediaContentType.forFile(file.fileName)
        var headers: [(String, String)] = [("Content-Type", type), ("Accept-Ranges", "bytes"),
                                           ("Cache-Control", "no-store"), ("Connection", "keep-alive")]
        let range: ClosedRange<Int64>
        let status: String
        switch HTTPRangeResult.resolve(request.range, length: length) {
        case .whole:
            guard length > 0 else {
                await sendHead(status: "200 OK", headers: headers + [("Content-Length", "0")])
                return true
            }
            range = 0...(length - 1)
            status = "200 OK"
            headers.append(("Content-Length", "\(length)"))
        case .partial(let r):
            range = r
            status = "206 Partial Content"
            headers.append(("Content-Length", "\(r.upperBound - r.lowerBound + 1)"))
            headers.append(("Content-Range", "bytes \(r.lowerBound)-\(r.upperBound)/\(length)"))
        case .unsatisfiable:
            await sendHead(status: "416 Range Not Satisfiable",
                           headers: [("Content-Range", "bytes */\(length)"), ("Content-Length", "0")])
            return true
        }
        guard await sendHead(status: status, headers: headers) else { return false }
        if request.method == "HEAD" { return true }

        let reader = UUID()
        file.readerStarted(reader, at: range.lowerBound)
        defer { file.readerFinished(reader) }
        var offset = range.lowerBound
        let end = range.upperBound + 1
        while offset < end {
            if Task.isCancelled { return false }
            let data: Data
            do {
                data = try await file.read(offset: offset, maxLength: Int(min(end - offset, 1024 * 1024)), reader: reader)
            } catch {
                torrentLog.notice("stream server: read at \(offset) failed: \(error.localizedDescription, privacy: .public); closing")
                return false
            }
            guard !data.isEmpty else { return false }
            guard await send(data) else { return false }
            offset += Int64(data.count)
            file.readerAdvanced(reader, to: offset)
        }
        return true
    }
}
