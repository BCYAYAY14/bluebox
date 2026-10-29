import Foundation
@testable import Torrent
import Testing

/// Input from peers and torrent files is untrusted: it must be rejected, never crash.
@Suite struct TorrentRobustnessTests {
    @Test(arguments: ["9223372036854775807:x", "9223372036854775800:abc", "d1:a9223372036854775807:xe"])
    func hugeStringLengthIsRejected(_ s: String) {
        #expect(throws: BencodeError.self) { try Bencode.decode(Data(s.utf8)) }
        #expect(throws: BencodeError.self) { try Bencode.decodePrefix(Data(s.utf8)) }
    }

    @Test func fileLengthsThatOverflowAreRejected() {
        let info = BValue.dict([
            "name": .str("x"), "piece length": .int(16384), "pieces": .bytes(Data(count: 20)),
            "files": .list([
                .dict(["length": .int(Int64.max), "path": .list([.str("a")])]),
                .dict(["length": .int(Int64.max), "path": .list([.str("b")])]),
            ]),
        ])
        #expect(throws: TorrentError.self) { try TorrentInfo(raw: Bencode.encode(info)) }
        let single = BValue.dict(["name": .str("x"), "piece length": .int(16384), "pieces": .bytes(Data(count: 20)),
                                  "length": .int(Int64.max)])
        #expect(throws: TorrentError.self) { try TorrentInfo(raw: Bencode.encode(single)) }
    }

    @Test func metadataRequestsOutOfRangeGetNothing() {
        let raw = Data(repeating: 7, count: 16384 + 10)
        #expect(PeerMessage.metadataChunk(raw, piece: 0)?.count == 16384)
        #expect(PeerMessage.metadataChunk(raw, piece: 1)?.count == 10)
        #expect(PeerMessage.metadataChunk(raw, piece: 2) == nil)
        #expect(PeerMessage.metadataChunk(raw, piece: -1) == nil)
        #expect(PeerMessage.metadataChunk(raw, piece: .max) == nil)
        #expect(PeerMessage.metadataChunk(raw, piece: .min) == nil)
    }

    @Test func aRejectedAddDoesNotListTheTorrentTwiceLater() async throws {
        let client = TorrentClient(directory: tempDir(), fetch: { _ in Data() })
        let hash = InfoHash(bytes: Data(repeating: 1, count: 20))!
        await #expect(throws: TorrentError.noTrackers) { try await client.add(TorrentDescriptor(infoHash: hash)) }
        try await client.add(TorrentDescriptor(infoHash: hash, trackers: [URL(string: "http://127.0.0.1:9/announce")!]))
        #expect(await client.all().count == 1)
        await client.stopAll()
    }
}
