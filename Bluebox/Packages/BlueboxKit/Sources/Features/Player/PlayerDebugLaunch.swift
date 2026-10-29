#if DEBUG
import Addons
import Domain
import Playback
import Foundation

/// Debug-only launch arguments for checking player features without UI
/// automation (use with `-ui-testing`, whose library and preferences are
/// throwaway):
///
/// - `-handoff-key <media key> -handoff-position <seconds>`: continue as if
///   Handoff brought that title over from another device.
/// - `-test-link <url>`: add the URL as a direct link (title "Player Test",
///   key `tmdb:movie:990001`) and continue it the same way. With
///   `-test-link-local`, it's first copied into the app's temporary folder,
///   so it plays as a local file (preview thumbnails need one).
/// - `-test-magnet <info hash>`: stream that torrent's largest file through the
///   normal release path (torrent engine, stream server, player).
/// - `-player-popover <tracks|episodes|speed|tools|chapters>` with `-player-page <page>`:
///   open that card (and a page inside it) once the video plays (see PlayerView).
extension AppModel {
    public func runPlayerDebugLaunchArguments(_ launchArgs: [String]) async {
        let args = launchArgs + Self.environmentDebugArguments
        func value(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let position = value("-handoff-position").flatMap(Int.init) ?? 0
        // A bare "host:port/path" is taken as http: on the Mac a launch argument that is a
        // full URL is also delivered as an open-URL event, and the window never appears.
        if let raw = value("-test-link"), let url = URL(string: raw.contains("://") ? raw : "http://" + raw) {
            // `-test-link-key tmdb:tv:9100001:s1e2` plays it as that episode (Episodes panel, Previous/Next).
            let key = value("-test-link-key").map(MediaKey.init(rawValue:)) ?? MediaKey.movie(tmdbID: 990_001)
            try? await addDirectLink(url: url, title: "Player Test", matching: key)
            if args.contains("-test-link-local") {
                // Download it first, so it plays as a finished download (a local file).
                await startDownload(key: key, title: "Player Test")
                for _ in 0..<120 where downloadedVariant(for: key) == nil { try? await Task.sleep(for: .milliseconds(500)) }
            }
            await continueWatching(WatchActivityPayload(key: key, title: "Player Test", position: position))
        } else if let hash = value("-test-magnet") {
            let release = AddonRelease(id: "test-\(hash)", title: "Torrent Test", name: "Test", infoHash: hash, fileIndex: nil,
                                       trackers: [], seeders: nil, sizeText: nil, resolution: nil, container: nil, url: nil)
            await play(NowPlayingItem(key: .movie(tmdbID: 990_002), title: "Torrent Test"), release: release)
        } else if let raw = value("-handoff-key") {
            await continueWatching(WatchActivityPayload(key: MediaKey(rawValue: raw), title: "Handoff Test", position: position))
        }
    }

    /// `-player-preview <fraction>`: hold the scrub preview there (as if hovering).
    static var debugPreviewFraction: Double? { debugValue("-player-preview").flatMap(Double.init) }
    /// `-player-pause <seconds>`: pause that long after the player opens (keeps controls up).
    static var debugPauseAfter: Double? { debugValue("-player-pause").flatMap(Double.init) }
    /// `-player-pip <seconds>`: start Picture in Picture that long after the player opens.
    static var debugPiPAfter: Double? { debugValue("-player-pip").flatMap(Double.init) }

    /// The same flags from `BLUEBOX_DEBUG_ARGS` (space-separated). On the Mac a
    /// launch argument that isn't a "-flag" (a URL, a number) is also taken as a
    /// file to open, and the main window then never appears.
    static var environmentDebugArguments: [String] {
        (ProcessInfo.processInfo.environment["BLUEBOX_DEBUG_ARGS"] ?? "").split(separator: " ").map(String.init)
    }

    static func debugValue(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments + environmentDebugArguments
        return args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
}
#endif
