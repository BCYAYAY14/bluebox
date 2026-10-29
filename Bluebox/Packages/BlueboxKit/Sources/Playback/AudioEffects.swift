import Foundation
import Synchronization

/// Listening aids applied to the soundtrack.
public struct AudioEffects: Equatable, Hashable, Sendable {
    /// Lifts the centre channel and the speech frequencies so dialogue cuts
    /// through music and effects.
    public var dialogueBoost = false
    /// A compressor and limiter: loud scenes come down, quiet ones come up.
    public var nightMode = false

    public init(dialogueBoost: Bool = false, nightMode: Bool = false) {
        self.dialogueBoost = dialogueBoost; self.nightMode = nightMode
    }

    public var isActive: Bool { dialogueBoost || nightMode }

    var bits: UInt8 { (dialogueBoost ? 1 : 0) | (nightMode ? 2 : 0) }
    init(bits: UInt8) { dialogueBoost = bits & 1 != 0; nightMode = bits & 2 != 0 }
}

/// The switches the audio thread reads, without locks.
final class AudioEffectsSwitch: Sendable {
    private let bits = Atomic<UInt8>(0)
    var value: AudioEffects { AudioEffects(bits: bits.load(ordering: .relaxed)) }
    func set(_ e: AudioEffects) { bits.store(e.bits, ordering: .relaxed) }
}

/// Dialogue boost and night mode for float PCM, cheap enough for the audio thread.
///
/// - Dialogue boost: with three or more channels the centre (index 2 in
///   AVFoundation's L R C LFE Ls Rs order) is raised 4 dB through a speech
///   presence filter and the rest lowered 2 dB. In stereo, the mid signal
///   (what's common to both sides, where dialogue sits) goes through the
///   presence filter and up 2 dB while the side signal drops 3 dB.
/// - Night mode: a linked feed-forward compressor (−30 dBFS threshold,
///   3:1, 10 ms attack, 250 ms release, +9 dB make-up) followed by a
///   limiter with a −1 dBFS ceiling. Gain is computed once per 32-frame block
///   and ramped across it.
///
/// Not thread-safe: one instance per audio stream, used from one thread.
final class AudioEffectsDSP: @unchecked Sendable {
    let switches: AudioEffectsSwitch
    private(set) var sampleRate: Double = 48_000
    private var presence: [Biquad] = []
    private var envelope: Float = 0
    private var compGain: Float = 1
    private var limitGain: Float = 1
    private var attackCoef: Float = 0
    private var releaseCoef: Float = 0
    private var limitRelease: Float = 0
    static let block = 32

    // Compressor settings.
    static let threshold: Float = -30
    static let ratio: Float = 3
    static let makeup: Float = 9
    static let ceiling: Float = 0.89  // −1 dBFS

    init(switches: AudioEffectsSwitch) {
        self.switches = switches
        prepare(sampleRate: 48_000, channels: 2)
    }

    func prepare(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        presence = (0..<max(channels, 1)).map { _ in Biquad.peaking(frequency: 2800, q: 0.9, gainDB: 5, sampleRate: self.sampleRate) }
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
        let fx = switches.value
        guard fx.isActive, !channels.isEmpty, frames > 0 else { return }
        if fx.dialogueBoost { boostDialogue(channels, stride: stride, frames: frames) }
        if fx.nightMode { compress(channels, stride: stride, frames: frames) } else { compGain = 1; limitGain = 1; envelope = 0 }
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
    }

    private func compress(_ ch: [UnsafeMutablePointer<Float>], stride: Int, frames: Int) {
        var start = 0
        while start < frames {
            let n = min(Self.block, frames - start)
            var peak: Float = 0
            for p in ch {
                for i in start..<(start + n) { peak = max(peak, abs(p[i * stride])) }
            }
            // Envelope follower on block peaks.
            envelope += (peak - envelope) * (peak > envelope ? attackCoef : releaseCoef)
            let levelDB = 20 * log10(max(envelope, 1e-6))
            let overDB = max(0, levelDB - Self.threshold)
            let gainDB = -overDB * (1 - 1 / Self.ratio) + Self.makeup
            let targetComp = pow(10, gainDB / 20)
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
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return Biquad(b0: Float((1 + alpha * a) / a0), b1: Float(-2 * cosw / a0), b2: Float((1 - alpha * a) / a0),
                      a1: Float(-2 * cosw / a0), a2: Float((1 - alpha / a) / a0))
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
