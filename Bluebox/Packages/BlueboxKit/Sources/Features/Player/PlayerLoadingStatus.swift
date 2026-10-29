import DesignSystem
import Foundation
import Playback
import TorrentStreaming

/// What the player says under its spinner while a video opens or stalls,
/// in place of a bare spinner and "--:--".
enum PlayerLoadingText {
    struct Line: Equatable {
        let headline: String
        let detail: String?
    }

    /// - Parameters:
    ///   - torrent: swarm numbers when the video streams from a torrent.
    static func line(status: PlaybackStatus, bufferFill: Double?, torrent: SwarmStats?, loadingNext: Bool,
                     elapsed: TimeInterval) -> Line? {
        if loadingNext { return Line(headline: "Finding the next episode…", detail: nil) }
        guard status == .loading || status == .buffering else { return nil }
        let fill = bufferFill.map { "Buffering \(Int(($0 * 100).rounded()))%" }
        if let t = torrent {
            let speed = t.downloadRate > 0
                ? ByteCountFormatter.string(fromByteCount: Int64(t.downloadRate), countStyle: .file) + "/s" : nil
            if t.connectedPeers == 0 {
                return Line(headline: "Connecting to peers…",
                            detail: t.knownPeers > 0 ? "\(t.knownPeers) found, none connected yet" : (elapsed > 20 ? "This torrent may have few seeders" : nil))
            }
            let peers = "\(t.connectedPeers) peer\(t.connectedPeers == 1 ? "" : "s")"
            let have = t.fileProgress > 0.005 ? "\(Int((t.fileProgress * 100).rounded()))% of the file in" : nil
            let detail = [peers, speed, have].compactMap { $0 }.joined(separator: " · ")
            if let fill { return Line(headline: fill, detail: detail) }
            return Line(headline: status == .loading ? "Opening the video…" : "Waiting for data…", detail: detail)
        }
        if let fill { return Line(headline: fill, detail: nil) }
        if status == .loading { return Line(headline: "Opening the video…", detail: elapsed > 12 ? "Still connecting" : nil) }
        return elapsed > 2 ? Line(headline: "Buffering…", detail: nil) : nil
    }
}
