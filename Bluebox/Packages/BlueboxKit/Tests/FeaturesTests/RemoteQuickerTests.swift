import Domain
@testable import Features
import Foundation
import Persistence
import Playback
import Sync
import Testing

/// The quicker remote (21 Nov 2026): one test per thing that used to be slow
/// or heavy. Over the in-memory channel of `RemoteControlFlowTests`.
@MainActor
@Suite(.serialized) struct RemoteQuickerTests {
    typealias Flow = RemoteControlFlowTests

    /// Long, since it returns as soon as the condition holds: the whole suite's snapshot tests
    /// can hold the main actor for half a minute.
    func until(_ timeout: Duration = .seconds(40), _ condition: @MainActor () -> Bool) async -> Bool {
        await Flow().until(timeout, condition)
    }

    /// A controllable Mac with nothing playing, its handler telling it when the highlight moves, and a phone that chose it.
    func appPair(phoneTiming: RemoteControl.Timing = Flow.fast) async -> (hub: FakeRemoteHub, mac: RemoteControl, phone: RemoteControl,
                                                                          handler: FakeAppHandler) {
        let hub = FakeRemoteHub()
        let handler = FakeAppHandler()
        let mac = RemoteControl(defaults: Flow.defaults(), now: { Date() }, timing: Flow.fast)
        mac.handler = handler
        handler.remote = mac
        mac.update(wanted: true, controllable: true, player: nil, makeChannel: hub.link("mac").make)
        let phone = RemoteControl(defaults: Flow.defaults(), now: { Date() }, timing: phoneTiming)
        phone.update(wanted: true, player: nil, makeChannel: hub.link("phone").make)
        _ = await until { phone.devices.count == 1 }
        phone.target = phone.devices.first?.id
        return (hub, mac, phone, handler)
    }

    /// A phone and a "Mac" that's only a link, so a test says exactly what the Mac sends.
    func scriptedMac(version: Int = RemoteDevice.currentVersion) async -> (hub: FakeRemoteHub, mac: FakeRemoteLink, phone: RemoteControl) {
        let hub = FakeRemoteHub()
        let mac = hub.link("mac")
        mac.bind(onMessage: { _ in }, onState: { _ in })
        await mac.start()
        let phone = RemoteControl(defaults: Flow.defaults(), now: { Date() }, timing: Flow.fast)
        phone.update(wanted: true, player: nil, makeChannel: hub.link("phone").make)
        _ = await until { phone.channelState == .joined }
        await mac.send(.device(RemoteDevice(id: "m", name: "Studio", kind: .mac, controllable: true, version: version)))
        _ = await until { phone.devices.count == 1 }
        phone.target = "m"
        return (hub, mac, phone)
    }

    static let row = RemoteScreen(deviceID: "m", title: "Home", focusedID: "c1", focusedLabel: "Card 1",
                                  focused: RemoteScreenItem(label: "Card 1", kind: .poster),
                                  before: RemoteScreenItem(label: "Card 0", kind: .poster),
                                  after: RemoteScreenItem(label: "Card 2", kind: .poster), horizontal: true, bumps: 0)

    func lastCommand(_ hub: FakeRemoteHub) -> RemoteCommand? {
        hub.sent.compactMap { if case .command(let c) = $0 { c } else { nil } }.last
    }

    /// The command just sent, once it's on the wire (the outbox sends it a moment later).
    func sent(_ action: RemoteCommand.Action, _ hub: FakeRemoteHub, count: Int = 1) async -> RemoteCommand? {
        let matching = { hub.sent.compactMap { m -> RemoteCommand? in if case .command(let c) = m, c.action == action { c } else { nil } } }
        _ = await until { matching().count >= count }
        return matching().last
    }

    // MARK: 1. Back from the background

