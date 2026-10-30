import Domain
import Foundation
import Observation
import Playback
import Speech
import Subtitles
import TorrentStreaming
import VLCPlayback

/// Sync to the Audio (top of the Timing page): listens to a couple of
/// minutes of the soundtrack with Apple's on-device speech recognition,
/// lines the words up with the subtitle text (`SubtitleAudioAlignment`) and
/// sets the delay, and the drift when it can tell. Runs only when asked.
///
/// The sound is decoded by libVLC to a short WAV per stretch. A torrent is
/// read from its file on disk, and only where it has downloaded, so the
/// stream isn't pulled elsewhere; a local file is sampled across the film,
/// which is what reveals drift.
@Observable
@MainActor
final class SubtitleAudioSync {
    enum Phase: Equatable {
        case idle
        case listening(part: Int, of: Int)
        case matching
        case done(SubtitleOffset, previous: SubtitleOffset, drift: Bool)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    static let clipLength: TimeInterval = 60

    var isRunning: Bool {
        switch phase { case .listening, .matching: true; default: false }
    }

    func start(_ session: PlayerSession) {
        task?.cancel()
        task = Task { await run(session) }
    }

    func cancel() { task?.cancel(); task = nil; phase = .idle }

    func undo(_ session: PlayerSession) {
        if case .done(_, let previous, _) = phase { session.applySubtitleOffset(previous) }
        phase = .idle
    }

    private func run(_ session: PlayerSession) async {
        guard let resource = session.currentResource, let duration = session.snapshot.duration, duration > 30 else {
            phase = .failed("Sync needs a video that's playing."); return
        }
        let cues = session.subtitleCues
        guard cues.count >= 10 else { phase = .failed("There aren't enough subtitle lines to match yet."); return }
        guard await Self.authorize() else {
            phase = .failed("Allow speech recognition for Bluebox in System Settings › Privacy & Security."); return
        }
        let locale = Locale(identifier: Self.language(of: session) ?? "en")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            phase = .failed("Speech recognition isn't available for \(Locale.current.localizedString(forIdentifier: locale.identifier) ?? "this language").")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            phase = .failed("This device can't recognise \(Locale.current.localizedString(forIdentifier: locale.identifier) ?? "this language") offline.")
            return
        }

        let (url, windows) = Self.plan(resource: resource, position: session.snapshot.position, duration: duration)
        guard !windows.isEmpty else { phase = .failed("Not enough of the video has downloaded to listen to yet."); return }
        let previous = session.subtitleOffset
        var words: [SubtitleAudioAlignment.HeardWord] = []
        let folder = FileManager.default.temporaryDirectory.appending(path: "bluebox-audio-sync", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, start) in windows.enumerated() {
            phase = .listening(part: i + 1, of: windows.count)
            let wav = folder.appending(path: "clip-\(i).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            do {
                try await VLCAudioClip.extract(url, start: start, duration: Self.clipLength, to: wav)
                words += try await Self.recognize(wav, with: recognizer).map { .init($0.text, at: start + $0.time) }
            } catch is CancellationError {
                phase = .idle; return
            } catch {
                Log.playback.notice("Audio sync: stretch at \(Int(start)) s failed: \(error.localizedDescription, privacy: .public)")
            }
            if Task.isCancelled { phase = .idle; return }
        }
        phase = .matching
        guard !words.isEmpty else { phase = .failed("No speech was heard. Try again in a stretch with dialogue."); return }
        guard let result = SubtitleAudioAlignment.fit(words: words, cues: cues, current: previous,
                                                      fitsDrift: session.canRetimeSubtitleLines) else {
            phase = .failed("The speech didn't match these subtitles well enough. Are they for this video, and in this language?")
            return
        }
        session.applySubtitleOffset(result.offset)
        phase = .done(result.offset, previous: previous, drift: result.fittedDrift)
    }

    /// The stretches to listen to, and where to read them from.
    static func plan(resource: PlaybackResource, position: TimeInterval, duration: TimeInterval) -> (URL, [TimeInterval]) {
        let last = max(0, duration - clipLength)
        if let stream = StreamAvailability.stream(for: resource.url) {
            // A torrent: from its file on disk, and only stretches already downloaded.
            func downloaded(_ start: TimeInterval) -> Bool {
                let len = Double(stream.fileLength)
                let from = Int64(len * max(0, start - 5) / duration), to = Int64(len * min(duration, start + clipLength + 5) / duration)
                return stream.isDownloaded(from..<to)
            }
            let candidates = [position - clipLength - 5, position * 0.5, position * 0.25, position]
                .map { min(max(0, $0), last) }
            var picked: [TimeInterval] = []
            for c in candidates where downloaded(c) && !picked.contains(where: { abs($0 - c) < clipLength }) {
                picked.append(c)
                if picked.count == 2 { break }
            }
            return (stream.fileURL, picked.sorted())
        }
        // Two stretches far apart in the film show drift: from here, and further on.
        let here = min(max(0, position - 5), last)
        let later = duration - position > 900 ? position + (duration - position) * 0.5 : max(0, position * 0.4)
        let second = min(max(0, later), last)
        return (resource.url, abs(second - here) < clipLength ? [here] : [here, second].sorted())
    }

    /// The main subtitle track's language, for the recogniser.
    static func language(of session: PlayerSession) -> String? {
        let id: String? = switch session.subtitleSelection {
        case .off: nil
        case .embedded(let id), .external(let id): id
        }
        let track = id.flatMap { id in session.allSubtitleTracks.first { $0.id == id } }
        return track?.languageCode ?? session.subtitleStyle.preferredLanguage
    }

    static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    /// Words heard in a clip, with their times from its start.
    static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> [(text: String, time: TimeInterval)] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        let holder = RecognitionHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[(text: String, time: TimeInterval)], Error>) in
                let once = ResumeOnce(c)
                holder.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        once.resume(.success(result.bestTranscription.segments.map { ($0.substring, $0.timestamp) }))
                    } else if let error {
                        once.resume(.failure(error))
                    }
                }
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }

    private final class RecognitionHolder: @unchecked Sendable { var task: SFSpeechRecognitionTask? }

    private final class ResumeOnce: @unchecked Sendable {
        private var continuation: CheckedContinuation<[(text: String, time: TimeInterval)], Error>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<[(text: String, time: TimeInterval)], Error>) { continuation = c }
        func resume(_ result: Result<[(text: String, time: TimeInterval)], Error>) {
            lock.withLock {
                continuation?.resume(with: result)
                continuation = nil
            }
        }
    }
}
