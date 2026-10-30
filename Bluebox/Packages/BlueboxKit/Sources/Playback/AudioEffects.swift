import Foundation
import Synchronization

/// Listening aids applied to the soundtrack.
public struct AudioEffects: Equatable, Hashable, Sendable {
    /// Lifts the centre channel and the speech frequencies so dialogue cuts
    /// through music and effects.
    public var dialogueBoost = false
    /// A compressor and limiter: loud scenes come down, quiet ones come up.
    public var nightMode = false
    /// A ten-band equaliser, after Dialogue Boost and before Night Mode.
    public var equalizer = EqualizerSettings()

    public init(dialogueBoost: Bool = false, nightMode: Bool = false, equalizer: EqualizerSettings = .init()) {
        self.dialogueBoost = dialogueBoost; self.nightMode = nightMode; self.equalizer = equalizer
    }

    public var isActive: Bool { dialogueBoost || nightMode || equalizer.isAudible }

    var bits: UInt8 { (dialogueBoost ? 1 : 0) | (nightMode ? 2 : 0) | (equalizer.isAudible ? 4 : 0) }
}

/// The settings the audio thread reads, without locks or allocation.
///
/// The switches are one byte. The equaliser is eleven signed bytes (ten bands
/// and the preamp, in tenths of a dB: ±12 dB fits, and 0.1 dB is below what
/// anyone hears) over two words, the second also holding a generation count
/// in its top half. Only the main thread writes, seqlock style: the
/// generation goes odd, the low word is stored, then the high word with the
/// data and the next even generation. A reader takes the high word, the low
/// word, then the high word again, and keeps what it read only if the
/// generation was even and unchanged; otherwise it tries again on the next
/// buffer. So the DSP rebuilds its filters only when the equaliser changed,
/// and never from half an update.
final class AudioEffectsSwitch: Sendable {
    private let bits = Atomic<UInt8>(0)
    private let eqLow = Atomic<UInt64>(0)   // bands 0–7
    private let eqHigh = Atomic<UInt64>(0)  // bands 8, 9, preamp; generation in bits 32–63

    struct Flags { let dialogueBoost, nightMode, equalizer: Bool }

    var flags: Flags {
        let b = bits.load(ordering: .relaxed)
        return Flags(dialogueBoost: b & 1 != 0, nightMode: b & 2 != 0, equalizer: b & 4 != 0)
    }

    /// What was last set, rebuilt (allocates: not for the audio thread).
    var value: AudioEffects {
        let f = flags
        var eq = EqualizerSettings(isOn: f.equalizer)
        var raw = [Float](repeating: 0, count: 11)
        raw.withUnsafeMutableBufferPointer { _ = readEqualizer(after: .max, into: $0) }
        eq.gains = raw[0..<10].map(Double.init); eq.preamp = Double(raw[10])
        return AudioEffects(dialogueBoost: f.dialogueBoost, nightMode: f.nightMode, equalizer: eq)
    }

    /// Main thread only.
    func set(_ e: AudioEffects) {
        let tenths = (e.equalizer.gains + [e.equalizer.preamp]).map { UInt64(UInt8(bitPattern: Int8(($0 * 10).rounded()))) }
        var low: UInt64 = 0
        for i in 0..<8 { low |= tenths[i] << (8 * UInt64(i)) }
        let data = tenths[8] | tenths[9] << 8 | tenths[10] << 16
        let high = eqHigh.load(ordering: .relaxed)
        if low != eqLow.load(ordering: .relaxed) || data != high & 0xFF_FFFF {
            let generation = high >> 32
            eqHigh.store((generation &+ 1) << 32 | high & 0xFFFF_FFFF, ordering: .releasing)
            eqLow.store(low, ordering: .releasing)
            eqHigh.store((generation &+ 2) << 32 | data, ordering: .releasing)
        }
        bits.store(e.bits, ordering: .releasing)
    }