    /// Was: the phone forgot its Mac in the background and showed No Mac to
    /// Control for 20 s after unlocking, since the Mac re-announced itself only
    /// to a phone it hadn't heard of. Now it keeps its Mac, screen and target,
    /// and the Mac answers its hello at once.
    @Test func theRemoteKeepsItsMacThroughTheBackground() async {
        let p = await appPair()
        p.handler.focused = ("c1", "Card 1")
        p.phone.send(.move(.right))
        #expect(await until { p.phone.screen?.focusedLabel == "Card 1" })
        p.phone.update(wanted: false, away: true, player: nil, makeChannel: p.hub.link("unused").make)
        #expect(p.phone.connection == .off && p.phone.reconnecting)
        #expect(p.phone.controlled?.id == p.mac.deviceID && p.phone.screen?.focusedLabel == "Card 1" && p.phone.target == p.mac.deviceID)

        let announced = p.hub.sent.filter { if case .device(let d) = $0 { d.id == p.mac.deviceID } else { false } }.count
        p.phone.update(wanted: true, player: nil, makeChannel: p.hub.link("phone-again").make)
        #expect(await until { p.phone.connection == .connected && !p.phone.reconnecting })
        #expect(p.hub.sent.filter { if case .device(let d) = $0 { d.id == p.mac.deviceID } else { false } }.count > announced)
        p.phone.send(.move(.right))
        #expect(await until { p.handler.log.filter { $0 == "move right" }.count == 2 })
    }

    /// Switched off (or signed out), the remote forgets its Mac, as before.
    @Test func switchedOffTheRemoteForgets() async {
        let p = await appPair()
        p.phone.update(wanted: false, player: nil, makeChannel: p.hub.link("unused").make)
        #expect(p.phone.devices.isEmpty && p.phone.controlled == nil && p.phone.screen == nil && !p.phone.reconnecting)
    }

    // MARK: 2. Scrubbing and the settle

    /// A scrub is many messages a second: the Mac neither acknowledges nor
    /// answers each one; the seek that ends it is acknowledged.
    @Test func scrubsAreNotAcknowledged() async throws {
        let p = try await Flow().pair()
        #expect(await until { p.phone.nowPlaying != nil })
        p.phone.scrub(to: 100)
        try await Task.sleep(for: .milliseconds(150))
        p.phone.scrub(to: 200)
        p.phone.endScrub(at: 220)
        #expect(await until { p.engine.seeks.last == 220 })
        try await Task.sleep(for: .milliseconds(100))
        let acked = Set(p.hub.sent.compactMap { if case .ack(let a) = $0 { a.commandID } else { nil } })
        let commands = p.hub.sent.compactMap { if case .command(let c) = $0 { c } else { nil } }
        #expect(commands.filter { if case .scrub = $0.action { true } else { false } }.allSatisfy { !acked.contains($0.id) })
        #expect(commands.filter { if case .seek = $0.action { true } else { false } }.allSatisfy { acked.contains($0.id) })
        #expect(p.engine.scrubs == [100, 200])
    }

    /// Was: every screen looked new while playing, since the player's state count went up underneath.
    @Test func theClockAloneIsNotANewScreen() {
        let playing = RemoteNowPlaying(deviceID: "m", deviceName: "Studio", title: "Dune", position: 10, duration: 100, paused: false, seq: 1)
        var a = RemoteScreen(deviceID: "m", title: "Dune", playing: playing)
        var b = a
        b.playing?.position = 0; b.playing?.seq = 0  // `lastScreen` is kept cleared of the clock
        a.playing?.seq = 7; a.playing?.position = 14; a.answers = UUID()
        #expect(RemoteControl.sameScreen(a, b))
        a.playing?.paused = true
        #expect(!RemoteControl.sameScreen(a, b))
        #expect(!RemoteControl.sameScreen(a, nil))
    }

    /// Was: every confirmation waited 300 ms after the Mac applied it. Now it
    /// goes out as soon as the player shows it; the settle is only the longest wait.
    @Test func aPlayerCommandIsConfirmedWithoutWaitingTheSettle() async throws {
        let hub = FakeRemoteHub()
        let engine = RemoteTestEngine()
        let player = PlayerSession(engine: engine, progress: try LibraryStore.make(inMemory: true))
        await player.start(NowPlayingItem(key: .movie(tmdbID: 1), title: "Severance"), resource: Flow.resource)
        var slow = Flow.fast
        slow.settle = .seconds(60)  // longer than `until` waits: a confirmation at all shows it didn't wait for it
        let mac = RemoteControl(defaults: Flow.defaults(), now: { Date() }, timing: slow)
        mac.update(wanted: true, player: player, makeChannel: hub.link("mac").make)
        let phone = RemoteControl(defaults: Flow.defaults(), now: { Date() }, timing: Flow.fast)
        phone.update(wanted: true, player: nil, makeChannel: hub.link("phone").make)
        #expect(await until { phone.nowPlaying != nil })
        phone.send(.volume(0.4))
        phone.send(.setPaused(true))
        #expect(await until { phone.awaiting.isEmpty })
        #expect(phone.nowPlaying?.paused == true)
    }

