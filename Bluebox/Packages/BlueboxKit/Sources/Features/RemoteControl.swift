import Domain
import Foundation
import Metadata
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
    /// Protocol 4: jumps, scrolling, the pointer, menus and the skip button;
    /// protocol 5: typing into a field and holding at the edge.
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
/// What's on its screen goes out only while a remote is about (a hello or
/// command in the last 45 s). With nothing playing and no remote about, it
/// lets App Nap have it and ticks every 10 s, enough to keep announcing
/// itself; a device joining is answered at once, so a phone still finds it.
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
///
/// Feeling quick (the quicker remote, 21 Nov 2026): the phone keeps its Mac,
/// its screen and its player through a trip to the background and says
/// hello on its way back, which the Mac always answers, so it can be used
/// again within one round trip. A move, the pointer switch, a bump at the
/// end of a row and a menu pick show on the phone at once (`predict`) and the
/// Mac's screen corrects them. The Mac publishes a player command as soon as
/// its player shows it, with `Timing.settle` only as the longest wait.
@MainActor @Observable
public final class RemoteControl {
    /// What the remote says about the link to the Mac.
    public enum Connection: Sendable, Equatable {
        case off, connecting, connected
        /// Joined, and the last command has gone unanswered for a while (two
        /// sends): amber, while it's still being sent.
        case lagging
        /// Joined, but the Mac didn't acknowledge the last command.
        case notAnswering
    }

