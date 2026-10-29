import Foundation
@testable import Playback
import Testing

@Suite struct AudioEffectsTests {
    private func run(_ fx: AudioEffects, left: [Float], right: [Float], sampleRate: Double = 48_000) -> ([Float], [Float]) {
        let switches = AudioEffectsSwitch()
        switches.set(fx)
        let dsp = AudioEffectsDSP(switches: switches)
        dsp.prepare(sampleRate: sampleRate, channels: 2)
        var l = left, r = right
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                // Feed in 512-frame slices, like a tap.
                var start = 0
                while start < lp.count {
                    let n = min(512, lp.count - start)
                    dsp.process([lp.baseAddress! + start, rp.baseAddress! + start], stride: 1, frames: n)
                    start += n
                }
            }
        }
        return (l, r)
    }

    private func sine(_ hz: Double, amp: Float, seconds: Double, rate: Double = 48_000) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(sin(2 * .pi * hz * Double($0) / rate)) * amp }
    }

    private func rms(_ x: ArraySlice<Float>) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))) }

    @Test func offIsBitExact() {
        let input = sine(1000, amp: 0.5, seconds: 0.1)
        let (l, r) = run(AudioEffects(), left: input, right: input)
        #expect(l == input && r == input)
    }

    @Test func dialogueBoostLiftsCentreSpeechOverSides() {
        // Speech-band tone in the centre; the same tone only in one side.
        let tone = sine(2800, amp: 0.2, seconds: 0.5)
        let centre = run(AudioEffects(dialogueBoost: true), left: tone, right: tone)
        let wide = run(AudioEffects(dialogueBoost: true), left: tone, right: tone.map { -$0 })
        let tail = 12_000...
        #expect(rms(centre.0[tail]) > rms(tone[tail]) * 1.5)  // presence +5 dB and mid +2 dB
        #expect(rms(wide.0[tail]) < rms(tone[tail]))           // side −3 dB
    }

    @Test func nightModeEvensOutLoudAndQuiet() {
        let quiet = sine(440, amp: 0.01, seconds: 1)
        let loud = sine(440, amp: 0.95, seconds: 1)
        let q = run(AudioEffects(nightMode: true), left: quiet, right: quiet).0
        let l = run(AudioEffects(nightMode: true), left: loud, right: loud).0
        let tail = 24_000...
        // Quiet comes up (make-up gain), loud comes down; the gap narrows.
        #expect(rms(q[tail]) > rms(quiet[tail]) * 2)
        #expect(rms(l[tail]) < rms(loud[tail]))
        let before = rms(loud[tail]) / rms(quiet[tail])
        let after = rms(l[tail]) / rms(q[tail])
        #expect(after < before / 4)
        // The limiter holds the ceiling.
        #expect(l.allSatisfy { abs($0) <= 1 })
        #expect(l[tail].max()! <= AudioEffectsDSP.ceiling + 0.02)
    }

    @Test func interleavedMatchesPlanar() {
        let tone = sine(1000, amp: 0.3, seconds: 0.05)
        let planar = run(AudioEffects(dialogueBoost: true, nightMode: true), left: tone, right: tone)
        let switches = AudioEffectsSwitch()
        switches.set(AudioEffects(dialogueBoost: true, nightMode: true))
        let dsp = AudioEffectsDSP(switches: switches)
        dsp.prepare(sampleRate: 48_000, channels: 2)
        var inter = tone.flatMap { [$0, $0] }
        inter.withUnsafeMutableBufferPointer { p in
            var start = 0
            while start < tone.count {
                let n = min(512, tone.count - start)
                let base = p.baseAddress! + start * 2
                dsp.process([base, base + 1], stride: 2, frames: n)
                start += n
            }
        }
        let left = stride(from: 0, to: inter.count, by: 2).map { inter[$0] }
        #expect(zip(left, planar.0).allSatisfy { abs($0 - $1) < 1e-5 })
    }
}