    // MARK: 3. The strip moves at once

    @Test func aStepIsDrawnFromTheNeighbourAlreadyShown() throws {
        let s = Self.row
        let right = try #require(RemoteControl.predict(.move(.right), on: s))
        #expect(right.focused?.label == "Card 2" && right.before?.label == "Card 1" && right.after == nil)
        let left = try #require(RemoteControl.predict(.move(.left), on: s))
        #expect(left.focused?.label == "Card 0" && left.after?.label == "Card 1" && left.before == nil)
        // Off the row, or past what's shown: only the Mac knows.
        #expect(RemoteControl.predict(.move(.down), on: s) == nil)
        #expect(RemoteControl.predict(.move(.right), on: right) == nil)
        // At an end the Mac said can't scroll on: a bump, felt at once.
        var end = s
        end.edges = [.right]
        #expect(RemoteControl.predict(.move(.right), on: end)?.bumps == 1)
        // The pointer switch, and a menu closing on a pick.
        #expect(RemoteControl.predict(.setPointer(true), on: s)?.pointer == true)
        var menu = s
        menu.menu = RemoteMenu(title: "Card 1", items: [RemoteMenu.Item(index: 0, title: "Play")])
        #expect(RemoteControl.predict(.menuPick(0), on: menu)?.menu == nil)
        #expect(RemoteControl.predict(.move(.right), on: menu) == nil)  // the pad moves through the menu
    }

    /// The strip moves when the finger does; a screen the Mac worked out
    /// before that move landed doesn't step it back; the one answering it settles it.
    @Test func theStripMovesBeforeTheMacAnswers() async {
        let p = await scriptedMac()
        await p.mac.send(.screen(Self.row))
        #expect(await until { p.phone.screen == Self.row })
        p.phone.send(.move(.right))
        #expect(p.phone.screen?.focused?.label == "Card 2")  // at once
        let move = await sent(.move(.right), p.hub)
        var stale = Self.row
        stale.answers = UUID()
        await p.mac.send(.screen(stale))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(p.phone.screen?.focused?.label == "Card 2")  // held
        var answer = Self.row
        answer.focusedLabel = "Card 2"
        answer.focused = RemoteScreenItem(label: "Card 2", kind: .poster)
        answer.after = RemoteScreenItem(label: "Card 3", kind: .poster)
        answer.answers = move?.id
        await p.mac.send(.screen(answer))
        #expect(await until { p.phone.screen == answer })
        // The pointer switch flips the pad at once too.
        p.phone.send(.setPointer(true))
        #expect(p.phone.screen?.pointer == true)
    }

    /// A Mac before protocol 5 doesn't say which command a screen answers: its screens are taken as they come.
    @Test func anOlderMacsScreensAreTakenAsTheyCome() async {
        let p = await scriptedMac(version: 4)
        await p.mac.send(.screen(Self.row))
        #expect(await until { p.phone.screen == Self.row })
        p.phone.send(.move(.right))
        #expect(p.phone.screen?.focused?.label == "Card 2")
        await p.mac.send(.screen(Self.row))  // the Mac didn't move (it bumped): its word
        #expect(await until { p.phone.screen == Self.row })
    }

    /// Was: two screens were worked out per move (its own, then one after the
    /// settle). Now one, carrying the command it answers.
    @Test func aMoveWorksOutOneScreen() async {
        let p = await appPair()
        p.handler.focused = ("c1", "Card 1")
        p.phone.send(.move(.right))
        #expect(await until { p.phone.screen?.focusedLabel == "Card 1" })
        try? await Task.sleep(for: .milliseconds(200))
        p.handler.screensWorkedOut = 0
        p.handler.focused = ("c2", "Card 2")
        p.phone.send(.move(.right))
        let move = await sent(.move(.right), p.hub, count: 2)
        #expect(await until { p.phone.screen?.focusedLabel == "Card 2" })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(p.handler.screensWorkedOut == 1)
        #expect(p.phone.screen?.answers == move?.id)
    }