    /// The equaliser's generation; always even when no update is under way.
    var equalizerGeneration: UInt32 { UInt32(truncatingIfNeeded: eqHigh.load(ordering: .acquiring) >> 32) }

    /// Writes the ten band gains then the preamp (dB) into `out` (11 floats)
    /// and returns their generation, unless that is `seen` or an update is
    /// under way (nil: try again later). No locks, no allocation.
    func readEqualizer(after seen: UInt32, into out: UnsafeMutableBufferPointer<Float>) -> UInt32? {
        let first = eqHigh.load(ordering: .acquiring)
        let generation = UInt32(truncatingIfNeeded: first >> 32)
        guard generation != seen, generation & 1 == 0, out.count >= 11 else { return nil }
        let low = eqLow.load(ordering: .acquiring)
        guard eqHigh.load(ordering: .acquiring) == first else { return nil }
        func dB(_ word: UInt64, _ byte: Int) -> Float { Float(Int8(bitPattern: UInt8(truncatingIfNeeded: word >> (8 * UInt64(byte))))) / 10 }
        for i in 0..<8 { out[i] = dB(low, i) }
        out[8] = dB(first, 0); out[9] = dB(first, 1); out[10] = dB(first, 2)
        return generation
    }
}

/// Dialogue boost and night mode for float PCM, cheap enough for the audio thread.
///
/// - Dialogue boost: with three or more channels the centre (index 2 in
///   AVFoundation's L R C LFE Ls Rs order) is raised 4 dB through a speech
///   presence filter and the rest lowered 2 dB. In stereo, the mid signal
///   (what's common to both sides, where dialogue sits) goes through the
///   presence filter and up 2 dB while the side signal drops 3 dB.
/// - Equaliser: ten peaking filters per channel at
///   `EqualizerSettings.frequencies`, after the preamp. Peaking filters
///   throughout rather than shelves at the ends: each band is then exactly its
///   gain at its own frequency (what the sliders say), the lowest band stops
///   boosting subsonics nobody can hear but which eat headroom, and it's the
///   shape VLC's equaliser (band-passes) has too, so both engines sound alike.
///   Q follows the band spacing (`bandQ`): about an octave wide in the middle,
///   narrower where 12, 14 and 16 kHz crowd together, so neighbours add up
///   less there (with a constant Q 1.1 the Treble preset peaked at +14 dB
///   for a +6 dB curve; with these, +10). Coefficients are worked out on the
///   audio thread, into storage made in `prepare`, only when the switch's
///   generation changes; the filters' state is kept, so a slider drag doesn't click.
/// - Night mode: a linked feed-forward compressor (−30 dBFS threshold,
///   3:1, 10 ms attack, 250 ms release, +9 dB make-up) followed by a
///   limiter with a −1 dBFS ceiling. Gain is computed once per 32-frame block
///   and ramped across it. With the equaliser on and Night Mode off, the
///   limiter still runs (without the compressor) to catch what the boosts
///   push past full scale.
///
/// Not thread-safe: one instance per audio stream, used from one thread.
final class AudioEffectsDSP: @unchecked Sendable {
    let switches: AudioEffectsSwitch
    private(set) var sampleRate: Double = 48_000
    private var presence: [Biquad] = []
    /// Channel c's band b is `eq[c * 10 + b]`.
    private var eq: [Biquad] = []
    private var eqChannels = 0
    /// The switch's last read: ten gains then the preamp, in dB.
    private var eqRead = [Float](repeating: 0, count: 11)
    /// The generation `eq` was built for; odd (never a real one) to rebuild.
    private var eqGeneration = UInt32.max
    private var eqPreamp: Float = 1
    private var envelope: Float = 0
    private var compGain: Float = 1
    private var limitGain: Float = 1
    private var attackCoef: Float = 0
    private var releaseCoef: Float = 0
    private var limitRelease: Float = 0
    static let block = 32
    static let bands = 10

