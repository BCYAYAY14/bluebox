import Foundation
import MediaPlayer

/// Publishes the current item to Control Center / the lock screen / the macOS
/// Now Playing menu and routes remote commands back to the session.
@MainActor
public final class NowPlayingBridge {
    private weak var session: PlayerSession?
    private var targets: [(MPRemoteCommand, Any)] = []
    private let center = MPNowPlayingInfoCenter.default()
    /// What was last published and when, to tell a real change from the playhead just moving on.
    private var sent: (state: Sent, position: TimeInterval, at: Date)?

    private struct Sent: Equatable {
        var title: String
        var subtitle: String?
        var duration: TimeInterval?
        var rate: Float
        var status: PlaybackStatus
    }

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
        guard let session, let item = session.item else { center.nowPlayingInfo = nil; sent = nil; return }
        let s = session.snapshot
        // The system moves the elapsed time on by the rate itself. This is called
        // on every tick of the playhead, so it only publishes again when something
        // else changed or the playhead isn't where the system thinks (a seek, a stall).
        let state = Sent(title: item.title, subtitle: item.subtitle, duration: s.duration, rate: s.rate, status: s.status)
        let date = Date()
        if let sent, sent.state == state {
            let speed = s.status == .playing ? Double(s.rate) : 0
            if abs(s.position - (sent.position + date.timeIntervalSince(sent.at) * speed)) < 1 { return }
        }
        sent = (state, s.position, date)
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
        sent = nil
        session = nil
    }
}
