import Foundation

/// What another app (Infuse) reads from Bluebox's localhost stream server:
/// a torrent stream it already serves, or a finished file on disk that only
/// Bluebox can open (iOS keeps each app's files to itself).
public enum ExternalStreams {
    /// Serves the file at `fileURL` and returns its `http://127.0.0.1` URL.
    /// The caller holds any security-scoped access for as long as it's served.
    public static func serve(fileAt fileURL: URL) async throws -> URL {
        let file = try LocalFileStream(url: fileURL)
        try await StreamServer.shared.start(preferredPort: 0)
        return StreamServer.shared.register(file)
    }

    /// Stops serving a file from `serve(fileAt:)`.
    public static func stopServing(_ url: URL) {
        StreamServer.shared.unregister(url)
    }

    /// When the stream at `url` was last in use: now while a client is
    /// connected, else its last read (nil if never read). Nil `served`
    /// once the server no longer has it.
    public static func lastUse(of url: URL) -> (served: Bool, at: Date?) {
        guard let activity = StreamServer.shared.activity(for: url) else { return (false, nil) }
        return (true, activity.connected ? Date() : activity.lastRead)
    }
}

/// A complete file on disk, read on request.
final class LocalFileStream: StreamableFile, @unchecked Sendable {
    let length: Int64
    let fileName: String
    private let handle: FileHandle
    private let lock = NSLock()

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        length = Int64(size)
        fileName = url.lastPathComponent
    }

    deinit { try? handle.close() }

    func read(offset: Int64, maxLength: Int, reader: UUID) async throws -> Data {
        try lock.withLock {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: maxLength) ?? Data()
        }
    }

    func readerStarted(_ reader: UUID, at offset: Int64) {}
    func readerAdvanced(_ reader: UUID, to offset: Int64) {}
    func readerFinished(_ reader: UUID) {}
}
