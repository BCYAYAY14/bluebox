import Foundation
@testable import Playback
import Testing

@Suite struct EqualizerSettingsTests {
    @Test func defaultsAreOffAndFlat() {
        let eq = EqualizerSettings()
        #expect(!eq.isOn && eq.gains == Array(repeating: 0, count: 10) && eq.preamp == 0)
        #expect(eq == .flat && eq.preset == .flat && !eq.isAudible)
        #expect(!AudioEffects().isActive)
    }

    @Test func clampsAndKeepsTenBands() {
        var eq = EqualizerSettings(gains: [20, -30, 3], preamp: 40)
        #expect(eq.gains == [12, -12, 3, 0, 0, 0, 0, 0, 0, 0])
        #expect(eq.preamp == 12)
        eq.setGain(99, band: 4)
        eq.setGain(.nan, band: 5)
        eq.setGain(5, band: 10)  // ignored
        #expect(eq.gains[4] == 12 && eq.gains[5] == 0 && eq.gains.count == 10)
        eq.gains = Array(repeating: -50, count: 14)
        #expect(eq.gains == Array(repeating: -12, count: 10))
        eq.preamp = -.infinity
        #expect(eq.preamp == 0)
    }

    @Test func codableRoundTrip() throws {
        let eq = EqualizerSettings(isOn: true, gains: [1, 2, 3, 4, 5, -1, -2, -3, -4, -5.5], preamp: -2.5)
        let back = try JSONDecoder().decode(EqualizerSettings.self, from: JSONEncoder().encode(eq))
        #expect(back == eq)
        let fx = AudioEffects(dialogueBoost: true, equalizer: eq)
        #expect(fx.equalizer.preset == nil)
    }

