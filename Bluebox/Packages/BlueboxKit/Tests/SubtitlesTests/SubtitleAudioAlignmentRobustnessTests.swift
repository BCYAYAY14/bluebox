import Foundation
@testable import Subtitles
import Testing

/// Sync to the Audio against what a recogniser really gives: words a little
/// off their time, some missed or misheard, stretches with no speech or
/// someone else's, and subtitles that aren't for this video at all.
@Suite struct SubtitleAudioAlignmentRobustnessTests {
    /// Same seed, same words: the tests don't flicker.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Everyday words, so lines share many word pairs as real dialogue does.
    static let vocabulary = ["i", "you", "we", "know", "think", "going", "to", "the", "a", "just", "what", "do", "don't",
                             "want", "here", "there", "now", "tell", "me", "him", "her", "it", "is", "was", "not", "can",
                             "get", "out", "come", "back", "look", "right", "okay", "please", "never", "said", "Jack", "Mara",
                             "house", "car", "money", "night", "door", "phone", "police", "time", "again", "really"]

    /// A film's worth of lines: one every 3.5 s for about two hours, 3 to 9 words each.
    static func film(seed: UInt64, lines: Int = 2000) -> [SubtitleCue] {
        var rng = Seeded(state: seed)
        return (0..<lines).map { i in
            let n = Int.random(in: 3...9, using: &rng)
            let text = (0..<n).map { _ in vocabulary.randomElement(using: &rng)! }.joined(separator: " ")
            let start = 20 + Double(i) * 3.5
            return SubtitleCue(start: start, end: start + Double.random(in: 1.5...3.2, using: &rng), text: text)
        }
    }

