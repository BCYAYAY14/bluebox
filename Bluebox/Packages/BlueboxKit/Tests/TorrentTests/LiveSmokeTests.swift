import Foundation
@testable import Torrent
import Testing

/// Opt-in check against the real network: BLUEBOX_LIVE_TORRENT=1 swift test --filter LiveSmoke
/// Uses Blender's Creative Commons film "Sintel" from webtorrent.io's public test torrents.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_LIVE_TORRENT"] == "1"))
struct LiveSmokeTests {
    @Test(.timeLimit(.minutes(3))) func fetchesMetadataAndStreamsTheFirstBytes() async throws {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://webtorrent.io/torrents/sintel.torrent")!)
        let d = try TorrentDescriptor(torrentFile: data)
        let dir = FileManager.default.temporaryDirectory.appending(path: "bluebox-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = TorrentClient(directory: dir)
        let hash = try await client.add(d)
        let info = try await client.info(for: hash)
        let video = try #require(info.files.firstIndex { $0.name.hasSuffix(".mp4") })
        let url = TorrentClient.streamURL(hash, file: video, ext: "mp4")
        let head = try await client.read(url, offset: 0, length: 64 * 1024)
        #expect(head.count == 64 * 1024)
        #expect(String(decoding: head[4..<8], as: UTF8.self) == "ftyp")
        print("Live:", await client.status(hash) as Any)
        await client.stopAll()
    }
}
