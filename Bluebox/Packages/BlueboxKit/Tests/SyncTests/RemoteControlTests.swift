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
        ]
        for m in messages {
            #expect(try RemoteMessage.decode(jsonObject: m.jsonObject()) == m)
        }
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

    @Test func positionStaysWithinTheItem() throws {
        var r = RemoteReconciler()
        r.receive(state(position: 2_995), at: t0)
        #expect(try #require(r.displayed(at: t0.addingTimeInterval(20))).position == 3_000)
    }
}
