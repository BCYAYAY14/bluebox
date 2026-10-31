#if DEBUG
import Addons
import Domain
import Playback
import Subtitles
import Foundation
import ImageIO
#if os(macOS)
import AppKit
#endif

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
/// - `-subtitle-stress <count>`: once playing, turns on the first text subtitle
///   from the file and changes the subtitle look `count` times, 3 s apart
///   (all of it applies live; nothing reopens the stream).
/// - `-subtitle-check <folder>`: once playing, switches to the second audio
///   track, then through subtitle tracks, presets and positions, logging
///   (category playback) whether the audio held and whether playback stalled.
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
        if args.contains("-demo-party") {
            await startDemoParty(lobby: args.contains("-demo-party-lobby"), chatOpen: !args.contains("-demo-party-closed"))
        }
        // Screenshots: the Join a Party sheet, empty.
        if args.contains("-open-join-party") { partyJoin = PartyJoinRequest() }
        if let count = value("-subtitle-stress").flatMap(Int.init) { await stressSubtitleStyle(count) }
        if let dir = value("-subtitle-check") { await checkSubtitles(saveTo: dir) }
    }

    /// `-subtitle-check <folder>`: once playing, picks the second audio track,
    /// then several subtitle tracks and looks, logging whether the audio held
    /// and whether playback stopped to load, and saving a frame after each step.
    private func checkSubtitles(saveTo dir: String) async {
        for _ in 0..<60 where activePlayer?.snapshot.status != .playing { try? await Task.sleep(for: .milliseconds(500)) }
        guard let session = activePlayer else { return }
        #if os(macOS)
        // For `screencapture -l`: the video's picture isn't in VLC snapshots of this surface.
        for w in NSApp.windows where w.isVisible { Log.playback.notice("subtitle check window \(w.windowNumber, privacy: .public)") }
        #endif
        await session.seek(to: 215)
        try? await Task.sleep(for: .seconds(3))
        let audio = session.snapshot.audioTracks
        if audio.count > 1 { session.selectAudio(audio[1].id) }
        try? await Task.sleep(for: .seconds(2))
        let wanted = session.snapshot.selectedAudioID
        var step = 0
        func check(_ name: String, _ change: () -> Void) async {
            step += 1
            change()
            var stalls: Set<String> = []
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(100))
                let st = session.snapshot.status
                if st == .loading || st == .buffering { stalls.insert("\(st)") }
            }
            let s = session.snapshot
            Log.playback.notice("subtitle check \(step, privacy: .public) \(name, privacy: .public): audio \(s.selectedAudioID ?? "nil", privacy: .public) (wanted \(wanted ?? "nil", privacy: .public)), status \(String(describing: s.status), privacy: .public), stalls \(stalls.sorted().joined(separator: ","), privacy: .public), position \(Int(s.position), privacy: .public)")
            if let image = await session.captureFrame() {
                let url = URL(fileURLWithPath: dir).appending(path: String(format: "%02d-%@.png", step, name))
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
                }
            }
        }
        let subs = session.snapshot.embeddedSubtitles.filter { !$0.isBitmap }
        for (i, t) in subs.prefix(3).enumerated() {
            await check("track\(i)") { session.selectSubtitle(.embedded(t.id)) }
        }
        if let first = subs.first { await check("back-to-first") { session.selectSubtitle(.embedded(first.id)) } }
        let base = subtitleStyle
        await check("bold-outline") { subtitleStyle = base.applying(.boldOutline) }
        await check("boxed") { subtitleStyle = base.applying(.boxed) }
        await check("large-print") { subtitleStyle = base.applying(.largePrint) }
        await check("top") { var s = subtitleStyle; s.pin(.top, .center); subtitleStyle = s }
        await check("middle") { var s = subtitleStyle; s.pin(.middle, .center); subtitleStyle = s }
        await check("standard") { var s = base.applying(.standard); s.resetPosition(); subtitleStyle = s }
        await check("off") { session.selectSubtitle(.off) }
        Log.playback.notice("subtitle check done")
    }

    private func stressSubtitleStyle(_ count: Int) async {
        try? await Task.sleep(for: .seconds(6))
        for i in 0..<count {
            guard let session = activePlayer else { return }
            if let track = session.snapshot.embeddedSubtitles.first(where: { !$0.isBitmap }),
               session.subtitleSelection != .embedded(track.id) {
                session.selectSubtitle(.embedded(track.id), remember: false)
            }
            var style = subtitleStyle
            if i.isMultiple(of: 2) { style.textColor = style.textColor == .white ? RGBA(1, 0.85, 0.2) : .white }
            else { style.relativeSize = style.relativeSize > 0.05 ? 0.045 : 0.07 }
            subtitleStyle = style
            Log.playback.notice("subtitle stress \(i + 1, privacy: .public) of \(count, privacy: .public)")
            try? await Task.sleep(for: .seconds(3))
        }
        Log.playback.notice("subtitle stress done")
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
