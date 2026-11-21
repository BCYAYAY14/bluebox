import Foundation
import Subtitles
import SwiftUI
import Testing
@testable import Features

/// Sync to the Audio's matching runs off the main actor: a fit reads every
/// line's words (a couple of hundred milliseconds in a debug build), and the
/// player has to keep drawing meanwhile. Prints "MAIN ACTOR" with the
/// longest the main actor was held, matching there and off it.
@MainActor
@Suite struct SubtitleSyncMainActorTests {
    /// A two-hour film's lines and three stretches heard 2 s late.
    static func film() -> ([SubtitleCue], [SubtitleAudioAlignment.HeardWord]) {
        let vocabulary = ["where", "were", "you", "last", "night", "waited", "station", "train", "late", "again", "phone", "bridge",
                          "Margaret", "garden", "party", "lemon", "cake", "wine", "cat", "coat", "weather", "library", "museum"]
        var seed: UInt64 = 42
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let cues = (0..<2000).map { i in
            // A word of its own in each line, so pairs can be placed.
            let text = (0..<(3 + next() % 6)).map { _ in vocabulary[next() % vocabulary.count] }.joined(separator: " ") + " line\(i)"
            return SubtitleCue(start: 20 + Double(i) * 3.5, end: 22.5 + Double(i) * 3.5, text: text)
        }
        var words: [SubtitleAudioAlignment.HeardWord] = []
        for (clip, from) in [595.0, 3600, 5400].enumerated() {
            for c in cues where c.start + 2 >= from && c.start + 2 < from + 60 {
                let ws = c.text.split(separator: " ")
                for (i, w) in ws.enumerated() {
                    let at: TimeInterval = c.start + 2 + 2 * (Double(i) + 0.5) / Double(ws.count)
                    words.append(.init(String(w), at: at, clip: clip))
                }
            }
        }
        return (cues, words)
    }

    /// The longest the main actor went without running a 5 ms ticker while
    /// `work` ran, and how often the ticker ran during it.
    static func longestHold(_ work: @MainActor () async -> Void) async -> (longest: Duration, ticks: Int) {
        var last = ContinuousClock.now, longest = Duration.zero, ticks = 0, counting = false
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                let now = ContinuousClock.now
                longest = max(longest, now - last)
                last = now
                if counting { ticks += 1 }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        last = .now
        counting = true
        await work()
        counting = false
        // The ticker's first run after the work notices a hold at the very end.
        try? await Task.sleep(for: .milliseconds(20))
        ticker.cancel()
        return (longest, ticks)
    }

    @Test func matchingLeavesTheMainActorFree() async throws {
        let (cues, words) = Self.film()
        var onMain: SubtitleAudioAlignment.Outcome?, offMain: SubtitleAudioAlignment.Outcome?
        let before = await Self.longestHold {
            onMain = SubtitleAudioAlignment.match(words: words, cues: cues, playhead: 600)
        }
        let after = await Self.longestHold {
            offMain = await SubtitleAudioSync.match(words: words, cues: cues, current: .init(), fitsDrift: true, playhead: 600, videoFrameRate: nil)
        }
        print("MAIN ACTOR held \(before.longest.formatted(.units(allowed: [.milliseconds]))) matching on it (\(before.ticks) ticks meanwhile), "
              + "\(after.longest.formatted(.units(allowed: [.milliseconds]))) off it (\(after.ticks) ticks)")
        #expect(onMain == offMain)
        #expect(abs((offMain?.result?.offset.seconds ?? 0) - 2) < 0.3, "\(String(describing: offMain))")
        // On the main actor nothing else ran while it fitted; off it, the main
        // actor kept running (timings vary with load, this doesn't).
        #expect(before.ticks == 0)
        #expect(after.ticks >= 2)
    }

    @Test func subtitleKeysStepATenthOrASecond() {
        #expect(PlayerKeys.subtitleStep("{", modifiers: [.shift]) == -0.1)
        #expect(PlayerKeys.subtitleStep("}", modifiers: []) == 0.1)
        #expect(PlayerKeys.subtitleStep("{", modifiers: [.shift, .option]) == -1)
        // Keyboards that hand over what Option types with ⇧[ and ⇧] (US: ” and ’).
        #expect(PlayerKeys.subtitleStep("”", modifiers: [.shift, .option]) == -1)
        #expect(PlayerKeys.subtitleStep("’", modifiers: [.shift, .option]) == 1)
        #expect(PlayerKeys.subtitleStep("}", modifiers: [.option]) == 1)
        #expect(PlayerKeys.subtitleStep("}", modifiers: [.command]) == nil)
        #expect(PlayerKeys.subtitleStep("[", modifiers: []) == nil)
        #expect(ShortcutsPage.all.contains { $0.0 == "⌥{ ⌥}" })
    }
}
