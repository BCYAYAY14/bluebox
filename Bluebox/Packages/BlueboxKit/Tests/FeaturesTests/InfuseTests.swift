@testable import Features
import Foundation
import Testing

@MainActor
@Suite struct InfuseTests {
    @Test func encodesTheVideoAndSubtitleLinks() throws {
        let video = try #require(URL(string: "https://dl.example.com/f/Movie 2010.mkv?token=a+b&x=1"))
        let sub = try #require(URL(string: "https://subs.example.com/en.srt"))
        let link = try #require(Infuse.playLink(for: video, subtitle: sub))
        #expect(link.absoluteString.hasPrefix("infuse://x-callback-url/play?url=https%3A%2F%2Fdl.example.com"))
        let items = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["url", "sub"])
        #expect(items[0].value == video.absoluteString)
        #expect(items[1].value == sub.absoluteString)
    }

    @Test func linksNeedingHeadersStayInBluebox() throws {
        let url = try #require(URL(string: "https://media.example.com/v.mkv"))
        #expect(Infuse.canOpen(url))
        #expect(!Infuse.canOpen(url, needsHeaders: true))
    }

    @Test func torrentStreamsAndFilesOpenEverywhere() throws {
        let stream = try #require(URL(string: "http://127.0.0.1:52000/stream/abc.mkv"))
        let file = URL(fileURLWithPath: "/tmp/movie.mkv")
        #expect(Infuse.canOpen(stream) && Infuse.canOpen(file))
        #expect(Infuse.isLoopback(stream))
    }
}