    // Compressor settings.
    static let threshold: Float = -30
    static let ratio: Float = 3
    static let makeup: Float = 9
    static let ceiling: Float = 0.89  // −1 dBFS

    /// Each band's Q from its distance to its neighbours: the mean gap in
    /// octaves as the bandwidth, clamped to 0.7…3 (0.9 at 60 Hz, 1.2 at
    /// 1 kHz, 2.3 at 12 kHz, 3 at 14 and 16 kHz).
    static let bandQ: [Double] = {
        let octaves = EqualizerSettings.frequencies.map { log2($0) }
        return octaves.indices.map { i in
            let gaps = [i - 1, i + 1].filter(octaves.indices.contains).map { abs(octaves[$0] - octaves[i]) }
            let width = pow(2, gaps.reduce(0, +) / Double(gaps.count))
            return min(max(width.squareRoot() / (width - 1), 0.7), 3)
        }
    }()

    init(switches: AudioEffectsSwitch) {
        self.switches = switches
        prepare(sampleRate: 48_000, channels: 2)
    }

    func prepare(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        presence = (0..<max(channels, 1)).map { _ in Biquad.peaking(frequency: 2800, q: 0.9, gainDB: 5, sampleRate: self.sampleRate) }
        eqChannels = max(channels, 1)
        eq = Array(repeating: Biquad.peaking(frequency: 1000, q: 1, gainDB: 0, sampleRate: self.sampleRate),
                   count: eqChannels * Self.bands)
        eqGeneration = .max
        envelope = 0; compGain = 1; limitGain = 1
        let blockSeconds = Double(Self.block) / self.sampleRate
        attackCoef = Float(1 - exp(-blockSeconds / 0.010))
        releaseCoef = Float(1 - exp(-blockSeconds / 0.250))
        limitRelease = Float(1 - exp(-blockSeconds / 0.080))
    }

    /// Processes `frames` frames in place. `channels[c]` points at channel c's
    /// first sample; consecutive frames are `stride` floats apart (1 when
    /// non-interleaved, the channel count when interleaved).
    func process(_ channels: [UnsafeMutablePointer<Float>], stride: Int, frames: Int) {
        let fx = switches.flags
        guard fx.dialogueBoost || fx.nightMode || fx.equalizer, !channels.isEmpty, frames > 0 else {
            compGain = 1; limitGain = 1; envelope = 0
            return
        }
        if fx.dialogueBoost { boostDialogue(channels, stride: stride, frames: frames) }
        if fx.equalizer { equalize(channels, stride: stride, frames: frames) }
        if fx.nightMode || fx.equalizer {
            dynamics(channels, stride: stride, frames: frames, compress: fx.nightMode)
        } else {
            compGain = 1; limitGain = 1; envelope = 0
        }
    }

    /// Rebuilds the band filters when the equaliser changed since the last buffer.
    private func refreshEqualizer() {
        let read = eqRead.withUnsafeMutableBufferPointer { switches.readEqualizer(after: eqGeneration, into: $0) }
        guard let read else { return }
        eqGeneration = read
        eqPreamp = pow(10, eqRead[10] / 20)
        let rate = sampleRate
        eq.withUnsafeMutableBufferPointer { bq in
            for b in 0..<Self.bands {
                let f = EqualizerSettings.frequencies[b], q = Self.bandQ[b], g = Double(eqRead[b])
                for c in 0..<eqChannels { bq[c * Self.bands + b].setPeaking(frequency: f, q: q, gainDB: g, sampleRate: rate) }
            }
        }
    }

    private func equalize(_ ch: [UnsafeMutablePointer<Float>], stride: Int, frames: Int) {
        refreshEqualizer()
        let pre = eqPreamp
        eq.withUnsafeMutableBufferPointer { bq in
            for c in 0..<min(ch.count, eqChannels) {
                let p = ch[c], base = c * Self.bands
                for i in 0..<frames {
                    var x = p[i * stride] * pre
                    for b in base..<(base + Self.bands) { x = bq[b].process(x) }
                    p[i * stride] = x
                }
                // A NaN in the source would otherwise live in the filters for good.
                if !bq[base + Self.bands - 1].z1.isFinite { for b in base..<(base + Self.bands) { bq[b].reset() } }
            }
        }
    }

