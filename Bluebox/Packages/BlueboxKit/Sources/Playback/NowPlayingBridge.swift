import Foundation
import MediaPlayer

/// Publishes the current item to Control Center / the lock screen / the macOS
/// Now Playing menu and routes remote commands back to the session.
@MainActor
public final class NowPlayingBridge {
    private weak var session: PlayerSession?
    private var targets: [(MPRemoteCommand, Any)] = []
    private let center = MPNowPlayingInfoCenter.default()

    public init() {}

    public func attach(_ session: PlayerSession) {
        detach()
        self.session = session
        let rc = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ handler: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            let token = command.addTarget { event in MainActor.assumeIsolated { handler(event) } }
            targets.append((command, token))
        }
        add(rc.playCommand) { [weak self] _ in self?.session?.engine.play(); return .success }
        add(rc.pauseCommand) { [weak self] _ in self?.session?.engine.pause(); return .success }
        add(rc.togglePlayPauseCommand) { [weak self] _ in self?.session?.togglePlayPause(); return .success }
        rc.skipForwardCommand.preferredIntervals = [10]
        rc.skipBackwardCommand.preferredIntervals = [10]
        add(rc.skipForwardCommand) { [weak self] _ in
            guard let s = self?.session else { return .noActionableNowPlayingItem }
            Task { await s.skip(by: 10) }; return .success
        }
        add(rc.skipBackwardCommand) { [weak self] _ in
            guard let s = self?.session else { return .noActionableNowPlayingItem }
            Task { await s.skip(by: -10) }; return .success
        }
        add(rc.changePlaybackPositionCommand) { [weak self] event in
            guard let s = self?.session, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { await s.seek(to: e.positionTime) }; return .success
        }
    }

    public func update() {
        guard let session, let item = session.item else { center.nowPlayingInfo = nil; return }
        let s = session.snapshot
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: s.position,
            MPNowPlayingInfoPropertyPlaybackRate: s.status == .playing ? Double(s.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(s.rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let sub = item.subtitle { info[MPMediaItemPropertyArtist] = sub }
        if let d = s.duration { info[MPMediaItemPropertyPlaybackDuration] = d }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = switch s.status {
        case .playing, .buffering: .playing
        case .paused, .loading: .paused
        default: .stopped
        }
        #endif
    }

    public func detach() {
        for (command, token) in targets { command.removeTarget(token) }
        targets = []
        center.nowPlayingInfo = nil
        session = nil
    }
}
