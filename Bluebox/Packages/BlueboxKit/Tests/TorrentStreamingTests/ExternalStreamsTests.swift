import Foundation
import Testing
@testable import TorrentStreaming

@Suite(.serialized) struct ExternalStreamsTests {
    @Test func servesAFileWithRangesAndStops() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Movie.mkv")
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        try bytes.write(to: file)

        let url = try await ExternalStreams.serve(fileAt: file)
        #expect(url.host == "127.0.0.1" && url.pathExtension == "mkv")
        #expect(ExternalStreams.lastUse(of: url).served)

        var request = URLRequest(url: url)
        request.setValue("bytes=1000-1999", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(data == bytes[1000..<2000])
        #expect(ExternalStreams.lastUse(of: url).at != nil)

        ExternalStreams.stopServing(url)
        #expect(!ExternalStreams.lastUse(of: url).served)
    }

    /// iOS can take a suspended app's listening socket away while the listener
    /// still reads "ready": the next stream must find that out and listen
    /// again on the same port, so a URL handed out before still works.
    @Test func listensAgainWhenTheSocketWasTakenAway() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Episode.mkv")
        let bytes = Data((0..<50_000).map { UInt8($0 % 241) })
        try bytes.write(to: file)

        let url = try await ExternalStreams.serve(fileAt: file)
        defer { ExternalStreams.stopServing(url) }
        let port = try #require(url.port.map(UInt16.init))
        #expect(await StreamServer.answers(port: port))

        StreamServer.shared.dropListeningSocketSilently()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await StreamServer.answers(port: port) == false)

        #expect(try await StreamServer.shared.start(preferredPort: 0) == port)
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == bytes)
    }
}
