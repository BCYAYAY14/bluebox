import Foundation
@testable import Playback
import Testing

@Suite struct PlaybackEngineRoutingTests {
    let av: Set<String> = ["mp4", "m4v", "mov", "m3u8", "ts"]
    let vlc: Set<String> = ["mkv", "avi", "webm", "mp4", "ts"]

    func route(_ container: String?, _ url: String? = nil) -> PlaybackEngineKind {
        PlaybackEngineRouting.choose(container: container, url: url.flatMap(URL.init(string:)), av: av, vlc: vlc)
    }

    @Test func prefersAVFoundationWhenItCanAttempt() {
        #expect(route("mp4") == .avFoundation)
        #expect(route("MOV") == .avFoundation)
        #expect(route("ts") == .avFoundation)
    }

    @Test func sendsOtherContainersToVLC() {
        #expect(route("mkv") == .vlc)
        #expect(route(".webm") == .vlc)
        #expect(route("avi", "http://127.0.0.1:8080/stream/abc") == .vlc)
    }

    @Test func customStreamSchemeStaysOnAVFoundation() {
        #expect(route("mkv", "bluebox-torrent://abc/0.mkv") == .avFoundation)
    }

    @Test func fallsBackToURLExtensionThenAVFoundation() {
        #expect(route(nil, "https://example.com/movie.mkv") == .vlc)
        #expect(route(nil, "http://127.0.0.1:8080/stream/token") == .avFoundation)
        #expect(route("xyz") == .avFoundation)  // neither knows it: AVFoundation reports the error
    }

    @Test func canAttemptIfEitherEngineCan() {
        #expect(PlaybackEngineRouting.canAttempt(container: "mkv", av: av, vlc: vlc))
        #expect(PlaybackEngineRouting.canAttempt(container: "m3u8", av: av, vlc: vlc))
        #expect(PlaybackEngineRouting.canAttempt(container: nil, av: av, vlc: vlc))
        #expect(!PlaybackEngineRouting.canAttempt(container: "xyz", av: av, vlc: vlc))
    }
}
