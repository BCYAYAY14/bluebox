@testable import Features
import Foundation
import Persistence
import Testing

@MainActor
@Suite struct ExternalPlayerTests {
    private let video = URL(string: "https://dl.example.com/f/Movie%202010.mkv?token=a+b&x=1")!
    private let sub = URL(string: "https://subs.example.com/en.srt")!

    private func query(_ link: URL?) throws -> [URLQueryItem] {
        let link = try #require(link)
        return try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
    }

    @Test func infuseEncodesTheVideoAndSubtitleLinks() throws {
        let link = ExternalPlayer.infuse.playLink(for: video, subtitle: sub, mac: false)
        #expect(link?.absoluteString.hasPrefix("infuse://x-callback-url/play?url=https%3A%2F%2Fdl.example.com") == true)
        let items = try query(link)
        #expect(items.map(\.name) == ["url", "sub"])
        #expect(items[0].value == video.absoluteString)
        #expect(items[1].value == sub.absoluteString)
        // The same link on the Mac.
        #expect(ExternalPlayer.infuse.playLink(for: video, subtitle: sub, mac: true) == link)
    }

    @Test func vlcStreamsOnIOSAndOpensTheLinkItselfOnTheMac() throws {
        let link = ExternalPlayer.vlc.playLink(for: video, subtitle: sub, mac: false)
        #expect(link?.absoluteString.hasPrefix("vlc-x-callback://x-callback-url/stream?url=https%3A%2F%2F") == true)
        let items = try query(link)
        #expect(items.map(\.name) == ["url", "sub"])
        #expect(items[0].value == video.absoluteString)
        #expect(ExternalPlayer.vlc.playLink(for: video, mac: true) == nil)
        #expect(ExternalPlayer.mpv.playLink(for: video, mac: true) == nil)
    }

    @Test func iinaWeblink() throws {
        let link = ExternalPlayer.iina.playLink(for: video, mac: true)
        #expect(link?.scheme == "iina" && link?.host == "weblink")
        #expect(try query(link).first { $0.name == "url" }?.value == video.absoluteString)
    }

    @Test func nPlayerPrefixesTheLinkAndVidHubOpensIt() throws {
        let local = try #require(URL(string: "http://127.0.0.1:52000/stream/abc.mkv"))
        #expect(ExternalPlayer.nplayer.playLink(for: local, mac: false)?.absoluteString == "nplayer-http://127.0.0.1:52000/stream/abc.mkv")
        #expect(ExternalPlayer.nplayer.playLink(for: video, mac: false)?.scheme == "nplayer-https")
        let vidhub = ExternalPlayer.vidhub.playLink(for: video, mac: false)
        #expect(vidhub?.absoluteString.hasPrefix("open-vidhub://x-callback-url/open?url=") == true)
        #expect(try query(vidhub).first?.value == video.absoluteString)
    }

    @Test func eachPlatformOffersItsOwnPlayers() {
        #if os(macOS)
        #expect(ExternalPlayer.forThisPlatform == [.iina, .vlc, .mpv, .infuse])
        #else
        #expect(ExternalPlayer.forThisPlatform == [.infuse, .vlc, .nplayer, .vidhub, .shareSheet])
        #endif
        // Every iOS player with a link has a scheme to ask about (LSApplicationQueriesSchemes).
        for player in [ExternalPlayer.infuse, .vlc, .nplayer, .vidhub] { #expect(player.queryScheme != nil) }
    }

    @Test func linksNeedingHeadersStayInBluebox() throws {
        let url = try #require(URL(string: "https://media.example.com/v.mkv"))
        #expect(ExternalPlayer.canOpen(url))
        #expect(!ExternalPlayer.canOpen(url, needsHeaders: true))
    }

    @Test func torrentStreamsAndFilesOpenEverywhere() throws {
        let stream = try #require(URL(string: "http://127.0.0.1:52000/stream/abc.mkv"))
        let file = URL(fileURLWithPath: "/tmp/movie.mkv")
        #expect(ExternalPlayer.canOpen(stream) && ExternalPlayer.canOpen(file))
        #expect(ExternalPlayer.isLoopback(stream))
    }

    @Test func alwaysOpenInInfuseBecomesOpenVideosInInfuse() throws {
        let defaults = try #require(UserDefaults(suiteName: "openIn.\(UUID().uuidString)"))
        let prefs = PreferencesStore(defaults: defaults)
        prefs.set(true, for: PlayerFeatureKey.alwaysOpenInInfuse)
        let settings = AppSettings(prefs: prefs)
        #expect(settings.openVideosIn == .infuse)
        // Choosing Bluebox sticks: the old switch doesn't bring Infuse back.
        settings.openVideosIn = nil
        #expect(AppSettings(prefs: prefs).openVideosIn == nil)
        settings.openVideosIn = .vlc
        #expect(AppSettings(prefs: prefs).openVideosIn == .vlc)
    }
}
