import Foundation
import Subtitles
import Testing
import VLCPlayback
@testable import Features

/// Opt-in: Sync to the Audio from end to end on a real recording, the way the
/// player runs it: libVLC decodes two stretches, the system transcriber
/// listens, and the words are matched to a subtitle file timed off by a known
/// amount. The folder holds `film.m4a` (or any file VLC plays) and `film.srt`,
/// and `BLUEBOX_AUDIO_SYNC_SHIFT` says how late the subtitles are, in seconds.
///
///     BLUEBOX_AUDIO_SYNC_DIR=/path/to/folder BLUEBOX_AUDIO_SYNC_SHIFT=2.5 swift test --filter AudioSyncEndToEndTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_AUDIO_SYNC_DIR"] != nil))
struct AudioSyncEndToEndTests {
    @Test func findsTheDelayFromTheSoundtrack() async throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        let env = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: env["BLUEBOX_AUDIO_SYNC_DIR"] ?? "/")
        let shift = Double(env["BLUEBOX_AUDIO_SYNC_SHIFT"] ?? "0") ?? 0
        let media = try #require(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.deletingPathExtension().lastPathComponent == "film" && $0.pathExtension != "srt" })
        let cues = try await SubtitleLoader().load(folder.appending(path: "film.srt")).cues
        let language = try #require(SubtitleAudioAlignment.language(of: cues))
        let locale = try #require(await TranscriberListening.locale(for: language))
        try await TranscriberListening.prepare(locale)

        var words: [SubtitleAudioAlignment.HeardWord] = []
        for start in [40.0, 120.0] {
            let wav = FileManager.default.temporaryDirectory.appending(path: "bluebox-sync-test-\(Int(start)).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            let from = try await VLCAudioClip.extract(media, start: start, duration: SubtitleAudioSync.clipLength, to: wav)
            let heard = try await SubtitleAudioSync.recognize(wav, with: .transcriber(locale), hints: [])
            print("AUDIO SYNC: \(heard.count) words from \(from) s, \(locale.identifier)")
            words += heard.map { .init($0.text, at: from + $0.time) }
        }
        let result = try #require(SubtitleAudioAlignment.fit(words: words, cues: cues))
        print("AUDIO SYNC: \(result.offset.seconds) s, scale \(result.offset.scale), \(result.matches) matches")
        #expect(abs(result.offset.seconds + shift) < 0.5)
        #expect(abs(result.offset.scale - 1) < 0.002)
    }
}
