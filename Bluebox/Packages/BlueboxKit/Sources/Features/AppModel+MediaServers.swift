import Domain
import Foundation
import MediaSources
import Playback

/// Watch progress with Jellyfin and Emby servers, both ways: what's watched on
/// the server's own apps comes in, and what's watched or marked here goes back.
extension AppModel {
    /// The enabled Jellyfin and Emby servers.
    func mediaServers() async -> [JellyfinSource] {
        var out: [JellyfinSource] = []
        for source in await registry.all() {
            if let server = source as? JellyfinSource, await registry.isEnabled(server.id) { out.append(server) }
        }
        return out
    }

    /// Stores a server's watched state and resume points where they're newer
    /// than what Bluebox has, then carries them on to other devices and Trakt.
    func applyServerProgress(_ records: [WatchProgress]) async {
        var changed: [MediaKey] = []
        for remote in records {
            let local = (try? await store.progress(for: remote.key)) ?? nil
            guard JellyfinSource.shouldApply(remote, over: local) else { continue }
            var record = remote
            // Keep the length Bluebox measured when the server didn't send one.
            if record.duration == nil { record.duration = local?.duration }
            if (try? await store.save(record)) != nil { changed.append(record.key) }
        }
        guard !changed.isEmpty else { return }
        noteLibraryChanged()  // redraws, and passes it on to the cloud and Trakt
        downloadsFollowProgress(changed, fromOtherDevice: true)  // Smart Downloads follow the server's watching too
    }

    /// Fresh state from the servers for one title, when its page opens.
    func refreshServerProgress(for key: MediaKey) async {
        for server in await mediaServers() {
            await applyServerProgress(await server.refreshWatchProgress(for: key))
        }
    }

    /// Marks movies or episodes played or unplayed on every server that has them.
    func reportWatchedToServers(_ keys: [MediaKey], watched: Bool) {
        guard !keys.isEmpty else { return }
        Task {
            for server in await mediaServers() {
                for key in keys { await server.setPlayed(key, watched) }
            }
        }
    }

    /// Reports the player's position to the server it's playing from (every
    /// save while playing, and once more as stopped when it closes). When Up
    /// Next has moved on, the item before is reported stopped where it was left.
    func reportServerPlayback(_ session: PlayerSession, stopped: Bool) async {
        let position = session.snapshot.position
        let paused = session.snapshot.status != .playing
        var current: (source: JellyfinSource, itemID: String)?
        if let variant = session.currentResource?.variant,
           let server = await registry.source(variant.sourceID) as? JellyfinSource {
            current = (server, variant.id)
        }
        if let last = serverPlayback, last.itemID != current?.itemID || last.source.id != current?.source.id {
            Task { await last.source.reportProgress(itemID: last.itemID, position: last.position, isPaused: true, stopped: true) }
            serverPlayback = nil
        }
        guard let current else { return }
        serverPlayback = stopped ? nil : (current.source, current.itemID, position)
        Task { await current.source.reportProgress(itemID: current.itemID, position: position, isPaused: paused, stopped: stopped) }
    }
}
