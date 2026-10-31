import Domain
import Foundation
import Observation
import Playback
import Sync
#if os(macOS)
import AppKit
import SystemConfiguration
#endif

/// What a controlled device does with the remote's app commands: go somewhere,
/// move or press its highlight, play. `AppModel` on the Mac; a fake in tests.
@MainActor public protocol RemoteAppHandler: AnyObject {
    func remoteGo(_ destination: RemoteDestination)
    func remotePlay(_ play: RemotePlay) async
    func remoteClosePlayer() async
    /// `driver`: the remote's name, shown on the highlight.
    func remoteFocus(_ id: String, driver: String)
    func remoteMove(_ direction: RemoteDirection, driver: String)
    func remoteSelect(driver: String)
    /// Protocol 4: jumps, scrolling, the pointer, menus and the skip button.
    func remote4(_ action: RemoteCommand.Action, driver: String)
    /// Where the app is and what's highlighted (`deviceID` is filled in by `RemoteControl`).
    func remoteScreen() -> RemoteScreen
    /// What the player's skip button offers now ("Skip Intro"), if anything.
    func remoteSkipOffer() -> String?
}

public extension RemoteAppHandler {
    func remote4(_ action: RemoteCommand.Action, driver: String) {}
    func remoteSkipOffer() -> String? { nil }
}

/// iPhone as a remote for the Mac (DECISIONS.md, UI review 17; the new remote, 31 Oct 2026).
///
/// The Mac (with Allow Remote Control on) joins the account's remote channel
/// whenever it's signed in, announces itself (`RemoteDevice`), and takes
/// commands for its player and for the app around it: go to Home, Search or a
/// title, move and press its highlight, play. While its player is open it
/// publishes what's playing: every 2 s while a remote said hello in the last
/// 45 s, every 15 s otherwise, and at once when play/pause, tracks, volume or
/// the item change. Player commands go through `PlayerSession`'s public
/// controls; app commands through `RemoteAppHandler`. One at a time, in order.
///
/// The phone (with Use as Remote on) joins while Bluebox isn't in the
/// background, says hello so the Mac publishes straight away (again every few
/// seconds until it hears one), and keeps the list of devices online for
/// "Play on". With one chosen (`target`), Play on the phone plays there and
/// the title pages it opens open there too. Its player controls draw at once
/// and reconcile with what the Mac publishes (`RemoteReconciler`).
///
/// Delivery: broadcast is fire-and-forget, and either side may be
/// reconnecting when a command goes out. So the Mac acknowledges every
/// command (`RemoteAck`) and the phone sends it again until it does, a few
/// times; the Mac applies each command ID once. Messages leave in the order
/// they were made, through one outbox per channel.
@MainActor @Observable
public final class RemoteControl {
    /// What the remote says about the link to the Mac.
    public enum Connection: Sendable, Equatable {
        case off, connecting, connected
        /// Joined, but the Mac didn't acknowledge the last command.
        case notAnswering
    }

    /// What the phone shows; nil when the controlled device isn't playing.
    public private(set) var nowPlaying: RemoteNowPlaying?
    public private(set) var channelState: RemoteChannel.State = .stopped
    /// The last command's retries all went unanswered. Cleared by the next ack:
    /// the Mac's states can keep coming while it doesn't hear us.
    public private(set) var macNotAnswering = false
    /// Devices that take commands, online now (not this one): playing first, then by name.
    public private(set) var devices: [RemoteDevice] = []
    /// "Play on": the device chosen to control. nil is This iPhone (the remote
    /// still shows whichever device plays).
    public var target: String? { didSet { if target != oldValue { targetChanged() } } }
    /// Where the controlled device is, and what's highlighted there.
    public private(set) var screen: RemoteScreen?
    /// Player commands drawn but not yet confirmed by the Mac, by `RemoteReconciler.kind`.
    public private(set) var awaiting: Set<Int> = []
    /// Bumped to open the remote (Play went to another device).
    public private(set) var presentRequest = 0
    /// The remote screen is open: keep the Mac publishing often.
    public var screenOpen = false { didSet { if screenOpen, !oldValue { wake(); sayHello() } } }

