import Foundation
@testable import Subtitles
import Testing

/// An audit of Sync to the Audio's matching, the way the player runs it
/// (stretches planned like `SubtitleAudioSync.plan` for a local file, the
/// early stop after two stretches that agree): prints one "AUDIT" line per
/// case with what was found and how far every line then lands from the speech.
/// Opt-in (a minute of fitting); `SubtitleSyncAcceptTests` checks the cases that matter.
///
///     BLUEBOX_AUDIT=1 swift test --filter SubtitleSyncAuditTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_AUDIT"] != nil))
struct SubtitleSyncAuditTests {
    typealias R = SubtitleAudioAlignmentRobustnessTests
    typealias Truth = (TimeInterval) -> TimeInterval  // cue time → when it's spoken

    /// A local two-hour film played from 10 minutes in: here, then 3/4 and 1/2 through (sorted).
    static let localStretches: [TimeInterval] = [595, 3600, 5400]

    struct Outcome {
        var result: SubtitleAudioAlignment.Result?
        var stretches: Int
        var ms: Double
        var median: Double, p90: Double, worst: Double
    }

    /// Runs the player's loop: listen to each stretch, fit after the second
    /// (the first, where only a delay is set), stop at 12 agreeing pairs.
    static func run(_ cues: [SubtitleCue], truth: @escaping Truth, stretches: [TimeInterval] = localStretches,
                    fitsDrift: Bool = true, playhead: TimeInterval = 600,
                    hear: (TimeInterval, Int) -> [SubtitleAudioAlignment.HeardWord]) -> Outcome {
        var words: [SubtitleAudioAlignment.HeardWord] = []
        var best: SubtitleAudioAlignment.Result?
        var used = 0
        var spent = 0.0
        for (i, from) in stretches.enumerated() {
            used = i + 1
            // Numbered by stretch, as the player does.
            words += hear(from, i).map { .init($0.text, at: $0.time, clip: i) }
            if i >= (fitsDrift ? 1 : 0) {
                let t0 = Date()
                let r = SubtitleAudioAlignment.fit(words: words, cues: cues, fitsDrift: fitsDrift, playhead: playhead)
                spent += Date().timeIntervalSince(t0)
                if let r { best = r; if r.matches >= 12, !r.isLocal { break } }
            }
        }
        if best == nil {
            let t0 = Date()
            best = SubtitleAudioAlignment.fit(words: words, cues: cues, fitsDrift: fitsDrift, playhead: playhead)
            spent += Date().timeIntervalSince(t0)
        }
        // Where every line lands against when it's spoken (none applied: as the file is timed).
        let applied = best?.offset ?? SubtitleOffset()
        let errors = cues.map { abs(applied.playerTime(forCueTime: $0.start) - truth($0.start)) }.sorted()
        return Outcome(result: best, stretches: used, ms: spent * 1000,
                       median: errors[errors.count / 2], p90: errors[errors.count * 9 / 10], worst: errors.last ?? 0)
    }

    static func report(_ name: String, _ o: Outcome) {
        let found = o.result.map { "\($0.offset.label), \($0.matches) pairs, drift \($0.fittedDrift)\($0.isLocal ? ", here only" : "")" } ?? "REFUSED"
        print(String(format: "AUDIT %@ | %@ | stretches %d | fit %.1f ms | line error median %.2f s, p90 %.2f s, max %.2f s",
                     name, found, o.stretches, o.ms, o.median, o.p90, o.worst))
    }

    static func listen(_ cues: [SubtitleCue], delay: Double, scale: Double = 1) -> (TimeInterval, Int) -> [SubtitleAudioAlignment.HeardWord] {
        { from, i in R.listen(cues, delay: delay, scale: scale, from: from, seed: UInt64(11 + i)) }
    }

    // MARK: Constant offsets

    @Test(arguments: [0.5, -0.5, 3.0, -3.0, 20.0, -20.0])
    func constantOffset(_ delay: Double) {
        let cues = R.film(seed: 21)
        let o = Self.run(cues, truth: { $0 + delay }, hear: Self.listen(cues, delay: delay))
        Self.report("constant \(delay) s (file, 3 stretches)", o)
        let one = Self.run(cues, truth: { $0 + delay }, stretches: [595], fitsDrift: false, hear: Self.listen(cues, delay: delay))
        Self.report("constant \(delay) s (track in video, 1 stretch)", one)
    }

    // MARK: Drift (frame rate)

    @Test(arguments: [25.0 / (24000.0 / 1001), (24000.0 / 1001) / 25.0])
    func frameRateDrift(_ scale: Double) {
        let cues = R.film(seed: 22)
        let truth: Truth = { $0 / scale - 2 }
        Self.report(String(format: "drift %.4f× (file, local plan)", scale),
                    Self.run(cues, truth: truth, hear: Self.listen(cues, delay: -2, scale: scale)))
        Self.report(String(format: "drift %.4f× (track in video: delay only)", scale),
                    Self.run(cues, truth: truth, fitsDrift: false, hear: Self.listen(cues, delay: -2, scale: scale)))
        // A torrent early on: only the start has downloaded (plan's candidates 235, 150, 75 for position 300).
        Self.report(String(format: "drift %.4f× (torrent at 5 min)", scale),
                    Self.run(cues, truth: truth, stretches: [75, 150, 235], playhead: 300, hear: Self.listen(cues, delay: -2, scale: scale)))
    }

    // MARK: A cut partway

