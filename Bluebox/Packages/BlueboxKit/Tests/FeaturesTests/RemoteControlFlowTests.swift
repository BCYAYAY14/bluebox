import Domain
@testable import Features
import Foundation
import Persistence
import Playback
import Subtitles
import Sync
import Testing

/// The remote end to end: a Mac's `RemoteControl` with a real `PlayerSession`
/// and a phone's, talking over an in-memory channel that can drop messages
/// and go offline the way Realtime does. One test per way it used to fail.
@MainActor
@Suite(.serialized) struct RemoteControlFlowTests {
    static let fast = RemoteControl.Timing(tick: .milliseconds(40), retries: [.milliseconds(80), .milliseconds(80), .milliseconds(80)],
                                           settle: .milliseconds(10), helloUntilHeard: 0.1, helloUntilHeardFor: 30)

    struct Pair {
        let hub: FakeRemoteHub
        let mac: RemoteControl
        let phone: RemoteControl
        let macLink: FakeRemoteLink
        let phoneLink: FakeRemoteLink
        let engine: RemoteTestEngine
        let player: PlayerSession
    }

    func pair(macFirst: Bool = false, macClock: @escaping () -> Date = { Date() }) async throws -> Pair {
        let hub = FakeRemoteHub()
        let engine = RemoteTestEngine()
        let player = PlayerSession(engine: engine, progress: try LibraryStore.make(inMemory: true))
        await player.start(NowPlayingItem(key: .movie(tmdbID: 1), title: "Severance"), resource: Self.resource)
        let mac = RemoteControl(defaults: Self.defaults(), now: macClock, timing: Self.fast)
        let phone = RemoteControl(defaults: Self.defaults(), now: { Date() }, timing: Self.fast)
        let macLink = hub.link("mac"), phoneLink = hub.link("phone")
        if macFirst {
            mac.update(wanted: true, player: player, makeChannel: macLink.make)
            #expect(await until { mac.channelState == .joined })
        }
        phone.update(wanted: true, player: nil, makeChannel: phoneLink.make)
        if !macFirst { mac.update(wanted: true, player: player, makeChannel: macLink.make) }
        return Pair(hub: hub, mac: mac, phone: phone, macLink: macLink, phoneLink: phoneLink, engine: engine, player: player)
    }

    // MARK: Delivery

    /// Was: a command sent while the Mac reconnected (every 40 minutes for a
    /// new token, on any network blip, after sleep) vanished, and the remote
    /// snapped back four seconds later.
    @Test func aCommandSentWhileTheMacReconnectsStillLands() async throws {
        let p = try await pair()
        #expect(await until { p.phone.nowPlaying != nil })
        p.macLink.goOffline()
        p.phone.send(.seek(600))
        #expect(p.phone.nowPlaying.map { abs($0.position - 600) < 2 } == true)  // drawn at once
        try await Task.sleep(for: .milliseconds(100))
        p.macLink.comeBack()
        #expect(await until { p.engine.seeks.contains(600) })
        #expect(await until { p.phone.nowPlaying.map { abs($0.position - 600) < 2 } == true })
        #expect(p.phone.connection == .connected)
    }

    /// A retry the Mac already applied is acknowledged again but not applied twice.
    @Test func aRetriedCommandIsAppliedOnce() async throws {
        let p = try await pair()
        #expect(await until { p.phone.nowPlaying != nil })
        p.hub.dropAcks(1)
        p.phone.send(.seek(300))
        #expect(await until { p.hub.sent.filter { if case .command = $0 { true } else { false } }.count >= 2 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(p.engine.seeks.filter { $0 == 300 }.count == 1)
        // Retries stop once acknowledged.
        let commands = p.hub.sent.filter { if case .command = $0 { true } else { false } }.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(p.hub.sent.filter { if case .command = $0 { true } else { false } }.count == commands)
    }

