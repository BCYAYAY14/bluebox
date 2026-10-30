import Addons
import Domain
import Foundation
import TorrentStreaming

/// A video Infuse reads from Bluebox's localhost stream server: a torrent
/// stream, or (iOS) a downloaded file only Bluebox can open. While it lasts,
/// `DownloadLifecycle` keeps Bluebox running in the background on iOS.
struct InfuseHandoff {
    /// What Infuse reads: `http://127.0.0.1:<port>/stream/<token>`.
    let url: URL
    /// Served by `ExternalStreams` (a file), so stopped here when done.
    let servesFile: Bool
    let isTorrent: Bool
    /// Held while the file is served.
    let scopedRoot: URL?
    let began: Date
}

extension AppModel {
    /// Bluebox keeps serving this long after Infuse last read (paused, or done watching).
    static let infuseIdleLimit: TimeInterval = 15 * 60

    /// True while Infuse may still be reading a stream from Bluebox.
    var isServingInfuse: Bool { infuseHandoff != nil }

    /// Hands `resource` to Infuse. False when it didn't open.
    func openInInfuse(_ resource: PlaybackResource, variant: MediaVariant) async -> Bool {
        await endInfuseHandoff()
        var url = resource.url
        var servesFile = false
        var scope: URL?
        #if os(iOS)
        if url.isFileURL {
            // Infuse can't open Bluebox's files on iOS: it reads them over localhost instead.
            if let root = resource.securityScopedRoot, root.startAccessingSecurityScopedResource() { scope = root }
            do {
                url = try await ExternalStreams.serve(fileAt: url)
                servesFile = true
            } catch {
                scope?.stopAccessingSecurityScopedResource()
                Log.playback.error("Infuse: couldn't serve the file: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        #endif
        guard await Infuse.open(url, subtitles: resource.externalSubtitles) else {
            if servesFile { ExternalStreams.stopServing(url) }
            scope?.stopAccessingSecurityScopedResource()
            return false
        }
        guard Infuse.isLoopback(url) else {
            releaseTorrentDownloadHolds()  // a web link: nothing of Bluebox's is involved any more
            return true
        }
        infuseHandoff = InfuseHandoff(url: url, servesFile: servesFile, isTorrent: variant.sourceID == addons.id,
                                      scopedRoot: scope, began: .now)
        watchInfuseHandoff()
        downloadLifecycle.downloadsChanged()
        return true
    }

    /// Stops serving what Infuse was reading: on the next Play, or once
    /// Infuse has left it alone for `infuseIdleLimit`.
    func endInfuseHandoff() async {
        guard let handoff = infuseHandoff else { return }
        infuseHandoff = nil
        infuseWatch?.cancel()
        infuseWatch = nil
        let stillServed = ExternalStreams.lastUse(of: handoff.url).served
        if handoff.servesFile { ExternalStreams.stopServing(handoff.url) }
        handoff.scopedRoot?.stopAccessingSecurityScopedResource()
        // Only this handoff's torrent: one that's already gone may have been replaced by a newer stream.
        if handoff.isTorrent, stillServed { await addons.stopStreaming() }
        releaseTorrentDownloadHolds()
        downloadLifecycle.downloadsChanged()
        Log.playback.notice("Infuse: stopped serving")
    }

    private func watchInfuseHandoff() {
        infuseWatch?.cancel()
        infuseWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, let handoff = self.infuseHandoff else { return }
                let use = ExternalStreams.lastUse(of: handoff.url)
                let idleSince = use.at ?? handoff.began
                if !use.served || Date().timeIntervalSince(idleSince) > Self.infuseIdleLimit {
                    await self.endInfuseHandoff()
                    return
                }
            }
        }
    }
}