    @Test func offsetChangesPartway() {
        // An extra 5 s scene at 2500 s of the video: lines after it are 5 s later.
        let cues = R.film(seed: 23)
        let cut: TimeInterval = 2500
        let truth: Truth = { $0 < cut ? $0 : $0 + 5 }
        let hear: (TimeInterval, Int) -> [SubtitleAudioAlignment.HeardWord] = { from, i in
            (R.listen(cues, delay: 0, from: from, seed: UInt64(30 + i)).filter { $0.time < cut }
                + R.listen(cues, delay: 5, from: from, seed: UInt64(40 + i)).filter { $0.time >= cut + 5 }).sorted { $0.time < $1.time }
        }
        let o = Self.run(cues, truth: truth, hear: hear)
        Self.report("cut +5 s at 2500 s", o)
        let applied = o.result?.offset ?? SubtitleOffset()
        let before = cues.filter { $0.start < cut }.map { abs(applied.playerTime(forCueTime: $0.start) - truth($0.start)) }
        let after = cues.filter { $0.start >= cut }.map { abs(applied.playerTime(forCueTime: $0.start) - truth($0.start)) }
        print(String(format: "AUDIT cut: lines before the cut off by %.2f s (median), after by %.2f s",
                     SubtitleAudioAlignment.median(before), SubtitleAudioAlignment.median(after)))
    }

    // MARK: Sparse dialogue, music

    @Test(arguments: [10.0, 20.0, 40.0])
    func sparseDialogue(_ gap: Double) {
        // A line every `gap` seconds instead of every 3.5 s.
        let dense = R.film(seed: 24)
        let cues = dense.enumerated().map { i, c in
            SubtitleCue(start: 20 + Double(i) * gap, end: 20 + Double(i) * gap + (c.end - c.start), text: c.text)
        }.filter { $0.start < 7000 }
        let o = Self.run(cues, truth: { $0 + 3 }, hear: Self.listen(cues, delay: 3))
        Self.report("sparse, a line every \(Int(gap)) s, +3 s", o)
    }

    @Test func musicInTwoOfThreeStretches() {
        // Score or a song where two stretches fall: nothing heard, or lyrics that aren't in the file.
        let cues = R.film(seed: 25)
        let song = R.film(seed: 77)
        let silent = Self.run(cues, truth: { $0 + 4 }) { from, i in
            i == 0 ? R.listen(cues, delay: 4, from: from, seed: 50) : []
        }
        Self.report("music: 2 of 3 stretches silent, +4 s", silent)
        let lyrics = Self.run(cues, truth: { $0 + 4 }) { from, i in
            i == 0 ? R.listen(cues, delay: 4, from: from, seed: 51) : R.listen(song, delay: 0, from: from, seed: UInt64(52 + i))
        }
        Self.report("music: 2 of 3 stretches lyrics, +4 s", lyrics)
        // Only a little speech under the music in the one stretch with any.
        let thin = Self.run(cues, truth: { $0 + 4 }) { from, i in
            i == 0 ? R.listen(cues, delay: 4, from: from, length: 15, missed: 0.5, seed: 53) : []
        }
        Self.report("music: 15 s of half-heard speech only, +4 s", thin)
    }

    // MARK: Wrong subtitles: refused or applied?

    @Test func wrongSubtitlesAcrossSeeds() {
        var acceptedEpisode = 0, acceptedGibberish = 0
        let trials = 40
        for s in 0..<UInt64(trials) {
            let cues = R.film(seed: 100 + s)
            // Another episode's dialogue (same everyday words, same names).
            let other = R.film(seed: 500 + s)
            if Self.run(cues, truth: { $0 }, hear: { from, i in R.listen(other, delay: 0, from: from, seed: s * 7 + UInt64(i)) }).result != nil {
                acceptedEpisode += 1
            }
            // Wrong language: the recogniser turns foreign speech into common words of the subtitles' language.
            let wrong = Self.run(cues, truth: { $0 }) { from, i in
                var rng = R.Seeded(state: s * 13 + UInt64(i))
                return (0..<150).map { _ in
                    SubtitleAudioAlignment.HeardWord(R.vocabulary.randomElement(using: &rng)!, at: from + Double.random(in: 0..<60, using: &rng))
                }.sorted { $0.time < $1.time }
            }
            if wrong.result != nil { acceptedGibberish += 1 }
        }
        print("AUDIT wrong subtitles: another episode applied \(acceptedEpisode)/\(trials); wrong-language gibberish applied \(acceptedGibberish)/\(trials)")
    }

    // MARK: Cost

    @Test func whereFitSpendsItsTime() {
        let cues = R.film(seed: 27)
        let words = R.listen(cues, delay: 2, from: 600) + R.listen(cues, delay: 2, from: 3600, seed: 8)
        func time(_ name: String, _ body: () -> Void) {
            let t0 = Date(); body()
            print(String(format: "AUDIT cost %@: %.0f ms", name, Date().timeIntervalSince(t0) * 1000))
        }
        time("cueWords (2000 lines)") { _ = SubtitleAudioAlignment.cueWords(cues) }
        let cw = SubtitleAudioAlignment.cueWords(cues)
        time("pairs of the lines' words") { _ = SubtitleAudioAlignment.pairs(cw) }
        time("pairs of what was heard") { _ = SubtitleAudioAlignment.pairs(words.map { ($0.text, $0.time) }) }
        time("SoundCues.strip × 2000") { for c in cues { _ = SoundCues.strip(c.text) } }
        time("whole fit") { _ = SubtitleAudioAlignment.fit(words: words, cues: cues) }
    }

    // MARK: Hearing quality

    @Test(arguments: [0.15, 0.35, 0.5, 0.65])
    func misheardShare(_ misheard: Double) {
        let cues = R.film(seed: 26)
        let o = Self.run(cues, truth: { $0 - 1.5 }) { from, i in
            R.listen(cues, delay: -1.5, from: from, jitter: 0.5, missed: 0.2, misheard: misheard, seed: UInt64(60 + i))
        }
        Self.report("misheard \(Int(misheard * 100))%, −1.5 s", o)
    }
}
