#if os(macOS)
@testable import Features
import Foundation
import Subtitles
import Testing
import VLCPlayback

/// The whole listening path on this Mac, with no player: libVLC decodes
/// stretches of a recording's sound (its start, its middle and its end, as
/// generated subtitles do), Apple's transcriber hears them, and the words
/// become lines. Opt-in, since the transcriber may download its model:
///
///     BLUEBOX_GENERATE_AUDIO=/path/to/long-english-speech.m4a swift test --filter GeneratedSubtitlesLiveCheck
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_GENERATE_AUDIO"] != nil))
struct GeneratedSubtitlesLiveCheck {
    let media = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BLUEBOX_GENERATE_AUDIO"] ?? "/")

    @Test(arguments: ["start", "middle", "end"])
    func appleHearsAStretchAndWritesLines(_ part: String) async throws {
        guard #available(macOS 26, *) else { return }
        let length = try #require(await Self.duration(of: media))
        let from: TimeInterval = part == "start" ? 0 : part == "middle" ? length / 2 : length - 20
        let wav = FileManager.default.temporaryDirectory.appending(path: "bluebox-generate-\(part).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let began = ContinuousClock.now
        let start = try await VLCAudioClip.extract(media, start: from, duration: min(SubtitleGenerator.chunk, length - from), to: wav)
        let decoded = ContinuousClock.now - began
        let locale = try #require(await TranscriberListening.locale(for: "en"))
        try await TranscriberListening.prepare(locale)
        let words = try await AppleListening(locale: locale).words(in: wav, offset: start)
        let cues = SpeechSubtitles.cues(SpeechSubtitles.sentences(words))
        print("GENERATE \(part): from \(from) s (clip at \(start) s), decoded in \(decoded), \(words.count) words, \(cues.count) lines")
        print(SpeechSubtitles.srt(Array(cues.prefix(3))))
        #expect(words.count >= 10)
        #expect(words.first.map { $0.start >= from - 1 } == true)
        #expect(cues.count >= 2)
        #expect(cues.allSatisfy { $0.text.split(separator: "\n").count <= 2 })
    }

    /// The same with Whisper, which downloads its model (632 MB) the first time.
    /// The recording's language comes from `BLUEBOX_GENERATE_LANGUAGE` (English if unset).
    @Test(arguments: ["start", "middle", "end"])
    func whisperHearsAStretchAndWritesLines(_ part: String) async throws {
        let language = ProcessInfo.processInfo.environment["BLUEBOX_GENERATE_LANGUAGE"] ?? "en"
        let length = try #require(await Self.duration(of: media))
        let from: TimeInterval = part == "start" ? 0 : part == "middle" ? length / 2 : length - 20
        let wav = FileManager.default.temporaryDirectory.appending(path: "bluebox-whisper-\(part).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let start = try await VLCAudioClip.extract(media, start: from, duration: min(SubtitleGenerator.chunk, length - from), to: wav)
        let began = ContinuousClock.now
        let listener = try await WhisperModel.shared.listener(language: language) { print("WHISPER status: \($0)") }
        let loaded = ContinuousClock.now - began
        let heardFrom = ContinuousClock.now
        let words = try await listener.words(in: wav, offset: start)
        let heard = ContinuousClock.now - heardFrom
        let cues = SpeechSubtitles.withoutInventedLines(SpeechSubtitles.cues(SpeechSubtitles.sentences(words)))
        if ProcessInfo.processInfo.environment["BLUEBOX_GENERATE_WORDS"] != nil { print("WORDS " + words.map { "[\($0.text)|\(String(format: "%.2f", $0.start))]" }.joined()) }
        print("WHISPER \(part) (\(language)): from \(from) s (clip at \(start) s), ready in \(loaded), heard in \(heard), \(words.count) words, \(cues.count) lines")
        print(SpeechSubtitles.srt(Array(cues.prefix(3))))
        #expect(words.count >= 10)
        #expect(words.first.map { $0.start >= from - 1 } == true)
        #expect(cues.count >= 2)
        #expect(cues.allSatisfy { $0.text.split(separator: "\n").count <= 2 })
    }

    static func duration(of url: URL) async -> TimeInterval? {
        guard let d = try? await AVURLAssetDuration.load(url) else { return nil }
        return d
    }
}

import AVFoundation
enum AVURLAssetDuration {
    static func load(_ url: URL) async throws -> TimeInterval {
        try await AVURLAsset(url: url).load(.duration).seconds
    }
}
#endif