    /// What the phone shows; nil when the controlled device isn't playing.
    public private(set) var nowPlaying: RemoteNowPlaying?
    public private(set) var channelState: RemoteChannel.State = .stopped
    /// The last command's retries all went unanswered. Cleared by the next ack:
    /// the Mac's states can keep coming while it doesn't hear us.
    public private(set) var macNotAnswering = false
    /// The last command has been sent twice without an answer (`Connection.lagging`).
    public private(set) var macLagging = false
    /// Back from the background (or just joined) and not yet heard from the
    /// Mac: the remote says Reconnecting… rather than No Mac to Control.
    public private(set) var reconnecting = false
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
        case .joined: macNotAnswering ? .notAnswering : macLagging ? .lagging : .connected
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
        /// The Mac's clock while it's idle (`isIdle`): often enough to announce
        /// itself every 20 to 30 s, well inside `RemoteDevice.goneAfter`.
        var idleTick: Duration = .seconds(10)
        /// While a remote is about, the screen goes out again this often even
        /// unchanged, so a lost one can't leave the phone's strip stale for long.
        var screenResend: TimeInterval = 10
        /// Back from the background, the devices it knew are kept this long
        /// for their own announce to arrive (one round trip, usually).
        var rejoinGrace: TimeInterval = 10
        /// Heard from the Mac this recently: the channel works, and a command
        /// it didn't answer is no reason to reconnect.
        var heardRecently: TimeInterval = 5
        /// A move drawn on the phone gives way to the Mac's screen after this, answered or not.
        var predictionHold: TimeInterval = 1.5
    }

    @ObservationIgnored private var channel: (any RemoteTransport)?
    /// Counts the channels made, so only the current one's state counts.
    @ObservationIgnored private var channelGeneration = 0
    @ObservationIgnored private var outbox: AsyncStream<RemoteMessage>.Continuation?
    @ObservationIgnored private var outboxTask: Task<Void, Never>?
    @ObservationIgnored private var reconciler = RemoteReconciler()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// The ticker is in its idle wait (`timing.idleTick`): a remote speaking, or a player opening, cuts it short.
    @ObservationIgnored private var tickingIdle = false
    @ObservationIgnored private var lastHello: Date?
    @ObservationIgnored private var joinedAt: Date?
    @ObservationIgnored private var lastAnnounced: Date?
    /// Every device heard from (phones too, for the Mac to name its driver), and when.
    @ObservationIgnored private var heard: [String: (device: RemoteDevice, at: Date)] = [:]
    /// Commands the Mac hasn't acknowledged yet, with their retry loops.
    @ObservationIgnored private var unacked: [UUID: (action: RemoteCommand.Action, retry: Task<Void, Never>)] = [:]
    @ObservationIgnored private var lastScrubSent: Date?
    /// The last time anything came from the controlled device (`Timing.heardRecently`).
    @ObservationIgnored private var lastHeardFromMac: Date?
    /// A state or screen has arrived since joining: the hellos can stop.
    @ObservationIgnored private var heardSinceJoin = false
    /// The Mac's own last screen, under one the phone drew ahead of it (`predict`).
    @ObservationIgnored private var macScreen: RemoteScreen?
    /// The newest command drawn ahead on the strip, and when: the Mac's screens
    /// that don't answer it yet are held back, so the strip doesn't step back and forth.
    @ObservationIgnored private var predicted: (id: UUID, at: Date)?
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
    @ObservationIgnored private var lastScreenAt: Date?
    /// From the clock, so a relaunched Mac carries on above what remotes last saw from it.
    @ObservationIgnored private var seq: Int
    /// Command IDs already applied: a retry is acknowledged again but not applied twice.
    @ObservationIgnored private var applied: [UUID] = []
    /// The command being applied; the next one waits for it.
    @ObservationIgnored private var applying: Task<Void, Never>?
    /// A screen waiting to go out (`screenChanged`).
    @ObservationIgnored private var screenPending: Task<Void, Never>?
    /// The last command applied (`RemoteScreen.answers`).
    @ObservationIgnored private var lastApplied: UUID?
    #if DEBUG
    /// Showing `seedForReview`'s state: the channel is left alone.
    @ObservationIgnored private var seededForReview = false
    #endif
    #if os(macOS)
    /// Keeps App Nap from slowing the channel while a remote is being used:
    /// held for `remoteLinger` after its last hello or command, not for as long
    /// as the switch is on (`holdActivity`).
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
    /// `away`: not wanted only because the app is in the background, so what
    /// the remote showed is kept for its return (`disconnect`).
    func update(wanted: Bool, away: Bool = false, controllable: Bool, account: AccountModel, player: PlayerSession?) {
        update(wanted: wanted, away: away, controllable: controllable, player: player) { onMessage, onState in
            account.makeRemoteChannel(onMessage: onMessage, onState: onState)
        }
    }

    func update(wanted: Bool, away: Bool = false, controllable: Bool = false, player: PlayerSession?,
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
        guard wanted else { disconnect(keep: away && !controllable); return }
        if channel == nil {
            // A channel left behind (the background) reports its stop late: it mustn't mark this one stopped.
            channelGeneration += 1
            let generation = channelGeneration
            channel = makeChannel({ [weak self] message in
                Task { @MainActor in self?.receive(message) }
            }, { [weak self] state in
                Task { @MainActor in
                    guard let self, self.channelGeneration == generation else { return }
                    self.channelChanged(state)
                }
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
            publishScreen(force: true)
        }
        #if os(macOS)
        // Held only while a remote is being used (`heardRemote`); one that stops taking commands lets go now.
        if !controllable { holdActivity(false) }
        #endif
        // Also brings the clock out of its idle wait when a player opens.
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
        macLagging = false
        guard let channel else { return }
        Task { await channel.reconnect() }
    }

    /// Leaves the channel. `keep`: a phone going into the background keeps
    /// its devices, screen and player, drawn as reconnecting, so coming back
    /// it has its Mac at once; switched off or signed out, it forgets them.
    private func disconnect(keep: Bool = false) {
        ticker?.cancel(); ticker = nil
        tickingIdle = false
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
        holdActivity(false)
        #endif
        channelState = .stopped
        joinedAt = nil
        macNotAnswering = false
        macLagging = false
        predicted = nil
        if keep {
            reconnecting = true
            return
        }
        reconnecting = false
        reconciler.clear()
        nowPlaying = nil
        heard.removeAll()
        devices = []
        screen = nil
        macScreen = nil
    }

    private func channelChanged(_ state: RemoteChannel.State) {
        guard channel != nil || state == .stopped else { return }
        channelState = state
        guard state == .joined else { return }
        joinedAt = now()
        heardSinceJoin = false
        if !controllable {
            // Back from the background: what it knew gets `rejoinGrace` for its
            // own announce to arrive, however long it was away.
            let date = now()
            let since = date.addingTimeInterval(timing.rejoinGrace - RemoteDevice.goneAfter)
            for (id, h) in heard where h.at < since { heard[id] = (h.device, since) }
            if devices.isEmpty { reconnecting = true }
        }
        // A state resync: the Mac publishes in full, the phone asks for one; both say who they are.
        announce()
        if player != nil { publish(force: true) }
        if controllable { publishScreen(force: true) } else { sayHello() }
    }

    private func enqueue(_ message: RemoteMessage) { outbox?.yield(message) }

    /// Once a second: the phone runs its clock forward; the Mac publishes when
    /// due. A Mac nobody is using (`isIdle`) ticks only every `timing.idleTick`,
    /// to announce itself, so the switch being on doesn't keep it from idling;
    /// a phone finds it anyway, since its arrival is answered at once (`receive`).
    private func startTicker() {
        // In the idle wait, but not idle any more (a remote spoke, a player opened): start again at the fast pace.
        if tickingIdle, !isIdle(at: now()) { ticker?.cancel(); ticker = nil; tickingIdle = false }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.nextTick() else { return }
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// How long until the next tick, noting whether it's the idle wait.
    private func nextTick() -> Duration {
        tickingIdle = isIdle(at: now())
        return tickingIdle ? timing.idleTick : timing.tick
    }

    /// A remote said hello or sent a command within `remoteLinger`.
    func remoteActive(at date: Date) -> Bool {
        lastRemoteSeen.map { date.timeIntervalSince($0) < Self.remoteLinger } ?? false
    }

    /// A Mac with nothing playing that no remote has spoken to lately. A
    /// phone keeps its fast clock (its own display and hellos run on it), and
    /// so does a Mac playing, whose changes (play, pause, tracks) are noticed on the tick.
    func isIdle(at date: Date) -> Bool {
        controllable && player == nil && !remoteActive(at: date)
    }

    /// A remote said hello or sent a command: answer it briskly for `remoteLinger`.
    private func heardRemote() {
        lastRemoteSeen = now()
        #if os(macOS)
        if controllable { holdActivity(true) }
        #endif
        startTicker()
    }

    #if os(macOS)
    private func holdActivity(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Answering Bluebox's remote")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
    #endif

    private func tick() {
        let date = now()
        let remoteAbout = remoteActive(at: date)
        #if os(macOS)
        // No remote for `remoteLinger`: App Nap may have the Mac again.
        if !remoteAbout { holdActivity(false) }
        #endif
        if channelState == .joined, lastAnnounced.map({ date.timeIntervalSince($0) >= RemoteDevice.announceInterval }) ?? true {
            announce()
        }
        pruneDevices(at: date)
        if player != nil { publish(force: false) }
        // Now and then the screen again (it carries the player too) while a remote is
        // about, playing or not: a lost one would leave the phone's strip stale.
        if controllable, remoteAbout, lastScreenAt.map({ date.timeIntervalSince($0) >= timing.screenResend }) ?? true {
            publishScreen(force: true)
        }
        if controllable { return }
        // Joined a while ago and nobody answered: not reconnecting any more, just nothing there.
        if reconnecting, channelState == .joined, let joinedAt, date.timeIntervalSince(joinedAt) >= timing.rejoinGrace {
            reconnecting = false
        }
        // A drawn move nobody answered: the Mac's word again.
        if let p = predicted, date.timeIntervalSince(p.at) >= timing.predictionHold {
            predicted = nil
            if let macScreen, macScreen != screen { screen = macScreen }
        }
        if channelState == .joined, let lastHello {
            let since = date.timeIntervalSince(lastHello)
            let justJoined = joinedAt.map { date.timeIntervalSince($0) < timing.helloUntilHeardFor } ?? false
            // Until a state or a screen answers (each hello costs the Mac a walk of its window). Not
            // "until one is shown": back from the background the old ones still are.
            if !heardSinceJoin, screenOpen || justJoined, since >= timing.helloUntilHeard {
                sayHello()
            } else if screenOpen, since >= 15 {
                sayHello()
            }
        }
        refreshDisplayed()
    }

    private func receive(_ message: RemoteMessage) {
        if !controllable, let from = message.sender, from == (target ?? controlled?.id) { lastHeardFromMac = now() }
        switch message {
        case .state(let s):
            guard player == nil, !controllable else { return }
            if let target, s.deviceID != target { return }  // the remote follows the device chosen
            heardSinceJoin = true
            reconciler.receive(s, at: now())
            refreshDisplayed()
        case .stopped(let id):
            reconciler.stopped(deviceID: id)
            refreshDisplayed()
        case .ack(let ack):
            guard !controllable else { return }
            unacked.removeValue(forKey: ack.commandID)?.retry.cancel()
            macNotAnswering = false
            macLagging = false
            reconciler.acknowledged(ack, at: now())
            refreshDisplayed()
        case .device(let d):
            guard d.id != deviceID else { return }
            let new = heard[d.id] == nil
            heard[d.id] = (d, now())
            pruneDevices(at: now())
            if d.controllable { reconnecting = false }
            // A device just joined (a phone opening Bluebox): it hears of this
            // Mac at once, rather than at the next announce, up to 30 s off while idle.
            if new, controllable { announce() }
        case .screen(let s):
            guard !controllable, s.deviceID == (target ?? controlled?.id) else { return }
            reconnecting = false
            heardSinceJoin = true
            let wasPlaying = screen?.playing != nil
            macScreen = s
            // The strip was moved ahead of the Mac: an older screen (worked out before
            // the newest drawn move landed) would step it back, so it waits for the answer.
            if let p = predicted, s.answers != nil, s.answers != p.id, now().timeIntervalSince(p.at) < timing.predictionHold {
                // Still take what isn't the highlight's: the player, a menu closing.
                if var shown = screen, shown.playing != s.playing { shown.playing = s.playing; screen = shown }
            } else {
                predicted = nil
                if s != screen { screen = s }
            }
            if let playing = s.playing, playing.deviceID == s.deviceID {
                reconciler.receive(playing, at: now())
                refreshDisplayed()
            } else if wasPlaying {
                // Its player closed (a Mac that never carries the player here never gets this far).
                reconciler.stopped(deviceID: s.deviceID)
                refreshDisplayed()
            }
        case .hello:
            guard controllable || player != nil else { return }
            heardRemote()
            // Always, not only to a remote new to us: a phone back from the background
            // forgot nothing, but its devices are waiting on this to say we're still here.
            announce()
            publish(force: true)
            publishScreen(force: true)
        case .command(let command):
            guard command.target == deviceID, controllable || player != nil else { return }
            heardRemote()
            // A scroll or pointer move is never retried, so it needs no ack.
            if !command.action.isContinuous { enqueue(.ack(RemoteAck(commandID: command.id, deviceID: deviceID, seq: seq))) }
            guard !applied.contains(command.id) else { return }  // a retry of one already applied
            applied.append(command.id)
            if applied.count > 64 { applied.removeFirst(applied.count - 64) }
            let driver = command.from.flatMap { heard[$0]?.device.name } ?? String(localized: "Remote")
            let run = { [weak self] in
                guard let self else { return }
                await self.apply(command.action, driver: driver)
                self.lastApplied = command.id
                self.answer(command.action)
            }
            if Self.runsAlone(command.action) {
                // Opening a stream can take a minute: the swipes and Back that follow mustn't queue behind it.
                Task { await run() }
            } else {
                let previous = applying
                applying = Task {
                    await previous?.value
                    await run()
                }
            }
        }
    }

    /// After applying a command, tell the remote what it did. A scrub or a
    /// pointer move says nothing (dozens a second; the seek that ends a scrub
    /// does). A move sends its own screen (`screenChanged`, from the
    /// highlight's walk). A player command goes out as soon as the player shows
    /// it, `settle` at the latest; the rest after `settle`, for the page to change.
    private func answer(_ action: RemoteCommand.Action) {
        if action.isContinuous { return }
        let settle = timing.settle
        switch action {
        case .move, .jump, .focus, .setPointer, .repeatMove, .text:
            // Under the player a move seeks: that still goes out (no walk of the window under it).
            guard player != nil else { return }
            Task { [weak self] in
                try? await Task.sleep(for: settle)
                self?.publish(force: true)
                self?.publishScreen(force: false)
            }
            return
        default: break
        }
        Task { [weak self] in
            if !action.isAppCommand {
                let deadline = ContinuousClock.now + settle
                while ContinuousClock.now < deadline {
                    guard let self else { return }
                    if let player = self.player, let state = self.makeState(player), RemoteReconciler.confirms(state, action) { break }
                    try? await Task.sleep(for: .milliseconds(15))
                }
            } else {
                try? await Task.sleep(for: settle)
            }
            self?.publish(force: true)
            self?.publishScreen(force: false)
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
        macScreen = nil
        predicted = nil
        heardSinceJoin = false
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

    /// Sends a command to the controlled device. Player commands draw at once,
    /// and so do the moves the strip can show (`predict`).
    public func send(_ action: RemoteCommand.Action) {
        guard channel != nil, let device = controlled else { return }
        if action.isAppCommand, device.version < 3 { return }  // a build without app commands
        if action.needsVersion4, device.version < 4 {
            // A Mac from before the better remote: a jump becomes single steps; the rest it can't do.
            if case .jump(let j) = action { for _ in 0..<j.count { send(.move(j.direction)) } }
            return
        }
        if action.needsVersion5, device.version < 5 { return }  // the views send what such a Mac knows instead
        let command = RemoteCommand(target: device.id, action: action, from: deviceID)
        if action.isAppCommand {
            // On the strip at once; the Mac's screen answering this command settles it.
            // Anything else the strip can't foresee lets the Mac's next screen through.
            if let shown = screen, let next = Self.predict(action, on: shown) {
                screen = next
                predicted = (command.id, now())
            } else {
                predicted = nil
            }
        }
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
            for (i, wait) in waits.enumerated() {
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled, self.unacked[command.id] != nil else { return }
                // Sent and resent with no answer: amber now, rather than only once every retry has gone.
                if i >= 1 { self.macLagging = true }
                self.enqueue(.command(command))
            }
            try? await Task.sleep(for: waits.last ?? .seconds(1))
            guard let self, !Task.isCancelled, self.unacked[command.id] != nil else { return }
            self.gaveUp(on: command.id)
        }
        unacked[command.id] = (action, retry)
    }

    /// No ack after every retry: show the Mac's word again and say so. The
    /// socket is reconnected only if it has gone quiet too: still hearing the
    /// Mac means the channel works, and otherwise a heartbeat finds out
    /// (`RemoteTransport.checkAlive`), rather than dropping a good socket.
    private func gaveUp(on id: UUID) {
        unacked[id] = nil
        reconciler.abandon(id)
        refreshDisplayed()
        if predicted?.id == id {
            predicted = nil
            if let macScreen { screen = macScreen }
        }
        macLagging = false
        macNotAnswering = true
        if let last = lastHeardFromMac, now().timeIntervalSince(last) < timing.heardRecently { return }
        if let channel { Task { await channel.checkAlive() } }
    }

    /// What the strip shows right after `action`, before the Mac answers, when
    /// that can be told from the screen alone: a step to the neighbour it
    /// already shows, a bump at an end (`RemoteScreen.edges`), the pointer
    /// switch, a menu closing on a pick. nil: wait for the Mac.
    nonisolated static func predict(_ action: RemoteCommand.Action, on s: RemoteScreen) -> RemoteScreen? {
        var p = s
        switch action {
        case .setPointer(let on):
            p.pointer = on ? true : nil
            return p
        case .menuPick:
            guard s.menu != nil else { return nil }
            p.menu = nil
            return p
        case .move(let d):
            guard s.pointer != true, s.menu == nil, let focused = s.focused, let horizontal = s.horizontal else { return nil }
            if s.edges?.contains(d) == true {
                p.bumps = (s.bumps ?? 0) + 1
                return p
            }
            let forward: Bool
            switch (horizontal, d) {
            case (true, .right), (false, .down): forward = true
            case (true, .left), (false, .up): forward = false
            default: return nil  // off the row: only the Mac knows what's there
            }
            // At the end of what it shows, the Mac may scroll on or bump: its call.
            guard let next = forward ? s.after : s.before else { return nil }
            p.focused = next
            p.focusedLabel = next.label
            p.focusedID = nil
            if forward { p.before = focused; p.after = nil } else { p.after = focused; p.before = nil }
            p.edges = nil
            return p
        default:
            return nil
        }
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
        case .jump, .scroll, .setPointer, .pointer, .click, .menu, .menuPick, .acceptSkip, .text, .repeatMove:
            handler?.remote4(action, driver: driver)
        default:
            guard let player else { return }
            await Self.apply(action, to: player)
        }
    }

    /// The Mac's screen or highlight changed (`AppModel` calls this): tell the remote.
    /// Commands that wait for a stream to open or close (Play, Next Episode,
    /// Close): applied beside the queue, not in it, so the commands after them
    /// (moves, Back to cancel) still land meanwhile.
    nonisolated static func runsAlone(_ action: RemoteCommand.Action) -> Bool {
        switch action {
        case .play, .nextEpisode, .closePlayer: true
        default: false
        }
    }

    /// The highlight or page changed. A move changes it a few times in a row
    /// (the highlight, then a scroll, then the page under it): one screen goes
    /// out for them all, a moment later.
    public func screenChanged() {
        guard screenPending == nil else { return }
        screenPending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self else { return }
            self.screenPending = nil
            self.publishScreen(force: false)
        }
    }

    /// Only while a remote is about (a hello or command within `remoteLinger`):
    /// working out the screen walks the Mac's window (and the first walk turns
    /// on its accessibility tree for good), which is wasted with no phone to
    /// see it: on joining, on every page the Mac's own user opens, every 10 s
    /// of a film. A phone that turns up says hello, and gets one at once.
    private func publishScreen(force: Bool) {
        guard controllable, channel != nil, channelState == .joined, remoteActive(at: now()), let handler else { return }
        var screen = handler.remoteScreen()
        screen.deviceID = deviceID
        screen.answers = lastApplied
        if let player, var state = makeState(player) {
            state.seq = seq
            screen.playing = state
        }
        guard force || !Self.sameScreen(screen, lastScreen) else { return }
        var compared = screen
        compared.playing?.position = 0
        lastScreen = compared
        lastScreenAt = now()
        enqueue(.screen(screen))
    }

    /// Equal apart from the clock: the player's position and its count of
    /// states (which goes up every couple of seconds while it plays) aren't a
    /// new screen, nor which command it answers. Compared with `lastScreen`, already cleared of those.
    nonisolated static func sameScreen(_ a: RemoteScreen, _ last: RemoteScreen?) -> Bool {
        guard let last else { return false }
        var a = a, b = last
        a.playing?.position = 0; a.playing?.seq = 0; a.answers = nil
        b.playing?.position = 0; b.playing?.seq = 0; b.answers = nil
        return a == b
    }

    private func publish(force: Bool) {
        guard let player, channel != nil, channelState == .joined, let state = makeState(player) else { return }
        let date = now()
        if !force, let last = lastPublished {
            let fast = remoteActive(at: date)
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
        // A number JSON can't hold (a stream's unknown length read as NaN or infinity) would
        // stop the whole state from being encoded, and the phone would never see the player.
        let duration = s.snapshot.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let chapters = s.snapshot.chapters.map(\.start).filter(\.isFinite)
        return RemoteNowPlaying(deviceID: deviceID, deviceName: Self.deviceName, title: item.title, subtitle: item.subtitle,
                                position: s.displayPosition.isFinite ? max(s.displayPosition, 0) : 0, duration: duration,
                                paused: !s.appearsPlaying,
                                audioTracks: s.snapshot.audioTracks.map { RemoteTrack(id: $0.id, label: $0.label) },
                                subtitleTracks: s.allSubtitleTracks.map { RemoteTrack(id: $0.id, label: $0.label) },
                                audioID: s.snapshot.selectedAudioID, subtitleID: subtitleID,
                                volume: s.isMuted || !s.volume.isFinite ? 0 : s.volume, hasNext: item.key.episodeNumbers != nil,
                                skipOffer: handler?.remoteSkipOffer(),
                                chapters: chapters.isEmpty ? nil : chapters)
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
             .menuPick, .acceptSkip, .text, .repeatMove:
            break  // the app's, not the player's
        }
    }

    #if DEBUG
    /// `-seed-remote` (with `-ui-testing`): show a Mac playing, without a channel, for screenshots of the remote.
    public func seedForReview() {
        seededForReview = true
        channelState = .joined
        // `-showcase` (README graphics): Blender Studio's open films instead of the usual titles.
        let showcase = SampleMetadataProvider.showcase
        let playing = showcase ? "Cosmos Laundromat" : "Severance"
        let mac = RemoteDevice(id: "review-mac", name: "Studio", kind: .mac, controllable: true, playing: playing)
        let other = RemoteDevice(id: "review-other", name: "Living Room Mac", kind: .mac, controllable: true)
        heard = [mac.id: (mac, .distantFuture), other.id: (other, .distantFuture)]
        devices = [mac, other]
        target = mac.id
        screen = RemoteScreen(deviceID: mac.id, title: "Home", focusedID: "title:severance", focusedLabel: playing,
                              focused: RemoteScreenItem(label: playing, kind: .poster),
                              before: RemoteScreenItem(label: showcase ? "Sintel" : "Under Blue Ice", kind: .poster),
                              after: RemoteScreenItem(label: showcase ? "Tears of Steel" : "Harbor Lights", kind: .poster),
                              horizontal: true, section: "Continue Watching", bumps: 0)
        // `-seed-remote-idle`: the Mac on Home with nothing playing, for the remote's getting-around screen.
        if ProcessInfo.processInfo.arguments.contains("-seed-remote-idle") {
            refreshDisplayed()
            return
        }
        reconciler.receive(RemoteNowPlaying(
            deviceID: mac.id, deviceName: "Studio", title: playing, subtitle: showcase ? nil : "S1·E2 · Half Loop",
            position: showcase ? 41 : 1_312, duration: showcase ? 730 : 3_240, paused: false,
            audioTracks: [RemoteTrack(id: "a1", label: "English · 5.1"), RemoteTrack(id: "a2", label: "Español · Stereo")],
            subtitleTracks: [RemoteTrack(id: "s1", label: "English"), RemoteTrack(id: "s2", label: "English (SDH)"),
                             RemoteTrack(id: "s3", label: "Français")],
            audioID: "a1", subtitleID: "s1", volume: 0.7, hasNext: true, skipOffer: "Skip Intro",
            chapters: showcase ? [0, 160, 410, 600] : [0, 95, 1_260, 2_410], seq: 1), at: now())
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

private extension RemoteMessage {
    /// The device it came from, where it says.
    var sender: String? {
        switch self {
        case .state(let s): s.deviceID
        case .command(let c): c.from
        case .hello(let from): from
        case .stopped(let id): id
        case .ack(let a): a.deviceID
        case .device(let d): d.id
        case .screen(let s): s.deviceID
        }
    }
}
