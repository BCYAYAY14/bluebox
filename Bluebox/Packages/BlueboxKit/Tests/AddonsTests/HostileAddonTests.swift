@testable import Addons
import Foundation
import Testing

/// Answers an add-on could send to crash or exhaust Bluebox (security review BB-04).
@Suite struct HostileAddonTests {
    private func stream(fileIdx: String = "0", videoSize: String = "1000") -> String {
        #"{"streams":[{"name":"Torrentio\n1080p","title":"Sintel.2010.1080p.mkv","infoHash":"64877b5490208c3015c0f5121287949d62622e54","fileIdx":\#(fileIdx),"behaviorHints":{"videoSize":\#(videoSize)}}]}"#
    }

    private func first(_ json: String) throws -> AddonRelease? {
        try StreamParser.parse(Data(json.utf8), addonID: "x", addonName: "X").releases.first
    }

    @Test func hugeNumbersAreIgnoredNotATrap() throws {
        for value in ["1e30", "-1e30", "1.7976931348623157e308", "9223372036854775808", "-9223372036854775809", #""1e30""#, #""nan""#, #""inf""#] {
            let byIndex = try #require(try first(stream(fileIdx: value)), "fileIdx \(value)")
            #expect(byIndex.fileIndex == nil)
            let bySize = try #require(try first(stream(videoSize: value)), "videoSize \(value)")
            #expect(bySize.videoSize == nil)
        }
    }

    @Test func boundaries() throws {
        #expect(try first(stream(fileIdx: "100000"))?.fileIndex == 100_000)
        #expect(try first(stream(fileIdx: "100001"))?.fileIndex == nil)
        #expect(try first(stream(fileIdx: "-1"))?.fileIndex == nil)
        #expect(try first(stream(fileIdx: "-9223372036854775808"))?.fileIndex == nil)
        #expect(try first(stream(videoSize: "1125899906842624"))?.videoSize == 1 << 50)
        #expect(try first(stream(videoSize: "1125899906842625"))?.videoSize == nil)
        #expect(try first(stream(videoSize: "9223372036854775807"))?.videoSize == nil)
    }

    @Test func fractionsAndMalformedValues() throws {
        #expect(try first(stream(fileIdx: "3.0"))?.fileIndex == 3)
        #expect(try first(stream(fileIdx: #""3""#))?.fileIndex == 3)
        #expect(try first(stream(fileIdx: "2.5"))?.fileIndex == nil)
        #expect(try first(stream(fileIdx: #""two""#))?.fileIndex == nil)
        #expect(try first(stream(fileIdx: "true"))?.fileIndex == nil)
        #expect(try first(stream(fileIdx: "[1]"))?.fileIndex == nil)
        #expect(try first(stream(videoSize: "1500000000.5"))?.videoSize == nil)
        #expect(try first(stream(videoSize: "null"))?.videoSize == nil)
    }

    @Test func sizesPrintedInTheTitleAreBounded() {
        #expect(ReleaseNameParser.statistics(in: "💾 999999999999999999999 TB").sizeBytes == nil)
        #expect(ReleaseNameParser.statistics(in: "Huge 99999999999999999999999999 GB pack").sizeBytes == nil)
        #expect(ReleaseNameParser.statistics(in: "💾 1024 TB").sizeBytes == 1 << 50)
        #expect(ReleaseNameParser.statistics(in: "💾 4.78 GB").sizeBytes == Int64(4.78 * 1_073_741_824))
    }

    @Test func streamCountIsCapped() throws {
        let one = #"{"name":"T","title":"Sintel.2010.1080p.mkv","infoHash":"64877b5490208c3015c0f5121287949d62622e54","fileIdx":0}"#
        let json = #"{"streams":["# + Array(repeating: one, count: StreamParser.maxStreams + 50).joined(separator: ",") + "]}"
        let envelope = try JSONDecoder().decode(StreamParser.Envelope.self, from: Data(json.utf8))
        #expect(envelope.streams.count == StreamParser.maxStreams)
    }

    @Test func oversizedAnswersAreRefused() async throws {
        #expect(AddonClient().responseLimit == 8 << 20)
        // A small limit stands in for the real 8 MiB, so the test stays cheap.
        let big = String(repeating: " ", count: 1_025)
        let client = AddonClient(transport: FakeTransport(["huge": .init(body: #"{"streams":[]}"# + big)]), responseLimit: 1_024)
        let addon = ResolvedAddon(id: "huge", name: "Huge", base: URL(string: "https://huge/cfg")!, types: ["movie"])
        await #expect(throws: AddonError.responseTooLarge) {
            try await client.streams(addon, request: StreamRequest(imdbID: "tt1727587"), timeout: 5)
        }
    }
}
