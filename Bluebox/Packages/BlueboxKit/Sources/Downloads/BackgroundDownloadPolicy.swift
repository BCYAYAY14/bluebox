import Foundation

/// iOS: whether Bluebox should keep itself running after you leave it, so
/// torrent downloads continue. Pure, so the rules are tested directly; the
/// app's `DownloadLifecycle` acts on the answer.
public enum BackgroundDownloadPolicy {
    public enum Decision: Sendable, Equatable {
        /// A torrent can download: keep the app running with a silent audio session.
        case keepAlive
        /// A torrent can download, and playback already keeps the app running
        /// (the silent session must not run alongside it).
        case playbackKeepsAlive
        /// Let iOS suspend the app; torrents stop and keep their data.
        case stop(StopReason)
    }

    public enum StopReason: Sendable, Equatable {
        /// Settings › Downloads › Keep Downloading in the Background is off.
        case settingOff
        /// No unfinished torrent download wants to run (none, or all paused or failed).
        case nothingToDownload
        /// Every torrent waits for Wi‑Fi (Wi‑Fi Only, the Mobile Data torrent
        /// rule, or "Download on Wi‑Fi Later").
        case waitingForWiFi
        case offline
        /// Held for another reason (e.g. the same release is streaming).
        case held
    }

    /// - Parameters:
    ///   - records: every download (finished and HTTP ones are ignored).
    ///   - conditions: the network now; `torrentsSuspended` is ignored (the
    ///     question is whether torrents could run if the app stays up).
    ///   - holds: download ID → reason it must wait.
    ///   - isPlaying: the player is playing.
    public static func decide(records: [DownloadRecord], settings: DownloadSettings, conditions: DownloadConditions,
                              holds: [String: String] = [:], isPlaying: Bool) -> Decision {
        guard settings.keepDownloadingInBackground else { return .stop(.settingOff) }
        let torrents = records.filter { $0.isTorrent && $0.isActive }
        guard !torrents.isEmpty else { return .stop(.nothingToDownload) }
        var running = conditions
        running.torrentsSuspended = false
        let plan = DownloadScheduler.plan(records: records, running: [], settings: settings, conditions: running, holds: holds)
        // Waiting only for a free slot still counts: it starts when one opens.
        let canRun = torrents.contains { r in
            switch plan.waits[r.id] {
            case nil, .queued: true
            default: false
            }
        }
        if canRun { return isPlaying ? .playbackKeepsAlive : .keepAlive }
        let waits = torrents.compactMap { plan.waits[$0.id] }
        if waits.contains(.offline) { return .stop(.offline) }
        if waits.contains(.wifi) { return .stop(.waitingForWiFi) }
        return .stop(.held)
    }
}
