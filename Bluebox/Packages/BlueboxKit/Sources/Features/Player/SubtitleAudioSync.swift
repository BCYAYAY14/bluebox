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
/// sets the delay, and the drift when it can tell. Runs only when asked, and
/// carries on if the card is closed (the player says when it's done).
///
/// The sound is decoded by libVLC to a short WAV per stretch. A torrent is
/// read from its file on disk, and only where it has downloaded, so the
/// stream isn't pulled elsewhere; a local file is sampled across the film,
/// which is what reveals drift. The next stretch is decoded while the last
/// is recognised, and two stretches that agree well end it early.
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
        // Running from the tap, while permission is asked and the first stretch decodes.
        phase = .listening(part: 1, of: 1)
        task = Task { await run(session) }
    }

    func cancel() { task?.cancel(); task = nil; phase = .idle }

    func undo(_ session: PlayerSession) {
        if case .done(_, let previous, _) = phase { session.applySubtitleOffset(previous) }
        phase = .idle
    }

    /// A run that was stopped (or replaced by a new one) leaves the phase to
    /// whoever stopped it: `cancel` has set it, or the new run owns it.
    private func update(_ phase: Phase) {
        guard !Task.isCancelled else { return }
        self.phase = phase
    }

    private func run(_ session: PlayerSession) async {
        guard let resource = session.currentResource, let duration = session.snapshot.duration, duration > 30 else {
            update(.failed("Sync needs a video that's playing.")); return
        }
        let selection = session.subtitleSelection
        var cues = session.subtitleCues
        guard cues.count >= 10 else { update(.failed("There aren't enough subtitle lines to match yet.")); return }
        guard await Self.authorize() else {
            update(.failed("Allow speech recognition for Bluebox in System Settings › Privacy & Security.")); return
        }
        if Task.isCancelled { return }
        let language = Self.language(of: session, cues: cues)
        let name = Locale.current.localizedString(forLanguageCode: language) ?? "this language"
        guard let recognizer = Self.recognizer(for: language), recognizer.isAvailable else {
            update(.failed("Speech recognition isn't available for \(name).")); return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            update(.failed("This device can't recognise \(name) offline.")); return
        }

        let previous = session.subtitleOffset
        let (url, planned) = Self.plan(resource: resource, position: session.snapshot.position, duration: duration)
        guard !planned.isEmpty else { update(.failed("Not enough of the video has downloaded to listen to yet.")); return }
        // A track in the video is only known where it has been read: listening elsewhere would match nothing.
        let windows = Self.withLines(planned, cues: cues, offset: previous)
        guard !windows.isEmpty else {
            update(.failed("The subtitles have no lines around here to match. Try again where there's dialogue.")); return
        }
        let fitsDrift = session.canRetimeSubtitleLines
        var words: [SubtitleAudioAlignment.HeardWord] = []
        var best: SubtitleAudioAlignment.Result?
        // Its own folder: a run stopped and started again doesn't share clips with the last.
        let folder = FileManager.default.temporaryDirectory.appending(path: "bluebox-audio-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // The next stretch is decoded while this one is being recognised.
        func decode(_ i: Int) -> Task<(URL, TimeInterval), Error> {
            let wav = folder.appending(path: "clip-\(i).wav")
            return Task {
                let start = try await VLCAudioClip.extract(url, headers: resource.httpHeaders, start: windows[i], duration: Self.clipLength, to: wav)
                return (wav, start)
            }
        }
        var next: Task<(URL, TimeInterval), Error>? = decode(0)
        defer { next?.cancel() }
        for i in windows.indices {
            update(.listening(part: i + 1, of: windows.count))
            guard let current = next else { break }
            next = i + 1 < windows.count ? decode(i + 1) : nil
            do {
                let (wav, start) = try await withTaskCancellationHandler { try await current.value } onCancel: { current.cancel() }
                defer { try? FileManager.default.removeItem(at: wav) }
                let hints = Self.hints(cues, around: start, offset: previous)
                words += try await Self.recognize(wav, with: recognizer, hints: hints).map { .init($0.text, at: start + $0.time) }
            } catch is CancellationError {
                return
            } catch {
                Log.playback.notice("Audio sync: stretch at \(Int(windows[i])) s failed: \(error.localizedDescription, privacy: .public)")
            }
            if Task.isCancelled { return }
            // A track in the video keeps being read while this listens.
            if session.subtitleSelection == selection { cues = session.subtitleCues }
            // Two stretches that agree well are enough (one, where only a delay is set): the third is for when they don't.
            if i >= (fitsDrift ? 1 : 0), let result = SubtitleAudioAlignment.fit(words: words, cues: cues, current: previous, fitsDrift: fitsDrift) {
                best = result
                if result.matches >= Self.confidentMatches { break }
            }
        }
        update(.matching)
        // Another track, or the next episode: what was heard doesn't belong to it.
        guard session.subtitleSelection == selection, session.currentResource?.url == resource.url else {
            update(.failed("The subtitles changed while Bluebox was listening. Try again.")); return
        }
        guard !words.isEmpty else { update(.failed("No speech was heard. Try again in a stretch with dialogue.")); return }
        guard let result = best ?? SubtitleAudioAlignment.fit(words: words, cues: cues, current: previous, fitsDrift: fitsDrift) else {
            update(.failed("The speech didn't match these subtitles well enough. Are they for this video, and in \(name)?"))
            return
        }
        guard !Task.isCancelled else { return }
        session.applySubtitleOffset(result.offset)
        phase = .done(result.offset, previous: previous, drift: result.fittedDrift)
    }

    /// Agreeing word pairs that settle it without listening to another stretch.
    static let confidentMatches = 12
    /// Stretches listened to at most.
    static let maxStretches = 3

    /// The stretches to listen to, and where to read them from. Spread apart,
    /// since stretches far apart in the film are what show drift; clear of the
    /// opening and closing credits where they can be.
    static func plan(resource: PlaybackResource, position: TimeInterval, duration: TimeInterval) -> (URL, [TimeInterval]) {
        let last = max(0, duration - clipLength)
        func clamp(_ t: TimeInterval) -> TimeInterval { min(max(0, t), last) }
        func spread(_ candidates: [TimeInterval], keep: (TimeInterval) -> Bool) -> [TimeInterval] {
            var picked: [TimeInterval] = []
            for c in candidates.map(clamp) where keep(c) && !picked.contains(where: { abs($0 - c) < clipLength }) {
                picked.append(c)
                if picked.count == maxStretches { break }
            }
            return picked.sorted()
        }
        if let stream = StreamAvailability.stream(for: resource.url) {
            // A torrent: from its file on disk, and only stretches already downloaded.
            func downloaded(_ start: TimeInterval) -> Bool {
                let len = Double(stream.fileLength)
                let from = Int64(len * max(0, start - 5) / duration), to = Int64(len * min(duration, start + clipLength + 5) / duration)
                return stream.isDownloaded(from..<to)
            }
            let candidates = [position - clipLength - 5, position * 0.5, position * 0.25, position, position * 0.75,
                              position + (duration - position) * 0.5]
            return (stream.fileURL, spread(candidates, keep: downloaded))
        }
        // From here, then the two of a quarter, half and three quarters through that are furthest from here.
        let here = clamp(position - 5)
        let others = [0.25, 0.5, 0.75].map { $0 * duration }.sorted { abs($0 - here) > abs($1 - here) }.prefix(2)
        return (resource.url, spread([here] + others, keep: { _ in true }))
    }

    /// The stretches with a few lines in or near them (as far off as the
    /// delay being fixed could be), in order.
    static func withLines(_ windows: [TimeInterval], cues: [SubtitleCue], offset: SubtitleOffset) -> [TimeInterval] {
        windows.filter { start in
            let from = offset.cueTime(forPlayerTime: start - 60), to = offset.cueTime(forPlayerTime: start + clipLength + 60)
            return cues.lazy.filter { $0.end >= from && $0.start <= to }.prefix(3).count == 3
        }
    }

    /// Names and less common words of the lines around a stretch, so the
    /// recogniser expects them (a character's name heard as two common words matches nothing).
    static func hints(_ cues: [SubtitleCue], around start: TimeInterval, offset: SubtitleOffset) -> [String] {
        // Generous either side: the delay being fixed can be tens of seconds.
        let from = offset.cueTime(forPlayerTime: start - 60), to = offset.cueTime(forPlayerTime: start + clipLength + 60)
        var seen = Set<String>(), out: [String] = []
        for cue in cues where cue.end >= from && cue.start <= to {
            let clean = SoundCues.strip(cue.text) ?? ""
            let words = clean.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            for (i, w) in words.enumerated() {
                let isName = i > 0 && w.first?.isUppercase == true && w.count >= 3
                guard isName || w.count >= 8, seen.insert(w.lowercased()).inserted else { continue }
                out.append(w)
                if out.count == 100 { return out }
            }
        }
        return out
    }

    /// The language to listen for: the one the lines are written in, read
    /// from their text (a track's tag can be missing, "und" or wrong), else
    /// the track's tag, else the preferred subtitle language, else English.
    static func language(of session: PlayerSession, cues: [SubtitleCue]) -> String {
        if let read = SubtitleAudioAlignment.language(of: cues) { return read }
        let id: String? = switch session.subtitleSelection {
        case .off: nil
        case .embedded(let id), .external(let id): id
        }
        let track = id.flatMap { id in session.allSubtitleTracks.first { $0.id == id } }
        let tagged = [track?.languageCode, session.subtitleStyle.preferredLanguage]
            .compactMap { $0 }.first { !$0.isEmpty && !["und", "mul", "zxx", "mis"].contains($0.lowercased()) }
        return tagged ?? "en"
    }

    /// A recogniser for `language` that can listen on this device: the
    /// language's usual region first, then this device's region of it, then
    /// any other ("fr" may have offline speech for Canada and not France).
    /// One that can't listen offline when none can, so the reason can be told.
    static func recognizer(for language: String) -> SFSpeechRecognizer? {
        let wanted = Locale(identifier: language)
        let code = wanted.language.languageCode
        let region = Locale.current.region
        let others = SFSpeechRecognizer.supportedLocales()
            .filter { $0.language.languageCode == code }
            .sorted { ($0.region == region ? 0 : 1, $0.identifier) < ($1.region == region ? 0 : 1, $1.identifier) }
        var fallback: SFSpeechRecognizer?
        for locale in [wanted] + others {
            guard let recognizer = SFSpeechRecognizer(locale: locale) else { continue }
            if recognizer.supportsOnDeviceRecognition { return recognizer }
            fallback = fallback ?? recognizer
        }
        return fallback
    }

    nonisolated static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    typealias Heard = [(text: String, time: TimeInterval)]

    /// Words heard in a clip, with their times from its start.
    static func recognize(_ url: URL, with recognizer: SFSpeechRecognizer, hints: [String] = []) async throws -> Heard {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = hints
        request.addsPunctuation = false
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        let holder = RecognitionHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Heard, Error>) in
                let once = ResumeOnce(c)
                holder.set(recognizer.recognitionTask(with: request, resultHandler: Self.handler(once)), once)
            }
        } onCancel: {
            holder.cancel()
        }
    }

    /// Made outside the main actor, so the closure isn't the main actor's:
    /// Speech calls it on the recogniser's queue (the main queue unless it's
    /// changed), and a main-actor closure called anywhere else stops the app,
    /// as `requestAuthorization`'s did.
    nonisolated private static func handler(_ once: ResumeOnce) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            if let result, result.isFinal {
                once.resume(.success(result.bestTranscription.segments.map { ($0.substring, $0.timestamp) }))
            } else if let error {
                once.resume(.failure(error))
            }
        }
    }

    /// The recognition task, for the cancellation handler (any thread). A
    /// stop ends the wait at once (Speech needn't call back after a cancel),
    /// including one that came before the task existed.
    private final class RecognitionHolder: @unchecked Sendable {
        private var task: SFSpeechRecognitionTask?
        private var once: ResumeOnce?
        private var cancelled = false
        private let lock = NSLock()
        func set(_ task: SFSpeechRecognitionTask, _ once: ResumeOnce) {
            let stop = lock.withLock { self.task = task; self.once = once; return cancelled }
            if stop { cancel() }
        }
        func cancel() {
            let (task, once) = lock.withLock { cancelled = true; return (self.task, self.once) }
            task?.cancel()
            once?.resume(.failure(CancellationError()))
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private var continuation: CheckedContinuation<Heard, Error>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<Heard, Error>) { continuation = c }
        func resume(_ result: Result<Heard, Error>) {
            lock.withLock {
                continuation?.resume(with: result)
                continuation = nil
            }
        }
    }
}
