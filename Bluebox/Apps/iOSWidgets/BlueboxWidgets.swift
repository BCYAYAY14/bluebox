import ActivityKit
import DownloadsActivity
import SwiftUI
import WidgetKit

/// Bluebox's widget extension: for now only the Downloads Live Activity,
/// started by the app (Features/DownloadsPresence.swift).
@main
struct BlueboxWidgets: WidgetBundle {
    var body: some Widget {
        DownloadsLiveActivity()
    }
}

private let brand = Color(red: DownloadsActivityStyle.brand.red, green: DownloadsActivityStyle.brand.green,
                          blue: DownloadsActivityStyle.brand.blue)
private let secondary = Color(white: 0.64)

/// The whole queue on the Lock Screen and in the Dynamic Island. OLED black,
/// no poster, blue only for progress.
struct DownloadsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadsActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ProgressRing(fraction: state.fraction, lineWidth: 4)
                        .frame(width: 36, height: 36)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.percentText)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    TitleLine(state: state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressBar(fraction: state.fraction)
                        Text(context.isStale ? "Open Bluebox to keep downloading" : state.detailLine)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                ProgressRing(fraction: state.fraction, lineWidth: 2.5)
                    .frame(width: 18, height: 18)
            } compactTrailing: {
                Text(state.percentText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
            } minimal: {
                ProgressRing(fraction: state.fraction, lineWidth: 2.5)
                    .frame(width: 18, height: 18)
            }
            .keylineTint(brand)
        }
    }
}

private struct LockScreenView: View {
    let state: DownloadsActivityState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TitleLine(state: state)
                Spacer(minLength: 8)
                Text(state.percentText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            Text(isStale ? "Paused · open Bluebox to keep downloading" : state.detailLine)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(secondary)
                .lineLimit(1)
            ProgressBar(fraction: state.fraction)
        }
        .padding(16)
    }
}

/// The current item in bold, its episode after it.
private struct TitleLine: View {
    let state: DownloadsActivityState

    var body: some View {
        HStack(spacing: 6) {
            Text(state.title).font(.headline.weight(.bold)).foregroundStyle(.white)
            if let subtitle = state.subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(secondary)
            }
        }
        .lineLimit(1)
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule().fill(brand).frame(width: max(g.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction * 100).rounded(.down))) percent")
    }
}

private struct ProgressRing: View {
    let fraction: Double
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(brand, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityLabel("Downloads \(Int((fraction * 100).rounded(.down))) percent")
    }
}
