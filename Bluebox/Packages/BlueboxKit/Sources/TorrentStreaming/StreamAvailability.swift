import Foundation

/// Read-only: which parts of a file being streamed from a torrent are on disk.
///
/// The localhost stream server registers each stream here while it serves
/// it. Readers that must not disturb playback (preview thumbnails) read the
/// partial file directly, and only where the bytes have arrived: a request
/// through the stream server would move libtorrent's priorities to that spot.
public enum StreamAvailability {
    public struct Stream: Sendable {
        /// The file on disk (partial: undownloaded ranges hold zeros).
        public let fileURL: URL
        public let fileLength: Int64
        let check: @Sendable (Range<Int64>) -> Bool

        /// True when every byte in `range` (offsets within the file) has downloaded and been verified.
        public func isDownloaded(_ range: Range<Int64>) -> Bool {
            let r = max(0, range.lowerBound)..<min(fileLength, range.upperBound)
            guard !r.isEmpty else { return false }
            return check(r)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var streams: [String: Stream] = [:]

    /// The stream served at `url` (`http://127.0.0.1:<port>/stream/<token>`), if it's live.
    public static func stream(for url: URL) -> Stream? {
        guard url.host == "127.0.0.1" || url.host == "localhost" else { return nil }
        let token = url.lastPathComponent
        return lock.withLock { streams[token] }
    }

    static func register(token: String, stream: Stream) { lock.withLock { streams[token] = stream } }
    static func unregister(token: String) { _ = lock.withLock { streams.removeValue(forKey: token) } }
}
