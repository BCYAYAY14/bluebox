import Foundation
import Testing
@testable import VLCPlayback

/// Opt-in: decodes stretches of real media files (any `film.*` in
/// `BLUEBOX_AUDIT_DIR`) the way Sync to the Audio does, and checks each
/// clip comes back quickly, holds the length asked for and says where it
/// really starts. Prints one "CLIP" line per stretch.
///
///     BLUEBOX_AUDIT_DIR=/path swift test --filter AudioClipMediaTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_AUDIT_DIR"] != nil), .serialized)
struct AudioClipMediaTests {
    static var folder: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["BLUEBOX_AUDIT_DIR"] ?? "/") }

    @Test(arguments: ["film.wav", "film.m4a", "film.mkv"])
    func decodesEveryStretchPromptly(_ name: String) async throws {
        let media = Self.folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: media.path) else { return }
        for start in [55.0, 87.0, 174.0, 261.0, 283.0] {
            let wav = FileManager.default.temporaryDirectory.appending(path: "bluebox-clip-\(name)-\(Int(start)).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            let t0 = Date()
            let from = try await VLCAudioClip.extract(media, start: start, duration: 60, to: wav)
            let took = Date().timeIntervalSince(t0)
            let bytes = (try? wav.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let seconds = Double(bytes - 44) / 32_000
            print(String(format: "CLIP %@ at %.0f: says %.2f, %.1f s of sound, took %.2f s", name, start, from, seconds, took))
            #expect(took < 20, "\(name) at \(start) took \(took) s")
            #expect(abs(from - start) < 0.3, "\(name) at \(start) says it starts at \(from)")
            #expect(abs(seconds - 60) < 0.5)
        }
    }
}

extension AudioClipMediaTests {
    /// The main thread busy while the clip decodes (the transcriber, the
    /// player's views): the first look at VLC comes late.
    @Test(arguments: ["film.wav", "film.m4a", "film.mkv"])
    func busyMainThreadStillGivesTheRightStart(_ name: String) async throws {
        let media = Self.folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: media.path) else { return }
        for start in [55.0, 174.0, 261.0] {
            let wav = FileManager.default.temporaryDirectory.appending(path: "bluebox-busy-\(name)-\(Int(start)).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            let busy = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(5))
                let until = Date().addingTimeInterval(0.4)
                while Date() < until {}
            }
            let t0 = Date()
            let from = try await VLCAudioClip.extract(media, start: start, duration: 60, to: wav)
            _ = await busy.value
            let bytes = (try? wav.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print(String(format: "CLIP busy %@ at %.0f: says %.2f, %.1f s of sound, took %.2f s", name, start, from,
                         Double(bytes - 44) / 32_000, Date().timeIntervalSince(t0)))
            #expect(abs(from - start) < 0.3, "\(name) at \(start) says it starts at \(from)")
        }
    }
}