    /// Was: nothing said the Mac had gone deaf; the pick just undid itself.
    @Test func aMacThatNeverAnswersIsShownAsSuch() async throws {
        let p = try await pair()
        #expect(await until { p.phone.nowPlaying != nil })
        p.hub.dropCommands = true
        p.phone.send(.audio("a2"))
        #expect(p.phone.nowPlaying?.audioID == "a2")  // drawn at once
        #expect(await until(.seconds(2)) { p.phone.connection == .notAnswering })
        #expect(p.phone.nowPlaying?.audioID == "a1")  // the Mac's word again
        #expect(await until { p.phoneLink.reconnects >= 1 })  // and our own socket is renewed in case it was ours
        // The next acknowledged command clears it.
        p.hub.dropCommands = false
        p.phone.send(.audio("a2"))
        #expect(await until { p.phone.connection == .connected && p.engine.snapshot.selectedAudioID == "a2" })
    }

    /// Was: quick ±10 taps went out in separate tasks and could land in either order.
    @Test func quickSkipsLandInOrder() async throws {
        let p = try await pair()
        #expect(await until { p.phone.nowPlaying != nil })
        let start = try #require(p.phone.nowPlaying).position
        for _ in 0..<5 { p.phone.skip(by: 10) }
        #expect(await until { p.engine.seeks.count >= 5 })
        #expect(p.engine.seeks == p.engine.seeks.sorted())
        #expect(abs(try #require(p.engine.seeks.last) - (start + 50)) < 1.5)
    }

    /// Was: Next Episode could be sent twice to a Mac from before acks, which
    /// would skip two; such a Mac gets each command once.
    @Test func olderMacsAreNotRetried() async throws {
        let hub = FakeRemoteHub()
        let oldMac = hub.link("old-mac"), phoneLink = hub.link("phone")
        let phone = RemoteControl(defaults: Self.defaults(), now: { Date() }, timing: Self.fast)
        oldMac.bind(onMessage: { _ in }, onState: { _ in })
        await oldMac.start()
        phone.update(wanted: true, player: nil, makeChannel: phoneLink.make)
        #expect(await until { phone.channelState == .joined })
        let old = RemoteNowPlaying(deviceID: "old", deviceName: "Old", title: "T", position: 0, duration: 100, paused: false, hasNext: true,
                                   seq: 1, version: nil)
        await oldMac.send(.state(old))
        #expect(await until { phone.nowPlaying != nil })
        phone.send(.nextEpisode)
        try await Task.sleep(for: .milliseconds(500))
        #expect(hub.sent.filter { if case .command = $0 { true } else { false } }.count == 1)
    }

    // MARK: Joining

    /// Was: the phone's hello could be lost (the Mac mid-reconnect), and then
    /// nothing showed until the Mac's slow publish, up to 15 s later.
    @Test func aLostHelloIsSaidAgain() async throws {
        let hub = FakeRemoteHub()
        let engine = RemoteTestEngine()
        let player = PlayerSession(engine: engine, progress: try LibraryStore.make(inMemory: true))
        await player.start(NowPlayingItem(key: .movie(tmdbID: 1), title: "Severance"), resource: Self.resource)
        let mac = RemoteControl(defaults: Self.defaults(), now: { Date() }, timing: Self.fast)
        mac.update(wanted: true, player: player, makeChannel: hub.link("mac").make)
        #expect(await until { mac.channelState == .joined })
        try await Task.sleep(for: .milliseconds(100))  // its join-time state went out to nobody

        hub.dropHellos(1)
        let phone = RemoteControl(defaults: Self.defaults(), now: { Date() }, timing: Self.fast)
        phone.update(wanted: true, player: nil, makeChannel: hub.link("phone").make)
        #expect(await until(.seconds(1)) { phone.nowPlaying?.title == "Severance" })
    }

    /// Was: a relaunched Mac started its seq at 1 again, and a phone that had
    /// seen the old one ignored every state from the new one.
    @Test func aRelaunchedMacIsHeard() async throws {
        let p = try await pair()
        #expect(await until { p.phone.nowPlaying != nil })
        let before = try #require(p.phone.nowPlaying).seq
        // The Mac quits without a farewell and comes back as a new process, with the same device ID.
        p.macLink.goOffline()
        p.mac.update(wanted: false, player: nil, makeChannel: p.macLink.make)
        let relaunched = RemoteControl(defaults: Self.defaults(id: p.mac.deviceID), now: { Date().addingTimeInterval(5) },
                                       timing: Self.fast)
        let link = p.hub.link("mac-2")
        relaunched.update(wanted: true, player: p.player, makeChannel: link.make)
        #expect(await until { (p.phone.nowPlaying?.seq ?? 0) > before })
    }

