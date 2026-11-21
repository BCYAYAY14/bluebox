import AVFoundation
import Domain
import Foundation
import Observation
import Playback
import Subtitles
import Translation
import TorrentStreaming
import VLCPlayback

/// Generated subtitles: when a video has no subtitles in a language you read,
/// Bluebox listens to its soundtrack on the device and writes them, translated
/// if you like, while it plays. Nothing leaves the device.
///
/// It starts at the playhead and keeps ahead of it, half a minute of sound
/// at a time, then fills in the rest of the film; a seek past what's written
/// starts writing from there. Apple's on-device transcriber listens where
/// the system has the language, Whisper (an optional download) where it
/// doesn't; Apple's Translation framework translates whole sentences. The
/// lines are a track like any other, tagged Generated, and are saved with
/// the title for next time (`GeneratedSubtitleStore`).
@Observable
@MainActor
final class SubtitleGenerator {
    enum Phase: Equatable {
        case idle
        /// Getting ready: downloading a speech model or a language.
        case preparing(String)
        case writing
        case done
        case failed(String)
    }

    /// Who listens.
    enum Engine: String, Codable, Sendable { case apple, whisper }

    struct Request: Equatable, Sendable {
        /// The language spoken in the video, and the one the lines are written in.
        var spoken: String
        var language: String
        var engine: Engine
        var translates: Bool { TrackChoice.normalized(spoken) != TrackChoice.normalized(language) }
    }

