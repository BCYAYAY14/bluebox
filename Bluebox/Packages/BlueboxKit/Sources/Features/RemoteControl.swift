import Domain
import Foundation
import Observation
import Playback
import Sync
#if os(macOS)
import SystemConfiguration
#endif

/// iPhone as a remote for the Mac player (DECISIONS.md, UI review 17).
///
/// The Mac (with Allow Remote Control on) joins the account's remote channel
/// while its player is open and publishes what's playing: every 2 s while a
/// remote said hello in the last 45 s, every 15 s otherwise, and at once when
/// play/pause, tracks, volume or the item change. Commands are applied to
/// `PlayerSession` through its public controls, nothing deeper.
///
/// The phone (with Use as Remote on) joins while Bluebox is in front, says
/// hello so the Mac publishes straight away, and shows "Playing on Mac".
/// Its controls draw at once and reconcile with what the Mac publishes
/// (`RemoteReconciler`).
@MainActor @Observable
public final class RemoteControl {
    /// What the phone shows; nil when no Mac is playing.
    public private(set) var nowPlaying: RemoteNowPlaying?
    public private(set) var channelState: RemoteChannel.State = .stopped
    /// The remote screen is open: keep the Mac publishing often.
    public var screenOpen = false { didSet { if screenOpen, !oldValue { sayHello() } } }

    @ObservationIgnored private var channel: RemoteChannel?
    @ObservationIgnored private var reconciler = RemoteReconciler()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastHello: Date?
    @ObservationIgnored let deviceID: String
    @ObservationIgnored let now: () -> Date
    // The Mac's side.
    @ObservationIgnored private weak var player: PlayerSession?
    @ObservationIgnored private var lastRemoteSeen: Date?
    @ObservationIgnored private var lastPublished: (state: RemoteNowPlaying, at: Date)?
    @ObservationIgnored private var seq = 0