    // MARK: The whole app (protocol 3)

    struct AppPair {
        let hub: FakeRemoteHub
        let mac: RemoteControl
        let phone: RemoteControl
        let handler: FakeAppHandler
    }

    /// A controllable Mac with nothing playing, and a phone that has chosen it.
    func appPair() async -> AppPair {
        let hub = FakeRemoteHub()
        let handler = FakeAppHandler()
        let mac = RemoteControl(defaults: Self.defaults(), now: { Date() }, timing: Self.fast)
        mac.handler = handler
        mac.update(wanted: true, controllable: true, player: nil, makeChannel: hub.link("mac").make)
        let phone = RemoteControl(defaults: Self.defaults(), now: { Date() }, timing: Self.fast)
        phone.update(wanted: true, player: nil, makeChannel: hub.link("phone").make)
        _ = await until { phone.devices.count == 1 }
        phone.target = phone.devices.first?.id
        return AppPair(hub: hub, mac: mac, phone: phone, handler: handler)
    }

    /// The Mac announces itself when it joins, and the phone hears it whenever
    /// it joined, so "Play on" lists it without anything playing.
    @Test func aControllableMacIsListedWithNothingPlaying() async {
        let p = await appPair()
        #expect(p.phone.devices.map(\.id) == [p.mac.deviceID])
        #expect(p.phone.devices.first?.controllable == true)
        #expect(p.phone.devices.first?.version == 3)
        #expect(p.phone.nowPlaying == nil)
    }

    /// Go, move, select and play reach the Mac's app, once each, in order,
    /// even when acks are lost and the phone resends them.
    @Test func appCommandsLandOnceAndInOrder() async {
        let p = await appPair()
        p.hub.dropAcks(2)
        p.phone.send(.go(.title(.movie(tmdbID: 7))))
        p.phone.send(.move(.right))
        p.phone.send(.move(.right))
        p.phone.send(.select)
        #expect(await until { p.handler.log.count >= 4 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(p.handler.log == ["go title(tmdb:movie:7)", "move right", "move right", "select"])
    }

    /// The Mac reports where it is and what's highlighted; the phone's Touch pad names it.
    @Test func theScreenFollowsTheHighlight() async {
        let p = await appPair()
        p.handler.focused = ("episode:x", "3 · In Perpetuity")
        p.phone.send(.move(.down))
        #expect(await until { p.phone.screen?.focusedLabel == "3 · In Perpetuity" })
        #expect(p.phone.screen?.title == "Severance")
    }

    /// Play on the phone goes to the chosen Mac (and opens the remote); with
    /// This iPhone chosen it plays here.
    @Test func playGoesToTheChosenDevice() async {
        let p = await appPair()
        let play = RemotePlay(key: .movie(tmdbID: 9), title: "Dune")
        let before = p.phone.presentRequest
        #expect(p.phone.playOnTarget(play))
        #expect(p.phone.presentRequest == before + 1)
        #expect(await until { p.handler.log.contains("play Dune") })
        p.phone.target = nil
        #expect(!p.phone.playOnTarget(play))
    }

    /// With two Macs playing, the remote follows the one chosen, not whichever published last.
    @Test func theRemoteFollowsTheChosenMac() async throws {
        let hub = FakeRemoteHub()
        var players: [PlayerSession] = []
        var macs: [RemoteControl] = []
        for title in ["Severance", "Dune"] {
            let player = PlayerSession(engine: RemoteTestEngine(), progress: try LibraryStore.make(inMemory: true))
            await player.start(NowPlayingItem(key: .movie(tmdbID: title.count), title: title), resource: Self.resource)
            let mac = RemoteControl(defaults: Self.defaults(), now: { Date() }, timing: Self.fast)
            mac.update(wanted: true, controllable: true, player: player, makeChannel: hub.link(title).make)
            players.append(player); macs.append(mac)
        }
        let phone = RemoteControl(defaults: Self.defaults(), now: { Date() }, timing: Self.fast)
        phone.update(wanted: true, player: nil, makeChannel: hub.link("phone").make)
        #expect(await until { phone.devices.count == 2 })
        phone.target = macs[1].deviceID
        #expect(await until { phone.nowPlaying?.title == "Dune" })
        try await Task.sleep(for: .milliseconds(300))  // Severance keeps publishing: still ignored
        #expect(phone.nowPlaying?.title == "Dune")
        #expect(phone.controlled?.id == macs[1].deviceID)
    }