    private(set) var phase: Phase = .idle
    /// What has been listened to, for the scrub bar's line and what's left.
    private(set) var covered = CoveredTime()
    private(set) var duration: TimeInterval = 0
    private(set) var request: Request?
    /// The track being written.
    private(set) var trackID: String?
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch phase { case .preparing, .writing: true; default: false }
    }

    /// Seconds of sound decoded and listened to at a time: long enough for
    /// whole sentences, short enough that the first lines come quickly.
    nonisolated static let chunk: TimeInterval = 30

    func start(_ session: PlayerSession, request: Request, title: String) {
        task?.cancel()
        self.request = request
        phase = .preparing("Getting ready…")
        task = Task { await run(session, request: request, title: title) }
    }

    func stop() {
        task?.cancel(); task = nil
        if isRunning { phase = .idle }
    }

    /// A new video: whatever was being written belonged to the last one.
    func reset() {
        stop()
        phase = .idle; covered = CoveredTime(); duration = 0; request = nil; trackID = nil
    }

    /// How far the lines go from `position`, while it's being written (the scrub bar's line).
    func reach(from position: TimeInterval) -> TimeInterval? {
        guard isRunning || phase == .done, duration > 0 else { return nil }
        return covered.reach(from: position)
    }

    private func update(_ phase: Phase) {
        guard !Task.isCancelled else { return }
        self.phase = phase
    }

    // MARK: Saved tracks

    /// Offers the tracks saved for this video at an earlier viewing (once its
    /// length is known), and turns one on if it's in the preferred language
    /// and nothing else is. A track left half written is carried on from where
    /// it stopped when it's generated again.
    static func addSaved(to session: PlayerSession, store: GeneratedSubtitleStore = .shared) {
        guard let key = session.item?.key, let duration = session.snapshot.duration, duration > 0 else { return }
        for saved in store.saved(for: key, duration: duration) {
            let sub = track(language: saved.note.language, file: saved.file)
            session.addSubtitleTrack(sub)
            if session.subtitleSelection == .off, let preferred = session.subtitleStyle.preferredLanguage,
               TrackChoice.normalized(preferred) == TrackChoice.normalized(saved.note.language) {
                session.selectSubtitle(.external(sub.id), remember: false)
            }
        }
    }

    static func track(language: String, file: URL) -> ExternalSubtitle {
        let name = Locale.current.localizedString(forLanguageCode: language) ?? language
        return ExternalSubtitle(id: ExternalSubtitle.generatedPrefix + language, url: file, languageCode: language, label: name, format: "srt")
    }

    // MARK: Writing

    private func run(_ session: PlayerSession, request: Request, title: String) async {
        guard #available(macOS 26, iOS 26, *) else {
            update(.failed("Generated subtitles need macOS 26 or iOS 26.")); return
        }
        guard let resource = session.currentResource, let key = session.item?.key,
              let duration = session.snapshot.duration, duration > 30 else {
            update(.failed("Generating subtitles needs a video that's playing.")); return
        }
        self.duration = duration
        let store = GeneratedSubtitleStore.shared
        let spokenName = Self.name(request.spoken), languageName = Self.name(request.language)

        // Who listens, and who translates.
        let listener: any SpeechListening
        do {
            listener = try await Self.listener(for: request) { [weak self] status in self?.update(.preparing(status)) }
        } catch is CancellationError { return } catch {
            update(.failed((error as? LocalizedError)?.errorDescription ?? "Bluebox can't listen to \(spokenName) on this device.")); return
        }
        var translator: SentenceTranslator?
        if request.translates {
            let source = Locale.Language(identifier: request.spoken), target = Locale.Language(identifier: request.language)
            guard await Self.translationStatus(from: request.spoken, to: request.language) == .installed else {
                update(.failed("Translating \(spokenName) into \(languageName) needs its languages downloaded first.")); return
            }
            translator = SentenceTranslator(TranslationSession(installedSource: source, target: target))
        }
        if Task.isCancelled { return }

        // Carries on from a track left half written at an earlier viewing.
        var words: [HeardWord] = []
        var translations: [String: String] = [:]
        let previous = store.saved(for: key, duration: duration)
            .first { $0.note.language == request.language && $0.note.spoken == request.spoken }
        var seed: [SubtitleCue] = []
        if let previous {
            covered = previous.note.covered
            seed = store.cues(previous)
        } else {
            covered = CoveredTime()
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "bluebox-generate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = store.files(for: key, language: request.language).srt
        let sub = Self.track(language: request.language, file: file)
        trackID = sub.id
        session.addSubtitleTrack(sub, cues: seed)
        session.selectSubtitle(.external(sub.id), remember: false)
        update(.writing)

        var cues = seed
        // What this run has listened to: lines saved before it stay everywhere else.
        var heardNow = CoveredTime()
        func publish() {
            // Translated, only the sentences whose translation has come back: one
            // that failed is asked for again after the next stretch, never shown untranslated.
            let sentences = SpeechSubtitles.sentences(words).filter { translator == nil || translations[$0.key] != nil }
            let fresh = SpeechSubtitles.cues(sentences, translations: translations)
            let written = request.engine == .whisper ? SpeechSubtitles.withoutInventedLines(fresh) : fresh
            let kept = seed.filter { !heardNow.contains($0.start) }
            cues = (kept + written).sorted { $0.start < $1.start }
            session.updateLiveSubtitle(id: sub.id, cues: cues)
        }
        func save() {
            let note = GeneratedSubtitleStore.Note(spoken: request.spoken, language: request.language, duration: duration,
                                                   covered: covered, engine: request.engine.rawValue, title: title, written: .now)
            do { try store.save(cues, note: note, for: key) } catch {
                Log.playback.notice("Generated subtitles: couldn't save: \(error.localizedDescription, privacy: .public)")
            }
        }

        let stream = StreamAvailability.stream(for: resource.url)
        let source = stream?.fileURL ?? resource.url
        var sinceSaved = 0
        while !Task.isCancelled {
            // Another video now: what's heard doesn't belong to it.
            guard session.currentResource?.url == resource.url else { break }
            if covered.covers(duration) { break }
            let available: (ClosedRange<TimeInterval>) -> Bool = { range in
                guard let stream else { return true }
                let length = Double(stream.fileLength)
                let from = Int64(length * max(0, range.lowerBound - 2) / duration)
                let to = Int64(length * min(duration, range.upperBound + 2) / duration)
                return stream.isDownloaded(from..<to)
            }
            guard let next = Self.nextChunk(position: session.position, duration: duration, covered: covered, available: available) else {
                // A torrent with nothing more downloaded yet: wait for it.
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            let wav = folder.appending(path: "clip.wav")
            do {
                let start = try await VLCAudioClip.extract(source, headers: stream == nil ? resource.httpHeaders : [:], start: next.lowerBound,
                                                           duration: next.upperBound - next.lowerBound, to: wav)
                let heard = try await listener.words(in: wav, offset: start)
                try? FileManager.default.removeItem(at: wav)
                words = (words + heard).sorted { $0.start < $1.start }
                // All of it, even if the clip began a little late: asking again would land late again.
                covered.insert(next); heardNow.insert(next)
                if let translator {
                    let wanted = SpeechSubtitles.sentences(words).filter { translations[$0.key] == nil }
                    do {
                        translations.merge(try await translator.translate(wanted.map { ($0.key, $0.text) })) { $1 }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Log.playback.notice("Generated subtitles: translation failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                // A stretch that can't be read (a broken part of the file) is skipped, not tried forever.
                Log.playback.notice("Generated subtitles: stretch at \(Int(next.lowerBound)) s failed: \(error.localizedDescription, privacy: .public)")
                covered.insert(next); heardNow.insert(next)
                if Task.isCancelled { break }
            }
            publish()
            sinceSaved += 1
            if sinceSaved >= 4 { save(); sinceSaved = 0 }
        }
        save()
        guard !Task.isCancelled, session.currentResource?.url == resource.url else { return }
        phase = covered.covers(duration) ? .done : .idle
    }

    /// The next stretch to listen to: the first not yet heard from just
    /// before the playhead, then from the start of the video. For a torrent,
    /// only stretches already downloaded.
    nonisolated static func nextChunk(position: TimeInterval, duration: TimeInterval, covered: CoveredTime,
                                      available: (ClosedRange<TimeInterval>) -> Bool) -> ClosedRange<TimeInterval>? {
        for origin in [max(0, position - 2), 0] {
            var from = origin
            while let gap = covered.firstGap(from: from, before: duration) {
                // Up to a chunk, stopping where the next heard stretch begins.
                let nextHeard = covered.ranges.first { $0.lowerBound > gap }?.lowerBound ?? duration
                let range = gap...min(gap + chunk, nextHeard, duration)
                if range.upperBound - range.lowerBound >= 1, available(range) { return range }
                from = range.upperBound + 0.01
            }
        }
        return nil
    }

    /// Whether Apple's Translation can translate between two languages here, and has them downloaded.
    nonisolated static func translationStatus(from source: String, to target: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
    }

    /// The languages Apple's Translation knows.
    nonisolated static func translatableLanguages() async -> Set<String> {
        Set(await LanguageAvailability().supportedLanguages.compactMap { $0.languageCode?.identifier })
    }

    static func name(_ language: String) -> String {
        Locale.current.localizedString(forLanguageCode: language) ?? language
    }

    // MARK: Listeners

    /// Apple's transcriber where the system has the language; otherwise
    /// Whisper, downloaded first if it isn't on the device yet.
    @available(macOS 26, iOS 26, *)
    private static func listener(for request: Request, status: @escaping @MainActor (String) -> Void) async throws -> any SpeechListening {
        switch request.engine {
        case .apple:
            guard let locale = await TranscriberListening.locale(for: request.spoken) else { throw ListenerError.unsupported(name(request.spoken)) }
            status("Getting \(name(request.spoken)) speech ready…")
            try await TranscriberListening.prepare(locale)
            return AppleListening(locale: locale)
        case .whisper:
            return try await WhisperModel.shared.listener(language: request.spoken, status: status)
        }
    }

    enum ListenerError: Error, LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self { case .unsupported(let name): "Apple's speech recognition doesn't know \(name) on this device." }
        }
    }

    /// The engine for a spoken language: Apple's where the system has it,
    /// else Whisper (an option to download).
    static func engine(for spoken: String) async -> Engine {
        if #available(macOS 26, iOS 26, *), await TranscriberListening.locale(for: spoken) != nil { return .apple }
        return .whisper
    }
}

/// Apple's Translation, for whole sentences at a time. One run uses it from
/// one task, one batch after another, so it's never used from two at once.
final class SentenceTranslator: @unchecked Sendable {
    private let session: TranslationSession
    init(_ session: TranslationSession) { self.session = session }

    /// Asks the system to download the languages (it shows its own sheet). False if it couldn't.
    nonisolated func prepare() async -> Bool {
        (try? await session.prepareTranslation()) != nil
    }

    /// Translations by key, in one batch.
    nonisolated func translate(_ sentences: [(key: String, text: String)]) async throws -> [String: String] {
        guard !sentences.isEmpty else { return [:] }
        let requests = sentences.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.key) }
        var out: [String: String] = [:]
        for response in try await session.translations(from: requests) {
            if let key = response.clientIdentifier { out[key] = response.targetText }
        }
        return out
    }
}

/// Something that turns a clip of sound into words with times.
protocol SpeechListening: Sendable {
    /// The words heard in `wav`, with their times in the video (the clip starts at `offset`).
    func words(in wav: URL, offset: TimeInterval) async throws -> [HeardWord]
}

@available(macOS 26, iOS 26, *)
struct AppleListening: SpeechListening {
    let locale: Locale
    func words(in wav: URL, offset: TimeInterval) async throws -> [HeardWord] {
        try await TranscriberListening.heard(wav, locale: locale, offset: offset)
    }
}
