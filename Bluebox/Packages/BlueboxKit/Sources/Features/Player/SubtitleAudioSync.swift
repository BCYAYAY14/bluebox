import AVFoundation
import Domain
import Foundation
import Observation
import Playback
import Speech
import Subtitles
import TorrentStreaming
import VLCPlayback

/// Sync to the Audio (top of the Timing page): listens to a couple of
/// minutes of the soundtrack with Apple's on-device speech recognition
/// (`SpeechTranscriber` where the system has it, else `SFSpeechRecognizer`),
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
        /// `here`: the stretches disagreed (the film's timing changes partway),
        /// so the delay is the one for this part of the film.
        case done(SubtitleOffset, previous: SubtitleOffset, drift: Bool, here: Bool)
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
        if case .done(_, let previous, _, _) = phase { session.applySubtitleOffset(previous) }
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
        let language = Self.language(of: session, cues: cues)
        let name = Locale.current.localizedString(forLanguageCode: language) ?? "this language"
        guard let listener = await listener(for: language, name: name) else { return }
        if Task.isCancelled { return }

        let previous = session.subtitleOffset
        let (url, planned) = Self.plan(resource: resource, position: session.snapshot.position, duration: duration)
        guard !planned.isEmpty else { update(.failed("Not enough of the video has downloaded to listen to yet.")); return }
        // A track in the video is only known where it has been read: listening elsewhere would match nothing.
        let windows = Self.withLines(planned, cues: cues, offset: previous)
        guard !windows.isEmpty else {
            update(.failed("The subtitles have no lines around here to match. Try again where there's dialogue.")); return
        }
        let fitsDrift = session.canRetimeSubtitleLines
        let playhead = session.snapshot.position
        let frameRate = session.engine.diagnostics().frameRate
        var words: [SubtitleAudioAlignment.HeardWord] = []
        var best: SubtitleAudioAlignment.Result?
        // What went wrong with the stretches that couldn't be read, to say when none could.
        var failure: Error?
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
                // Numbered by stretch: each votes on its own, however close they are.
                words += try await Self.recognize(wav, with: listener, hints: hints).map { .init($0.text, at: start + $0.time, clip: i) }
            } catch is CancellationError {
                return
            } catch {
                failure = error
                Log.playback.notice("Audio sync: stretch at \(Int(windows[i])) s failed: \(error.localizedDescription, privacy: .public)")
            }
            if Task.isCancelled { return }
            // A track in the video keeps being read while this listens.
            if session.subtitleSelection == selection { cues = session.subtitleCues }
            // Two stretches that agree well are enough (one, where only a delay is set): the third is for when they don't.
            // A delay for this part only (the stretches disagree) listens on: another stretch may settle it.
            if i >= (fitsDrift ? 1 : 0), let result = await Self.match(words: words, cues: cues, current: previous, fitsDrift: fitsDrift,
                                                                                       playhead: playhead, videoFrameRate: frameRate).result {
                best = result
                if result.matches >= Self.confidentMatches, !result.isLocal { break }
            }
        }
        update(.matching)
        // Another track, or the next episode: what was heard doesn't belong to it.
        guard session.subtitleSelection == selection, session.currentResource?.url == resource.url else {
            update(.failed("The subtitles changed while Bluebox was listening. Try again.")); return
        }
        guard !words.isEmpty else {
            // Every stretch failed to read: say why, rather than blame the dialogue.
            update(.failed(failure.map(Self.message(for:)) ?? "No speech was heard. Try again in a stretch with dialogue.")); return
        }
        let outcome: SubtitleAudioAlignment.Outcome = if let best { .fitted(best) } else {
            await Self.match(words: words, cues: cues, current: previous, fitsDrift: fitsDrift, playhead: playhead, videoFrameRate: frameRate)
        }
        guard !Task.isCancelled else { return }
        let result: SubtitleAudioAlignment.Result
        switch outcome {
        case .fitted(let fitted): result = fitted
        case .refused(.drifts):
            update(.failed(fitsDrift
                ? "These subtitles drift against the speech, and Bluebox couldn't hear far enough apart to measure it. Try again later in the video, or use Slipping Out of Sync?"
                : "These subtitles drift against the speech, and only their delay can be moved here. Add a subtitle file to fix the drift."))
            return
        case .refused:
            update(.failed("The speech didn't match these subtitles well enough. Are they for this video, and in \(name)?"))
            return
        }
        guard !Task.isCancelled else { return }
        session.applySubtitleOffset(result.offset)
        phase = .done(result.offset, previous: previous, drift: result.fittedDrift, here: result.isLocal)
    }

    /// The matching, off the main actor: a fit reads every line's words (about
    /// 200 ms in a debug build, two or three per run), which held up the
    /// player's drawing while it ran. Only the outcome comes back here.
    nonisolated static func match(words: [SubtitleAudioAlignment.HeardWord], cues: [SubtitleCue], current: SubtitleOffset, fitsDrift: Bool,
                                  playhead: TimeInterval?, videoFrameRate: Double?) async -> SubtitleAudioAlignment.Outcome {
        await Task.detached(priority: .userInitiated) {
            SubtitleAudioAlignment.match(words: words, cues: cues, current: current, fitsDrift: fitsDrift,
                                         playhead: playhead, videoFrameRate: videoFrameRate)
        }.value
    }

    /// What to say when a stretch's sound couldn't be read.
    static func message(for error: Error) -> String {
        switch error as? VLCAudioClip.Failure {
        case .couldNotDecode: "Bluebox couldn't decode the sound of this video."
        case .noSound: "No sound could be read where Bluebox listened. Try again in another part of the video."
        case .timedOut: "Reading the sound of this video took too long. Try again once more of it has loaded."
        case nil: "Bluebox couldn't listen to this video's sound."
        }
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

    /// What listens to the clips.
    enum Listener {
        /// The system's newer on-device transcriber (macOS 26, iOS 26), for this locale.
        case transcriber(Locale)
        case recognizer(SFSpeechRecognizer)
    }

    /// The transcriber where the system has one for the language: it needs no
    /// permission and downloads the language's model on first use. Otherwise
    /// the older recogniser, which asks for speech recognition permission and
    /// only works offline in languages the device already has (the reason most
    /// runs failed: "can't recognise English offline", or the permission was
    /// never granted). Nil once the reason it can't listen has been shown.
    private func listener(for language: String, name: String) async -> Listener? {
        if #available(macOS 26, iOS 26, *), let locale = await TranscriberListening.locale(for: language) {
            do {
                try await TranscriberListening.prepare(locale)
                return .transcriber(locale)
            } catch is CancellationError {
                return nil
            } catch {
                // No network for the model, say: the older recogniser may still have the language.
                Log.playback.notice("Audio sync: transcriber for \(locale.identifier, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        if Task.isCancelled { return nil }
        guard await Self.authorize() else {
            update(.failed("Allow speech recognition for Bluebox in System Settings › Privacy & Security.")); return nil
        }
        guard let recognizer = Self.recognizer(for: language), recognizer.isAvailable else {
            update(.failed("Speech recognition isn't available for \(name).")); return nil
        }
        guard recognizer.supportsOnDeviceRecognition else {
            update(.failed("This device can't recognise \(name) offline.")); return nil
        }
        return .recognizer(recognizer)
    }

    static func recognize(_ url: URL, with listener: Listener, hints: [String]) async throws -> Heard {
        switch listener {
        case .transcriber(let locale):
            guard #available(macOS 26, iOS 26, *) else { return [] }
            return try await TranscriberListening.recognize(url, locale: locale, hints: hints)
        case .recognizer(let recognizer):
            return try await recognize(url, with: recognizer, hints: hints)
        }
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
                // Each word at its middle, as with the transcriber.
                once.resume(.success(result.bestTranscription.segments.map { ($0.substring, $0.timestamp + $0.duration / 2) }))
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

/// Sync to the Audio's listening with `SpeechAnalyzer` and `SpeechTranscriber`
/// (macOS 26, iOS 26): on-device, word times included, no permission to ask
/// for, and many more languages than the older recogniser has offline.
@available(macOS 26, iOS 26, *)
enum TranscriberListening {
    static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    /// The transcriber's locale for a language code: the region given, else
    /// this device's region of it, else the language's usual one ("en" is
    /// American English, not the first English the list happens to hold).
    static func locale(for language: String) async -> Locale? {
        let wanted = Locale(identifier: language)
        guard let code = wanted.language.languageCode else { return nil }
        let given = wanted.language.region, here = Locale.current.region
        let usual = Locale.Language(identifier: Locale.Language(identifier: language).maximalIdentifier).region
        func rank(_ l: Locale) -> Int {
            if let given, l.language.region == given { return 0 }
            if l.language.region == here { return 1 }
            return l.language.region == usual ? 2 : 3
        }
        return await SpeechTranscriber.supportedLocales
            .filter { $0.language.languageCode == code }
            .min { (rank($0), $0.identifier) < (rank($1), $1.identifier) }
    }

    /// Downloads the language's model if this device doesn't have it yet.
    static func prepare(_ locale: Locale) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module(locale)]) {
            try await request.downloadAndInstall()
        }
    }

    /// Words heard in a clip, with when each starts and ends in the video
    /// (the clip starts at `offset`), for generated subtitles. The text keeps
    /// the transcriber's spacing and punctuation, which is what finds sentences.
    static func heard(_ url: URL, locale: Locale, offset: TimeInterval) async throws -> [HeardWord] {
        let transcriber = module(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let words = Task {
            var out: [HeardWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    out.append(HeardWord(String(result.text[run.range].characters), start: offset + range.start.seconds,
                                         end: offset + range.end.seconds))
                }
            }
            return out
        }
        return try await withTaskCancellationHandler {
            do {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                words.cancel()
                throw error
            }
            return try await words.value
        } onCancel: {
            words.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Words heard in a clip, with their times from its start.
    static func recognize(_ url: URL, locale: Locale, hints: [String]) async throws -> SubtitleAudioSync.Heard {
        let transcriber = module(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            try? await analyzer.setContext(context)
        }
        let file = try AVAudioFile(forReading: url)
        let words = Task {
            var out: SubtitleAudioSync.Heard = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    // The word's middle, where a line's word is placed too: its
                    // start put every word heard 0.2 to 0.5 s early.
                    out.append((String(result.text[run.range].characters), range.start.seconds + range.duration.seconds / 2))
                }
            }
            return out
        }
        return try await withTaskCancellationHandler {
            do {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                words.cancel()
                throw error
            }
            return try await words.value
        } onCancel: {
            words.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
