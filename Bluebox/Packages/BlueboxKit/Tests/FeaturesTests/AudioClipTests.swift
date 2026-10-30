import Foundation
import Testing
import VLCPlayback

/// Opt-in: decodes a minute of a real video's sound with libVLC, as Sync to
/// the Audio does, and checks it's a 16 kHz mono WAV made faster than real time.
///
///     BLUEBOX_AUDIO_VIDEO=/path/to/video.mkv swift test --filter VLCAudioClipTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_AUDIO_VIDEO"] != nil))
struct VLCAudioClipTests {
    @Test func decodesAMinuteQuickly() async throws {
        let video = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BLUEBOX_AUDIO_VIDEO"] ?? "/")
        let out = FileManager.default.temporaryDirectory.appending(path: "bluebox-clip-test.wav")
        let began = ContinuousClock.now
        try await VLCAudioClip.extract(video, start: 300, duration: 60, to: out)
        let took = ContinuousClock.now - began
        let data = try Data(contentsOf: out)
        print("AUDIO clip: \(data.count) bytes in \(took)")
        #expect(data.prefix(4) == Data("RIFF".utf8))
        // 60 s × 16 000 samples × 2 bytes, give or take the edges.
        #expect(data.count == 44 + 60 * 32_000)
        #expect(took < .seconds(30))
    }
}