    private func boostDialogue(_ ch: [UnsafeMutablePointer<Float>], stride: Int, frames: Int) {
        switch ch.count {
        case 1:
            for i in 0..<frames { ch[0][i * stride] = presence[0].process(ch[0][i * stride]) }
        case 2:
            let midGain: Float = 1.26, sideGain: Float = 0.71  // +2 dB, −3 dB
            for i in 0..<frames {
                let l = ch[0][i * stride], r = ch[1][i * stride]
                let mid = presence[0].process((l + r) * 0.5) * midGain
                let side = (l - r) * 0.5 * sideGain
                ch[0][i * stride] = mid + side
                ch[1][i * stride] = mid - side
            }
        default:
            let centreGain: Float = 1.58, otherGain: Float = 0.79  // +4 dB, −2 dB
            for c in ch.indices {
                let p = ch[c]
                if c == 2 {
                    for i in 0..<frames { p[i * stride] = presence[c].process(p[i * stride]) * centreGain }
                } else if c != 3 {  // leave the LFE alone
                    for i in 0..<frames { p[i * stride] *= otherGain }
                }
            }
        }
        // A NaN in the source would otherwise live in the filter for good.
        for c in presence.indices where !presence[c].z1.isFinite { presence[c].reset() }
    }

    /// The compressor and limiter, or with `compress` false the limiter alone.
    private func dynamics(_ ch: [UnsafeMutablePointer<Float>], stride: Int, frames: Int, compress: Bool) {
        var start = 0
        while start < frames {
            let n = min(Self.block, frames - start)
            var peak: Float = 0
            for p in ch {
                for i in start..<(start + n) { peak = max(peak, abs(p[i * stride])) }
            }
            var targetComp: Float = 1
            if compress {
                // Envelope follower on block peaks.
                envelope += (peak - envelope) * (peak > envelope ? attackCoef : releaseCoef)
                let levelDB = 20 * log10(max(envelope, 1e-6))
                let overDB = max(0, levelDB - Self.threshold)
                let gainDB = -overDB * (1 - 1 / Self.ratio) + Self.makeup
                targetComp = pow(10, gainDB / 20)
            }
            // Limiter: never let this block's peak exceed the ceiling.
            let needed = peak * targetComp > Self.ceiling ? Self.ceiling / (peak * targetComp) : 1
            let targetLimit = needed < limitGain ? needed : limitGain + (needed - limitGain) * limitRelease
            let fromGain = compGain * limitGain
            let toGain = targetComp * targetLimit
            // Ramp up smoothly; when the gain must drop, drop at once (no overshoot).
            let ramp = toGain > fromGain
            for i in 0..<n {
                let g = ramp ? fromGain + (toGain - fromGain) * Float(i + 1) / Float(n) : toGain
                for p in ch {
                    let v = p[(start + i) * stride] * g
                    p[(start + i) * stride] = min(max(v, -1), 1)
                }
            }
            compGain = targetComp; limitGain = targetLimit
            start += n
        }
    }
}

/// A second-order filter (RBJ cookbook), transposed direct form II.
struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var z1: Float = 0, z2: Float = 0

    static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        var f = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
        f.setPeaking(frequency: frequency, q: q, gainDB: gainDB, sampleRate: sampleRate)
        return f
    }

    /// New coefficients, the state kept (no click when a gain moves).
    mutating func setPeaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        b0 = Float((1 + alpha * a) / a0); b1 = Float(-2 * cosw / a0); b2 = Float((1 - alpha * a) / a0)
        a1 = Float(-2 * cosw / a0); a2 = Float((1 - alpha / a) / a0)
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
