import Foundation
@testable import Sync
import Testing

/// iPhone as a remote: the wire format, the Realtime broadcast framing, and
/// how the remote reconciles its optimistic controls with what the Mac publishes.
@Suite struct RemoteControlTests {
    let mac = "mac-1"
    let t0 = Date(timeIntervalSince1970: 1_000)

    func state(position: TimeInterval = 100, paused: Bool = false, seq: Int = 1, device: String? = nil,
               audio: String? = "a1", subtitle: String? = nil, volume: Float = 0.8) -> RemoteNowPlaying {
        RemoteNowPlaying(deviceID: device ?? mac, deviceName: "Studio", title: "Severance", subtitle: "S1·E2",
                         position: position, duration: 3_000, paused: paused,
                         audioTracks: [RemoteTrack(id: "a1", label: "English"), RemoteTrack(id: "a2", label: "French")],
                         subtitleTracks: [RemoteTrack(id: "s1", label: "English")],
                         audioID: audio, subtitleID: subtitle, volume: volume, hasNext: true, seq: seq)
    }

    // MARK: Encoding

    @Test func messagesRoundTrip() throws {
        let messages: [RemoteMessage] = [
            .state(state()),
            .command(RemoteCommand(target: mac, action: .setPaused(true))),
            .command(RemoteCommand(target: mac, action: .seek(42.5))),
            .command(RemoteCommand(target: mac, action: .nextEpisode)),
            .command(RemoteCommand(target: mac, action: .audio("a2"))),
            .command(RemoteCommand(target: mac, action: .subtitle("s1"))),
            .command(RemoteCommand(target: mac, action: .subtitle(nil))),
            .command(RemoteCommand(target: mac, action: .volume(0.25))),
            .hello(from: "phone"),
            .stopped(deviceID: mac),
            // The whole app (protocol 3).
            .command(RemoteCommand(target: mac, action: .scrub(812), from: "phone")),
            .command(RemoteCommand(target: mac, action: .closePlayer)),
            .command(RemoteCommand(target: mac, action: .go(.home))),
            .command(RemoteCommand(target: mac, action: .go(.search("dune")))),
            .command(RemoteCommand(target: mac, action: .go(.title(.movie(tmdbID: 438631))))),
            .command(RemoteCommand(target: mac, action: .go(.back))),
            .command(RemoteCommand(target: mac, action: .focus("episode:tmdb:tv:95396:s1e3"))),
            .command(RemoteCommand(target: mac, action: .move(.left))),
            .command(RemoteCommand(target: mac, action: .select)),
            .command(RemoteCommand(target: mac, action: .play(RemotePlay(key: .movie(tmdbID: 1), title: "Dune", subtitle: "2021",
                                                                          resume: false, release: Data("{}".utf8))))),
            .device(RemoteDevice(id: mac, name: "Studio", kind: .mac, controllable: true, playing: "Dune")),
            .screen(RemoteScreen(deviceID: mac, title: "Severance", focusedID: "play", focusedLabel: "Play S1·E3")),
            // The better remote (protocol 4).
            .command(RemoteCommand(target: mac, action: .jump(RemoteJump(.down, count: 4)))),
            .command(RemoteCommand(target: mac, action: .scroll(RemoteScroll(dx: -3, dy: 120)))),
            .command(RemoteCommand(target: mac, action: .scroll(RemoteScroll(dx: 0, dy: 8, velocityX: 0, velocityY: 1400)))),
            .command(RemoteCommand(target: mac, action: .setPointer(true))),
            .command(RemoteCommand(target: mac, action: .pointer(RemotePointerMove(dx: 12.5, dy: -4)))),
            .command(RemoteCommand(target: mac, action: .click)),
            .command(RemoteCommand(target: mac, action: .menu)),
            .command(RemoteCommand(target: mac, action: .menuPick(3))),
            .command(RemoteCommand(target: mac, action: .acceptSkip)),
            .state(RemoteNowPlaying(deviceID: mac, deviceName: "Studio", title: "Severance", position: 30, duration: 3000, paused: false,
                                    skipOffer: "Skip Intro", chapters: [0, 312, 1800], seq: 9)),
            .screen(RemoteScreen(deviceID: mac, title: "Home", focusedID: "title:x", focusedLabel: "Severance",
                                 focused: RemoteScreenItem(label: "Severance", kind: .poster, image: URL(string: "https://example.com/p.jpg")),
                                 before: RemoteScreenItem(label: "Dune", kind: .poster), after: RemoteScreenItem(label: "Skip intros", kind: .toggle, isOn: true),
                                 horizontal: true, section: "Continue Watching", pointer: nil, bumps: 2,
                                 menu: RemoteMenu(title: "Severance", items: [RemoteMenu.Item(index: 1, title: "Play", systemImage: "play.fill"),
                                                                              RemoteMenu.Item(index: 3, title: "Remove", destructive: true)],
                                                  highlighted: 1))),
        ]
        for m in messages {
            #expect(try RemoteMessage.decode(jsonObject: m.jsonObject()) == m)
        }
    }