    /// Scrubbing from the phone moves the Mac's picture as it goes (quick
    /// seeks) and lands with one exact seek.
    @Test func scrubbingMovesTheMacLive() async throws {
        let p = try await pair()
        #expect(await until { p.phone.nowPlaying != nil })
        p.phone.scrub(to: 100)
        try await Task.sleep(for: .milliseconds(150))  // past the scrub interval
        p.phone.scrub(to: 200)
        p.phone.scrub(to: 210)  // too soon: skipped
        #expect(await until { p.engine.scrubs.count >= 2 })
        #expect(p.engine.scrubs == [100, 200])
        p.phone.endScrub(at: 220)
        #expect(await until { p.engine.seeks.last == 220 })
        #expect(!p.player.isScrubbing)
    }

    // MARK: Helpers

    static let resource = PlaybackResource(
        variant: MediaVariant(id: "v", sourceID: SourceID("s"), mediaKey: nil, displayName: "v", container: "mp4", location: .remote),
        url: URL(string: "https://example.invalid/v.mp4")!
    )

    static func defaults(id: String? = nil) -> UserDefaults {
        let d = UserDefaults(suiteName: "remote.\(UUID().uuidString)")!
        if let id { d.set(id, forKey: "bluebox.remote.deviceID") }
        return d
    }

