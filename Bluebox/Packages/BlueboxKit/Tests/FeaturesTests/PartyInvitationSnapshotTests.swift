#if os(macOS)
import AppKit
@testable import Features
import Foundation
import SwiftUI
@testable import Sync
import Testing

/// Draws Join the Party's invitation in each state in an offscreen Mac
/// window and saves a PNG of each, for design review without a server or a
/// second device. Runs only when /tmp/bluebox-party-shots exists.
@MainActor
@Suite struct PartyInvitationSnapshotTests {
    nonisolated static let folder = "/tmp/bluebox-party-shots"

    let invite = TogetherInvite(code: TogetherJoinCode("K7QM2XDP")!, projectURL: URL(string: "https://abcd1234.supabase.co")!,
                                publishableKey: "sb_publishable_example")
    let dune = TogetherTitle(key: "tmdb:movie:693134", name: "Dune: Part Two",
                             release: TogetherRelease(infoHash: "beef", duration: 9_960, label: "2160p · WEB-DL"))

    @Test(.enabled(if: FileManager.default.fileExists(atPath: PartyInvitationSnapshotTests.folder)))
    func snapshotEveryState() async throws {
        let app = AppModel.demo()
        await app.bootstrap()
        let now = Date()
        let sam = TogetherParticipant(id: "sam", name: "Sam", symbol: "star.fill", color: 13, joinedAt: now, status: .ready, match: .exact)
        let mia = TogetherParticipant(id: "mia", name: "Mia", symbol: "leaf.fill", color: 10, joinedAt: now.addingTimeInterval(5), status: .ready,
                                      match: .exact)
        let jo = TogetherParticipant(id: "jo", name: "Jo", symbol: "flame.fill", color: 8, joinedAt: now.addingTimeInterval(9), status: .loading)

        func invitation(_ messages: [TogetherMessage], copy: PartyInvitation.Copy? = nil, gaveUp: Bool = false) -> PartyInvitation {
            let peek = TogetherPeek(id: "me", transport: SilentLink())
            for m in messages { peek.receive(m) }
            peek.gaveUp = gaveUp
            let i = PartyInvitation(invite: invite, app: app)
            i.peek = peek
            i.copy = copy
            i.year = 2024
            i.lookedUp = peek.title?.key  // keep the copy drawn here rather than the demo library's

            return i
        }
        let people: [TogetherMessage] = [.presence(sam), .presence(mia), .presence(jo)]
        let states: [(String, PartyJoinRequest, PartyInvitation?)] = [
            ("1-lobby", PartyJoinRequest(invite: invite),
             invitation(people + [.title(dune, from: "sam", seq: 1), .settings(TogetherPartySettings(host: "sam", lobby: true, seq: 1, from: "sam"))],
                        copy: .ready("2160p · WEB-DL"))),
            ("2-playing", PartyJoinRequest(invite: invite),
             invitation(people + [.title(dune, from: "sam", seq: 1), .settings(TogetherPartySettings(host: "sam", lobby: false, seq: 2, from: "sam")),
                                  .state(from: "sam", TogetherPlayhead(position: 2_530, paused: false, sentAt: now))],
                        copy: .sameLength("1080p · BluRay"))),
            ("3-missing-copy", PartyJoinRequest(invite: invite),
             invitation(people + [.title(dune, from: "sam", seq: 1), .settings(TogetherPartySettings(host: "sam", lobby: false, seq: 2, from: "sam"))],
                        copy: .missing)),
            ("4-getting-ready", PartyJoinRequest(invite: invite), invitation([])),
            ("5-quiet", PartyJoinRequest(invite: invite), invitation([], gaveUp: true)),
            ("6-locked", PartyJoinRequest(invite: invite),
             invitation([.presence(sam),
                         .settings(TogetherPartySettings(host: "sam", lobby: false, locked: true, admitted: ["sam", "mia"], seq: 3, from: "sam"))])),
            ("7-code", PartyJoinRequest(), nil),
        ]
        for (name, request, inv) in states {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: PartyJoinScreen(request: request, invitation: inv).environment(app)
                .frame(width: 1100, height: 680))
            window.contentView = host
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(900))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(Self.folder)/\(name).png"))
            window.orderOut(nil)
        }
    }
}

/// A room that never answers.
private final class SilentLink: TogetherTransport, @unchecked Sendable {
    func start(onMessage: @escaping @Sendable (TogetherMessage) -> Void, onConnection: @escaping @Sendable (TogetherConnection) -> Void) async {}
    func send(_ message: TogetherMessage) async -> Bool { false }
    func stop() async {}
}
#endif
