import Foundation
@testable import Sync
import Testing

/// Join the Party: looking at a party before joining it, and invite links
/// that work for friends who don't have Bluebox yet.
@MainActor
@Suite struct TogetherPeekTests {
    let hub = FakeTogetherHub()
    let clock = TestClock()

    func room(_ id: String, joinedAfter: TimeInterval = 0) -> TogetherRoom {
        let clock = clock
        return TogetherRoom(me: TogetherParticipant(id: id, name: id.capitalized, joinedAt: clock.now.addingTimeInterval(joinedAfter)),
                            transport: hub.link(), now: { clock.now })
    }

    func peek(_ id: String = "zed", attempts: Int = 3) -> TogetherPeek {
        let clock = clock
        return TogetherPeek(id: id, transport: hub.link(), askEvery: .milliseconds(30), attempts: attempts, now: { clock.now })
    }

    let dune = TogetherTitle(key: "tmdb:movie:438631", name: "Dune: Part Two",
                             release: TogetherRelease(infoHash: "beef", label: "2160p · WEB-DL"))

    func settle(_ done: @MainActor () -> Bool = { false }) async {
        for _ in 0..<200 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aPeekSeesTheLobbyWithoutJoiningIt() async {
        let sam = room("sam"), mia = room("mia", joinedAfter: 1)
        sam.host(lobby: true)
        sam.start(dune)
        await sam.join(); await mia.join()
        await settle { sam.others["mia"] != nil }
        let p = peek()
        await p.start()
        await settle { p.people.count == 2 && p.settings != nil && p.title != nil }
        #expect(p.situation == .lobby)
        #expect(p.host?.name == "Sam")
        #expect(p.everyone.map(\.id) == ["sam", "mia"])
        #expect(p.title == dune)
        // Nobody counts the peek as here, and it never says hello.
        #expect(sam.others["zed"] == nil && mia.others["zed"] == nil)
        #expect(!hub.messages.contains { if case .hello(let who) = $0 { who.id == "zed" } else { false } })
        await p.stop()
    }

    @Test func aPeekSeesWhereThePartyIs() async {
        let sam = room("sam")
        sam.host(lobby: false)
        sam.start(dune)
        sam.heartbeat(TogetherPlayhead(position: 2_530, paused: false, sentAt: clock.now), status: .ready)
        await sam.join()
        let p = peek()
        await p.start()
        await settle { p.playheads["sam"] != nil && p.settings != nil }
        clock.advance(10)
        #expect(p.situation == .playing(TogetherPlayhead(position: 2_540, paused: false, sentAt: clock.now)))
        await p.stop()
    }

    @Test func aPartyWithNothingPickedYet() async {
        let sam = room("sam")
        sam.host(lobby: false)
        await sam.join()
        let p = peek()
        await p.start()
        await settle { p.answered && p.settings != nil }
        #expect(p.situation == .picking)
        await p.stop()
    }

    @Test func aLockedPartySaysSoAndNothingElse() async {
        let sam = room("sam"), mia = room("mia", joinedAfter: 1)
        sam.host(lobby: false)
        sam.start(dune)
        await sam.join(); await mia.join()
        await settle { sam.others["mia"] != nil }
        sam.setLocked(true)
        await settle { mia.settings?.locked == true }
        let p = peek()
        await p.start()
        await settle { p.settings?.locked == true }
        await settle { p.situation != .locked }  // give any wrong answers time to arrive
        #expect(p.situation == .locked)
        // Only the host answers: enough for "Sam locked this party", nothing about what's on or who's there.
        #expect(p.host?.name == "Sam")
        #expect(p.people.count == 1 && p.title == nil)
        await p.stop()
    }

    @Test func anEmptyRoomGoesQuiet() async {
        let p = peek(attempts: 2)
        await p.start()
        #expect(p.situation == .looking)
        await settle { p.gaveUp }
        #expect(p.situation == .quiet)
        #expect(hub.messages.filter { $0 == .peek(from: "zed") }.count == 2)
        await p.stop()
    }

    @Test func anUnreachableRoom() async {
        let p = TogetherPeek(id: "zed", transport: RefusingLink())
        await p.start()
        await settle { p.connection != .connecting }
        #expect(p.situation == .unreachable("The room couldn't be reached."))
    }

    @Test func anOlderHostLeavesOutTheSettings() {
        // A presence and a title but no settings: under way, nobody knows where.
        let p = peek()
        p.receive(.presence(TogetherParticipant(id: "sam", name: "Sam", joinedAt: clock.now)))
        #expect(p.situation == .picking)
        p.receive(.title(dune, from: "sam", seq: 1))
        #expect(p.situation == .playing(nil))
    }

    @Test func thePeekMessageRoundTrips() throws {
        let m = TogetherMessage.peek(from: "zed")
        #expect(try TogetherMessage.decode(m.encoded()) == m)
        #expect(try m.jsonObject()["type"] as? String == "peek")
        #expect(m.sender == "zed")
    }

    // MARK: Web links

    let invite = TogetherInvite(code: TogetherJoinCode("K7QM2XDP")!, projectURL: URL(string: "https://abcdefghijklmnop.supabase.co")!,
                                publishableKey: "sb_publishable_example")

    @Test func invitesAreWebLinksWithTheDetailsAfterTheHash() throws {
        let web = invite.webURL
        #expect(web.absoluteString == "https://bcyayay14.github.io/bluebox/party.html#K7QM2XDP&p=abcdefghijklmnop.supabase.co&k=sb_publishable_example")
        #expect(web.query == nil)  // nothing for GitHub to see
        #expect(TogetherInvite(url: web) == invite)
        #expect(TogetherInvite(url: URL(string: "https://bcyayay14.github.io/bluebox/party#K7QM2XDP&p=abcdefghijklmnop.supabase.co&k=sb_publishable_example")!) == invite)
        // The app's own links still work, and other pages aren't invites.
        #expect(TogetherInvite(url: invite.url) == invite)
        #expect(TogetherInvite(url: URL(string: "https://bcyayay14.github.io/bluebox/add.html#K7QM2XDP&p=a.co&k=x")!) == nil)
        #expect(TogetherInvite(url: URL(string: "https://example.com/bluebox/party.html#K7QM2XDP&p=a.co&k=x")!) == nil)
        #expect(TogetherInvite(url: URL(string: "https://bcyayay14.github.io/bluebox/party.html#K7QM2XDP")!) == nil)
    }

    @Test func theWebLinkCanSayWhoInvitedYouAndToWhat() throws {
        let web = invite.webURL(from: "Sam", watching: "Tom & Jerry = 100% #1")
        let fragment = try #require(web.fragment(percentEncoded: true))
        #expect(fragment == "K7QM2XDP&p=abcdefghijklmnop.supabase.co&k=sb_publishable_example&n=Sam&t=Tom%20%26%20Jerry%20%3D%20100%25%20%231")
        #expect(TogetherInvite(url: web) == invite)
    }

    @Test func aLinkIsFoundInPastedText() {
        let pasted = "Join my Watch Party in Bluebox: Dune: Part Two \(invite.webURL.absoluteString)"
        #expect(TogetherInvite(text: pasted) == invite)
        #expect(TogetherInvite(text: "<\(invite.url.absoluteString)>") == invite)
        #expect(TogetherInvite(text: "K7QM-2XDP") == nil)
    }
}

/// A room that can't be reached.
private final class RefusingLink: TogetherTransport, @unchecked Sendable {
    func start(onMessage: @escaping @Sendable (TogetherMessage) -> Void, onConnection: @escaping @Sendable (TogetherConnection) -> Void) async {
        onConnection(.failed("The room couldn't be reached."))
    }
    func send(_ message: TogetherMessage) async -> Bool { false }
    func stop() async {}
}