    @Test func decodesLeniently() throws {
        func decode(_ json: String) throws -> EqualizerSettings {
            try JSONDecoder().decode(EqualizerSettings.self, from: Data(json.utf8))
        }
        let empty = try decode("{}")
        #expect(empty == EqualizerSettings())
        let short = try decode(#"{"isOn": true, "gains": [3, 40]}"#)
        #expect(short.isOn && short.gains == [3, 12, 0, 0, 0, 0, 0, 0, 0, 0] && short.preamp == 0)
        let long = try decode(#"{"gains": [1,1,1,1,1,1,1,1,1,1,1,1], "preamp": -99}"#)
        #expect(long.gains == Array(repeating: 1, count: 10) && long.preamp == -12 && !long.isOn)
        let wrongTypes = try decode(#"{"isOn": "yes", "gains": "loud", "preamp": null}"#)
        #expect(wrongTypes == EqualizerSettings())
    }

    @Test func presetsMatchWithinTolerance() {
        for preset in EqualizerPreset.allCases {
            #expect(preset.gains.count == 10)
            let eq = EqualizerSettings().applying(preset)
            #expect(eq.isOn && eq.preset == preset && eq.gains == preset.gains && eq.preamp == preset.preamp)
            #expect(eq.isAudible == (preset != .flat))
        }
        var nudged = EqualizerSettings().applying(.cinema)
        nudged.setGain(nudged.gains[3] + 0.04, band: 3)
        #expect(nudged.preset == .cinema)
        nudged.setGain(nudged.gains[3] + 0.5, band: 3)
        #expect(nudged.preset == nil)  // Custom
        nudged = nudged.applying(.cinema)
        nudged.preamp += 1
        #expect(nudged.preset == nil)
        #expect(EqualizerPreset.bassBoost.title == "Bass Boost")
    }

    @Test func activeWhenOnlyTheEqualizerIsAudible() {
        #expect(AudioEffects(equalizer: EqualizerSettings().applying(.music)).isActive)
        #expect(!AudioEffects(equalizer: EqualizerSettings(isOn: true)).isActive)          // on, flat
        #expect(!AudioEffects(equalizer: EqualizerSettings(gains: [6] + Array(repeating: 0, count: 9))).isActive)  // off
    }

    // MARK: VLC's combined curve

    @Test func combinesDialogueBoostAndEqualizerForVLC() throws {
        #expect(EqualizerCurve.combined(AudioEffects()) == nil)
        #expect(EqualizerCurve.combined(AudioEffects(nightMode: true, equalizer: EqualizerSettings(isOn: true))) == nil)

        let voice = try #require(EqualizerCurve.combined(AudioEffects(dialogueBoost: true)))
        #expect(voice.gains == EqualizerPreset.voice.gains && voice.preamp == EqualizerPreset.voice.preamp)

        let bass = EqualizerSettings().applying(.bassBoost)
        let both = try #require(EqualizerCurve.combined(AudioEffects(dialogueBoost: true, equalizer: bass)))
        #expect(both.gains == zip(EqualizerPreset.voice.gains, bass.gains).map { $0 + $1 })
        #expect(both.preamp == -7)

        // The extremes stay inside libVLC's ±20 dB (the clamp is a backstop).
        var loud = EqualizerSettings(isOn: true, gains: Array(repeating: 12, count: 10), preamp: -12)
        loud.setGain(-12, band: 0)
        let clamped = try #require(EqualizerCurve.combined(AudioEffects(dialogueBoost: true, equalizer: loud)))
        #expect(clamped.gains[5] == 17 && clamped.gains[0] == -16 && clamped.preamp == -15)
        #expect(EqualizerCurve(preamp: 0, gains: Array(repeating: 0, count: 10)).resampled(at: [31, 1000, 20000]) == [0, 0, 0])
    }

    @Test func resamplesOntoOtherBands() {
        let curve = EqualizerCurve(preamp: 0, gains: [6, 0, 0, 0, 2, 4, 0, 0, 0, -3])
        let vlc = curve.resampled(at: [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
        #expect(vlc[0] == 6)                  // below the lowest band: level
        #expect(abs(vlc[5] - 2) < 1e-9)       // on a band: its gain
        #expect(vlc[9] == -3)
        // 2 kHz is log-midway between 1 and 3 kHz (in proportion log2(2)/log2(3)).
        #expect(abs(vlc[6] - (2 + 2 * log2(2) / log2(3))) < 1e-9)
        #expect(vlc.allSatisfy { $0 >= -3 && $0 <= 6 })
    }
}

@Suite struct EqualizerDSPTests {
    private func sine(_ hz: Double, amp: Float, seconds: Double, rate: Double = 48_000) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(sin(2 * .pi * hz * Double($0) / rate)) * amp }
    }

    private func rmsDB(_ x: ArraySlice<Float>) -> Double {
        10 * log10(Double(x.reduce(0) { $0 + $1 * $1 }) / Double(max(x.count, 1)) + 1e-20)
    }

    private func run(_ fx: AudioEffects, _ input: [Float], switches: AudioEffectsSwitch = AudioEffectsSwitch(),
                     dsp existing: AudioEffectsDSP? = nil) -> [Float] {
        switches.set(fx)
        let dsp = existing ?? { let d = AudioEffectsDSP(switches: switches); d.prepare(sampleRate: 48_000, channels: 2); return d }()
        var l = input, r = input
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                var start = 0
                while start < lp.count {
                    let n = min(512, lp.count - start)
                    dsp.process([lp.baseAddress! + start, rp.baseAddress! + start], stride: 1, frames: n)
                    start += n
                }
            }
        }
        #expect(zip(l, r).allSatisfy { $0 == $1 || ($0.isNaN && $1.isNaN) })  // a mono signal stays mono
        return l
    }

    private func eq(band: Int, _ dB: Double) -> AudioEffects {
        var e = EqualizerSettings(isOn: true)
        e.setGain(dB, band: band)
        return AudioEffects(equalizer: e)
    }

    @Test func flatEqualizerLeavesTheSignalAlone() {
        let input = sine(440, amp: 0.5, seconds: 0.2)
        #expect(run(AudioEffects(equalizer: EqualizerSettings(isOn: true)), input) == input)
        // Through the filters at 0 dB (a band set and set back): unchanged within rounding.
        let switches = AudioEffectsSwitch()
        let dsp = AudioEffectsDSP(switches: switches)
        dsp.prepare(sampleRate: 48_000, channels: 2)
        _ = run(eq(band: 4, 6), input, switches: switches, dsp: dsp)
        var zero = EqualizerSettings(isOn: true, preamp: 0.1)  // audible only by 0.1 dB of preamp
        zero.setGain(0, band: 4)
        let out = run(AudioEffects(equalizer: zero), input, switches: switches, dsp: dsp)
        let gain = Float(pow(10, 0.1 / 20))
        let tail = 4800...
        #expect(zip(out[tail], input[tail]).allSatisfy { abs($0 - $1 * gain) < 1e-3 })
    }

    @Test func aBandRaisesItsFrequencyAndLeavesOthers() {
        let tail = 9600...
        for (band, hz) in [(4, 1000.0), (0, 60), (7, 12000)] {
            let near = sine(hz, amp: 0.1, seconds: 0.5)
            let raised = rmsDB(run(eq(band: band, 6), near)[tail]) - rmsDB(near[tail])
            #expect(abs(raised - 6) < 0.3, "band \(band): \(raised) dB")
        }
        // Far from 1 kHz: 60 Hz and 12 kHz move by a fraction of a dB.
        for hz in [60.0, 12000] {
            let far = sine(hz, amp: 0.1, seconds: 0.5)
            let moved = rmsDB(run(eq(band: 4, 6), far)[tail]) - rmsDB(far[tail])
            #expect(abs(moved) < 0.5, "\(hz) Hz: \(moved) dB")
        }
        // A cut works the other way.
        let tone = sine(3000, amp: 0.1, seconds: 0.5)
        let cut = rmsDB(run(eq(band: 5, -9), tone)[tail]) - rmsDB(tone[tail])
        #expect(abs(cut + 9) < 0.3)
    }

    @Test func preampScalesTheLevel() {
        let tone = sine(800, amp: 0.1, seconds: 0.3)
        let out = run(AudioEffects(equalizer: EqualizerSettings(isOn: true, preamp: -6)), tone)
        #expect(abs(rmsDB(out[4800...]) - rmsDB(tone[4800...]) + 6) < 0.2)
    }

    @Test func liveChangesTakeEffectWithoutNewFilters() {
        // One DSP, the switch changed between buffers, as a slider drag would.
        let switches = AudioEffectsSwitch()
        let dsp = AudioEffectsDSP(switches: switches)
        dsp.prepare(sampleRate: 48_000, channels: 2)
        let tone = sine(1000, amp: 0.1, seconds: 0.3)
        let tail = 4800...
        let up = run(eq(band: 4, 6), tone, switches: switches, dsp: dsp)
        let down = run(eq(band: 4, -6), tone, switches: switches, dsp: dsp)
        #expect(abs(rmsDB(up[tail]) - rmsDB(tone[tail]) - 6) < 0.3)
        #expect(abs(rmsDB(down[tail]) - rmsDB(tone[tail]) + 6) < 0.3)
        // Off again: bypassed, bit for bit.
        #expect(run(AudioEffects(), tone, switches: switches, dsp: dsp) == tone)
    }

    @Test func boostsNeverClipOrMakeNaNs() {
        // Full-scale bass through every band at +12: the limiter holds it under full scale.
        let loud = zip(sine(60, amp: 0.9, seconds: 0.5), sine(14000, amp: 0.09, seconds: 0.5)).map { $0 + $1 }
        let all = AudioEffects(dialogueBoost: true, equalizer: EqualizerSettings(isOn: true, gains: Array(repeating: 12, count: 10), preamp: 12))
        let out = run(all, loud)
        #expect(out.allSatisfy { $0.isFinite && abs($0) <= 1 })
        // Night Mode on top, and a NaN in the source: finite again straight after.
        var withNaN = loud
        withNaN[1000] = .nan
        let night = run(AudioEffects(dialogueBoost: true, nightMode: true, equalizer: all.equalizer), withNaN)
        #expect(night[4096...].allSatisfy { $0.isFinite && abs($0) <= 1 })
        // Silence and DC stay finite.
        #expect(run(all, [Float](repeating: 0, count: 4800)).allSatisfy { $0 == 0 })
        #expect(run(all, [Float](repeating: 0.5, count: 4800)).allSatisfy { $0.isFinite })
    }

    @Test func interleavedMatchesPlanar() {
        let fx = AudioEffects(equalizer: EqualizerSettings().applying(.headphones))
        let tone = zip(sine(200, amp: 0.2, seconds: 0.05), sine(9000, amp: 0.2, seconds: 0.05)).map { $0 + $1 }
        let planar = run(fx, tone)
        let switches = AudioEffectsSwitch()
        switches.set(fx)
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
        #expect(zip(left, planar).allSatisfy { abs($0 - $1) < 1e-5 })
    }

    @Test func switchCarriesTheEqualizer() {
        let switches = AudioEffectsSwitch()
        let fx = AudioEffects(nightMode: true, equalizer: EqualizerSettings(isOn: true, gains: [1.23, -4.5, 12, -12, 0, 0, 0, 0, 7.7, -0.1], preamp: -3.3))
        let before = switches.equalizerGeneration
        switches.set(fx)
        let after = switches.equalizerGeneration
        #expect(after != before && after % 2 == 0)
        let back = switches.value
        #expect(back.nightMode && !back.dialogueBoost && back.equalizer.isOn)
        #expect(zip(back.equalizer.gains, fx.equalizer.gains).allSatisfy { abs($0 - $1) <= 0.05 })
        #expect(abs(back.equalizer.preamp + 3.3) <= 0.05)
        // The same gains again (or a switch flipped): no new generation, so no rebuild.
        var same = fx
        same.dialogueBoost = true
        switches.set(same)
        #expect(switches.equalizerGeneration == after)
        var buffer = [Float](repeating: 0, count: 11)
        let seen = buffer.withUnsafeMutableBufferPointer { switches.readEqualizer(after: after, into: $0) }
        #expect(seen == nil)
    }
}