    static let fastInterval: TimeInterval = 2
    static let slowInterval: TimeInterval = 15
    /// After a hello, publish fast for this long; the remote screen says hello every 15 s.
    static let remoteLinger: TimeInterval = 45

    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        let key = "bluebox.remote.deviceID"
        if let id = defaults.string(forKey: key) { deviceID = id } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: key)
        }
        self.now = now
    }

    // MARK: Connection

    /// Joins or leaves the channel. `player`: the Mac's open player (nil on the phone).
    func update(wanted: Bool, account: AccountModel, player: PlayerSession?) {
        // The player closed: tell remotes now rather than letting them time out.
        if self.player != nil, player == nil || !wanted, let channel {
            let id = deviceID
            Task { await channel.send(.stopped(deviceID: id)) }
        }
        self.player = player
        lastPublished = nil
        guard wanted else { disconnect(); return }
        if channel == nil {
            channel = account.makeRemoteChannel(onMessage: { [weak self] message in
                Task { @MainActor in self?.receive(message) }
            }, onState: { [weak self] state in
                Task { @MainActor in self?.channelChanged(state) }
            })
            guard let channel else { return }
            Task { await channel.start() }
        }
        startTicker()
    }

    private func disconnect() {
        ticker?.cancel(); ticker = nil
        if let channel {
            self.channel = nil
            // After the farewell above: a moment for it to go out before the socket closes.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                await channel.stop()
            }
        }
        channelState = .stopped
        reconciler.clear()
        nowPlaying = nil
    }

    private func channelChanged(_ state: RemoteChannel.State) {
        guard channel != nil || state == .stopped else { return }
        channelState = state
        guard state == .joined else { return }
        if player != nil { publish(force: true) } else { sayHello() }
    }

    /// Once a second: the phone runs its clock forward; the Mac publishes when due.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        if player != nil { publish(force: false); return }
        if screenOpen, let lastHello, now().timeIntervalSince(lastHello) >= 15 { sayHello() }
        refreshDisplayed()
    }

    private func receive(_ message: RemoteMessage) {
        switch message {
        case .state(let s):
            guard player == nil else { return }
            reconciler.receive(s, at: now())
            refreshDisplayed()
        case .stopped(let id):
            reconciler.stopped(deviceID: id)
            refreshDisplayed()
        case .hello:
            guard player != nil else { return }
            lastRemoteSeen = now()
            publish(force: true)
        case .command(let command):
            guard command.target == deviceID, let player else { return }
            lastRemoteSeen = now()
            Task {
                await Self.apply(command.action, to: player)
                // Give the engine a moment to report the change, then tell the remote.
                try? await Task.sleep(for: .milliseconds(300))
                self.publish(force: true)
            }
        }
    }

    // MARK: The phone

    private func refreshDisplayed() {
        let shown = reconciler.displayed(at: now())
        if shown != nowPlaying { nowPlaying = shown }
    }

    private func sayHello() {
        guard let channel, channelState == .joined else { return }
        lastHello = now()
        let id = deviceID
        Task { await channel.send(.hello(from: id)) }
    }

    /// Sends a command to the Mac that's playing, showing it at once.
    public func send(_ action: RemoteCommand.Action) {
        guard let target = nowPlaying?.deviceID, let channel else { return }
        reconciler.apply(action, at: now())
        refreshDisplayed()
        let command = RemoteCommand(target: target, action: action)
        Task { await channel.send(.command(command)) }
    }

    /// ±10 s from what the remote shows, so quick taps add up.
    public func skip(by delta: TimeInterval) {
        guard let s = nowPlaying else { return }
        let target = max(0, s.position + delta)
        send(.seek(s.duration.map { min(target, $0) } ?? target))
    }

    // MARK: The Mac

    private func publish(force: Bool) {
        guard let player, let channel, channelState == .joined, let state = makeState(player) else { return }
        let date = now()
        if !force, let last = lastPublished {
            let fast = lastRemoteSeen.map { date.timeIntervalSince($0) < Self.remoteLinger } ?? false
            let interval = fast ? Self.fastInterval : Self.slowInterval
            let changed = !Self.samePlayback(last.state, state)
            guard changed || date.timeIntervalSince(last.at) >= interval else { return }
        }
        seq += 1
        var published = state
        published.seq = seq
        lastPublished = (published, date)
        Task { await channel.send(.state(published)) }
    }

    /// Equal apart from the clock: a change here is published at once.
    nonisolated static func samePlayback(_ a: RemoteNowPlaying, _ b: RemoteNowPlaying) -> Bool {
        var a = a, b = b
        a.position = 0; b.position = 0; a.seq = 0; b.seq = 0
        return a == b
    }

    func makeState(_ s: PlayerSession) -> RemoteNowPlaying? {
        guard let item = s.item else { return nil }
        let subtitleID: String? = switch s.subtitleSelection {
        case .off: nil
        case .embedded(let id), .external(let id): id
        }
        return RemoteNowPlaying(deviceID: deviceID, deviceName: Self.deviceName, title: item.title, subtitle: item.subtitle,
                                position: s.displayPosition, duration: s.snapshot.duration, paused: !s.appearsPlaying,
                                audioTracks: s.snapshot.audioTracks.map { RemoteTrack(id: $0.id, label: $0.label) },
                                subtitleTracks: s.allSubtitleTracks.map { RemoteTrack(id: $0.id, label: $0.label) },
                                audioID: s.snapshot.selectedAudioID, subtitleID: subtitleID,
                                volume: s.isMuted ? 0 : s.volume, hasNext: item.key.episodeNumbers != nil)
    }

    /// The bridge to the player: only `PlayerSession`'s public controls.
    static func apply(_ action: RemoteCommand.Action, to s: PlayerSession) async {
        switch action {
        case .setPaused(let paused):
            if paused == s.appearsPlaying { s.togglePlayPause() }
        case .seek(let t):
            await s.seek(to: t)
        case .nextEpisode:
            await s.playNext()
        case .audio(let id):
            s.selectAudio(id)
        case .subtitle(let id):
            guard let id else { s.selectSubtitle(.off); return }
            guard let track = s.allSubtitleTracks.first(where: { $0.id == id }) else { return }
            s.selectSubtitle(track.isExternal ? .external(id) : .embedded(id))
        case .volume(let v):
            if s.isMuted, v > 0 { s.setMuted(false) }
            s.setVolume(v)
        }
    }

    static let deviceName: String = {
        #if os(macOS)
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        #else
        "iPhone"
        #endif
    }()
}