    public var connection: Connection {
        switch channelState {
        case .stopped: .off
        case .connecting: .connecting
        case .joined: macNotAnswering ? .notAnswering : .connected
        }
    }

    /// The device the remote controls: the one chosen, else the one playing, else the only one online.
    public var controlled: RemoteDevice? {
        if let target { return devices.first { $0.id == target } ?? nowPlaying.map(Self.device(for:)) }
        if let s = nowPlaying { return devices.first { $0.id == s.deviceID } ?? Self.device(for: s) }
        return devices.count == 1 ? devices[0] : nil
    }

    /// Clock and retry timings; tests shorten them.
    struct Timing {
        var tick: Duration = .seconds(1)
        /// The wait before each resend of an unacknowledged command; it's given up one wait after the last.
        var retries: [Duration] = [.milliseconds(700), .milliseconds(1_400), .milliseconds(2_500)]
        /// After applying a command, a moment for the engine to report it before publishing.
        var settle: Duration = .milliseconds(300)
        /// Say hello this often until a state arrives (a hello can be lost while the Mac reconnects).
        var helloUntilHeard: TimeInterval = 3
        /// For this long after joining, or while the remote screen is open.
        var helloUntilHeardFor: TimeInterval = 30
        /// Live scrubbing: at most one position this often.
        var scrubInterval: TimeInterval = 0.12
    }

    @ObservationIgnored private var channel: (any RemoteTransport)?
    @ObservationIgnored private var outbox: AsyncStream<RemoteMessage>.Continuation?
    @ObservationIgnored private var outboxTask: Task<Void, Never>?
    @ObservationIgnored private var reconciler = RemoteReconciler()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastHello: Date?
    @ObservationIgnored private var joinedAt: Date?
    @ObservationIgnored private var lastAnnounced: Date?
    /// Every device heard from (phones too, for the Mac to name its driver), and when.
    @ObservationIgnored private var heard: [String: (device: RemoteDevice, at: Date)] = [:]
    /// Commands the Mac hasn't acknowledged yet, with their retry loops.
    @ObservationIgnored private var unacked: [UUID: (action: RemoteCommand.Action, retry: Task<Void, Never>)] = [:]
    @ObservationIgnored private var lastScrubSent: Date?
    @ObservationIgnored let deviceID: String
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored let timing: Timing
    // The Mac's side.
    /// Takes app commands: Allow Remote Control is on here.
    @ObservationIgnored private var controllable = false
    @ObservationIgnored public weak var handler: (any RemoteAppHandler)?
    @ObservationIgnored private weak var player: PlayerSession?
    @ObservationIgnored private var lastRemoteSeen: Date?
    @ObservationIgnored private var lastPublished: (state: RemoteNowPlaying, at: Date)?
    @ObservationIgnored private var lastScreen: RemoteScreen?
    /// From the clock, so a relaunched Mac carries on above what remotes last saw from it.
    @ObservationIgnored private var seq: Int
    /// Command IDs already applied: a retry is acknowledged again but not applied twice.
    @ObservationIgnored private var applied: [UUID] = []
    /// The command being applied; the next one waits for it.
    @ObservationIgnored private var applying: Task<Void, Never>?
    #if DEBUG
    /// Showing `seedForReview`'s state: the channel is left alone.
    @ObservationIgnored private var seededForReview = false
    #endif
    #if os(macOS)
    /// Keeps App Nap from slowing the channel while the Mac waits for the remote.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    #endif

    static let fastInterval: TimeInterval = 2
    static let slowInterval: TimeInterval = 15
    /// After a hello, publish fast for this long; the remote screen says hello every 15 s.
    static let remoteLinger: TimeInterval = 45

