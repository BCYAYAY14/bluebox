import Foundation
import Subtitles
import Testing
import VLCPlayback
@testable import Features

/// Opt-in audit: Sync to the Audio on a recording whose line times are known
/// exactly (`film.srt` timed to the sound, any `film.*` VLC plays). Listens
/// to three stretches the way the player plans them, times decoding and
/// listening, then matches the words against the lines shifted and stretched
/// by known amounts and prints what each finds ("AUDIT E2E").
///
///     BLUEBOX_AUDIT_DIR=/path BLUEBOX_AUDIT_MEDIA=film.m4a swift test --filter AudioSyncAuditEndToEndTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_AUDIT_DIR"] != nil))
struct AudioSyncAuditEndToEndTests {
    @Test func auditOnAKnownRecording() async throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        let env = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: env["BLUEBOX_AUDIT_DIR"] ?? "/")
        let media = folder.appending(path: env["BLUEBOX_AUDIT_MEDIA"] ?? "film.wav")
        let truth = try await SubtitleLoader().load(folder.appending(path: "film.srt")).cues
        let locale = try #require(await TranscriberListening.locale(for: "en"))
        let t0 = Date()
        try await TranscriberListening.prepare(locale)
        print(String(format: "AUDIT E2E prepare %.1f s", Date().timeIntervalSince(t0)))

        let duration = (truth.last?.end ?? 0) + 5
        let last = duration - SubtitleAudioSync.clipLength
        // The local plan from 60 s in: here, then the two quarter points furthest away.
        let here = 55.0
        let others = [0.25, 0.5, 0.75].map { min($0 * duration, last) }.sorted { abs($0 - here) > abs($1 - here) }.prefix(2)
        var words: [SubtitleAudioAlignment.HeardWord] = []
        for (clip, start) in ([here] + others).sorted().enumerated() {
            let wav = FileManager.default.temporaryDirectory.appending(path: "bluebox-audit-\(Int(start)).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            let d0 = Date()
            // As the player does: a stretch that fails is logged and the rest go on.
            guard let from = try? await VLCAudioClip.extract(media, start: start, duration: SubtitleAudioSync.clipLength, to: wav) else {
                print(String(format: "AUDIT E2E stretch %.0f s: decode FAILED after %.2f s", start, Date().timeIntervalSince(d0)))
                continue
            }
            let decode = Date().timeIntervalSince(d0)
            let r0 = Date()
            let heard = try await SubtitleAudioSync.recognize(wav, with: .transcriber(locale), hints: [])
            let listen = Date().timeIntervalSince(r0)
            print(String(format: "AUDIT E2E stretch %.0f s (clip says %.2f): decode %.2f s, listen %.2f s, %d words", start, from, decode, listen, heard.count))
            words += heard.map { .init($0.text, at: from + $0.time, clip: clip) }
        }

        func shifted(_ late: Double, scale: Double = 1) -> [SubtitleCue] {
            truth.map { SubtitleCue(start: $0.start * scale + late, end: $0.end * scale + late, text: $0.text) }
        }
        func check(_ name: String, _ cues: [SubtitleCue], fitsDrift: Bool = true) {
            let f0 = Date()
            let r = SubtitleAudioAlignment.fit(words: words, cues: cues, fitsDrift: fitsDrift, playhead: 60)
            let ms = Date().timeIntervalSince(f0) * 1000
            // How far each line then lands from where it's spoken.
            let errors = zip(cues, truth).map { abs((r?.offset ?? .init()).playerTime(forCueTime: $0.start) - $1.start) }.sorted()
            print(String(format: "AUDIT E2E %@ | %@ | fit %.1f ms | line error median %.3f s, max %.3f s", name,
                         r.map { "\($0.offset.label) scale \($0.offset.scale), \($0.matches) pairs\($0.isLocal ? ", here only" : "")" } ?? "REFUSED", ms,
                         errors[errors.count / 2], errors.last ?? 0))
        }
        check("in sync", truth)
        for late in [2.0, -0.5, 3.0, 20.0, -20.0] { check("lines \(late) s late", shifted(late)) }
        check("lines 2 s late, track in video", shifted(2), fitsDrift: false)
        check("lines timed 25/23.976", shifted(0, scale: 25 / (24000.0 / 1001)))
        check("lines timed 23.976/25", shifted(0, scale: (24000.0 / 1001) / 25))
    }
}
