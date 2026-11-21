import Foundation
import Testing
@testable import VLCPlayback

/// Sync to the Audio's clips start where they say: each second of a
/// generated recording holds its own number, so a clip's first and last
/// samples tell which stretch of the recording it really holds. Both ways of
/// reading are checked: AVFoundation (files it opens) and libVLC (the rest).
@MainActor
@Suite(.serialized) struct AudioClipStartTests {
    /// Three minutes of 16 kHz mono where every sample in second n is n × 100.
    static func recording() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bluebox-numbered-\(UUID().uuidString).wav")
        var samples = Data(capacity: 180 * 32_000)
        for second in 0..<180 {
            let value = Int16(second * 100)
            let bytes = withUnsafeBytes(of: value.littleEndian) { Data($0) }
            for _ in 0..<16_000 { samples.append(bytes) }
        }
        try (VLCAudioClip.wavHeader(dataBytes: samples.count) + samples).write(to: url)
        return url
    }

    /// The second numbers of a clip's first and last samples, and its length.
    static func seconds(in clip: URL) throws -> (first: Int, last: Int, length: TimeInterval) {
        let data = try Data(contentsOf: clip)
        let samples = data.dropFirst(44)
        func value(at i: Int) -> Int {
            let lo = Int(samples[samples.startIndex + i]), hi = Int(Int8(bitPattern: samples[samples.startIndex + i + 1]))
            return hi << 8 | lo
        }
        // A sample in from each end: a codec's edge can blend two seconds.
        let first = Int((Double(value(at: 3200)) / 100).rounded()), last = Int((Double(value(at: samples.count - 3200)) / 100).rounded())
        return (first, last, Double(samples.count) / 32_000)
    }

    @Test func avFoundationReadsExactlyTheStretch() async throws {
        let source = try Self.recording()
        defer { try? FileManager.default.removeItem(at: source) }
        let clip = FileManager.default.temporaryDirectory.appending(path: "bluebox-clip-av-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: clip) }
        let from = try #require(try await VLCAudioClip.read(source, start: 55, duration: 60, to: clip))
        #expect(abs(from - 55) < 0.01)
        let s = try Self.seconds(in: clip)
        #expect(s.first == 55 && s.last == 114 && abs(s.length - 60) < 0.01)
    }

    @Test func libVLCSaysWhereItsClipStarts() async throws {
        let source = try Self.recording()
        defer { try? FileManager.default.removeItem(at: source) }
        for start in [0.0, 55, 110] {
            let clip = FileManager.default.temporaryDirectory.appending(path: "bluebox-clip-vlc-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: clip) }
            let began = Date()
            let from = try await VLCAudioClip.decode(source, headers: [:], start: start, duration: 60, to: clip)
            let s = try Self.seconds(in: clip)
            // What it says matches what it holds, and it came back promptly (it used to wait out 180 s).
            #expect(abs(from - Double(s.first)) < 0.15, "said \(from), holds second \(s.first)")
            #expect(abs(from - start) < 0.15 && abs(s.length - 60) < 0.15)
            #expect(Date().timeIntervalSince(began) < 30)
        }
    }

    @Test func aMissingFileSaysItCouldntDecode() async {
        let missing = URL(fileURLWithPath: "/nonexistent/bluebox-\(UUID().uuidString).mkv")
        let clip = FileManager.default.temporaryDirectory.appending(path: "bluebox-clip-missing.wav")
        await #expect(throws: VLCAudioClip.Failure.self) {
            try await VLCAudioClip.extract(missing, start: 0, duration: 60, to: clip)
        }
    }
}
