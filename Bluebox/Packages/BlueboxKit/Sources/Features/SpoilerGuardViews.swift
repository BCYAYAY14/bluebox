import DesignSystem
import Domain
import SwiftUI

// Spoiler guard's look (rules in Domain › SpoilerGuard): a heavy blur under a
// dark wash, so a still reads as "there's a picture here" without giving
// away who's in it.

extension View {
    /// Blurs and dims this artwork while `hidden`.
    func spoilerBlurred(_ hidden: Bool) -> some View {
        modifier(SpoilerBlur(hidden: hidden))
    }
}

private struct SpoilerBlur: ViewModifier {
    let hidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .blur(radius: hidden ? 18 : 0, opaque: true)
            .overlay { if hidden { Color.black.opacity(0.35) } }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: hidden)
    }
}

/// Where a hidden synopsis was: one quiet line, so the row keeps its height
/// and it's clear something was left out on purpose.
struct SpoilerHiddenSynopsis: View {
    var large = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash").font(.caption.weight(.semibold))
            Text("Synopsis hidden to avoid spoilers")
        }
        .font(large ? .callout : .footnote)
        .foregroundStyle(Palette.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The small "Show" button that reveals one guarded episode.
struct SpoilerRevealButton: View {
    let reveal: () -> Void

    var body: some View {
        Button(action: reveal) {
            Text("Show")
                .font(.caption.weight(.bold))
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .background(Palette.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.edge))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(haptic: true))
        .accessibilityLabel("Show spoilers for this episode")
        .help("Show this episode's picture and synopsis")
    }
}