    /// A screen from a Mac before protocol 4 has none of the new fields, and still reads.
    @Test func anOlderScreenStillReads() throws {
        let json: [String: Any] = ["type": "screen", "screen": ["deviceID": mac, "title": "Home", "focusedLabel": "Dune"]]
        guard case .screen(let s) = try RemoteMessage.decode(jsonObject: json) else { Issue.record("not a screen"); return }
        #expect(s.focusedLabel == "Dune" && s.focused == nil && s.menu == nil && s.pointer == nil)
        #expect(RemoteCommand.Action.jump(RemoteJump(.left, count: 2)).needsVersion4)
        #expect(!RemoteCommand.Action.move(.left).needsVersion4)
    }

    @Test func wireFormatIsStable() throws {
        let command = RemoteMessage.command(RemoteCommand(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                                          target: mac, action: .seek(10)))
        let json = try command.jsonObject()
        #expect(json["type"] as? String == "command")
        let body = try #require(json["command"] as? [String: Any])
        #expect(body["target"] as? String == mac)
        #expect((body["action"] as? [String: Any])?["kind"] as? String == "seek")
        #expect((body["action"] as? [String: Any])?["value"] as? Double == 10)
        // Subtitles off has no value at all.
        let off = try RemoteMessage.command(RemoteCommand(target: mac, action: .subtitle(nil))).jsonObject()
        #expect(((off["command"] as? [String: Any])?["action"] as? [String: Any])?["value"] == nil)
        // A message from a newer build that this one doesn't know is refused, not misread.
        #expect(throws: (any Error).self) { try RemoteMessage.decode(jsonObject: ["type": "teleport"]) }
        #expect(throws: (any Error).self) {
            try RemoteMessage.decode(jsonObject: ["type": "command", "command": ["id": UUID().uuidString, "target": "x",
                                                                                 "action": ["kind": "rewindTime"]]])
        }
    }

    // MARK: Channel framing

    @Test func topicIsPerAccount() {
        #expect(RemoteChannel.topic(userID: "ABC-123") == "realtime:bluebox-remote:abc-123")
    }

    @Test func joinAndBroadcastFraming() throws {
        let join = RemoteChannel.joinMessage(topic: "realtime:bluebox-remote:u", token: "jwt", ref: "1")
        #expect(join["event"] as? String == "phx_join")
        let config = try #require((join["payload"] as? [String: Any])?["config"] as? [String: Any])
        #expect((config["broadcast"] as? [String: Any])?["self"] as? Bool == false)
        // Private: Realtime checks the realtime.messages policies (security review BB-03).
        #expect(config["private"] as? Bool == true)
        _ = try JSONSerialization.data(withJSONObject: join)

        let payload = try RemoteMessage.hello(from: "phone").jsonObject()
        let out = RemoteChannel.broadcastMessage(topic: "realtime:bluebox-remote:u", payload: payload, ref: "2")
        let data = try JSONSerialization.data(withJSONObject: out)
        // What the other device receives has the same shape as what was sent.
        #expect(RemoteChannel.classify(data, topic: "realtime:bluebox-remote:u", joinRef: "1") == .message(.hello(from: "phone")))
    }

    @Test func classifiesIncoming() {
        let topic = "realtime:bluebox-remote:u"
        func c(_ s: String) -> RemoteChannel.Incoming { RemoteChannel.classify(Data(s.utf8), topic: topic, joinRef: "1") }
        #expect(c(#"{"topic":"realtime:bluebox-remote:u","event":"phx_reply","ref":"1","payload":{"status":"ok","response":{}}}"#) == .joined)
        // A reply to a broadcast or heartbeat isn't the join.
        #expect(c(#"{"topic":"realtime:bluebox-remote:u","event":"phx_reply","ref":"7","payload":{"status":"ok","response":{}}}"#) == .other)
        #expect(c(#"{"topic":"realtime:bluebox-remote:u","event":"phx_reply","ref":"1","payload":{"status":"error","response":{"reason":"Unauthorized"}}}"#) == .closed("Unauthorized"))
        // Another account's topic, another broadcast event, or garbage: ignored.
        #expect(c(#"{"topic":"realtime:bluebox-remote:v","event":"broadcast","payload":{"event":"remote","payload":{"type":"hello","device":"x"}}}"#) == .other)
        #expect(c(#"{"topic":"realtime:bluebox-remote:u","event":"broadcast","payload":{"event":"other","payload":{"type":"hello","device":"x"}}}"#) == .other)
        #expect(c(#"{"topic":"realtime:bluebox-remote:u","event":"broadcast","payload":{"event":"remote","payload":{"type":"nope"}}}"#) == .other)
        #expect(c(#"{"topic":"realtime:bluebox-remote:u","event":"phx_close","payload":{}}"#) == .closed("phx_close"))
        #expect(c("not json") == .other)
    }

    // MARK: Reconciling

    @Test func runsTheClockForwardWhilePlaying() throws {
        var r = RemoteReconciler()
        r.receive(state(position: 100), at: t0)
        #expect(try #require(r.displayed(at: t0.addingTimeInterval(5))).position == 105)
        r.receive(state(position: 200, paused: true, seq: 2), at: t0)
        #expect(try #require(r.displayed(at: t0.addingTimeInterval(5))).position == 200)
    }

    @Test func optimisticPauseHoldsUntilTheMacAgrees() throws {
        var r = RemoteReconciler(timeout: 4)
        r.receive(state(position: 100), at: t0)
        r.apply(.setPaused(true), at: t0.addingTimeInterval(2))
        // Shown paused at once, frozen where it was when tapped.
        var shown = try #require(r.displayed(at: t0.addingTimeInterval(3)))
        #expect(shown.paused && shown.position == 102)
        // A state sent before the Mac got the command doesn't undo it.
        r.receive(state(position: 102.5, paused: false, seq: 2), at: t0.addingTimeInterval(2.5))
        shown = try #require(r.displayed(at: t0.addingTimeInterval(3)))
        #expect(shown.paused)
        // The Mac confirms; its position wins from here.
        r.receive(state(position: 102.6, paused: true, seq: 3), at: t0.addingTimeInterval(3))
        shown = try #require(r.displayed(at: t0.addingTimeInterval(10)))
        #expect(shown.paused && shown.position == 102.6)
    }

    @Test func aLostCommandTimesOutToTheMacsState() throws {
        var r = RemoteReconciler(timeout: 4)
        r.receive(state(position: 100), at: t0)
        r.apply(.setPaused(true), at: t0)
        #expect(try #require(r.displayed(at: t0.addingTimeInterval(1))).paused)
        // Nothing confirms it: after the timeout the Mac's word (still playing) is shown again.
        #expect(try #require(r.displayed(at: t0.addingTimeInterval(5))).paused == false)
    }

    @Test func seekShowsTheTargetAndKeepsCounting() throws {
        var r = RemoteReconciler()
        r.receive(state(position: 100), at: t0)
        r.apply(.seek(600), at: t0.addingTimeInterval(1))
        #expect(try #require(r.displayed(at: t0.addingTimeInterval(2))).position == 601)
        // Confirmed by a state near the target.
        r.receive(state(position: 601.2, seq: 2), at: t0.addingTimeInterval(2))
        #expect(try #require(r.displayed(at: t0.addingTimeInterval(2))).position == 601.2)
    }

    @Test func tracksAndVolumeOverlayUntilConfirmed() throws {
        var r = RemoteReconciler()
        r.receive(state(), at: t0)
        r.apply(.audio("a2"), at: t0)
        r.apply(.subtitle("s1"), at: t0)
        r.apply(.volume(0.3), at: t0)
        r.apply(.volume(0.4), at: t0)  // a newer one replaces it
        var shown = try #require(r.displayed(at: t0.addingTimeInterval(1)))
        #expect(shown.audioID == "a2" && shown.subtitleID == "s1" && shown.volume == 0.4)
        r.receive(state(seq: 2, audio: "a2", subtitle: "s1", volume: 0.4), at: t0.addingTimeInterval(1))
        r.apply(.subtitle(nil), at: t0.addingTimeInterval(1))
        shown = try #require(r.displayed(at: t0.addingTimeInterval(2)))
        #expect(shown.audioID == "a2" && shown.subtitleID == nil && shown.volume == 0.4)
    }

    @Test func olderStatesAreIgnoredAndStoppingClears() {
        var r = RemoteReconciler()
        r.receive(state(position: 500, seq: 5), at: t0)
        r.receive(state(position: 10, seq: 4), at: t0.addingTimeInterval(1))
        #expect(r.published?.position == 500)
        // Another Mac's player takes over (its own seq).
        r.receive(state(position: 7, seq: 1, device: "mac-2"), at: t0.addingTimeInterval(1))
        #expect(r.published?.deviceID == "mac-2")
        r.stopped(deviceID: mac)  // not the one shown
        #expect(r.published != nil)
        r.stopped(deviceID: "mac-2")
        #expect(r.displayed(at: t0.addingTimeInterval(1)) == nil)
    }

    @Test func goesStaleWithoutStates() {
        var r = RemoteReconciler(staleAfter: 30)
        #expect(r.displayed(at: t0) == nil)
        r.receive(state(), at: t0)
        #expect(r.displayed(at: t0.addingTimeInterval(29)) != nil)
        #expect(r.displayed(at: t0.addingTimeInterval(31)) == nil)
    }

    // MARK: Acknowledged commands

    /// Was: a state the Mac sent before it had the seek, 2 s short of the
    /// target, counted as confirming it, so the remote jumped back.
    @Test func onlyAStateAfterTheAckConfirms() throws {
        var r = RemoteReconciler()
        r.receive(state(position: 100, seq: 10), at: t0)
        let id = UUID()
        r.apply(.seek(110), id: id, at: t0)
        // Published before the Mac had it: near the target by chance, but not the seek's doing.
        r.receive(state(position: 108.5, seq: 11), at: t0.addingTimeInterval(0.3))
        #expect(r.isPending(id))
        r.acknowledged(RemoteAck(commandID: id, deviceID: mac, seq: 11), at: t0.addingTimeInterval(0.4))
        r.receive(state(position: 110.2, seq: 12), at: t0.addingTimeInterval(0.6))
        #expect(!r.isPending(id))
    }

    /// Was: a seek on a slow stream took longer than 4 s to land and the remote
    /// snapped back to the old time meanwhile. Acknowledged, it waits longer.
    @Test func anAcknowledgedSeekWaitsForASlowEngine() throws {
        var r = RemoteReconciler(timeout: 4, ackedTimeout: (15, 8))
        r.receive(state(position: 100, seq: 10), at: t0)
        let id = UUID()
        r.apply(.seek(1_200), id: id, at: t0)
        r.acknowledged(RemoteAck(commandID: id, deviceID: mac, seq: 10), at: t0.addingTimeInterval(0.2))
        // Still buffering at the old spot after 6 s.
        r.receive(state(position: 106, seq: 11), at: t0.addingTimeInterval(6))
        #expect(try #require(r.displayed(at: t0.addingTimeInterval(6))).position == 1_206)
        // Unacknowledged it would have given up at 4 s.
        var lost = RemoteReconciler(timeout: 4)
        lost.receive(state(position: 100, seq: 10), at: t0)
        lost.apply(.seek(1_200), id: UUID(), at: t0)
        lost.receive(state(position: 106, seq: 11), at: t0.addingTimeInterval(6))
        #expect(try #require(lost.displayed(at: t0.addingTimeInterval(6))).position == 106)
    }

    @Test func anAbandonedCommandShowsTheMacsWord() throws {
        var r = RemoteReconciler()
        r.receive(state(), at: t0)
        let id = UUID()
        r.apply(.audio("a2"), id: id, at: t0)
        #expect(try #require(r.displayed(at: t0)).audioID == "a2")
        r.abandon(id)
        #expect(try #require(r.displayed(at: t0)).audioID == "a1")
    }

    /// Was: a Mac that restarted counted its seq from 1 again, and a phone that
    /// still held the old Mac's state ignored it until the phone went to the background.
    @Test func aStaleStateGivesWayToALowerSeq() {
        var r = RemoteReconciler(staleAfter: 30)
        r.receive(state(position: 500, seq: 900), at: t0)
        r.receive(state(position: 10, seq: 3), at: t0.addingTimeInterval(5))
        #expect(r.published?.seq == 900)  // fresh: a late message, ignored
        r.receive(state(position: 10, seq: 3), at: t0.addingTimeInterval(40))
        #expect(r.published?.seq == 3)  // stale: the Mac came back
    }

    @Test func versionAndAcksRoundTrip() throws {
        let ack = RemoteMessage.ack(RemoteAck(commandID: UUID(), deviceID: mac, seq: 42))
        #expect(try RemoteMessage.decode(jsonObject: ack.jsonObject()) == ack)
        #expect(state().acknowledges)
        // A state from a build before acks has no version, and isn't retried.
        var json = try RemoteMessage.state(state()).jsonObject()
        var body = try #require(json["state"] as? [String: Any])
        body["version"] = nil
        json["state"] = body
        guard case .state(let old) = try RemoteMessage.decode(jsonObject: json) else { Issue.record("not a state"); return }
        #expect(!old.acknowledges)
    }

    @Test func accessTokenFraming() {
        let m = RemoteChannel.accessTokenMessage(topic: "realtime:bluebox-remote:u", token: "jwt2", ref: "9")
        #expect(m["event"] as? String == "access_token")
        #expect((m["payload"] as? [String: Any])?["access_token"] as? String == "jwt2")
    }

    @Test func positionStaysWithinTheItem() throws {
        var r = RemoteReconciler()
        r.receive(state(position: 2_995), at: t0)
        #expect(try #require(r.displayed(at: t0.addingTimeInterval(20))).position == 3_000)
    }
}
