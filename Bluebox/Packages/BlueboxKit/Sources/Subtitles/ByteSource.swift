import Foundation

/// Random access to the bytes of a video, wherever it is: a file, a web
/// server, or Bluebox's torrent stream server (which waits for pieces that
/// haven't arrived, so a read near the playhead returns once they have).
public protocol ByteSource: Sendable {
    func length() async throws -> Int64
    /// The bytes in `range`, clipped to the end of the file.
    func read(_ range: Range<Int64>) async throws -> Data
}

public enum ByteSourceError: Error, Equatable, Sendable {
    case unreadable
    case noRanges
}

/// A source for a playback URL: files are read directly, http(s) with range requests.
public func byteSource(for url: URL, headers: [String: String] = [:]) -> (any ByteSource)? {
    if url.isFileURL { return FileByteSource(url: url) }
    if url.scheme == "http" || url.scheme == "https" { return HTTPByteSource(url: url, headers: headers) }
    return nil
}

public struct FileByteSource: ByteSource {
    let url: URL
    public init(url: URL) { self.url = url }

    public func length() async throws -> Int64 {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size else { throw ByteSourceError.unreadable }
        return size.int64Value
    }

    public func read(_ range: Range<Int64>) async throws -> Data {
        let url = url
        return try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(max(0, range.lowerBound)))
            return try handle.read(upToCount: range.count) ?? Data()
        }.value
    }
}

/// Range requests over HTTP. The length comes from the first response's Content-Range.
public final class HTTPByteSource: ByteSource, @unchecked Sendable {
    let url: URL
    let headers: [String: String]
    private let session: URLSession
    private let lock = NSLock()
    private var total: Int64?

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
        let config = URLSessionConfiguration.ephemeral
        // The torrent stream server waits for pieces, never forever (its own timeout is shorter).
        config.timeoutIntervalForRequest = 45
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    deinit { session.invalidateAndCancel() }

    public func length() async throws -> Int64 {
        if let total = lock.withLock({ total }) { return total }
        _ = try await read(0..<1)
        guard let total = lock.withLock({ total }) else { throw ByteSourceError.noRanges }
        return total
    }

    public func read(_ range: Range<Int64>) async throws -> Data {
        guard !range.isEmpty else { return Data() }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ByteSourceError.unreadable }
        if http.statusCode == 416 { return Data() }
        // A server that ignores ranges sends the whole file: no use for reading near the playhead.
        guard http.statusCode == 206 else { throw ByteSourceError.noRanges }
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/"), let length = Int64(contentRange[contentRange.index(after: slash)...]) {
            lock.withLock { total = length }
        }
        return data
    }
}
