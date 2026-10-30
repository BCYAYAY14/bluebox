import DesignSystem
import Playback
import SwiftUI

/// Playback speed in one card: presets for one tap, then the dial for
/// anything between (1.1× lectures) in 0.05 steps, with how long is left at
/// that speed. The value shows in blue when it isn't normal, the same as on
/// the bar's button.
struct SpeedPanel: View {
    let rate: Float
    /// Time left in the video at normal speed, when known.
    var remaining: TimeInterval? = nil
    let onSet: (Float) -> Void
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlayerCardHeader("Playback Speed") {
                if PanelMetrics.showsShortcuts { HStack(spacing: 3) { KeyCap("["); KeyCap("]") }.help("Slower ([) or faster (])") }
            }
            // A phone on its side: the dial alone (its slider and steps cover the presets).
            if !PanelMetrics.dense {
                // The usual speeds as segments; the rarer ones in More.
                let preset = PlaybackSpeed.presets.first { abs(rate - $0) < 0.001 } ?? rate
                PanelSegmentsWithMore(selection: Binding(get: { preset }, set: { onSet($0) }),
                                      shown: [1, 1.25, 1.5, 2].map { (PlaybackSpeed.isNormal($0) ? "Normal" : PlaybackSpeed.label($0), $0) },
                                      more: [0.5, 0.75, 1.75].map { (PlaybackSpeed.label($0), $0) })
            }
            ValueDial(title: "Speed", value: Double(rate), range: 0.25...3, defaultValue: 1, fine: 0.05, coarse: 0.25,
                      format: { PlaybackSpeed.label(Float($0)) }, meaning: meaning,
                      stepLabel: { String(format: $0 > 0 ? "+%g" : "−%g", abs($0)) }) { onSet(PlaybackSpeed.clamp(Float($0))) }
            if !short {
                Text(Self.hint).font(.caption).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speedPanel")
    }

    /// "Normal speed", or how long is left at this speed: "38 min left (saves 9 min)".
    private func meaning(_ r: Double) -> String {
        guard abs(r - 1) > 0.001 else { return "Normal speed" }
        guard let remaining, remaining > 10 else { return r > 1 ? "Faster than normal" : "Slower than normal" }
        let at = remaining / r
        return "\(Formatters.duration(at)) left, \(r > 1 ? "saving" : "adding") \(Formatters.duration(abs(remaining - at)))"
    }

    /// A phone on its side: the card has no room for the hint.
    private var short: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    static var hint: String {
        #if os(macOS)
        "Hold → to play at 2× for a moment."
        #else
        "Press and hold the video to play at 2× for a moment."
        #endif
    }
}
