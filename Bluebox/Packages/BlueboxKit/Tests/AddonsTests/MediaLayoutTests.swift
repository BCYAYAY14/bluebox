@testable import Addons
import Domain
import Foundation
import Testing
@testable import TorrentStreaming

@Suite struct MediaLayoutTests {
    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + payload.count)
        return withUnsafeBytes(of: size.bigEndian, Array.init) + Array(type.utf8) + payload
    }

    private func mvhd(timescale: UInt32, duration: UInt32) -> [UInt8] {
        var payload: [UInt8] = [0, 0, 0, 0]          // version 0, flags
        payload += [UInt8](repeating: 0, count: 8)   // creation, modification
        payload += withUnsafeBytes(of: timescale.bigEndian, Array.init)
        payload += withUnsafeBytes(of: duration.bigEndian, Array.init)
        payload += [UInt8](repeating: 0, count: 80)
        return box("mvhd", payload)
    }

    @Test func faststartMP4NeedsNothingFromTheEnd() {
        let moov = box("moov", mvhd(timescale: 1000, duration: 888_000))
        let head = box("ftyp", Array("isom".utf8) + [0, 0, 2, 0]) + moov + box("mdat", [1, 2, 3])
        let layout = MediaLayout.sniff(head: Data(head), fileLength: 100_000_000, fileExtension: "mp4")
        #expect(layout.container == .mp4)
        #expect(layout.tail == nil)
        #expect(layout.duration == 888)
        #expect(layout.headIndexEnd == Int64(16 + moov.count))
        #expect(layout.bitrate(fileLength: 100_000_000)! > 112_000)
    }

    @Test func mp4WithMoovAtTheEndNeedsExactlyTheMoov() {
        let ftyp = box("ftyp", Array("isom".utf8) + [0, 0, 2, 0])
        let mdatSize: UInt32 = 50_000_000
        let head = ftyp + withUnsafeBytes(of: mdatSize.bigEndian, Array.init) + Array("mdat".utf8) + [UInt8](repeating: 7, count: 1000)
        let layout = MediaLayout.sniff(head: Data(head), fileLength: 50_400_000, fileExtension: "mp4")
        let expected: Range<Int64> = (Int64(ftyp.count) + 50_000_000)..<50_400_000
        #expect(layout.tail == expected)
        #expect(layout.duration == nil)

        let moov = Data(box("moov", mvhd(timescale: 600, duration: 600 * 734)))
        #expect(MediaLayout.movieDuration(searching: moov) == 734)
    }

    @Test func matroskaDurationAndTail() {
        // EBML magic, then Segment Info: TimecodeScale 1 ms, Duration 734000.0 (float64).
        var head: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x80, 0x18, 0x53, 0x80, 0x67]
        head += [0x2A, 0xD7, 0xB1, 0x83, 0x0F, 0x42, 0x40]
        head += [0x44, 0x89, 0x88] + withUnsafeBytes(of: Double(734_000).bitPattern.bigEndian, Array.init)
        let layout = MediaLayout.sniff(head: Data(head), fileLength: 900_000_000, fileExtension: "mkv")
        #expect(layout.container == .matroska)
        #expect(layout.duration == 734)
        let expected: Range<Int64> = (900_000_000 - 1024 * 1024)..<900_000_000
        #expect(layout.tail == expected)
    }

    @Test func prebufferFollowsSpeedAndBitrate() {
        let mb: Int64 = 1024 * 1024
        // Download faster than the film: the minimum.
        #expect(PrebufferPlan.targetBytes(bitrate: 200_000, downloadRate: 2_000_000, fileLength: 2000 * mb,
                                          minimum: 3 * mb, maximum: 16 * mb, stallFreeSeconds: 60) == 3 * mb)
        // Slower: enough to play a minute before catching up.
        #expect(PrebufferPlan.targetBytes(bitrate: 400_000, downloadRate: 300_000, fileLength: 2000 * mb,
                                          minimum: 3 * mb, maximum: 16 * mb, stallFreeSeconds: 60) == 6_000_000)
        // Much slower: capped.
        #expect(PrebufferPlan.targetBytes(bitrate: 1_000_000, downloadRate: 50_000, fileLength: 2000 * mb,
                                          minimum: 3 * mb, maximum: 16 * mb, stallFreeSeconds: 60) == 16 * mb)
        // Small file: never more than the file.
        #expect(PrebufferPlan.targetBytes(bitrate: nil, downloadRate: 0, fileLength: 2 * mb,
                                          minimum: 3 * mb, maximum: 16 * mb, stallFreeSeconds: 60) == 2 * mb)
    }
}

@Suite struct SavedReleaseTests {
    @Test func rebuildsATorrentVariantAfterRelaunch() throws {
        let hash = String(repeating: "ab", count: 20)
        let variant = MediaVariant(id: "\(hash):3", sourceID: SourceID("addons"), mediaKey: .movie(tmdbID: 1),
                                   displayName: "Film.2010.1080p.mkv", container: "mkv", location: .remote)
        let release = try #require(StremioSource.release(fromVariant: variant))
        #expect(release.infoHash == hash)
        #expect(release.fileIndex == 3)
        #expect(release.magnet?.hasPrefix("magnet:?xt=urn:btih:\(hash)&dn=Film.2010.1080p.mkv") == true)
    }

    @Test func rebuildsADebridVariant() throws {
        let variant = MediaVariant(id: "https://example.com/rd/file.mkv", sourceID: SourceID("addons"),
                                   mediaKey: .movie(tmdbID: 1), displayName: "file.mkv", location: .remote)
        let release = try #require(StremioSource.release(fromVariant: variant))
        #expect(release.isDebrid)
    }
}
