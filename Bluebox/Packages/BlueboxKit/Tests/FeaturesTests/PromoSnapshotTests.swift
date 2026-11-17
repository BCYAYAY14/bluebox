#if os(macOS)
import AppKit
import Domain
@testable import Features
import Foundation
@testable import Metadata
import Persistence
@testable import Playback
@testable import Sync
import SwiftUI
import Testing
import TorrentStreaming

/// Renders the Mac app's main pages in an offscreen window, with the showcase
/// catalog (Blender Studio's Creative Commons films and their TMDB artwork),
/// and saves a PNG of each for the README and docs-site graphics. Runs only
/// when /tmp/bluebox-promo-shots/mac exists; needs the network for artwork.
/// Run it on its own (`swift test --filter PromoSnapshotTests`): the showcase
/// switch is process-wide, so tests running alongside would see its catalog.
@MainActor
@Suite(.serialized) struct PromoSnapshotTests {
    nonisolated static let folder = "/tmp/bluebox-promo-shots/mac"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: PromoSnapshotTests.folder)))
    func snapshotMainPages() async throws {
        SampleMetadataProvider.showcase = true
        defer { SampleMetadataProvider.showcase = false; unsetenv("BLUEBOX_DEBUG_ARGS") }
        UserDefaults.standard.set(true, forKey: "bluebox.firstRunCardDismissed")
        PreferencesStore().set(false, for: PreferenceKey.launchIntro)  // no ident over the window

        let pages: [(name: String, args: String)] = [
            ("home", "-ui-testing -open-tab home"),
            ("title-sintel", "-ui-testing -open-tab home -open-title tmdb:movie:45745"),
            ("downloads", "-ui-testing -open-tab downloads"),
            ("title-cosmos", "-ui-testing -open-tab home -open-title tmdb:movie:358332"),
            ("movies", "-ui-testing -open-tab movies"),
            ("library", "-ui-testing -open-tab library"),
            ("profiles", "-ui-testing -profile-picker"),
        ]
        for page in pages {
            setenv("BLUEBOX_DEBUG_ARGS", page.args, 1)
            let app = AppModel.demo(seed: false)
            await app.bootstrap()
            await app.seedShowcaseForReview(family: page.name == "profiles")
            try await snapshot(RootView().environment(app), size: CGSize(width: 1440, height: 900), name: page.name, wait: 6)
        }
    }

    /// Watch Party's invitation, Settings with the family's profiles, and stats for nerds.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: PromoSnapshotTests.folder)))
    func snapshotFeatures() async throws {
        defer { SampleMetadataProvider.showcase = false }
        let app = AppModel.demo(seed: false)
        await app.bootstrap()
        await app.seedShowcaseForReview(family: true)

        // Watch Party: Sam's invitation to Sintel, in the lobby and already playing.
        let invite = TogetherInvite(code: TogetherJoinCode("K7QM2XDP")!, projectURL: URL(string: "https://abcd1234.supabase.co")!,
                                    publishableKey: "sb_publishable_example")
        let sintel = TogetherTitle(key: "tmdb:movie:45745", name: "Sintel",
                                   release: TogetherRelease(infoHash: "beef", duration: 888, label: "1080p · WEB-DL"))
        let now = Date()
        let sam = TogetherParticipant(id: "sam", name: "Sam", symbol: "star.fill", color: 13, joinedAt: now, status: .ready, match: .exact)
        let mia = TogetherParticipant(id: "mia", name: "Mia", symbol: "heart.fill", color: 10, joinedAt: now.addingTimeInterval(5),
                                      status: .ready, match: .exact)
        let jo = TogetherParticipant(id: "jo", name: "Jo", symbol: "flame.fill", color: 8, joinedAt: now.addingTimeInterval(9), status: .loading)
        for (name, lobby) in [("party-lobby", true), ("party-playing", false)] {
            let peek = TogetherPeek(id: "me", transport: QuietLink())
            var messages: [TogetherMessage] = [.presence(sam), .presence(mia), .presence(jo), .title(sintel, from: "sam", seq: 1),
                                               .settings(TogetherPartySettings(host: "sam", lobby: lobby, seq: 2, from: "sam"))]
            if !lobby { messages.append(.state(from: "sam", TogetherPlayhead(position: 312, paused: false, sentAt: now))) }
            for m in messages { peek.receive(m) }
            let invitation = PartyInvitation(invite: invite, app: app)
            invitation.peek = peek
            invitation.copy = .ready("1080p · WEB-DL")
            invitation.year = 2010
            invitation.lookedUp = peek.title?.key  // keep the copy drawn here; the backdrop is set below instead
            invitation.backdrop = SampleMetadataProvider.titles.first { $0.key == .movie(tmdbID: 45745) }?.backdrop.flatMap { URL(string: $0.path) }
            try await snapshot(PartyJoinScreen(request: PartyJoinRequest(invite: invite), invitation: invitation).environment(app),
                               size: CGSize(width: 1440, height: 900), name: name, wait: 4)
        }

        // Settings pages, as the Settings window draws them.
        for page in [SettingsPage.profiles, .appearance, .languages, .sources, .torrents] {
            UserDefaults.standard.set(page.rawValue, forKey: "bluebox.settingsPage")
            try await snapshot(SettingsView().environment(app), size: CGSize(width: 1000, height: 700), name: "settings-\(page.rawValue)", wait: 2)
        }

        // Stats for nerds over a 4K HDR torrent of Sintel, with a minute for the graph to fill.
        UserDefaults.standard.set("Video,Buffer,Torrent", forKey: "playerStatsOpenSections")
        defer { UserDefaults.standard.removeObject(forKey: "playerStatsOpenSections") }
        let engine = StatsTestEngine.vlc
        let resource = PlaybackResource(
            variant: MediaVariant(id: "r", sourceID: app.addons.id, mediaKey: nil, displayName: "Sintel.2010.2160p.mkv",
                                  container: "mkv", location: .remote),
            url: URL(string: "http://127.0.0.1:8090/stream/abc")!)
        let player = PlayerSession(engine: engine, progress: try LibraryStore.make(inMemory: true))
        await player.start(NowPlayingItem(key: .movie(tmdbID: 45745), title: "Sintel", subtitle: nil), resource: resource)
        await player.seek(to: 300)
        engine.snapshot.status = .playing
        engine.snapshot.position = 312
        engine.snapshot.bufferedUntil = 348
        let swarm = SwarmStats(connectedPeers: 42, seeds: 11, knownPeers: 120, downloadRate: 3_100_000, downloadedBytes: 1_700_000_000,
                               fileProgress: 0.37)
        let card = PlayerStatsCard(session: player, swarm: swarm, fileRanges: TorrentFileRanges(length: 4_600_000_000, ranges: [0..<1_980_000_000]),
                                   maxHeight: 560, onCopied: {}, onClose: {})
            .padding(16)
            .frame(width: 334, height: 592, alignment: .topLeading)
            .environment(app)
        try await snapshot(card, size: CGSize(width: 334, height: 592), name: "stats", wait: 62)
        await player.end()
    }

    private func snapshot(_ view: some View, size: CGSize, name: String, wait seconds: Double) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view)
        // The window's size, not the view's ideal one (RootView's is only its top bar).
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setContentSize(size)
        window.orderBack(nil)
        try await Task.sleep(for: .seconds(seconds))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(Self.folder)/\(name).png"))
        window.orderOut(nil)
    }
}
/// A party room that never answers: the invitation only shows what it was sent.
private final class QuietLink: TogetherTransport, @unchecked Sendable {
    func start(onMessage: @escaping @Sendable (TogetherMessage) -> Void, onConnection: @escaping @Sendable (TogetherConnection) -> Void) async {}
    func send(_ message: TogetherMessage) async -> Bool { false }
    func stop() async {}
}
#endif
