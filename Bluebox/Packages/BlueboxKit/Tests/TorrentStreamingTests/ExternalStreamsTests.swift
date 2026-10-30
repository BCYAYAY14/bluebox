import Foundation
import Testing
@testable import TorrentStreaming

@Suite struct ExternalStreamsTests {
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
}
