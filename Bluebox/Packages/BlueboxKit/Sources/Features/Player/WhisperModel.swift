import Foundation
import Observation
import Subtitles
import WhisperKit

/// Whisper, for generated subtitles in languages Apple's transcriber doesn't
/// hear: OpenAI's speech model run on the device by WhisperKit (Core ML).
/// It isn't part of the app; it's downloaded the first time a language needs
/// it (the size is shown first), kept in Application Support › Bluebox › Whisper, and
/// can be deleted in Settings › Subtitles.
@Observable
@MainActor
final class WhisperModel {
    static let shared = WhisperModel()

    /// Large v3 Turbo, compressed: close to the full model's accuracy at a
    /// third of its size, small enough for an iPhone.
    static let variant = "large-v3-v20240930_turbo_632MB"
    static let approximateBytes: Int64 = 632_000_000

    enum State: Equatable {
        case absent
        case downloading(Double)
        case ready
    }

    private(set) var state: State = .absent
    private var kit: WhisperKit?

    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Bluebox/Whisper", directoryHint: .isDirectory)

    init() {
        if modelFolder != nil { state = .ready }
    }

    /// The downloaded model's folder, if it's on the device.
    private var modelFolder: URL? {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(Self.variant) {
            // Only a finished download has the decoder.
            if FileManager.default.fileExists(atPath: url.appending(path: "TextDecoder.mlmodelc").path) { return url }
        }
        return nil
    }

    /// Space the model takes on the device.
    var bytesOnDisk: Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    func delete() {
        kit = nil
        try? FileManager.default.removeItem(at: folder)
        state = .absent
    }

    /// Downloads the model if it isn't here yet, and loads it.
    func prepare(status: @escaping @MainActor (String) -> Void) async throws -> WhisperKit {
        if let kit { return kit }
        let model: URL
        if let existing = modelFolder {
            model = existing
        } else {
            state = .downloading(0)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                model = try await WhisperKit.download(variant: Self.variant, downloadBase: folder) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        WhisperModel.shared.state = .downloading(fraction)
                        status("Downloading Whisper… \(Int(fraction * 100)) %")
                    }
                }
            } catch {
                state = .absent
                throw error
            }
        }
        status("Getting Whisper ready…")
        let loaded = try await WhisperKit(WhisperKitConfig(modelFolder: model.path, verbose: false, prewarm: true, load: true, download: false))
        kit = loaded
        state = .ready
        return loaded
    }

    func listener(language: String, status: @escaping @MainActor (String) -> Void) async throws -> any SpeechListening {
        WhisperListening(kit: try await prepare(status: status), language: language)
    }
}

/// Whisper listening to a clip: word times included, in the language asked for.
struct WhisperListening: SpeechListening, @unchecked Sendable {
    let kit: WhisperKit
    let language: String

    func words(in wav: URL, offset: TimeInterval) async throws -> [HeardWord] {
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: wav.path)
        let options = DecodingOptions(task: .transcribe, language: String(language.prefix(2)), skipSpecialTokens: true, wordTimestamps: true)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        var out: [HeardWord] = []
        for segment in results.flatMap(\.segments) {
            // A stretch Whisper itself thinks is silence is where it invents lines.
            if segment.noSpeechProb > 0.6 { continue }
            for word in segment.words ?? [] {
                out.append(HeardWord(word.word, start: offset + Double(word.start), end: offset + Double(word.end)))
            }
        }
        return out
    }
}