    public convenience init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.init(defaults: defaults, now: now, timing: Timing())
    }

    init(defaults: UserDefaults, now: @escaping () -> Date, timing: Timing) {
        let key = "bluebox.remote.deviceID"
        if let id = defaults.string(forKey: key) { deviceID = id } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: key)
        }
        self.now = now
        self.timing = timing
        seq = Int(now().timeIntervalSince1970 * 1000)
        #if os(macOS)
        // A socket from before the Mac slept is usually dead without knowing it.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let channel = self?.channel else { return }
                await channel.reconnect()
            }
        }
        #endif
    }

    // MARK: Connection

    /// Joins or leaves the channel. `controllable`: this device takes commands
    /// (the Mac with Allow Remote Control on). `player`: its open player.
    func update(wanted: Bool, controllable: Bool, account: AccountModel, player: PlayerSession?) {
        update(wanted: wanted, controllable: controllable, player: player) { onMessage, onState in
            account.makeRemoteChannel(onMessage: onMessage, onState: onState)
        }
    }

    func update(wanted: Bool, controllable: Bool = false, player: PlayerSession?,
                makeChannel: (_ onMessage: @escaping @Sendable (RemoteMessage) -> Void,
                              _ onState: @escaping @Sendable (RemoteChannel.State) -> Void) -> (any RemoteTransport)?) {
        #if DEBUG
        if seededForReview { return }
        #endif
        // The player closed: tell remotes now rather than letting them time out.
        if self.player != nil, player == nil || !wanted, channel != nil {
            enqueue(.stopped(deviceID: deviceID))
        }
        let playerChanged = self.player !== player
        self.player = player
        self.controllable = controllable
        lastPublished = nil
        guard wanted else { disconnect(); return }
        if channel == nil {
            channel = makeChannel({ [weak self] message in
                Task { @MainActor in self?.receive(message) }
            }, { [weak self] state in
                Task { @MainActor in self?.channelChanged(state) }
            })
            guard let channel else { return }
            let (stream, continuation) = AsyncStream<RemoteMessage>.makeStream()
            outbox = continuation
            outboxTask = Task {
                for await message in stream { await channel.send(message) }
            }
            Task { await channel.start() }
        } else if playerChanged, channelState == .joined {
            announce()  // what it's playing changed
            publish(force: true)
        }
        #if os(macOS)
        if controllable, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Answering Bluebox's remote")
        } else if !controllable, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        #endif
        startTicker()
    }

    /// Back in front, or the remote opened: reconnect now if the channel is down, rather than after its wait.
    func wake() {
        guard let channel, channelState != .joined else { return }
        Task { await channel.reconnect() }
    }

    /// Try Again: reconnect now, whatever the channel thinks, and ask the Mac to answer.
    public func retry() {
        macNotAnswering = false
        guard let channel else { return }
        Task { await channel.reconnect() }
    }

    private func disconnect() {
        ticker?.cancel(); ticker = nil
        for (_, u) in unacked { u.retry.cancel() }
        unacked.removeAll()
        if let channel {
            self.channel = nil
            // The farewell above (and anything else queued) goes out before the socket closes.
            outbox?.finish(); outbox = nil
            let drained = outboxTask
            outboxTask = nil
            Task {
                await drained?.value
                await channel.stop()
            }
        }
        #if os(macOS)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        #endif
        channelState = .stopped
        joinedAt = nil
        macNotAnswering = false
        reconciler.clear()
        nowPlaying = nil
        heard.removeAll()
        devices = []
        screen = nil
    }

    private func channelChanged(_ state: RemoteChannel.State) {
        guard channel != nil || state == .stopped else { return }
        channelState = state
        guard state == .joined else { return }
        joinedAt = now()
        // A state resync: the Mac publishes in full, the phone asks for one; both say who they are.
        announce()
        if player != nil { publish(force: true) }
        if controllable { publishScreen(force: true) } else { sayHello() }
    }

    private func enqueue(_ message: RemoteMessage) { outbox?.yield(message) }

    /// Once a second: the phone runs its clock forward; the Mac publishes when due.
    private func startTicker() {
        guard ticker == nil else { return }
        let interval = timing.tick
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let date = now()
        if channelState == .joined, lastAnnounced.map({ date.timeIntervalSince($0) >= RemoteDevice.announceInterval }) ?? true {
            announce()
        }
        pruneDevices(at: date)
        if player != nil { publish(force: false) }
        if controllable { return }
        if channelState == .joined, let lastHello {
            let since = date.timeIntervalSince(lastHello)
            let justJoined = joinedAt.map { date.timeIntervalSince($0) < timing.helloUntilHeardFor } ?? false
            if reconciler.published == nil, screenOpen || justJoined, since >= timing.helloUntilHeard {
                sayHello()
            } else if screenOpen, since >= 15 {
                sayHello()
            }
        }
        refreshDisplayed()
    }

    private func receive(_ message: RemoteMessage) {
        switch message {
        case .state(let s):
            guard player == nil, !controllable else { return }
            if let target, s.deviceID != target { return }  // the remote follows the device chosen
            reconciler.receive(s, at: now())
            refreshDisplayed()
        case .stopped(let id):
            reconciler.stopped(deviceID: id)
            refreshDisplayed()
        case .ack(let ack):
            guard !controllable else { return }
            unacked.removeValue(forKey: ack.commandID)?.retry.cancel()
            macNotAnswering = false
            reconciler.acknowledged(ack, at: now())
            refreshDisplayed()
        case .device(let d):
            guard d.id != deviceID else { return }
            heard[d.id] = (d, now())
            pruneDevices(at: now())
        case .screen(let s):
            guard !controllable, s.deviceID == (target ?? controlled?.id) else { return }
            if s != screen { screen = s }
        case .hello(let from):
            guard controllable || player != nil else { return }
            lastRemoteSeen = now()
            if heard[from] == nil { announce() }  // a remote that hasn't heard of us yet
            publish(force: true)
            publishScreen(force: true)
        case .command(let command):
            guard command.target == deviceID, controllable || player != nil else { return }
            lastRemoteSeen = now()
            // A scroll or pointer move is never retried, so it needs no ack.
            if !command.action.isContinuous { enqueue(.ack(RemoteAck(commandID: command.id, deviceID: deviceID, seq: seq))) }
            guard !applied.contains(command.id) else { return }  // a retry of one already applied
            applied.append(command.id)
            if applied.count > 64 { applied.removeFirst(applied.count - 64) }
            let previous = applying
            let settle = timing.settle
            let driver = command.from.flatMap { heard[$0]?.device.name } ?? String(localized: "Remote")
            applying = Task {
                await previous?.value
                await self.apply(command.action, driver: driver)
                // Give the engine a moment to report the change, then tell the remote.
                Task { [weak self] in
                    try? await Task.sleep(for: settle)
                    self?.publish(force: true)
                    self?.publishScreen(force: false)
                }
            }
        }
    }

    // MARK: Devices

    private func announce() {
        guard channel != nil, channelState == .joined else { return }
        lastAnnounced = now()
        enqueue(.device(RemoteDevice(id: deviceID, name: Self.deviceName, kind: Self.deviceKind, controllable: controllable,
                                     playing: player?.item?.title)))
    }

    private func pruneDevices(at date: Date) {
        heard = heard.filter { date.timeIntervalSince($0.value.at) < RemoteDevice.goneAfter }
        let online = heard.values.map(\.device).filter(\.controllable)
            .sorted { ($0.playing == nil ? 1 : 0, $0.name) < ($1.playing == nil ? 1 : 0, $1.name) }
        if online != devices { devices = online }
    }

    private func targetChanged() {
        // The remote follows the chosen device: forget what another one published.
        if let target, let shown = reconciler.published, shown.deviceID != target { reconciler.clear() }
        screen = nil
        refreshDisplayed()
        sayHello()
    }

    private static func device(for s: RemoteNowPlaying) -> RemoteDevice {
        RemoteDevice(id: s.deviceID, name: s.deviceName, kind: .mac, controllable: true, playing: s.title,
                     version: s.acknowledges ? 2 : 1)
    }

    // MARK: The phone

    private func refreshDisplayed() {
        let date = now()
        let shown = reconciler.displayed(at: date)
        if shown != nowPlaying { nowPlaying = shown }
        let waiting = reconciler.pendingKinds(at: date)
        if waiting != awaiting { awaiting = waiting }
    }

    private func sayHello() {
        guard channel != nil, channelState == .joined, !controllable else { return }
        lastHello = now()
        enqueue(.hello(from: deviceID))
    }

    /// Sends a command to the controlled device. Player commands draw at once.
    public func send(_ action: RemoteCommand.Action) {
        guard channel != nil, let device = controlled else { return }
        if action.isAppCommand, device.version < 3 { return }  // a build without app commands
        if action.needsVersion4, device.version < 4 {
            // A Mac from before the better remote: a jump becomes single steps; the rest it can't do.
            if case .jump(let j) = action { for _ in 0..<j.count { send(.move(j.direction)) } }
            return
        }
        let command = RemoteCommand(target: device.id, action: action, from: deviceID)
        if !action.isAppCommand {
            // A newer command of the same kind replaces an unanswered one: stop sending that.
            for (id, u) in unacked where !u.action.isAppCommand && RemoteReconciler.kind(u.action) == RemoteReconciler.kind(action) {
                u.retry.cancel()
                unacked[id] = nil
            }
            reconciler.apply(action, id: command.id, at: now())
            refreshDisplayed()
        }
        enqueue(.command(command))
        if action.isContinuous { return }  // never retried (`isContinuous`)
        // Builds before acks would apply a resent Next Episode twice.
        let acknowledges = action.isAppCommand || (nowPlaying?.acknowledges ?? (device.version >= 2))
        guard acknowledges else { return }
        let waits = timing.retries
        let retry = Task { [weak self] in
            for wait in waits {
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled, self.unacked[command.id] != nil else { return }
                self.enqueue(.command(command))
            }
            try? await Task.sleep(for: waits.last ?? .seconds(1))
            guard let self, !Task.isCancelled, self.unacked[command.id] != nil else { return }
            self.gaveUp(on: command.id)
        }
        unacked[command.id] = (action, retry)
    }

    /// No ack after every retry: show the Mac's word again, say so, and make sure our own socket isn't the problem.
    private func gaveUp(on id: UUID) {
        unacked[id] = nil
        reconciler.abandon(id)
        refreshDisplayed()
        macNotAnswering = true
        if let channel { Task { await channel.reconnect() } }
    }

    /// ±10 s from what the remote shows, so quick taps add up.
    public func skip(by delta: TimeInterval) {
        guard let s = nowPlaying else { return }
        let target = max(0, s.position + delta)
        send(.seek(s.duration.map { min(target, $0) } ?? target))
    }

    /// While the finger moves: the Mac's picture follows, a few times a second.
    public func scrub(to seconds: TimeInterval) {
        let date = now()
        if let last = lastScrubSent, date.timeIntervalSince(last) < timing.scrubInterval { return }
        lastScrubSent = date
        send(.scrub(seconds))
    }

    /// The finger lifted: land there and play on.
    public func endScrub(at seconds: TimeInterval) {
        lastScrubSent = nil
        send(.seek(seconds))
    }

    /// A device picked in the Play On menu: it becomes the one controlled, and the
    /// remote opens on it straight away, so an idle Mac can be browsed without
    /// playing something first. This iPhone (nil) only stops playing elsewhere.
    public func choose(_ deviceID: String?) {
        target = deviceID
        if deviceID != nil { presentRequest += 1 }
    }

    /// Open Remote: the remote for the chosen device, or the only one there is.
    public func openRemote() {
        guard controlled != nil else { return }
        presentRequest += 1
    }

    /// "Play on" another device: Play there instead of here, and open the remote. False when nothing's chosen.
    public func playOnTarget(_ play: RemotePlay) -> Bool {
        guard let target, devices.contains(where: { $0.id == target && $0.version >= 3 }) else { return false }
        send(.play(play))
        presentRequest += 1
        return true
    }

    /// A page opened on the phone opens on the chosen device too.
    public func follow(_ destination: RemoteDestination) {
        guard let target, devices.contains(where: { $0.id == target && $0.version >= 3 }) else { return }
        send(.go(destination))
    }

    // MARK: The Mac

    private func apply(_ action: RemoteCommand.Action, driver: String) async {
        switch action {
        case .go(let d): handler?.remoteGo(d)
        case .focus(let id): handler?.remoteFocus(id, driver: driver)
        case .move(let d): handler?.remoteMove(d, driver: driver)
        case .select: handler?.remoteSelect(driver: driver)
        case .play(let p): await handler?.remotePlay(p)
        case .closePlayer: await handler?.remoteClosePlayer()
        case .jump, .scroll, .setPointer, .pointer, .click, .menu, .menuPick, .acceptSkip: handler?.remote4(action, driver: driver)
        default:
            guard let player else { return }
            await Self.apply(action, to: player)
        }
    }

    /// The Mac's screen or highlight changed (`AppModel` calls this): tell the remote.
    public func screenChanged() { publishScreen(force: false) }

    private func publishScreen(force: Bool) {
        guard controllable, channel != nil, channelState == .joined, let handler else { return }
        var screen = handler.remoteScreen()
        screen.deviceID = deviceID
        guard force || screen != lastScreen else { return }
        lastScreen = screen
        enqueue(.screen(screen))
    }

    private func publish(force: Bool) {
        guard let player, channel != nil, channelState == .joined, let state = makeState(player) else { return }
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
        enqueue(.state(published))
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
                                volume: s.isMuted ? 0 : s.volume, hasNext: item.key.episodeNumbers != nil,
                                skipOffer: handler?.remoteSkipOffer(),
                                chapters: s.snapshot.chapters.isEmpty ? nil : s.snapshot.chapters.map(\.start))
    }

    /// The bridge to the player: only `PlayerSession`'s public controls.
    static func apply(_ action: RemoteCommand.Action, to s: PlayerSession) async {
        switch action {
        case .setPaused(let paused):
            if paused == s.appearsPlaying { s.togglePlayPause() }
        case .seek(let t):
            if s.isScrubbing { await s.endScrub(at: t) } else { await s.seek(to: t) }
        case .scrub(let t):
            s.scrub(to: t)
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
        case .closePlayer, .go, .focus, .move, .select, .play, .jump, .scroll, .setPointer, .pointer, .click, .menu,
             .menuPick, .acceptSkip:
            break  // the app's, not the player's
        }
    }

    #if DEBUG
    /// `-seed-remote` (with `-ui-testing`): show a Mac playing, without a channel, for screenshots of the remote.
    public func seedForReview() {
        seededForReview = true
        channelState = .joined
        let mac = RemoteDevice(id: "review-mac", name: "Studio", kind: .mac, controllable: true, playing: "Severance")
        let other = RemoteDevice(id: "review-other", name: "Living Room Mac", kind: .mac, controllable: true)
        heard = [mac.id: (mac, .distantFuture), other.id: (other, .distantFuture)]
        devices = [mac, other]
        target = mac.id
        screen = RemoteScreen(deviceID: mac.id, title: "Home", focusedID: "title:severance", focusedLabel: "Severance",
                              focused: RemoteScreenItem(label: "Severance", kind: .poster),
                              before: RemoteScreenItem(label: "Under Blue Ice", kind: .poster),
                              after: RemoteScreenItem(label: "Harbor Lights", kind: .poster),
                              horizontal: true, section: "Continue Watching", bumps: 0)
        // `-seed-remote-idle`: the Mac on Home with nothing playing, for the remote's getting-around screen.
        if ProcessInfo.processInfo.arguments.contains("-seed-remote-idle") {
            refreshDisplayed()
            return
        }
        reconciler.receive(RemoteNowPlaying(
            deviceID: mac.id, deviceName: "Studio", title: "Severance", subtitle: "S1·E2 · Half Loop",
            position: 1_312, duration: 3_240, paused: false,
            audioTracks: [RemoteTrack(id: "a1", label: "English · 5.1"), RemoteTrack(id: "a2", label: "Español · Stereo")],
            subtitleTracks: [RemoteTrack(id: "s1", label: "English"), RemoteTrack(id: "s2", label: "English (SDH)"),
                             RemoteTrack(id: "s3", label: "Français")],
            audioID: "a1", subtitleID: "s1", volume: 0.7, hasNext: true, skipOffer: "Skip Intro",
            chapters: [0, 95, 1_260, 2_410], seq: 1), at: now())
        // Never stale while the screenshot is taken.
        reconciler.staleAfter = .infinity
        refreshDisplayed()
    }
    #endif

    static let deviceName: String = {
        #if os(macOS)
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        #else
        "iPhone"
        #endif
    }()

    static var deviceKind: RemoteDevice.Kind {
        #if os(macOS)
        .mac
        #elseif os(tvOS)
        .appleTV
        #else
        .iPhone
        #endif
    }
}
