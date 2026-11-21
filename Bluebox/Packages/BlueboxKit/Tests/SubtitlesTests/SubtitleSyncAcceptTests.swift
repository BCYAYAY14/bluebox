import Foundation
@testable import Subtitles
import Testing

/// Sync to the Audio accepts only what the stretches agree on: a speed only
/// when it's a real frame-rate change, stretches counted by clip however
/// close, a stretch at the playhead when they disagree, and nothing chance
/// can produce. The cases the audit measured, before and after.
@Suite struct SubtitleSyncAcceptTests {
    typealias R = SubtitleAudioAlignmentRobustnessTests
    static let film25 = 25.0 / (24000.0 / 1001)

    /// What three stretches hear, numbered as the player numbers them.
    static func heard(_ cues: [SubtitleCue], at starts: [TimeInterval], delay: (Int) -> Double = { _ in 0 }, scale: Double = 1,
                      seed: UInt64 = 1) -> [SubtitleAudioAlignment.HeardWord] {
        starts.enumerated().flatMap { i, from in
            R.listen(cues, delay: delay(i), scale: scale, from: from, seed: seed + UInt64(i)).map { .init($0.text, at: $0.time, clip: i) }
        }
    }

    @Test func driftIsFittedFromATorrentsFirstMinutes() throws {
        // Three stretches under a minute apart (a torrent five minutes in) used
        // to merge into one: −6 s applied, lines up to 283 s off by the end.
        let cues = R.film(seed: 22)
        let words = Self.heard(cues, at: [75, 150, 235], delay: { _ in -2 }, scale: Self.film25)
        let r = try #require(SubtitleAudioAlignment.fit(words: words, cues: cues, playhead: 300))
        #expect(r.fittedDrift)
        // Snapped to the real ratio, so the end of a two-hour film lands too.
        #expect(abs(r.offset.scale - SubtitleOffset(scale: Self.film25).scale) < 1e-4)
        for c in [cues[100], cues[1000], cues[1999]] {
            #expect(abs(r.offset.playerTime(forCueTime: c.start) - (c.start / Self.film25 - 2)) < 0.3)
        }
    }

    @Test func driftADelayCantHoldIsRefusedNotApplied() {
        // A track in the video (only a delay can move it) with lines made for 25 fps:
        // the delay that fits one stretch was 120 s and more off elsewhere.
        let cues = R.film(seed: 22)
        let words = Self.heard(cues, at: [595], delay: { _ in -2 }, scale: Self.film25)
        #expect(SubtitleAudioAlignment.match(words: words, cues: cues, fitsDrift: false, playhead: 600) == .refused(.drifts))
    }

    @Test func aSpeedThatIsntAFrameRateChangeIsNeverApplied() {
        // 1.1% fast is no frame-rate change: noise or a misread stretch.
        let cues = R.film(seed: 31)
        let words = Self.heard(cues, at: [595, 3600, 5400], scale: 1.011)
        let r = SubtitleAudioAlignment.fit(words: words, cues: cues, playhead: 600)
        #expect(r == nil || r?.offset.scale == 1)
    }

    @Test func oneStretchReadLateDoesNotInventDrift() throws {
        // A recording in sync, with one clip reporting its start 1.95 s late (as an
        // M4A did): "+2.8 s · 1.011×" was applied, lines then 0.9 s off on average.
        let cues = R.film(seed: 32)
        let words = Self.heard(cues, at: [595, 3600, 5400], delay: { $0 == 1 ? -1.95 : 0 })
        let r = try #require(SubtitleAudioAlignment.fit(words: words, cues: cues, playhead: 600))
        #expect(r.offset.scale == 1)
        #expect(abs(r.offset.seconds) < 0.3)
    }

    @Test func aCutPartwayTakesTheDelayAtThePlayheadAndSaysSo() throws {
        // An extra 5 s scene at 2500 s: the stretches disagree.
        let cues = R.film(seed: 23)
        let words = Self.heard(cues, at: [595, 3600, 5400], delay: { $0 == 0 ? 0 : 5 })
        let early = try #require(SubtitleAudioAlignment.fit(words: words, cues: cues, playhead: 600))
        #expect(early.isLocal && abs(early.offset.seconds) < 0.3)
        let late = try #require(SubtitleAudioAlignment.fit(words: words, cues: cues, playhead: 5420))
        #expect(late.isLocal && abs(late.offset.seconds - 5) < 0.3)
    }

    @Test func stretchesThatAgreeAreNotLocal() throws {
        let cues = R.film(seed: 33)
        let r = try #require(SubtitleAudioAlignment.fit(words: Self.heard(cues, at: [595, 3600, 5400], delay: { _ in 3 }), cues: cues, playhead: 600))
        #expect(!r.isLocal && !r.fittedDrift && abs(r.offset.seconds - 3) < 0.3)
    }

    @Test func gibberishIsNeverApplied() {
        // Speech in another language comes out as common words of this one (was applied 5 times in 40).
        var accepted = 0
        for s in 0..<UInt64(40) {
            let cues = R.film(seed: 100 + s)
            let words = [595.0, 3600, 5400].enumerated().flatMap { i, from -> [SubtitleAudioAlignment.HeardWord] in
                var rng = R.Seeded(state: s * 13 + UInt64(i))
                return (0..<150).map { _ in .init(R.vocabulary.randomElement(using: &rng)!, at: from + Double.random(in: 0..<60, using: &rng), clip: i) }
            }
            if SubtitleAudioAlignment.fit(words: words, cues: cues, playhead: 600) != nil { accepted += 1 }
        }
        #expect(accepted == 0)
    }

    @Test func speedsAreTheRealFrameRateChanges() {
        let ks = SubtitleAudioAlignment.speeds(videoFrameRate: nil).map(\.k)
        for k in [25 / (24000.0 / 1001), 24 / (24000.0 / 1001), 25.0 / 24, 30 / (30000.0 / 1001)] {
            #expect(ks.contains { abs($0 - k) < 1e-9 } && ks.contains { abs($0 - 1 / k) < 1e-9 })
        }
        // A 23.976 video: only speeds that end at 23.976.
        #expect(SubtitleAudioAlignment.speeds(videoFrameRate: 23.976).allSatisfy { abs($0.video - 24000.0 / 1001) < 0.01 })
    }
}
