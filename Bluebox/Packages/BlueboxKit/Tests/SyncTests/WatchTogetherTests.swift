import Foundation
@testable import Sync
import Testing

/// Watch Party: the wire format, join codes and invites, matching a
/// release across devices, the drift correction maths, and rooms joined and
/// left over an in-memory hub.
@Suite struct WatchTogetherMessageTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    var title: TogetherTitle {
        TogetherTitle(key: "tmdb:tv:95396:s1e2", name: "Severance", subtitle: "S1·E2 · Half Loop",
                      release: TogetherRelease(infoHash: "ABCDEF0123", fileIndex: 3, fileName: "Severance.S01E02.mkv",
                                               sizeBytes: 1_500_000_000, label: "1080p · WEB-DL · 1.5 GB"))
    }

    @Test func everyMessageRoundTrips() throws {
        let alice = TogetherParticipant(id: "a", name: "Alice", joinedAt: t0, status: .unavailable("No add-on has it"), away: true, match: .sameLength)
        let head = TogetherPlayhead(position: 61.5, paused: false, rate: 1.25, sentAt: t0)
        let messages: [TogetherMessage] = [
            .hello(alice), .presence(TogetherParticipant(id: "b", name: "Bo", joinedAt: t0, status: .buffering)),
            .title(title, from: "a", seq: 4),
            .command(TogetherCommand(action: .seek, playhead: head, seq: 7, from: "b")),
            .state(from: "a", head), .leave(from: "b"),
            .chat(TogetherChatMessage(from: "a", name: "Alice", symbol: "star.fill", color: 2, text: "NO WAY", sentAt: t0, position: 61,
                                      replyTo: .init(id: "m1", name: "Bo", text: "here it comes"), mentions: ["b"])),
            .reaction(TogetherReaction(id: "r1", from: "b", name: "Bo", emoji: "😂", sentAt: t0, onMessage: "m2")),
            .typing(from: "a"),
            .history(to: "c", from: "a", messages: [TogetherChatMessage(id: "m1", from: "b", name: "Bo", text: "hi", sentAt: t0)], reactions: []),
            .settings(TogetherPartySettings(host: "a", lobby: false, hostOnlyControls: true, locked: true, admitted: ["a", "b"],
                                            removed: ["z"], queue: [TogetherQueueItem(id: "q", key: "tmdb:tv:1:s1e4", name: "Severance", subtitle: "S1·E4")],
                                            seq: 3, from: "a")),
            .countdown(TogetherCountdown(position: 0, seconds: 3, from: "a")),
            .upNext(TogetherUpNext(id: "u", item: TogetherQueueItem(id: "q", key: "k", name: "N"), fromQueue: true, phase: .cancelled, by: "Bo", from: "b")),
        ]
        for m in messages {
            #expect(try TogetherMessage.decode(m.encoded()) == m)
            #expect(try TogetherMessage.decode(jsonObject: m.jsonObject()) == m)
        }
    }

    @Test func theWireFormatIsPlainJSON() throws {
        let m = TogetherMessage.command(TogetherCommand(action: .pause, playhead: TogetherPlayhead(position: 10, paused: true, sentAt: t0),
                                                        seq: 2, from: "a"))
        let json = try m.jsonObject()
        #expect(json["type"] as? String == "command")
        let command = try #require(json["command"] as? [String: Any])
        #expect(command["action"] as? String == "pause")
        // Milliseconds since 1970, so Apple's reference-date default never leaks onto the wire.
        #expect((command["playhead"] as? [String: Any])?["sentAt"] as? Double == 1_000_000)
        #expect(title.release.infoHash == "abcdef0123")
    }

    @Test func unknownThingsFromNewerVersions() throws {
        #expect(throws: (any Error).self) { try TogetherMessage.decode(Data(#"{"type":"dance"}"#.utf8)) }
        let p = try JSONDecoder().decode(TogetherParticipant.Status.self, from: Data(#"{"kind":"napping"}"#.utf8))
        #expect(p == .loading)
    }

    @Test func aPlayheadRunsForwardOnlyWhilePlaying() {
        let playing = TogetherPlayhead(position: 100, paused: false, rate: 1.5, sentAt: t0)
        #expect(playing.position(at: t0.addingTimeInterval(2)) == 103)
        #expect(playing.position(at: t0.addingTimeInterval(-5)) == 100)  // a clock behind ours: no going back
        #expect(TogetherPlayhead(position: 100, paused: true, sentAt: t0).position(at: t0.addingTimeInterval(9)) == 100)
    }

    @Test func laterCommandsWinAndTiesGoToTheHigherDevice() {
        let head = TogetherPlayhead(position: 0, paused: true, sentAt: t0)
        let c = TogetherCommand(action: .play, playhead: head, seq: 5, from: "m")
        #expect(c.isNewer(than: nil))
        #expect(c.isNewer(than: (4, "z")))
        #expect(!c.isNewer(than: (6, "a")))
        #expect(c.isNewer(than: (5, "a")))
        #expect(!c.isNewer(than: (5, "z")))
    }

    // MARK: Codes and invites

    @Test func joinCodesAreReadable() throws {
        var g = SeededGenerator(seed: 7)
        for _ in 0..<200 {
            let code = TogetherJoinCode.random(using: &g)
            #expect(code.value.count == 8)
            #expect(TogetherJoinCode(code.description) == code)
            #expect(TogetherJoinCode(code.description.lowercased()) == code)
        }
        let code = try #require(TogetherJoinCode(" k7qm - 2xdp "))
        #expect(code.description == "K7QM-2XDP")
        #expect(TogetherJoinCode("K7QM-2XD") == nil)  // too short
        #expect(TogetherJoinCode("K7QM-2XD0") == nil)  // 0 is never in a code
        #expect(TogetherJoinCode("I7QM-2XDP") == nil)
    }

    @Test func invitesCarryTheHostsProject() throws {
        let code = try #require(TogetherJoinCode("K7QM2XDP"))
        let invite = TogetherInvite(code: code, projectURL: URL(string: "https://abcdefghijklmnop.supabase.co")!,
                                    publishableKey: "sb_publishable_example")
        #expect(invite.url.absoluteString == "bluebox://party/K7QM2XDP?p=abcdefghijklmnop.supabase.co&k=sb_publishable_example")
        #expect(TogetherInvite(url: invite.url) == invite)
        // The first round's links still open.
        #expect(TogetherInvite(url: URL(string: "bluebox://together/K7QM2XDP?p=abcdefghijklmnop.supabase.co&k=sb_publishable_example")!) == invite)
        #expect(TogetherInvite(url: URL(string: "bluebox://together/K7QM2XDP?k=x")!) == nil)
        #expect(TogetherInvite(url: URL(string: "bluebox://auth-callback/K7QM2XDP?p=a.co&k=x")!) == nil)
    }

    // MARK: Finding the same release

    @Test func releasesMatchByHashThenFileThenLength() {
        let watched = TogetherRelease(infoHash: "aa", fileIndex: 3, releaseID: "torrentio:aa:3", fileName: "Film.mkv",
                                      sizeBytes: 100, duration: 6_000, label: "1080p")
        #expect(watched.match(TogetherRelease(infoHash: "AA", fileIndex: 3, label: "")) == .exact)
        #expect(watched.match(TogetherRelease(infoHash: "aa", fileIndex: nil, label: "")) == .exact)
        // Another episode's file in the same season pack.
        #expect(watched.match(TogetherRelease(infoHash: "aa", fileIndex: 4, label: "")) == .none)
        #expect(watched.match(TogetherRelease(releaseID: "torrentio:aa:3", label: "")) == .sameFile)
        #expect(watched.match(TogetherRelease(fileName: "film.MKV", sizeBytes: 100, label: "")) == .sameFile)
        #expect(watched.match(TogetherRelease(fileName: "film.MKV", sizeBytes: 101, label: "")) == .none)
        #expect(watched.match(TogetherRelease(duration: 6_001, label: "")) == .sameLength)
        #expect(watched.match(TogetherRelease(duration: 6_004, label: "")) == .none)
        typealias M = TogetherRelease.Match
        #expect(M.exact > M.sameFile && M.sameFile > M.sameLength && M.sameLength > M.none)
    }
}

// MARK: Drift

@Suite struct DriftCorrectorTests {
    @Test func smallGapsAreLeftAlone() {
        var d = DriftCorrector()
        #expect(d.correct(local: 100.4, anchor: 100, rate: 1) == .none)
        #expect(d.correct(local: 99.6, anchor: 100, rate: 1) == .none)
        #expect(!d.nudging)
    }

    @Test func behindPlaysFasterAheadPlaysSlower() throws {
        var d = DriftCorrector()
        guard case .nudge(let faster) = d.correct(local: 99.2, anchor: 100, rate: 1) else { Issue.record("no nudge"); return }
        #expect(abs(faster - 1.05) < 0.0001)  // 0.8 s over 8 s is 10 %: held to 5 %
        d.reset()
        guard case .nudge(let slower) = d.correct(local: 100.6, anchor: 100, rate: 1) else { Issue.record("no nudge"); return }
        #expect(abs(slower - 0.95) < 0.0001)
    }

    @Test func aNudgeIsProportionalAndScaledByTheRoomsRate() {
        var d = DriftCorrector()
        d.maxNudge = 0.2
        guard case .nudge(let r) = d.correct(local: 99.2, anchor: 100, rate: 2) else { Issue.record("no nudge"); return }
        #expect(abs(r - 2 * 1.1) < 0.0001)  // 0.8 / 8 = 10 % of 2×
    }

    @Test func aNudgeStopsOnlyOnceSettled() {
        var d = DriftCorrector()
        #expect(d.correct(local: 99, anchor: 100, rate: 1) != .none)
        #expect(d.nudging)
        // Inside the tolerance but not yet settled: keeps nudging, so it doesn't flap.
        guard case .nudge = d.correct(local: 99.7, anchor: 100, rate: 1) else { Issue.record("stopped early"); return }
        #expect(d.correct(local: 99.9, anchor: 100, rate: 1) == .restore(rate: 1))
        #expect(!d.nudging)
        #expect(d.correct(local: 99.9, anchor: 100, rate: 1) == .none)
    }

    @Test func bigGapsSeekAheadOfTheAnchor() {
        var d = DriftCorrector()
        _ = d.correct(local: 99, anchor: 100, rate: 1)
        #expect(d.correct(local: 90, anchor: 100, rate: 1) == .seek(to: 100.3))
        #expect(!d.nudging)
        #expect(d.correct(local: 110, anchor: 100, rate: 2) == .seek(to: 100.6))
        #expect(d.correct(local: 5, anchor: 0, rate: 1) == .seek(to: 0.3))
    }
}

// MARK: Rooms

/// An in-memory stand-in for a Realtime room: whatever one link
/// sends reaches every other started link, in order.
final class FakeTogetherHub: @unchecked Sendable {
    private let lock = NSLock()
    private var links: [ObjectIdentifier: FakeTogetherLink] = [:]
    private(set) var sent: [TogetherMessage] = []

    func link() -> FakeTogetherLink { FakeTogetherLink(hub: self) }

    func attach(_ link: FakeTogetherLink) { lock.withLock { links[ObjectIdentifier(link)] = link } }
    func detach(_ link: FakeTogetherLink) { _ = lock.withLock { links.removeValue(forKey: ObjectIdentifier(link)) } }

    func deliver(_ message: TogetherMessage, from sender: FakeTogetherLink) -> Bool {
        let targets = lock.withLock { () -> [FakeTogetherLink] in
            guard links[ObjectIdentifier(sender)] != nil else { return [] }
            sent.append(message)
            return links.values.filter { $0 !== sender }
        }
        for link in targets { link.receive(message) }
        return lock.withLock { links[ObjectIdentifier(sender)] != nil }
    }

    var messages: [TogetherMessage] { lock.withLock { sent } }
}

final class FakeTogetherLink: TogetherTransport, @unchecked Sendable {
    let hub: FakeTogetherHub
    private let lock = NSLock()
    private var onMessage: (@Sendable (TogetherMessage) -> Void)?
    /// Drops everything it would hear (a lost connection that hasn't noticed).
    var deaf = false

    init(hub: FakeTogetherHub) { self.hub = hub }

    func start(onMessage: @escaping @Sendable (TogetherMessage) -> Void, onConnection: @escaping @Sendable (TogetherConnection) -> Void) async {
        lock.withLock { self.onMessage = onMessage }
        hub.attach(self)
        onConnection(.connected)
    }

    func send(_ message: TogetherMessage) async -> Bool { hub.deliver(message, from: self) }

    func stop() async {
        hub.detach(self)
        lock.withLock { onMessage = nil }
    }

    func receive(_ message: TogetherMessage) {
        guard !deaf else { return }
        lock.withLock { onMessage }?(message)
    }
}

@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 10_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

@MainActor
@Suite struct TogetherRoomTests {
    let hub = FakeTogetherHub()
    let clock = TestClock()

    func room(_ id: String, joinedAfter: TimeInterval = 0) -> TogetherRoom {
        let clock = clock
        return TogetherRoom(me: TogetherParticipant(id: id, name: id.capitalized, joinedAt: clock.now.addingTimeInterval(joinedAfter)),
                            transport: hub.link(), now: { clock.now })
    }

    let dune = TogetherTitle(key: "tmdb:movie:438631", name: "Dune",
                             release: TogetherRelease(infoHash: "beef", label: "2160p · WEB-DL"))

    /// Waits for messages to pass through the rooms' inboxes and outboxes.
    func settle(_ done: @MainActor () -> Bool = { false }) async {
        for _ in 0..<200 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func joiningIntroducesEveryoneAndCatchesTheNewcomerUp() async {
        let alice = room("alice"), bo = room("bo", joinedAfter: 30)
        var started: [TogetherTitle] = []
        bo.onTitle = { started.append($0) }
        await alice.join()
        alice.start(dune)
        alice.heartbeat(TogetherPlayhead(position: 300, paused: false, sentAt: clock.now), status: .ready)
        await bo.join()
        await settle { bo.title != nil && alice.others["bo"] != nil && bo.others["alice"] != nil && bo.playheads["alice"] != nil }
        #expect(alice.others["bo"]?.name == "Bo")
        #expect(bo.others["alice"]?.status == .ready)
        #expect(bo.title == dune)
        #expect(started == [dune])
        #expect(bo.playheads["alice"]?.position == 300)
        #expect(bo.anchor?.id == "alice")
        #expect(alice.anchor?.id == "alice")
    }

    @Test func commandsReachEveryoneElseOnce() async throws {
        let alice = room("alice"), bo = room("bo", joinedAfter: 1), cy = room("cy", joinedAfter: 2)
        var heard: [String: [TogetherCommand]] = [:]
        for r in [alice, bo, cy] { r.onCommand = { heard[r.me.id, default: []].append($0) } }
        for r in [alice, bo, cy] { await r.join() }
        await settle { alice.others.count == 2 && bo.others.count == 2 && cy.others.count == 2 }

        let sent = try #require(bo.perform(.pause, playhead: TogetherPlayhead(position: 42, paused: true, sentAt: clock.now)))
        await settle { heard["alice"]?.count == 1 && heard["cy"]?.count == 1 }
        #expect(heard["alice"] == [sent] && heard["cy"] == [sent])
        #expect(heard["bo"] == nil)  // never your own back

        // A stale copy (lower clock) arriving late is ignored.
        alice.receive(.command(TogetherCommand(action: .play, playhead: TogetherPlayhead(position: 1, paused: false, sentAt: clock.now),
                                               seq: sent.seq - 1, from: "cy")))
        #expect(heard["alice"]?.count == 1)
    }

    @Test func twoPeopleAtOnceEndUpTheSameEverywhere() async throws {
        let alice = room("alice"), bo = room("bo")
        var aliceHeard: [TogetherCommand] = [], boHeard: [TogetherCommand] = []
        alice.onCommand = { aliceHeard.append($0) }
        bo.onCommand = { boHeard.append($0) }
        // Both press at the same Lamport time, before hearing each other.
        let a = try #require(alice.perform(.pause, playhead: TogetherPlayhead(position: 10, paused: true, sentAt: clock.now)))
        let b = try #require(bo.perform(.play, playhead: TogetherPlayhead(position: 10, paused: false, sentAt: clock.now)))
        #expect(a.seq == b.seq)
        alice.receive(.command(b))
        bo.receive(.command(a))
        // "bo" > "alice": Bo's play wins on both devices; Alice's pause is dropped by Bo.
        #expect(aliceHeard == [b])
        #expect(boHeard.isEmpty)
    }

    @Test func leavingAndGoingQuiet() async {
        let alice = room("alice"), bo = room("bo", joinedAfter: 1), cy = room("cy", joinedAfter: 2)
        for r in [alice, bo, cy] { await r.join() }
        await settle { cy.others.count == 2 && bo.others.count == 2 }
        #expect(cy.anchor?.id == "alice")

        await alice.leave()
        await settle { cy.others["alice"] == nil && bo.others["alice"] == nil }
        #expect(cy.others.keys.sorted() == ["bo"])
        #expect(alice.connection == .closed && alice.others.isEmpty)
        // The next longest-present takes over as anchor.
        #expect(cy.anchor?.id == "bo")

        // Bo's network drops without a goodbye: forgotten after `goneAfter`.
        (bo.transport as? FakeTogetherLink)?.deaf = true
        await bo.transport.stop()
        clock.advance(TogetherRoom.goneAfter - 1)
        cy.heartbeat(nil, status: .ready)
        #expect(cy.others["bo"] != nil)
        clock.advance(2)
        cy.heartbeat(nil, status: .ready)
        #expect(cy.others.isEmpty)
        #expect(cy.anchor?.id == "cy")
    }

    @Test func someoneWhoCantPlayItIsNeverTheAnchor() {
        let bo = room("bo", joinedAfter: 10)
        bo.receive(.presence(TogetherParticipant(id: "alice", name: "Alice", joinedAt: clock.now, status: .unavailable("Not in your add-ons"))))
        bo.receive(.presence(TogetherParticipant(id: "cy", name: "Cy", joinedAt: clock.now.addingTimeInterval(5), status: .buffering)))
        bo.start(dune)
        #expect(bo.anchor?.id == "cy")
        #expect(bo.unavailable.map(\.name) == ["Alice"])
        #expect(bo.waitingFor.map(\.name) == ["Cy"])
    }

    @Test func aNewTitleOnlyFromALaterStart() {
        let bo = room("bo")
        var started: [String] = []
        bo.onTitle = { started.append($0.name) }
        bo.start(dune)  // seq 1
        let arrival = TogetherTitle(key: "tmdb:movie:1", name: "Arrival", release: TogetherRelease(infoHash: "cafe", label: ""))
        bo.receive(.title(arrival, from: "alice", seq: 1))  // same time, lower device: Bo's Dune stands
        #expect(bo.title == dune)
        bo.receive(.title(arrival, from: "alice", seq: 2))
        #expect(bo.title == arrival && started == ["Arrival"])
        bo.receive(.title(arrival, from: "alice", seq: 2))  // a repeat for a newcomer: no restart
        #expect(started == ["Arrival"])
    }

    @Test func driftIsCorrectedAgainstTheAnchor() {
        let bo = room("bo", joinedAfter: 10)
        bo.receive(.presence(TogetherParticipant(id: "alice", name: "Alice", joinedAt: clock.now, status: .ready)))
        bo.receive(.state(from: "alice", TogetherPlayhead(position: 100, paused: false, sentAt: clock.now)))
        clock.advance(1)  // Alice is at 101 now
        #expect(bo.fix(for: TogetherPlayhead(position: 100.8, paused: false, sentAt: clock.now)) == .none)
        guard case .drift(.nudge(let r)) = bo.fix(for: TogetherPlayhead(position: 100, paused: false, sentAt: clock.now)) else {
            Issue.record("no nudge"); return
        }
        #expect(r > 1)
        #expect(bo.fix(for: TogetherPlayhead(position: 80, paused: false, sentAt: clock.now)) == .drift(.seek(to: 101.3)))

        // Just after a command, players are still getting there: left alone.
        bo.perform(.seek, playhead: TogetherPlayhead(position: 200, paused: false, sentAt: clock.now))
        #expect(bo.fix(for: TogetherPlayhead(position: 200, paused: false, sentAt: clock.now)) == .none)
    }

    @Test func aLostPauseIsPutRight() {
        let bo = room("bo", joinedAfter: 10)
        bo.receive(.presence(TogetherParticipant(id: "alice", name: "Alice", joinedAt: clock.now, status: .ready)))
        bo.receive(.state(from: "alice", TogetherPlayhead(position: 50, paused: true, sentAt: clock.now)))
        let playing = TogetherPlayhead(position: 50, paused: false, sentAt: clock.now)
        #expect(bo.fix(for: playing) == .none)  // might be a pause on its way
        clock.advance(TogetherRoom.adoptAfter)
        #expect(bo.fix(for: playing) == .match(TogetherPlayhead(position: 50, paused: true, rate: 1, sentAt: clock.now)))
    }

    @Test func theAnchorItselfIsNeverCorrected() {
        let alice = room("alice")
        alice.receive(.presence(TogetherParticipant(id: "bo", name: "Bo", joinedAt: clock.now.addingTimeInterval(9))))
        alice.receive(.state(from: "bo", TogetherPlayhead(position: 900, paused: false, sentAt: clock.now)))
        #expect(alice.fix(for: TogetherPlayhead(position: 1, paused: false, sentAt: clock.now)) == .none)
    }
}

// MARK: The party

@MainActor
@Suite struct WatchPartyTests {
    let hub = FakeTogetherHub()
    let clock = TestClock()

    func room(_ id: String, joinedAfter: TimeInterval = 0) -> TogetherRoom {
        let clock = clock
        return TogetherRoom(me: TogetherParticipant(id: id, name: id.capitalized, joinedAt: clock.now.addingTimeInterval(joinedAfter)),
                            transport: hub.link(), now: { clock.now })
    }

    func settle(_ done: @MainActor () -> Bool = { false }) async {
        for _ in 0..<200 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func messages(_ r: TogetherRoom) -> [String] {
        r.feed.compactMap { if case .message(let m) = $0 { m.text } else { nil } }
    }

    @Test func chatReachesEveryoneAndNewcomersGetTheHistory() async {
        let alice = room("alice"), bo = room("bo", joinedAfter: 1), cy = room("cy", joinedAfter: 2)
        alice.host()
        await alice.join(); await bo.join()
        await settle { alice.others["bo"] != nil && bo.settings != nil }
        let first = alice.say("here it comes", at: 3_952)
        bo.say("  ")  // nothing
        await settle { messages(bo) == ["here it comes"] }
        bo.react("😂", to: first)
        await settle { alice.reactions.count == 1 }
        #expect(alice.reactionCounts(on: first!.id).map(\.count) == [1])

        // Cy arrives later and gets the chat (once, from Alice, who's been here longest).
        await cy.join()
        await settle { messages(cy) == ["here it comes"] && cy.reactions.count == 1 }
        #expect(hub.messages.filter { if case .history("cy", let from, _, _) = $0 { from == "alice" } else { false } }.count == 1)
        #expect(hub.messages.filter { if case .history("cy", _, _, _) = $0 { true } else { false } }.count == 1)
        #expect(cy.settings?.host == "alice")
        #expect(cy.feed.count >= 1)
    }

    @Test func mentionsAndReplies() {
        let alice = room("alice")
        alice.receive(.presence(TogetherParticipant(id: "s1", name: "Sam", joinedAt: clock.now)))
        alice.receive(.presence(TogetherParticipant(id: "s2", name: "Sam Lee", joinedAt: clock.now)))
        let q = TogetherChatMessage(from: "s1", name: "Sam", text: String(repeating: "x", count: 300), sentAt: clock.now)
        let m = alice.say("@Sam Lee NO WAY", replyingTo: q)
        #expect(m?.mentions == ["s2"])
        #expect(m?.replyTo?.name == "Sam" && m?.replyTo?.text.count == 120)
        #expect(TogetherChatMessage(from: "a", name: "A", text: String(repeating: "y", count: 900), sentAt: clock.now).text.count == 500)
    }

    @Test func oneGuestCantFloodTheRoom() {
        let alice = room("alice")
        for i in 0..<20 {
            alice.receive(.chat(TogetherChatMessage(id: "m\(i)", from: "bo", name: "Bo", text: "spam", sentAt: clock.now)))
        }
        #expect(messages(alice).count == TogetherRoom.floodLimit)
        clock.advance(TogetherRoom.floodWindow)
        alice.receive(.chat(TogetherChatMessage(id: "later", from: "bo", name: "Bo", text: "ok", sentAt: clock.now)))
        #expect(messages(alice).last == "ok")
    }

    @Test func typingLapses() {
        let alice = room("alice")
        alice.receive(.presence(TogetherParticipant(id: "bo", name: "Bo", joinedAt: clock.now)))
        alice.receive(.typing(from: "bo"))
        #expect(alice.typingNames == ["Bo"])
        clock.advance(TogetherRoom.typingLasts + 0.1)
        #expect(alice.typingNames.isEmpty)
    }

    @Test func theHostHandsOverOnLeavingAndTheLongestPresentTakesOver() async {
        let alice = room("alice"), bo = room("bo", joinedAfter: 1), cy = room("cy", joinedAfter: 2)
        alice.host()
        for r in [alice, bo, cy] { await r.join() }
        await settle { bo.settings != nil && cy.settings != nil && cy.others.count == 2 }
        await alice.leave()
        await settle { bo.settings?.host == "bo" && cy.settings?.host == "bo" }
        #expect(bo.isHost && !cy.isHost)

        // Bo vanishes without a word: Cy, the longest present left, takes over.
        (bo.transport as? FakeTogetherLink)?.deaf = true
        await bo.transport.stop()
        clock.advance(TogetherRoom.goneAfter + 1)
        cy.heartbeat(nil, status: .ready)
        #expect(cy.isHost)
    }

    @Test func hostTools() async {
        let alice = room("alice"), bo = room("bo", joinedAfter: 1)
        var ended: String?
        bo.onEnded = { ended = $0 }
        alice.host(lobby: false)
        await alice.join(); await bo.join()
        await settle { bo.settings != nil && alice.others["bo"] != nil }

        // Only I Control Playback: Bo's presses stay on Bo's device, and others ignore them.
        alice.setHostOnlyControls(true)
        await settle { bo.settings?.hostOnlyControls == true }
        #expect(!bo.canControl && alice.canControl)
        #expect(bo.perform(.pause, playhead: TogetherPlayhead(position: 1, paused: true, sentAt: clock.now)) == nil)
        var heard: [TogetherCommand] = []
        alice.onCommand = { heard.append($0) }
        alice.receive(.command(TogetherCommand(action: .pause, playhead: TogetherPlayhead(position: 1, paused: true, sentAt: clock.now),
                                               seq: 99, from: "bo")))
        #expect(heard.isEmpty)

        // Locking keeps Bo in and Cy out.
        alice.setLocked(true)
        await settle { bo.settings?.locked == true }
        #expect(ended == nil)
        let cy = room("cy", joinedAfter: 2)
        var cyEnded: String?
        cy.onEnded = { cyEnded = $0 }
        await cy.join()
        await settle { cyEnded != nil }
        #expect(cyEnded == "This party is locked.")
        #expect(alice.others["cy"] == nil)

        // Removing Bo ends it for Bo.
        alice.remove("bo")
        await settle { ended != nil }
        #expect(ended == "You were removed from the party.")
        #expect(alice.others["bo"] == nil)
    }

    @Test func endingForEveryone() async {
        let alice = room("alice"), bo = room("bo", joinedAfter: 1)
        var ended: String?
        bo.onEnded = { ended = $0 }
        alice.host()
        await alice.join(); await bo.join()
        await settle { bo.settings != nil && bo.others["alice"] != nil }
        alice.endForEveryone()
        await settle { ended != nil }
        #expect(ended == "Alice ended the party.")
    }

    @Test func steppingAwayAndCatchingUp() {
        let bo = room("bo", joinedAfter: 10)
        var heard: [TogetherCommand] = []
        bo.onCommand = { heard.append($0) }
        bo.receive(.presence(TogetherParticipant(id: "alice", name: "Alice", joinedAt: clock.now, status: .ready)))
        bo.receive(.state(from: "alice", TogetherPlayhead(position: 100, paused: false, sentAt: clock.now)))
        bo.stepAway()
        // Nobody lines up with Bo, Bo lines up with nobody, and the room's presses wait.
        #expect(bo.fix(for: TogetherPlayhead(position: 10, paused: true, sentAt: clock.now)) == .none)
        #expect(bo.perform(.pause, playhead: TogetherPlayhead(position: 10, paused: true, sentAt: clock.now)) == nil)
        bo.receive(.command(TogetherCommand(action: .seek, playhead: TogetherPlayhead(position: 200, paused: false, sentAt: clock.now),
                                            seq: 5, from: "alice")))
        #expect(heard.isEmpty)
        clock.advance(10)
        let back = bo.catchUp()
        #expect(back?.position == 210 && back?.paused == false)
        #expect(!bo.me.away)

        // Someone who stepped away isn't waited for.
        let alice = room("alice")
        alice.start(TogetherTitle(key: "k", name: "Dune", release: TogetherRelease(label: "")))
        alice.receive(.presence(TogetherParticipant(id: "mia", name: "Mia", joinedAt: clock.now, status: .buffering, away: true)))
        #expect(alice.waitingFor.isEmpty)
    }

    @Test func theLobbyCountsDownTogether() async {
        let alice = room("alice"), bo = room("bo", joinedAfter: 1)
        var starts: [String: TogetherCountdown] = [:]
        alice.onCountdown = { starts["alice"] = $0 }
        bo.onCountdown = { starts["bo"] = $0 }
        alice.host()
        await alice.join(); await bo.join()
        await settle { bo.settings?.lobby == true }
        bo.startCountdown(from: 0)  // not the host: nothing
        #expect(starts.isEmpty)
        alice.startCountdown(from: 0)
        await settle { starts.count == 2 }
        #expect(bo.countdownEndsAt == clock.now.addingTimeInterval(3))
        #expect(bo.settings?.lobby == false && alice.settings?.lobby == false)
    }

    @Test func upNextWaitsForEveryonesCopyThenCountsDown() async {
        let alice = room("alice"), bo = room("bo", joinedAfter: 1)
        var due: [String] = []
        var proposed: [String] = []
        alice.onUpNextDue = { due.append("alice:" + $0.item.key) }
        bo.onUpNextDue = { due.append("bo:" + $0.item.key) }
        bo.onUpNext = { proposed.append($0.item.key) }
        alice.host(lobby: false)
        await alice.join(); await bo.join()
        await settle { bo.settings != nil && alice.others["bo"] != nil }
        let item = TogetherQueueItem(id: "e4", key: "tmdb:tv:1:s1e4", name: "Severance", subtitle: "S1·E4")
        alice.enqueue(item)
        alice.proposeUpNext(item, fromQueue: true)
        await settle { proposed == [item.key] }
        let id = alice.upNext!.id
        alice.upNextFound(id)
        #expect(alice.upNextEndsAt == nil)  // Bo hasn't found it yet
        bo.upNextFound(id)
        await settle { alice.upNextEndsAt != nil }
        clock.advance(TimeInterval(TogetherUpNext.countdown))
        alice.tick(); bo.tick()
        #expect(due.sorted() == ["alice:" + item.key, "bo:" + item.key])
        #expect(alice.settings?.queue.isEmpty == true)

        // Cancel: gone for everyone.
        let e5 = TogetherQueueItem(key: "tmdb:tv:1:s1e5", name: "Severance", subtitle: "S1·E5")
        alice.proposeUpNext(e5, fromQueue: false)
        await settle { bo.upNext?.item.key == e5.key }
        bo.cancelUpNext()
        await settle { alice.upNext == nil }
        #expect(alice.feed.contains { if case .event(_, let text, _) = $0 { text == "Bo cancelled S1·E5" } else { false } })
    }
}

// MARK: Realtime framing

@Suite struct TogetherRealtimeRoomTests {
    let code = TogetherJoinCode("K7QM2XDP")!

    @Test func theTopicIsTheCode() {
        #expect(TogetherRealtimeRoom.topic(code) == "realtime:bluebox-together:k7qm2xdp")
        // The migration's policy pattern accepts exactly these.
        #expect(SupabaseSetupFiles.watchTogetherMigrationSQL.contains("'^bluebox-together:[a-z0-9]{8}$'"))
        let join = TogetherRealtimeRoom.joinMessage(topic: "t", token: "tok", ref: "1")
        let config = ((join["payload"] as? [String: Any])?["config"] as? [String: Any])
        #expect(config?["private"] as? Bool == true)
    }

    @Test func broadcastsComeBackAsMessages() throws {
        let topic = TogetherRealtimeRoom.topic(code)
        let m = TogetherMessage.leave(from: "bo")
        let frame = TogetherRealtimeRoom.broadcastMessage(topic: topic, payload: try m.jsonObject(), ref: "9")
        let data = try JSONSerialization.data(withJSONObject: frame)
        #expect(TogetherRealtimeRoom.classify(data, topic: topic, joinRef: "1") == .message(m))
        #expect(TogetherRealtimeRoom.classify(data, topic: "realtime:bluebox-together:other000", joinRef: "1") == .other)
    }

    @Test func aRefusedJoinIsFinal() throws {
        let topic = TogetherRealtimeRoom.topic(code)
        func reply(_ status: String, _ reason: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["topic": topic, "event": "phx_reply", "ref": "1",
                                                        "payload": ["status": status, "response": ["reason": reason]]])
        }
        #expect(TogetherRealtimeRoom.classify(try reply("ok", ""), topic: topic, joinRef: "1") == .joined)
        guard case .refused = TogetherRealtimeRoom.classify(try reply("error", "Unauthorized: You do not have permissions"),
                                                            topic: topic, joinRef: "1") else {
            Issue.record("not refused"); return
        }
        #expect(TogetherRealtimeRoom.classify(try reply("error", "timeout"), topic: topic, joinRef: "1") == .closed("timeout"))
    }
}

/// Repeatable codes in tests.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
