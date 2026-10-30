import Addons
import Domain
import Foundation
import TorrentStreaming

/// A video an external player (Infuse, VLC…) reads from Bluebox's localhost stream server: a torrent
/// stream, or (iOS) a downloaded file only Bluebox can open. While it lasts,
/// `DownloadLifecycle` keeps Bluebox running in the background on iOS.
struct ExternalHandoff {
    /// What the player reads: `http://127.0.0.1:<port>/stream/<token>`.
    let url: URL
    /// Served by `ExternalStreams` (a file), so stopped here when done.
    let servesFile: Bool
    let isTorrent: Bool
    /// Held while the file is served.
    let scopedRoot: URL?
    let began: Date
}

extension AppModel {
    /// Bluebox keeps serving this long after the player last read (paused, or done watching).
    static let externalIdleLimit: TimeInterval = 15 * 60

    /// True while an external player may still be reading a stream from Bluebox.
    var isServingExternalPlayer: Bool { externalHandoff != nil }

    /// Hands `resource` to `player`. False when it didn't open.
    func openExternally(_ resource: PlaybackResource, variant: MediaVariant, in player: ExternalPlayer) async -> Bool {
        await endExternalHandoff()
        var url = resource.url
        var servesFile = false
        var scope: URL?
        #if os(iOS)
        if url.isFileURL, player == .shareSheet {
            // The file itself: Save to Files, AirDrop, or an app that takes videos.
            ShareSheet.present(url)
            return true
        }
        if url.isFileURL {
            // Other apps can't open Bluebox's files on iOS: they read them over localhost instead.
            if let root = resource.securityScopedRoot, root.startAccessingSecurityScopedResource() { scope = root }
            do {
                url = try await ExternalStreams.serve(fileAt: url)
                servesFile = true
            } catch {
                scope?.stopAccessingSecurityScopedResource()
                Log.playback.error("\(player.name, privacy: .public): couldn't serve the file: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        #endif
        guard await player.open(url, subtitles: resource.externalSubtitles) else {
            if servesFile { ExternalStreams.stopServing(url) }
            scope?.stopAccessingSecurityScopedResource()
            return false
        }
        guard ExternalPlayer.isLoopback(url) else {
            releaseTorrentDownloadHolds()  // a web link: nothing of Bluebox's is involved any more
            return true
        }
        externalHandoff = ExternalHandoff(url: url, servesFile: servesFile, isTorrent: variant.sourceID == addons.id,
                                      scopedRoot: scope, began: .now)
        watchExternalHandoff()
        downloadLifecycle.downloadsChanged()
        return true
    }

    /// Stops serving what the player was reading: on the next Play, or once
    /// it has left it alone for `externalIdleLimit`.
    func endExternalHandoff() async {
        guard let handoff = externalHandoff else { return }
        externalHandoff = nil
        externalWatch?.cancel()
        externalWatch = nil
        let stillServed = ExternalStreams.lastUse(of: handoff.url).served
        if handoff.servesFile { ExternalStreams.stopServing(handoff.url) }
        handoff.scopedRoot?.stopAccessingSecurityScopedResource()
        // Only this handoff's torrent: one that's already gone may have been replaced by a newer stream.
        if handoff.isTorrent, stillServed { await addons.stopStreaming() }
        releaseTorrentDownloadHolds()
        downloadLifecycle.downloadsChanged()
        Log.playback.notice("External player: stopped serving")
    }

    private func watchExternalHandoff() {
        externalWatch?.cancel()
        externalWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, let handoff = self.externalHandoff else { return }
                let use = ExternalStreams.lastUse(of: handoff.url)
                let idleSince = use.at ?? handoff.began
                if !use.served || Date().timeIntervalSince(idleSince) > Self.externalIdleLimit {
                    await self.endExternalHandoff()
                    return
                }
            }
        }
    }
}