    // MARK: 4. A Mac that doesn't answer, and typing

    /// Was: nothing showed for 7 s. Now amber once a command and its first
    /// resend go unanswered, and red with Try Again once every retry has.
    @Test func aSlowMacTurnsAmberBeforeGivingUp() async throws {
        let p = try await Flow().pair()
        #expect(await until { p.phone.nowPlaying != nil })
        p.hub.dropCommands = true
        p.phone.send(.audio("a2"))
        var seen: [RemoteControl.Connection] = []
        _ = await until {
            if seen.last != p.phone.connection { seen.append(p.phone.connection) }
            return p.phone.connection == .notAnswering
        }
        #expect(seen == [.connected, .lagging, .notAnswering])
        p.hub.dropCommands = false
        p.phone.send(.audio("a2"))
        #expect(await until { p.phone.connection == .connected })
    }

    /// Nothing from the Mac at all: the link itself may be dead, so it's checked (here, reconnected).
    @Test func aSilentLinkIsCheckedWhenTheMacStopsAnswering() async throws {
        let hub = FakeRemoteHub()
        let player = PlayerSession(engine: RemoteTestEngine(), progress: try LibraryStore.make(inMemory: true))
        await player.start(NowPlayingItem(key: .movie(tmdbID: 1), title: "Severance"), resource: Flow.resource)
        let mac = RemoteControl(defaults: Flow.defaults(), now: { Date() }, timing: Flow.fast)
        let macLink = hub.link("mac"), phoneLink = hub.link("phone")
        mac.update(wanted: true, player: player, makeChannel: macLink.make)
        var quiet = Flow.fast
        quiet.heardRecently = 0.05
        let phone = RemoteControl(defaults: Flow.defaults(), now: { Date() }, timing: quiet)
        phone.update(wanted: true, player: nil, makeChannel: phoneLink.make)
        #expect(await until { phone.nowPlaying != nil })
        macLink.goOffline()
        phone.send(.audio("a2"))
        #expect(await until { phone.connection == .notAnswering || phoneLink.reconnects >= 1 })
        #expect(await until { phoneLink.reconnects >= 1 })
    }

    /// Typing into the Mac's highlighted field: the whole text, once, as `text`; never to a Mac that doesn't know it.
    @Test func typingReachesTheMacsField() async {
        let p = await appPair()
        p.phone.send(.text("dune"))
        #expect(await until { p.handler.log.contains("text(\"dune\")") })
        let old = await scriptedMac(version: 4)
        old.phone.send(.text("dune"))
        old.phone.send(.repeatMove(.right))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(lastCommand(old.hub) == nil)
    }

    /// The same words again on Search (Return, or a resend) leave a result opened from it open.
    @Test func searchStartsOverOnlyForNewWords() throws {
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                           prefs: PreferencesStore(defaults: UserDefaults(suiteName: "quicker.\(UUID().uuidString)")!), forceSample: true)
        #expect(app.remoteSearchStartsOver("", onSearch: false))
        #expect(app.remoteSearchStartsOver("dune", onSearch: true))
        #expect(!app.remoteSearchStartsOver("dune", onSearch: true))
        #expect(app.remoteSearchStartsOver("dune", onSearch: false))  // from elsewhere: back to Search's results
        #expect(app.remoteSearchStartsOver("dunes", onSearch: true))
    }

    // MARK: 5. Polish

    /// With nothing playing, the screen still goes out again now and then while a remote is about, so a lost one heals.
    @Test func aLostScreenIsSentAgainWithNothingPlaying() async {
        let hub = FakeRemoteHub()
        let handler = FakeAppHandler()
        var timing = Flow.fast
        timing.screenResend = 0.2
        let mac = RemoteControl(defaults: Flow.defaults(), now: { Date() }, timing: timing)
        mac.handler = handler
        mac.update(wanted: true, controllable: true, player: nil, makeChannel: hub.link("mac").make)
        let phone = RemoteControl(defaults: Flow.defaults(), now: { Date() }, timing: Flow.fast)
        phone.update(wanted: true, player: nil, makeChannel: hub.link("phone").make)
        #expect(await until { hub.sent.contains { if case .screen = $0 { true } else { false } } })
        let screens = hub.sent.filter { if case .screen = $0 { true } else { false } }.count
        #expect(await until { hub.sent.filter { if case .screen = $0 { true } else { false } }.count >= screens + 2 })
    }
}

