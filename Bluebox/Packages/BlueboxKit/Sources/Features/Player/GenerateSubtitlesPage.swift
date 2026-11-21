import DesignSystem
import Playback
import Speech
import SwiftUI
import Translation
import WhisperKit

/// Generate Subtitles (a page in the Audio & Subtitles card): the language
/// spoken, the one to write the lines in, and who listens. Apple's speech
/// recognition where the system has the language, Whisper where it doesn't
/// (downloaded once, its size said first); Apple's Translation for anything
/// else than the spoken language, its languages downloaded by the system
/// when they're missing.
struct GenerateSubtitlesPage: View {
    @Environment(AppModel.self) private var app
    /// The player's, so writing carries on when the card closes.
    @Environment(SubtitleGenerator.self) private var sharedGenerator: SubtitleGenerator?
    @State private var ownGenerator = SubtitleGenerator()
    private var generator: SubtitleGenerator { sharedGenerator ?? ownGenerator }
    let session: PlayerSession
    let onBack: () -> Void

    @State private var spoken = ""
    @State private var language = ""
    @State private var spokenChoices: [String] = []
    @State private var languageChoices: [String] = []
    @State private var engine: SubtitleGenerator.Engine?
    @State private var translation: LanguageAvailability.Status?
    /// Set to ask the system for the translation languages (it shows its own download sheet).
    @State private var preparing: TranslationSession.Configuration?
    /// Whisper would download on mobile data (or in Low Data Mode): asked first.
    @State private var asksMobileData = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var whisper: WhisperModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerPageHeader("Generate Subtitles", onBack: onBack)
            if !spoken.isEmpty {
                PanelSection("Spoken") {
                    PanelSegmentsWithMore(selection: $spoken, shown: options(spokenChoices.prefix(2)), more: options(spokenChoices.dropFirst(2)))
                }
                PanelSection("Subtitles In") {
                    PanelSegmentsWithMore(selection: $language, shown: options(languageChoices.prefix(2)), more: options(languageChoices.dropFirst(2)))
                }
                listensWith
                if generator.isRunning {
                    PanelActionButton(title: "Stop Generating", symbol: "stop.fill") { generator.stop() }
                } else if asksMobileData {
                    // Like Bluebox's other mobile data questions: the size first, Wi‑Fi the easy way out.
                    Text("You're on mobile data. Whisper is a \(Formatters.bytes(WhisperModel.approximateBytes)) download.")
                        .font(.caption).foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    PanelActionButton(title: "Download Now on Mobile Data", symbol: "antenna.radiowaves.left.and.right") {
                        generate(onMobileData: true)
                    }
                    Button("Wait for Wi‑Fi") { withAnimation(Motion.standard(reduceMotion)) { asksMobileData = false } }
                        .font(.subheadline.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle())
                        .foregroundStyle(Palette.brandBright)
                } else {
                    PanelActionButton(title: "Generate", symbol: "sparkles") { generate() }
                        .disabled(!canGenerate)
                        .accessibilityIdentifier("generate.start")
                }
                if case .failed(let message) = generator.phase {
                    Text(ui: message).font(.caption).foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(deviceNote)
                    .font(.caption).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .task { await loadChoices() }
        .task(id: spoken) {
            asksMobileData = false
            engine = spoken.isEmpty ? nil : await SubtitleGenerator.engine(for: spoken)
        }
        .task(id: "\(spoken)>\(language)") { await checkTranslation() }
        .translationTask(preparing) { translator in
            _ = await SentenceTranslator(translator).prepare()
            await checkTranslation()
            if translation == .installed { start() }
            preparing = nil
        }
    }

    private func options<S: Sequence<String>>(_ codes: S) -> [(String, String)] {
        codes.map { (SubtitleGenerator.name($0), $0) }
    }

    @ViewBuilder private var listensWith: some View {
        PanelSection("Listens With") {
            VStack(alignment: .leading, spacing: 4) {
                switch engine {
                case .apple:
                    Text("Apple's speech recognition, on this device").font(.callout)
                case .whisper where !app.settings.allowsWhisper:
                    Text("Apple's speech recognition doesn't know this language, and Allow Whisper is off in Settings › Privacy & Features.")
                        .font(.callout).foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                case .whisper:
                    Text("Whisper, on this device").font(.callout)
                    if case .downloading(let fraction) = whisper.state {
                        ProgressView(value: fraction).tint(Palette.brand)
                    } else if whisper.state == .absent {
                        Text("Apple's speech recognition doesn't know this language, so Bluebox downloads Whisper once (\(Formatters.bytes(WhisperModel.approximateBytes))).")
                            .font(.caption).foregroundStyle(Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case nil:
                    ProgressView().controlSize(.small)
                }
                if translation == .unsupported {
                    Text("Apple's Translation can't translate \(SubtitleGenerator.name(spoken)) into \(SubtitleGenerator.name(language)).")
                        .font(.caption).foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if translation == .supported {
                    Text("Translated with Apple's Translation. Its languages download first.")
                        .font(.caption).foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if translation == .installed {
                    Text("Translated with Apple's Translation, on this device.")
                        .font(.caption).foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    private var deviceNote: String {
        #if os(macOS)
        "Nothing leaves this Mac. The subtitles are saved with the video; delete them in Settings › Subtitles."
        #else
        "Nothing leaves this device. The subtitles are saved with the video; delete them in Settings › Subtitles."
        #endif
    }

    private var canGenerate: Bool {
        engine != nil && translation != .unsupported && !spoken.isEmpty && !language.isEmpty && !whisperTurnedOff
    }

    /// The language needs Whisper, and Allow Whisper is off in Settings › Privacy & Features.
    private var whisperTurnedOff: Bool {
        engine == .whisper && !app.settings.allowsWhisper
    }

    /// No language, or a code that names none ("und", "mul", "zxx", "mis").
    static func isUntagged(_ code: String?) -> Bool {
        guard let code = code.map(TrackChoice.normalized), !code.isEmpty else { return true }
        return ["und", "mul", "zxx", "mis"].contains(code)
    }

    private var translates: Bool { TrackChoice.normalized(spoken) != TrackChoice.normalized(language) }

    private func generate(onMobileData: Bool = false) {
        if engine == .whisper, whisper.state == .absent, app.settings.isOnMobileData, !onMobileData {
            withAnimation(Motion.standard(reduceMotion)) { asksMobileData = true }
            return
        }
        asksMobileData = false
        if translates, translation == .supported {
            preparing = TranslationSession.Configuration(source: Locale.Language(identifier: spoken), target: Locale.Language(identifier: language))
        } else {
            start()
        }
    }

    private func start() {
        guard let engine else { return }
        generator.start(session, request: .init(spoken: spoken, language: language, engine: engine), title: session.item?.title ?? "")
        onBack()
    }

    private func checkTranslation() async {
        guard !spoken.isEmpty, !language.isEmpty else { return }
        guard translates else { translation = nil; return }
        translation = await SubtitleGenerator.translationStatus(from: spoken, to: language)
    }

    /// The likely spoken language first (the audio track's, else the language
    /// the title was made in, else this device's), then every language either
    /// engine hears; your subtitle language first for the lines, then the
    /// spoken one, then the rest Apple's Translation knows.
    private func loadChoices() async {
        let audio = session.slowSnapshot.audioTracks.first { $0.id == session.slowSnapshot.selectedAudioID }?.languageCode
        let device = Locale.current.language.languageCode?.identifier ?? "en"
        // An untagged track ("und") is usually in the title's own language (TMDB's), not the device's.
        var original: String?
        if Self.isUntagged(audio), let key = session.item?.key {
            original = try? await app.metadata.detail(for: key.seriesKey ?? key).originalLanguage
        }
        let candidates: [String] = [audio, original, device].compactMap { $0.map(TrackChoice.normalized) }
        let guess = candidates.first { !Self.isUntagged($0) } ?? "en"
        let preferred = (session.subtitleStyle.preferredLanguage ?? app.subtitleStyle.preferredLanguage).map(TrackChoice.normalized) ?? device
        let first = preferred == guess ? [guess] : [preferred, guess]
        // The likely choices straight away; the long lists follow.
        spokenChoices = [guess]
        languageChoices = first
        spoken = generator.request?.spoken ?? guess
        language = generator.request?.language ?? preferred

        var heard = Set(Constants.languageCodes)
        if #available(macOS 26, iOS 26, *) {
            for locale in await SpeechTranscriber.supportedLocales { if let code = locale.language.languageCode?.identifier { heard.insert(code) } }
        }
        let byName = { (a: String, b: String) in SubtitleGenerator.name(a).localizedCompare(SubtitleGenerator.name(b)) == .orderedAscending }
        let named = heard.subtracting([guess]).filter { Locale.current.localizedString(forLanguageCode: $0) != nil }
        spokenChoices = [guess] + named.sorted(by: byName)
        let translatable = await SubtitleGenerator.translatableLanguages()
        languageChoices = first + translatable.subtracting(first).sorted(by: byName)
    }
}
