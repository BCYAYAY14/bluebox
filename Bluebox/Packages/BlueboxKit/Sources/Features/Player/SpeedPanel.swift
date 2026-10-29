import DesignSystem
import Playback
import SwiftUI

/// Playback speed in one card: presets for one tap, then − and + in 0.05
/// steps for anything between (1.1× lectures). The value shows in blue when
/// it isn't normal, the same as on the bar's button.
struct SpeedPanel: View {
    let rate: Float
    let onSet: (Float) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlayerCardHeader("Playback Speed") {
                Text(PlaybackSpeed.label(rate))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(PlaybackSpeed.isNormal(rate) ? Palette.textSecondary : Palette.brandBright)
                    .contentTransition(.numericText())
            }
            ChipFlow(items: PlaybackSpeed.presets) { r in
                PanelChip(title: PlaybackSpeed.isNormal(r) ? "Normal" : PlaybackSpeed.label(r),
                          selected: abs(rate - r) < 0.001) { onSet(r) }
                    .accessibilityLabel(PlaybackSpeed.isNormal(r) ? "Normal speed" : "\(PlaybackSpeed.label(r)) speed")
            }
            HStack(spacing: Spacing.s) {
                stepButton(-1)
                VStack(spacing: 1) {
                    Text(PlaybackSpeed.label(rate))
                        .font(.title3.weight(.heavy)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("in 0.05 steps").font(.caption2).foregroundStyle(Palette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Speed")
                .accessibilityValue(PlaybackSpeed.label(rate))
                .accessibilityAdjustableAction { dir in onSet(PlaybackSpeed.stepped(rate, by: dir == .increment ? 1 : -1)) }
                stepButton(1)
            }
            .padding(6)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: PlayerCardMetrics.tileRadius, style: .continuous))
            Text(Self.hint).font(.caption).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.snappy(duration: 0.2), value: rate)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speedPanel")
    }

    private func stepButton(_ direction: Int) -> some View {
        let next = PlaybackSpeed.stepped(rate, by: direction)
        return Button { onSet(next) } label: {
            Image(systemName: direction < 0 ? "minus" : "plus")
                .font(.body.weight(.bold))
                .frame(width: PanelMetrics.control + 4, height: PanelMetrics.control + 4)
                .background(Color.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PanelPressStyle())
        .buttonRepeatBehavior(.enabled)
        .disabled(abs(next - rate) < 0.001)
        .accessibilityLabel(direction < 0 ? "Slower" : "Faster")
        .help(direction < 0 ? "Slower (0.05×) ([)" : "Faster (0.05×) (])")
    }

    static var hint: String {
        #if os(macOS)
        "[ and ] step 0.05 · hold → to play at 2×"
        #else
        "Press and hold the video to play at 2×"
        #endif
    }
}
