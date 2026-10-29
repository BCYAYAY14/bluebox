import CryptoKit
import Domain
import Foundation
@testable import MediaSources
import Torrent
import Testing

@Suite struct TorrentSourceTests {
    /// A two-video torrent whose file list is already known (as with a .torrent file).
    func descriptor() throws -> TorrentDescriptor {
        let sizes = [20_000, 10_000, 500]
        let names = ["Night.of.the.Living.Dead.1968.1080p.mp4", "Extras.mkv", "notes.txt"]
        let total = sizes.reduce(0, +)
        let pieces = Data(count: 20 * ((total + 16383) / 16384))
        let info = Bencode.encode(.dict([
            "name": .str("Night of the Living Dead (1968)"), "piece length": .int(16384), "pieces": .bytes(pieces),
            "files": .list(zip(names, sizes).map { .dict(["length": .int(Int64($1)), "path": .list([.str($0)])]) }),
        ]))
        var root = Data("d4:info".utf8); root.append(info); root.append(Data("e".utf8))
        var d = try TorrentDescriptor(torrentFile: root)
        d.webSeeds = [URL(string: "https://seed.invalid/")!]
        return d
    }

    @Test func matchesVideoFilesAndResolvesToStreamURLs() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ts-\(UUID().uuidString)")
        let client = TorrentClient(directory: dir, fetch: { _ in throw URLError(.notConnectedToInternet) })
        let source = TorrentSource(client: client, items: [])
        let movie = MediaKey.movie(tmdbID: 10331)
        let item = try await source.add(try descriptor(), matcher: { parsed in
            parsed.title.lowercased() == "night of the living dead" && parsed.year == 1968 ? movie : nil
        })
        #expect(item.matches == [0: movie])
        #expect(try await source.catalog().map(\.container) == ["mp4", "mkv"])
        let variants = try await source.variants(for: movie)
        #expect(variants.count == 1)
        #expect(variants[0].resolution == "1080p")
        let resource = try await source.resolve(variants[0])
        #expect(resource.url.scheme == TorrentClient.scheme)
        #expect(resource.url.lastPathComponent == "0.mp4")

        await source.remove(item.infoHash)
        #expect(try await source.variants(for: movie).isEmpty)
        await client.stopAll()
    }
}