    /// What the recogniser hears in `[from, from + 60)` when the speech plays at
    /// `heard = cue / scale + delay`: words up to `jitter` s off their place in
    /// the line, a share missed and a share misheard.
    static func listen(_ cues: [SubtitleCue], delay: Double, scale: Double = 1, from: Double, length: Double = 60,
                       jitter: Double = 0.35, missed: Double = 0.15, misheard: Double = 0.15, seed: UInt64 = 7) -> [SubtitleAudioAlignment.HeardWord] {
        var rng = Seeded(state: seed)
        var out: [SubtitleAudioAlignment.HeardWord] = []
        for c in cues {
            let words = c.text.split(separator: " ").map(String.init)
            let step = (c.end - c.start) / Double(words.count)
            for (i, w) in words.enumerated() {
                let t = (c.start + step * (Double(i) + 0.5)) / scale + delay + Double.random(in: -jitter...jitter, using: &rng)
                guard t >= from, t < from + length else { continue }
                let roll = Double.random(in: 0..<1, using: &rng)
                if roll < missed { continue }
                out.append(.init(roll < missed + misheard ? "uh\(Int.random(in: 0..<50, using: &rng))" : w, at: t))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    // MARK: The delay

    @Test(arguments: [-42.0, -3.7, 0.0, 1.25, 8.0, 95.0])
    func recoversAKnownDelay(_ delay: Double) throws {
        let cues = Self.film(seed: 1)
        let words = Self.listen(cues, delay: delay, from: 1800)
        let r = try #require(SubtitleAudioAlignment.fit(words: words, cues: cues))
        #expect(abs(r.offset.seconds - delay) < 0.35, "found \(r.offset.seconds) for \(delay)")
        #expect(r.offset.scale == 1 && !r.fittedDrift)
    }

    @Test func keepsTheSpeedInUseWhenOnlyTheDelayIsFound() throws {
        // Speed set by hand earlier (25 → 23.976); one stretch can only place the delay.
        let scale = 25.0 / (24000.0 / 1001)
        let cues = Self.film(seed: 2)
        let words = Self.listen(cues, delay: 4, scale: scale, from: 2400)
        let r = try #require(SubtitleAudioAlignment.fit(words: words, cues: cues, current: SubtitleOffset(seconds: 0, scale: scale)))
        #expect(!r.fittedDrift)
        #expect(abs(r.offset.scale - SubtitleOffset(scale: scale).scale) < 1e-9)
        #expect(abs(r.offset.seconds - 4) < 0.35)
    }

    // MARK: Drift

    @Test func recoversDriftAcrossThreeStretches() throws {
        let scale = 25.0 / (24000.0 / 1001)
        let cues = Self.film(seed: 3)
        let words = Self.listen(cues, delay: -2, scale: scale, from: 900, seed: 1)
            + Self.listen(cues, delay: -2, scale: scale, from: 3500, seed: 2)
            + Self.listen(cues, delay: -2, scale: scale, from: 5600, seed: 3)
        let r = try #require(SubtitleAudioAlignment.fit(words: words, cues: cues))
        #expect(r.fittedDrift)
        #expect(abs(r.offset.scale - scale) < 0.001)
        for c in [cues[200], cues[1000], cues[1700]] {
            #expect(abs(r.offset.playerTime(forCueTime: c.start) - (c.start / scale - 2)) < 0.5)
        }
    }

    @Test func noDriftWhenThereIsNone() throws {
        let cues = Self.film(seed: 4)
        let words = Self.listen(cues, delay: 6.5, from: 1000, seed: 1) + Self.listen(cues, delay: 6.5, from: 5000, seed: 2)
        let r = try #require(SubtitleAudioAlignment.fit(words: words, cues: cues))
        #expect(!r.fittedDrift && r.offset.scale == 1)
        #expect(abs(r.offset.seconds - 6.5) < 0.35)
    }

    // MARK: Noise

    @Test func heavyMishearingStillPlacesTheDelay() throws {
        let cues = Self.film(seed: 5)
        let words = Self.listen(cues, delay: -12, from: 3000, jitter: 0.6, missed: 0.3, misheard: 0.35)
        let r = try #require(SubtitleAudioAlignment.fit(words: words, cues: cues))
        #expect(abs(r.offset.seconds + 12) < 0.5)
    }

    @Test func otherVoicesInTheStretchDoNotMoveIt() throws {
        // A third of what's heard is someone else's dialogue (a TV in the scene, a flashback's lines from elsewhere).
        let cues = Self.film(seed: 6)
        let real = Self.listen(cues, delay: 3, from: 2000)
        let stray = Self.listen(cues, delay: 3 - 700, from: 2000, missed: 0.6, seed: 9)
        let r = try #require(SubtitleAudioAlignment.fit(words: (real + stray).sorted { $0.time < $1.time }, cues: cues))
        #expect(abs(r.offset.seconds - 3) < 0.35)
    }

    @Test func aStretchWithoutDialogueDoesNotInventDrift() throws {
        // The second stretch is a song or a crowd: words heard, none of them these lines.
        let cues = Self.film(seed: 7)
        let other = Self.film(seed: 99)
        let words = Self.listen(cues, delay: 2, from: 1500) + Self.listen(other, delay: 0, from: 5200, seed: 4)
        let r = try #require(SubtitleAudioAlignment.fit(words: words, cues: cues))
        #expect(!r.fittedDrift && r.offset.scale == 1)
        #expect(abs(r.offset.seconds - 2) < 0.35)
    }

    // MARK: Refusals

    @Test func refusesSubtitlesForAnotherEpisode() {
        // Same characters, same everyday words: plenty of word pairs in common, none at a steady offset.
        let cues = Self.film(seed: 8)
        let other = Self.film(seed: 80)
        let words = Self.listen(other, delay: 0, from: 1200, seed: 1) + Self.listen(other, delay: 0, from: 4000, seed: 2)
            + Self.listen(other, delay: 0, from: 6000, seed: 3)
        #expect(SubtitleAudioAlignment.fit(words: words, cues: cues) == nil)
    }

    @Test func refusesNothingHeard() {
        #expect(SubtitleAudioAlignment.fit(words: [], cues: Self.film(seed: 9)) == nil)
        #expect(SubtitleAudioAlignment.fit(words: [.init("hello", at: 10)], cues: Self.film(seed: 9)) == nil)
    }

    @Test func refusesNoLines() {
        let words = Self.listen(Self.film(seed: 10), delay: 0, from: 600)
        #expect(SubtitleAudioAlignment.fit(words: words, cues: []) == nil)
        // Lines that are all sound cues have no words to match.
        let cues = (0..<50).map { SubtitleCue(start: Double($0) * 4, end: Double($0) * 4 + 2, text: "[music playing]") }
        #expect(SubtitleAudioAlignment.fit(words: words, cues: cues) == nil)
    }

    @Test func refusesAShortFileThatBarelyOverlaps() {
        // Ten lines, and the stretch heard is an hour after them.
        let cues = Array(Self.film(seed: 11).prefix(10))
        let words = Self.listen(Self.film(seed: 11), delay: 0, from: 3600)
        #expect(SubtitleAudioAlignment.fit(words: words, cues: cues) == nil)
    }

    @Test func refusesMoreThanTheDelayCanHold() {
        // Twenty minutes out is another cut of the film, not a delay to set (and SubtitleOffset stops at ten).
        let cues = Self.film(seed: 12)
        let words = Self.listen(cues, delay: 1200, from: 4000)
        #expect(SubtitleAudioAlignment.fit(words: words, cues: cues) == nil)
    }

    @Test func refusesOnlyCommonWords() {
        // "you know" over and over places nothing.
        let cues = (0..<200).map { SubtitleCue(start: Double($0) * 3, end: Double($0) * 3 + 2, text: "you know you know") }
        let words = Self.listen(cues, delay: 1, from: 100)
        #expect(SubtitleAudioAlignment.fit(words: words, cues: cues) == nil)
    }

    // MARK: Language

    @Test func readsTheLanguageOfTheLines() {
        let english = (0..<30).map { SubtitleCue(start: Double($0) * 3, end: Double($0) * 3 + 2, text: "Where were you last night? I waited for hours.") }
        let french = (0..<30).map { SubtitleCue(start: Double($0) * 3, end: Double($0) * 3 + 2, text: "Où étais-tu hier soir ? Je t'ai attendu pendant des heures.") }
        let spanish = (0..<30).map { SubtitleCue(start: Double($0) * 3, end: Double($0) * 3 + 2, text: "¿Dónde estabas anoche? Te esperé durante horas.") }
        #expect(SubtitleAudioAlignment.language(of: english) == "en")
        #expect(SubtitleAudioAlignment.language(of: french) == "fr")
        #expect(SubtitleAudioAlignment.language(of: spanish) == "es")
        #expect(SubtitleAudioAlignment.language(of: []) == nil)
        #expect(SubtitleAudioAlignment.language(of: [SubtitleCue(start: 0, end: 1, text: "[music]")]) == nil)
    }
}
