import Foundation

/// Ready-made equaliser curves. Each is on `EqualizerSettings.frequencies`.
public enum EqualizerPreset: String, CaseIterable, Codable, Sendable {
    case flat, voice, bassBoost, treble, cinema, music, headphones

    public var title: String {
        switch self {
        case .flat: "Flat"
        case .voice: "Voice"
        case .bassBoost: "Bass Boost"
        case .treble: "Treble"
        case .cinema: "Cinema"
        case .music: "Music"
        case .headphones: "Headphones"
        }
    }

    /// Ten band gains in dB, one per `EqualizerSettings.frequencies`.
    public var gains: [Double] {
        switch self {
        case .flat: Array(repeating: 0, count: 10)
        // Rumble and hiss down, speech presence (1–6 kHz) up: Dialogue Boost's curve on VLC.
        case .voice: [-4, -3, -1, 1, 3, 5, 4, 0, -1, -2]
        case .bassBoost: [6, 5, 3, 1, 0, 0, 0, 0, 0, 0]
        case .treble: [0, 0, 0, 0, 0, 1, 3, 5, 6, 6]
        case .cinema: [3, 2, 0, -1, 0, 1, 2, 2, 1, 0]
        case .music: [3, 2, 1, 0, -1, 0, 1, 2, 3, 3]
        case .headphones: [2, 3, 1, -1, -1, 0, 2, 4, 5, 5]
        }
    }

    /// Headroom for the boosts, in dB: roughly the curve's peak, so a full-scale
    /// soundtrack stays clear of the limiter.
    public var preamp: Double {
        switch self {
        case .flat: 0
        case .voice: -3
        case .bassBoost, .treble: -4
        case .cinema, .music: -2
        case .headphones: -3
        }
    }
}

/// A ten-band graphic equaliser: one gain per band and a preamp, all in dB.
///
/// The gains are always ten and always within `gainRange` (setting or decoding
/// anything else is padded, cut and clamped), so the engines never check.
public struct EqualizerSettings: Hashable, Codable, Sendable {
    /// Band centres in Hz: the classic Winamp/VLC set the presets are drawn on.
    /// AVPlayer filters at exactly these; libVLC 4's own bands are octaves
    /// (31 Hz–16 kHz), so VLC gets the curve resampled onto those
    /// (`EqualizerCurve.resampled`).
    public static let frequencies: [Double] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
    public static let gainRange: ClosedRange<Double> = -12...12
    public static let preampRange: ClosedRange<Double> = -12...12
    /// How close (dB) gains have to be to count as a preset.
    static let presetTolerance = 0.05

    public var isOn: Bool
    public var gains: [Double] { didSet { gains = Self.normalised(gains) } }
    public var preamp: Double { didSet { preamp = Self.clamped(preamp, to: Self.preampRange) } }

    public init(isOn: Bool = false, gains: [Double] = Array(repeating: 0, count: 10), preamp: Double = 0) {
        self.isOn = isOn
        self.gains = Self.normalised(gains)
        self.preamp = Self.clamped(preamp, to: Self.preampRange)
    }

    public static let flat = EqualizerSettings()

    /// The preset these gains and preamp match (within 0.05 dB), or nil ("Custom").
    /// Whether it's on doesn't matter.
    public var preset: EqualizerPreset? {
        EqualizerPreset.allCases.first { p in
            abs(p.preamp - preamp) <= Self.presetTolerance
                && zip(p.gains, gains).allSatisfy { abs($0 - $1) <= Self.presetTolerance }
        }
    }

    /// The preset's gains and preamp, switched on.
    public func applying(_ preset: EqualizerPreset) -> EqualizerSettings {
        EqualizerSettings(isOn: true, gains: preset.gains, preamp: preset.preamp)
    }

    /// Sets one band (clamped); a band outside 0..<10 is ignored.
    public mutating func setGain(_ dB: Double, band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = dB
    }

    /// True when it changes the sound (on and not flat).
    public var isAudible: Bool { isOn && preset != .flat }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case isOn, gains, preamp }

    /// Lenient: anything missing takes its default, and the gains are padded,
    /// cut and clamped like any other, so a settings file from another
    /// version never fails to load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(isOn: (try? c.decodeIfPresent(Bool.self, forKey: .isOn)) ?? false,
                  gains: (try? c.decodeIfPresent([Double].self, forKey: .gains)) ?? [],
                  preamp: (try? c.decodeIfPresent(Double.self, forKey: .preamp)) ?? 0)
    }

    // MARK: Normalising

    static func normalised(_ g: [Double]) -> [Double] {
        (0..<10).map { $0 < g.count ? clamped(g[$0], to: gainRange) : 0 }
    }

    /// Clamped, with NaN and infinities taken as 0 (a slider can't produce
    /// them, but a bad file could, and NaN would silence the filters for good).
    static func clamped(_ v: Double, to range: ClosedRange<Double>) -> Double {
        v.isFinite ? min(max(v, range.lowerBound), range.upperBound) : 0
    }
}

/// A preamp and ten band gains (dB) on `EqualizerSettings.frequencies`, as
/// handed to an engine whose equaliser also carries Dialogue Boost (VLC's).
package struct EqualizerCurve: Equatable, Sendable {
    package var preamp: Double
    package var gains: [Double]

    /// libVLC's equaliser takes −20…+20 dB, preamp and bands alike.
    package static let engineRange: ClosedRange<Double> = -20...20

    /// Dialogue Boost (the Voice curve) and the equaliser, added together and
    /// clamped to `engineRange`; nil when neither changes the sound.
    package static func combined(_ e: AudioEffects) -> EqualizerCurve? {
        var parts: [(gains: [Double], preamp: Double)] = []
        if e.dialogueBoost { parts.append((EqualizerPreset.voice.gains, EqualizerPreset.voice.preamp)) }
        if e.equalizer.isAudible { parts.append((e.equalizer.gains, e.equalizer.preamp)) }
        guard !parts.isEmpty else { return nil }
        let clamp = { (v: Double) in min(max(v, engineRange.lowerBound), engineRange.upperBound) }
        return EqualizerCurve(
            preamp: clamp(parts.reduce(0) { $0 + $1.preamp }),
            gains: (0..<10).map { band in clamp(parts.reduce(0) { $0 + $1.gains[band] }) })
    }

    /// The curve read off at other band centres: straight lines between the
    /// bands on a log-frequency axis, level beyond the first and last.
    package func resampled(at targets: [Double]) -> [Double] {
        let f = EqualizerSettings.frequencies.map { log2($0) }
        return targets.map { target in
            let x = log2(max(target, 1))
            if x <= f[0] { return gains[0] }
            if x >= f[f.count - 1] { return gains[f.count - 1] }
            let i = f.lastIndex { $0 <= x } ?? 0
            let t = (x - f[i]) / (f[i + 1] - f[i])
            return gains[i] + (gains[i + 1] - gains[i]) * t
        }
    }
}