    func until(_ timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// The Mac's app, as the remote sees it: records what it was asked.
@MainActor
final class FakeAppHandler: RemoteAppHandler {
    var log: [String] = []
    var focused: (id: String, label: String)?

    func remoteGo(_ destination: RemoteDestination) {
        if case .title(let key) = destination { log.append("go title(\(key))") } else { log.append("go \(destination)") }
    }
    func remotePlay(_ play: RemotePlay) async { log.append("play \(play.title)") }
    func remoteClosePlayer() async { log.append("close") }
    func remoteFocus(_ id: String, driver: String) { log.append("focus \(id)") }
    func remoteMove(_ direction: RemoteDirection, driver: String) { log.append("move \(direction.rawValue)") }
    func remoteSelect(driver: String) { log.append("select") }
    func remoteScreen() -> (title: String, focusedID: String?, focusedLabel: String?) {
        ("Severance", focused?.id, focused?.label)
    }
}

// MARK: - The in-memory channel

/// Realtime broadcast in memory: every joined link hears what the others send
/// (never its own), in order. Messages can be lost on purpose.
final class FakeRemoteHub: @unchecked Sendable {
    private let lock = NSLock()
    private var links: [FakeRemoteLink] = []
    private var _sent: [RemoteMessage] = []
    private var acksToDrop = 0, hellosToDrop = 0
    private var _dropCommands = false

    /// Everything a joined link sent, lost or not.
    var sent: [RemoteMessage] { lock.withLock { _sent } }
    var dropCommands: Bool {
        get { lock.withLock { _dropCommands } }
        set { lock.withLock { _dropCommands = newValue } }
    }
    func dropAcks(_ n: Int) { lock.withLock { acksToDrop = n } }
    func dropHellos(_ n: Int) { lock.withLock { hellosToDrop = n } }

    func link(_ name: String) -> FakeRemoteLink {
        let link = FakeRemoteLink(name: name, hub: self)
        lock.withLock { links.append(link) }
        return link
    }

    func deliver(_ message: RemoteMessage, from sender: FakeRemoteLink) {
        let targets: [FakeRemoteLink]? = lock.withLock {
            _sent.append(message)
            switch message {
            case .ack where acksToDrop > 0: acksToDrop -= 1; return nil
            case .hello where hellosToDrop > 0: hellosToDrop -= 1; return nil
            case .command where _dropCommands: return nil
            default: return links.filter { $0 !== sender }
            }
        }
        for link in targets ?? [] { link.hear(message) }
    }
}

final class FakeRemoteLink: RemoteTransport, @unchecked Sendable {
    let name: String
    private weak var hub: FakeRemoteHub?
    private let lock = NSLock()
    private var onMessage: (@Sendable (RemoteMessage) -> Void)?
    private var onState: (@Sendable (RemoteChannel.State) -> Void)?
    private var started = false, online = true, joined = false
    private var _reconnects = 0

    init(name: String, hub: FakeRemoteHub) { self.name = name; self.hub = hub }

    var reconnects: Int { lock.withLock { _reconnects } }

    /// For `RemoteControl.update(…makeChannel:)`.
    var make: (@escaping @Sendable (RemoteMessage) -> Void, @escaping @Sendable (RemoteChannel.State) -> Void) -> (any RemoteTransport)? {
        { [self] onMessage, onState in bind(onMessage: onMessage, onState: onState); return self }
    }

    func bind(onMessage: @escaping @Sendable (RemoteMessage) -> Void, onState: @escaping @Sendable (RemoteChannel.State) -> Void) {
        lock.withLock { self.onMessage = onMessage; self.onState = onState }
    }

    func start() async {
        let (state, online) = lock.withLock { started = true; joined = self.online; return (onState, self.online) }
        state?(online ? .joined : .connecting)
    }

    func stop() async {
        let state = lock.withLock { started = false; joined = false; return onState }
        state?(.stopped)
    }

    func send(_ message: RemoteMessage) async -> Bool {
        guard lock.withLock({ joined }), let hub else { return false }
        hub.deliver(message, from: self)
        return true
    }

    func reconnect() async {
        let (state, joinedNow) = lock.withLock { _reconnects += 1; joined = started && online; return (onState, joined) }
        if joinedNow { state?(.joined) }
    }

    /// The socket drops: sends fail and nothing is heard until `comeBack`.
    func goOffline() {
        let state = lock.withLock { online = false; joined = false; return onState }
        state?(.connecting)
    }

    func comeBack() {
        let state = lock.withLock { online = true; joined = started; return onState }
        state?(.joined)
    }

    func hear(_ message: RemoteMessage) {
        let handler = lock.withLock { joined ? onMessage : nil }
        handler?(message)
    }
}

// MARK: - A player engine

@MainActor
final class RemoteTestEngine: PlaybackEngine {
    static let supportedContainers: Set<String> = ["mp4"]
    var snapshot = PlaybackSnapshot() { didSet { onChange?(snapshot) } }
    var onChange: ((PlaybackSnapshot) -> Void)?
    var seeks: [TimeInterval] = []
    var scrubs: [TimeInterval] = []

    func load(_ resource: PlaybackResource, startAt: TimeInterval?) async throws {
        var s = PlaybackSnapshot()
        s.status = .paused
        s.duration = 3600
        s.position = startAt ?? 0
        s.audioTracks = [MediaTrack(id: "a1", kind: .audio, label: "English", languageCode: "en"),
                         MediaTrack(id: "a2", kind: .audio, label: "French", languageCode: "fr")]
        s.selectedAudioID = "a1"
        s.embeddedSubtitles = [MediaTrack(id: "s0", kind: .subtitle, label: "English", languageCode: "en")]
        snapshot = s
    }
    func play() { snapshot.status = .playing }
    func pause() { snapshot.status = .paused }
    func seek(to seconds: TimeInterval) async { seeks.append(seconds); snapshot.position = seconds }
    func scrub(to seconds: TimeInterval) { scrubs.append(seconds) }
    func setRate(_ rate: Float) { snapshot.rate = rate }
    func selectAudio(_ trackID: String?) { snapshot.selectedAudioID = trackID }
    func selectEmbeddedSubtitle(_ trackID: String?) {}
    func selectSecondaryEmbeddedSubtitle(_ trackID: String?) {}
    func stop() { snapshot.status = .idle }
    func setVideoAdjustments(_ adjustments: VideoAdjustments) {}
    func setVolume(_ volume: Float, muted: Bool) {}
    func setAudioDelay(_ seconds: TimeInterval) {}
    var supportsAudioDelay: Bool { true }
    func setSubtitleBurnIn(_ burnIn: SubtitleBurnIn?) {}
}
