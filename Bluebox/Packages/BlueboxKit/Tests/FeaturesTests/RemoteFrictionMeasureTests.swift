import Domain
@testable import Features
import Foundation
import Persistence
import Playback
import Sync
import Testing
#if os(macOS)
import AppKit
import SwiftUI
#endif

/// Measurements for the remote friction audit (not assertions about behaviour):
/// the production timings (`RemoteControl.Timing()`), over an in-memory channel
/// with a fixed one-way delay per message, standing in for phone → Realtime → Mac.
/// Each test prints what it measured. Only with `REMOTE_MEASURE=1` set: it
/// takes a minute, opens a window of its own (which the highlight's tests
/// would find as the main window) and measures timing, which a busy machine skews.
///
///     REMOTE_MEASURE=1 swift test --filter RemoteFrictionMeasureTests
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["REMOTE_MEASURE"] != nil))
struct RemoteFrictionMeasureTests {

    // MARK: A channel with latency

    final class LatencyHub: @unchecked Sendable {
        let oneWay: TimeInterval
        private let lock = NSLock()
        private var links: [LatencyLink] = []
        private var _log: [(at: Date, from: String, message: RemoteMessage)] = []
        var dropCommands = false
        init(oneWay: TimeInterval) { self.oneWay = oneWay }
        var log: [(at: Date, from: String, message: RemoteMessage)] { lock.withLock { _log } }
        func clearLog() { lock.withLock { _log.removeAll() } }
        func link(_ name: String) -> LatencyLink {
            let l = LatencyLink(name: name, hub: self)
            lock.withLock { links.append(l) }
            return l
        }
        func deliver(_ m: RemoteMessage, from sender: LatencyLink) {
            let targets: [LatencyLink] = lock.withLock {
                _log.append((Date(), sender.name, m))
                if case .command = m, dropCommands { return [] }
                return links.filter { $0 !== sender }
            }
            let delay = oneWay
            for t in targets {
                if delay == 0 { t.hear(m) } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { t.hear(m) }
                }
            }
        }
    }

    final class LatencyLink: RemoteTransport, @unchecked Sendable {
        let name: String
        private weak var hub: LatencyHub?
        private let lock = NSLock()
        private var onMessage: (@Sendable (RemoteMessage) -> Void)?
        private var onState: (@Sendable (RemoteChannel.State) -> Void)?
        private var joined = false
        init(name: String, hub: LatencyHub) { self.name = name; self.hub = hub }
        var make: (@escaping @Sendable (RemoteMessage) -> Void, @escaping @Sendable (RemoteChannel.State) -> Void) -> (any RemoteTransport)? {
            { [self] m, s in lock.withLock { onMessage = m; onState = s }; return self }
        }
        func start() async { let s = lock.withLock { joined = true; return onState }; s?(.joined) }
        func stop() async { let s = lock.withLock { joined = false; return onState }; s?(.stopped) }
        func send(_ message: RemoteMessage) async -> Bool {
            guard lock.withLock({ joined }), let hub else { return false }
            hub.deliver(message, from: self)
            return true
        }
        func reconnect() async { let s = lock.withLock { onState }; s?(.joined) }
        func hear(_ m: RemoteMessage) { let h = lock.withLock { joined ? onMessage : nil }; h?(m) }
    }

    /// A Mac app whose highlight is an index along a row; counts how often the screen is worked out
    /// (each one a walk of the window's accessibility tree in the real app).
    final class CountingHandler: RemoteAppHandler {
        var index = 0
        var pointer = false
        var screens = 0
        /// The page, as `remoteGo` changes it (the real Mac's title follows its page).
        var title = "Home"
        weak var remote: RemoteControl?
        func remoteGo(_ destination: RemoteDestination) {
            if case .search(let q) = destination { title = "Search: \(q)" }
            remote?.screenChanged()
        }
        func remotePlay(_ play: RemotePlay) async {}
        func remoteClosePlayer() async {}
        func remoteFocus(_ id: String, driver: String) {}
        func remoteMove(_ direction: RemoteDirection, driver: String) {
            index += direction == .right ? 1 : -1
            remote?.screenChanged()  // RemoteFocus.onChange in the app
        }
        func remoteSelect(driver: String) {}
        func remote4(_ action: RemoteCommand.Action, driver: String) {
            switch action {
            case .setPointer(let on): pointer = on; remote?.screenChanged()
            case .jump(let j): index += j.direction == .right ? j.count : -j.count; remote?.screenChanged()
            default: break
            }
        }
        func remoteScreen() -> RemoteScreen {
            screens += 1
            // With the neighbours either side, as the real Mac's `RemoteFocus.screen()` sends them.
            return RemoteScreen(deviceID: "", title: title, focusedID: "item:\(index)", focusedLabel: "Item \(index)",
                                focused: RemoteScreenItem(label: "Item \(index)", kind: .poster),
                                before: RemoteScreenItem(label: "Item \(index - 1)", kind: .poster),
                                after: RemoteScreenItem(label: "Item \(index + 1)", kind: .poster), horizontal: true,
                                pointer: pointer ? true : nil)
        }
    }

    static let production = RemoteControl.Timing()

    func until(_ timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

    struct Rig {
        let hub: LatencyHub
        let mac: RemoteControl
        let phone: RemoteControl
        let handler: CountingHandler
        let engine: RemoteTestEngine
        let player: PlayerSession?
    }

    func rig(oneWay: TimeInterval, playing: Bool) async throws -> Rig {
        let hub = LatencyHub(oneWay: oneWay)
        let engine = RemoteTestEngine()
        var player: PlayerSession?
        if playing {
            let p = PlayerSession(engine: engine, progress: try LibraryStore.make(inMemory: true))
            await p.start(NowPlayingItem(key: .movie(tmdbID: 1), title: "Severance"), resource: RemoteControlFlowTests.resource)
            player = p
        }
        let handler = CountingHandler()
        let mac = RemoteControl(defaults: RemoteControlFlowTests.defaults(), now: { Date() }, timing: Self.production)
        handler.remote = mac
        mac.handler = handler
        mac.update(wanted: true, controllable: true, player: player, makeChannel: hub.link("mac").make)
        let phone = RemoteControl(defaults: RemoteControlFlowTests.defaults(), now: { Date() }, timing: Self.production)
        phone.update(wanted: true, player: nil, makeChannel: hub.link("phone").make)
        _ = await until { phone.devices.count == 1 && (!playing || phone.nowPlaying != nil) && phone.screen != nil }
        phone.target = phone.devices.first?.id
        _ = await until { phone.screen != nil }
        try await Task.sleep(for: .milliseconds(400))
        hub.clearLog()
        handler.screens = 0
        return Rig(hub: hub, mac: mac, phone: phone, handler: handler, engine: engine, player: player)
    }

    func counts(_ log: [(at: Date, from: String, message: RemoteMessage)]) -> String {
        var c: [String: Int] = [:]
        for e in log {
            let k: String = switch e.message {
            case .command: "command"
            case .ack: "ack"
            case .state: "state"
            case .screen: "screen"
            case .hello: "hello"
            case .device: "device"
            case .stopped: "stopped"
            }
            c["\(e.from).\(k)", default: 0] += 1
        }
        return c.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    // MARK: Measurements

    /// Tap to "the Mac agrees" for player commands, and swipe to "the strip moved" for a step.
    @Test(arguments: [0.0, 0.06, 0.15])
    func timeToConfirm(oneWay: TimeInterval) async throws {
        let r = try await rig(oneWay: oneWay, playing: true)
        var out: [String] = []
        for (name, action) in [("pause", RemoteCommand.Action.setPaused(true)), ("play", .setPaused(false)),
                               ("seek", .seek(900)), ("audio", .audio("a2")), ("volume", .volume(0.5))] {
            let t = Date()
            r.phone.send(action)
            let drawnAt = ms(t)
            let ok = await until { r.phone.awaiting.isEmpty }
            out.append("\(name): drawn \(drawnAt) ms, confirmed \(ok ? "\(ms(t)) ms" : "never")")
            try await Task.sleep(for: .milliseconds(200))
        }
        print("MEASURE confirm oneWay=\(Int(oneWay * 1000))ms: " + out.joined(separator: "; "))
    }

    @Test(arguments: [0.0, 0.06, 0.15])
    func timeForAStepToShowOnThePhone(oneWay: TimeInterval) async throws {
        let r = try await rig(oneWay: oneWay, playing: false)
        var times: [Int] = []
        var agreed: [Int] = []
        for _ in 0..<5 {
            let before = r.phone.screen?.focusedLabel
            let target = r.handler.index + 1
            let t = Date()
            r.phone.send(.move(.right))
            _ = await until { r.phone.screen?.focusedLabel != before }
            times.append(ms(t))
            // And the Mac's own screen saying the same.
            _ = await until { r.phone.screen?.focusedID == "item:\(target)" }
            agreed.append(ms(t))
            try await Task.sleep(for: .milliseconds(500))
        }
        // The pointer switch: the pad changes mode only when the Mac's screen says so.
        let t = Date()
        r.phone.send(.setPointer(true))
        _ = await until { r.phone.screen?.pointer == true }
        let pointer = ms(t)
        print("MEASURE step→strip oneWay=\(Int(oneWay * 1000))ms: \(times) ms (Mac's screen agrees \(agreed) ms); pointer switch→pad mode \(pointer) ms")
    }

    /// A six-step swipe (one `.move` per 56 pt): messages on the wire and screens worked out on the Mac.
    @Test func messagesForASwipe() async throws {
        let r = try await rig(oneWay: 0.06, playing: false)
        for _ in 0..<6 {
            r.phone.send(.move(.right))
            try await Task.sleep(for: .milliseconds(40))  // a swipe at ~1400 pt/s
        }
        _ = await until { r.handler.index == 6 }
        try await Task.sleep(for: .milliseconds(1500))
        print("MEASURE swipe 6 steps: \(counts(r.hub.log)); Mac screens worked out: \(r.handler.screens)")
    }

    /// Dragging the timeline for 3 s at 60 Hz, then letting go.
    @Test func messagesForAScrub() async throws {
        let r = try await rig(oneWay: 0.06, playing: true)
        let start = Date()
        var calls = 0
        while Date().timeIntervalSince(start) < 3 {
            r.phone.scrub(to: 100 + Date().timeIntervalSince(start) * 100)
            calls += 1
            try await Task.sleep(for: .milliseconds(16))
        }
        let end = Date()
        r.phone.endScrub(at: 420)
        _ = await until { r.engine.seeks.last == 420 }
        let landed = ms(end)
        _ = await until { r.phone.awaiting.isEmpty }
        let confirmed = ms(end)
        try await Task.sleep(for: .milliseconds(800))
        print("MEASURE scrub 3 s: \(calls) drag events; \(counts(r.hub.log)); engine scrubs \(r.engine.scrubs.count); "
              + "lift→Mac seek \(landed) ms, lift→phone confirmed \(confirmed) ms")
    }

    /// Typing "severance" at 6 characters a second: the search box sends after 250 ms of quiet (600 before the quicker remote).
    /// (The view's debounce, modelled here: one `.go(.search)` per pause; Return no longer resends the same words.)
    @Test func searchTypingDelay() async throws {
        let r = try await rig(oneWay: 0.06, playing: false)
        var lastSent: Date?
        let typed = Date()
        let word = "severance"
        for i in word.indices {
            _ = i
            try await Task.sleep(for: .milliseconds(166))
        }
        let lastKey = Date()
        try await Task.sleep(for: .milliseconds(250))
        r.phone.send(.go(.search(word)))
        lastSent = Date()
        _ = await until { r.hub.log.contains { if case .screen = $0.message { $0.from == "mac" } else { false } } }
        print("MEASURE search: typed \(word.count) chars in \(Int(lastKey.timeIntervalSince(typed) * 1000)) ms; "
              + "last key → sent \(Int(lastSent!.timeIntervalSince(lastKey) * 1000)) ms; last key → Mac screen back \(ms(lastKey)) ms")
    }

    /// The Mac stops hearing commands: how long until the phone says Not Answering.
    @Test func timeToNotAnswering() async throws {
        let r = try await rig(oneWay: 0.06, playing: true)
        r.hub.dropCommands = true
        let t = Date()
        r.phone.send(.setPaused(true))
        let amber = await until(.seconds(12)) { r.phone.connection == .lagging || r.phone.connection == .notAnswering }
        print("MEASURE amber (lagging) after \(amber ? "\(ms(t)) ms" : "never")")
        let ok = await until(.seconds(12)) { r.phone.connection == .notAnswering }
        print("MEASURE not answering after \(ok ? "\(ms(t)) ms" : "never"); commands sent \(r.hub.log.filter { if case .command = $0.message { true } else { false } }.count)")
    }

    /// The phone comes back from the background (it leaves the channel there): how long
    /// it shows nothing to control, with an instant join (the real one adds a socket and phx_join).
    @Test(arguments: [false, true])
    func rejoiningAfterTheBackground(playing: Bool) async throws {
        let hub = LatencyHub(oneWay: 0.06)
        let engine = RemoteTestEngine()
        var player: PlayerSession?
        if playing {
            let p = PlayerSession(engine: engine, progress: try LibraryStore.make(inMemory: true))
            await p.start(NowPlayingItem(key: .movie(tmdbID: 1), title: "Severance"), resource: RemoteControlFlowTests.resource)
            player = p
        }
        let handler = CountingHandler()
        let mac = RemoteControl(defaults: RemoteControlFlowTests.defaults(), now: { Date() }, timing: Self.production)
        handler.remote = mac; mac.handler = handler
        mac.update(wanted: true, controllable: true, player: player, makeChannel: hub.link("mac").make)
        let phone = RemoteControl(defaults: RemoteControlFlowTests.defaults(), now: { Date() }, timing: Self.production)
        let link = hub.link("phone")
        phone.update(wanted: true, player: nil, makeChannel: link.make)
        _ = await until { (!playing || phone.nowPlaying != nil) && phone.devices.count == 1 }
        phone.target = phone.devices.first?.id
        // Background: RemoteControlHost's `want` goes false, marked as away (only the background).
        phone.update(wanted: false, away: true, player: nil, makeChannel: link.make)
        let blank = phone.nowPlaying == nil && phone.devices.isEmpty && phone.screen == nil && phone.controlled == nil
        try await Task.sleep(for: .milliseconds(300))
        let t = Date()
        // A fresh socket, as `makeRemoteChannel` makes.
        phone.update(wanted: true, player: nil, makeChannel: hub.link("phone-again").make)
        _ = await until(.seconds(35)) { phone.controlled != nil }
        print("MEASURE rejoin playing=\(playing): something to control after \(ms(t)) ms")
        _ = await until(.seconds(35)) { phone.connection == .connected && !phone.reconnecting }
        print("MEASURE rejoin playing=\(playing): connected, and the Mac heard from, after \(ms(t)) ms")
        _ = await until(.seconds(35)) { !phone.devices.isEmpty }
        let devices = ms(t)
        let controllable = phone.controlled != nil
        _ = await until(.seconds(2)) { phone.nowPlaying != nil }
        let playerBack = ms(t)
        _ = await until(.seconds(2)) { phone.screen != nil }
        let screen = ms(t)
        print("MEASURE rejoin: controlled when devices came back \(controllable); blank while away \(blank); target kept \(phone.target != nil); devices back \(devices) ms, "
              + "player back \(playerBack) ms, screen back \(screen) ms (plus the real socket + join)")
    }

    #if os(macOS)
    /// The cost of one walk of a window's accessibility tree (`RemoteWindow.elements`), on a
    /// Home-like page: a sidebar and eight rows of twenty posters, and of `RemoteFocus.screen()`.
    @Test func accessibilityWalkCost() async throws {
        let view = HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<14) { i in Button("Sidebar \(i)") {}.buttonStyle(.plain) }
                Spacer()
            }
            .frame(width: 200)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Button("Play") {}; Button("More Info") {}; Button("My List") {} }.frame(height: 300)
                    ForEach(0..<8) { row in
                        VStack(alignment: .leading) {
                            Text("Row \(row)").font(.headline)
                            ScrollView(.horizontal) {
                                HStack(spacing: 10) {
                                    ForEach(0..<20) { i in
                                        Button { } label: { Color.gray.frame(width: 120, height: 180).overlay(Text("T\(row)-\(i)")) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(800))
        let remote = RemoteWindow(main: window)
        let coldStart = Date()
        var found = remote.elements()
        let cold = ms(coldStart)
        _ = await until(.seconds(5)) { found = remote.elements(); return found.count > 20 }
        var walks: [Double] = []
        for _ in 0..<15 {
            let t = ContinuousClock.now
            found = remote.elements()
            let d = ContinuousClock.now - t
            walks.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        let focus = RemoteFocus()
        focus.platform = remote
        focus.window = { (CGRect(x: 0, y: 0, width: 1400, height: 900), nil) }
        focus.move(.right, driver: "Phone")  // reveals the first item
        var screens: [Double] = []
        for _ in 0..<10 {
            focus.invalidate()
            let t = ContinuousClock.now
            _ = focus.screen()
            let d = ContinuousClock.now - t
            screens.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        var moves: [Double] = []
        for _ in 0..<6 {
            focus.invalidate()
            let t = ContinuousClock.now
            focus.move(.right, driver: "Phone")
            let d = ContinuousClock.now - t
            moves.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        func med(_ a: [Double]) -> String { String(format: "%.1f", a.sorted()[a.count / 2]) }
        print("MEASURE AX walk: \(found.count) elements; first walk \(cold) ms; walk median \(med(walks)) ms "
              + "(min \(String(format: "%.1f", walks.min() ?? 0)), max \(String(format: "%.1f", walks.max() ?? 0))); "
              + "screen() median \(med(screens)) ms; move() median \(med(moves)) ms")
    }
    #endif
}
