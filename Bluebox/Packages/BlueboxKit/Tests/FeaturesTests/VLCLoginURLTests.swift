import Domain
import Foundation
import Testing
@testable import VLCPlayback

/// VLC can't send an `Authorization` header, so a Basic login (WebDAV) goes
/// into the URL it opens, and nowhere else.
@Suite @MainActor struct VLCLoginURLTests {
    let variant = MediaVariant(id: "v", sourceID: SourceID("dav"), mediaKey: nil, displayName: "Film", container: "mkv",
                               resolution: nil, sizeBytes: nil, location: .remote, isDownloadable: true)

    func resource(_ url: String, headers: [String: String]) -> PlaybackResource {
        PlaybackResource(variant: variant, url: URL(string: url)!, httpHeaders: headers)
    }

    @Test func basicLoginMovesIntoTheURL() throws {
        let header = "Basic " + Data("brian:fake pass@word".utf8).base64EncodedString()
        let r = resource("https://nas.example.com/dav/Film%20One.mkv", headers: ["Authorization": header])
        let url = VLCEngine.mediaURL(for: r)
        #expect(url.user(percentEncoded: false) == "brian")
        #expect(url.password(percentEncoded: false) == "fake pass@word")
        #expect(url.host() == "nas.example.com" && url.path(percentEncoded: false) == "/dav/Film One.mkv")
        // It isn't also passed as an option VLC would warn about.
        #expect(!VLCEngine.mediaOptions(for: r, startAt: nil).contains { $0.lowercased().contains("authorization") })
        // What's logged has no login in it.
        #expect(!Redactor.redact(url).contains("fake"))
    }

    @Test func otherURLsAreLeftAlone() {
        let plain = resource("https://cdn.example.com/a.mp4", headers: ["User-Agent": "Bluebox"])
        #expect(VLCEngine.mediaURL(for: plain) == plain.url)
        let bearer = resource("https://cdn.example.com/a.mp4", headers: ["Authorization": "Bearer fake"])
        #expect(VLCEngine.mediaURL(for: bearer) == bearer.url)
        let file = PlaybackResource(variant: variant, url: URL(fileURLWithPath: "/tmp/a.mkv"),
                                    httpHeaders: ["Authorization": "Basic " + Data("a:b".utf8).base64EncodedString()])
        #expect(VLCEngine.mediaURL(for: file) == file.url)
    }
}