/// The Mac's highlight: held edges, typing, bumps the phone can feel ahead, one walk per move.
@MainActor
@Suite struct RemoteFocusQuickerTests {
    func row(_ window: FakeWindow, count: Int) {
        window.items = (0..<count).map { .init(label: "B\($0)", kind: .button, frame: CGRect(x: 20 + $0 * 120, y: 100, width: 100, height: 40)) }
    }

    func until(seconds: Double = 40, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// One message holds the edge: the Mac steps on its own until let go, or the row ends.
    @Test func aHeldEdgeStepsUntilLetGoOrTheEnd() async {
        let window = FakeWindow()
        window.canScroll = false
        row(window, count: 6)
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        focus.repeatInterval = .milliseconds(20)
        focus.move(.right, driver: "iPhone")  // shows B0
        focus.repeatMove(.right, driver: "iPhone")
        let before = focus.screen().bumps ?? 0
        #expect(await until { focus.focusedLabel == "B5" })
        try? await Task.sleep(for: .milliseconds(100))
        let bumps = focus.screen().bumps ?? 0
        try? await Task.sleep(for: .milliseconds(150))
        // Stopped at the end: one bump, not one per tick.
        #expect(bumps == before + 1 && (focus.screen().bumps ?? 0) == bumps)
        focus.repeatMove(.left, driver: "iPhone")
        #expect(await until { focus.focusedLabel == "B3" })
        focus.repeatMove(nil, driver: "iPhone")
        let stopped = focus.focusedLabel
        try? await Task.sleep(for: .milliseconds(100))
        #expect(focus.focusedLabel == stopped)
    }

    /// The phone hears which ways a move would bump, and a field's text.
    @Test func theScreenSaysWhereTheEndsAre() {
        let window = FakeWindow()
        window.canScroll = false
        window.items = [.init(label: "Search", kind: .field, frame: CGRect(x: 20, y: 100, width: 300, height: 30), value: "dune"),
                        .init(label: "Go", kind: .button, frame: CGRect(x: 340, y: 100, width: 60, height: 30))]
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        focus.move(.right, driver: "iPhone")  // shows Search
        let s = focus.screen()
        #expect(s.focused?.value == "dune")
        #expect(Set(s.edges ?? []) == [.left, .up, .down])
        window.canScroll = true
        #expect(focus.screen().edges == [])  // the page can scroll on: the Mac's call
    }

    /// Typing goes into the highlighted field, clicking into it first.
    @Test func typingGoesIntoTheHighlightedField() {
        let window = FakeWindow()
        window.items = [.init(label: "Search", kind: .field, frame: CGRect(x: 20, y: 100, width: 300, height: 30))]
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        focus.move(.right, driver: "iPhone")
        focus.type("sev", driver: "iPhone")
        #expect(window.log == ["type sev at 170,115"])
    }

    /// The screen after a move is worked out from the move's own walk of the window.
    @Test func aMovesScreenReusesItsWalk() {
        let window = FakeWindow()
        row(window, count: 4)
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        focus.elementsLifetime = 5
        focus.move(.right, driver: "iPhone")
        focus.invalidate()
        focus.move(.right, driver: "iPhone")
        let walks = window.walks
        #expect(focus.screen().focused?.label == "B1")
        #expect(window.walks == walks)
    }

    /// The pointer's acceleration follows the finger's speed, however the messages were spaced.
    @Test func thePointerFollowsTheFingersSpeedNotTheMessages() {
        let window = FakeWindow()
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        focus.setPointer(true, driver: "iPhone")
        let start = focus.pointer!
        // 10 pt in a twentieth of a second, and 5 pt in a fortieth, twice: the same speed, the same distance.
        focus.movePointer(dx: 10, dy: 0, dt: 0.05, driver: "iPhone")
        let one = focus.pointer!.x - start.x
        focus.movePointer(dx: -10, dy: 0, dt: 0.05, driver: "iPhone")
        focus.movePointer(dx: 5, dy: 0, dt: 0.025, driver: "iPhone")
        focus.movePointer(dx: 5, dy: 0, dt: 0.025, driver: "iPhone")
        #expect(abs((focus.pointer!.x - start.x) - one) < 0.01)
    }
}
