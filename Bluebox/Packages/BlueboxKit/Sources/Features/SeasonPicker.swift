import DesignSystem
import Domain
import SwiftUI

/// One season in the full-screen list.
struct SeasonChoice: Identifiable, Equatable {
    let number: Int
    let name: String
    let episodeCount: Int
    /// Finished episodes of this season.
    let watched: Int
    var id: Int { number }

    /// "8 episodes · 2 of 8 watched", "6 episodes · All watched".
    var caption: String {
        var s = episodeCount == 1 ? "1 episode" : "\(episodeCount) episodes"
        if watched > 0 {
            s += watched >= episodeCount && episodeCount > 0 ? " · All watched" : " · \(watched) of \(episodeCount) watched"
        }
        return s
    }

    /// Numbered seasons in order, then Specials (season 0) last, as Netflix lists them.
    static func make(_ seasons: [SeasonSummary], progress: [MediaKey: WatchProgress]) -> [SeasonChoice] {
        var watched: [Int: Int] = [:]
        for p in progress.values where p.isCompleted {
            if let (s, _) = p.key.episodeNumbers { watched[s, default: 0] += 1 }
        }
        let ordered = seasons.filter { $0.number > 0 }.sorted { $0.number < $1.number } + seasons.filter { $0.number <= 0 }
        return ordered.map {
            SeasonChoice(number: $0.number, name: $0.number == 0 ? "Specials" : $0.name, episodeCount: $0.episodeCount,
                         watched: min(watched[$0.number] ?? 0, $0.episodeCount))
        }
    }
}

/// "Season 2 ▾": opens the full-screen season list.
struct SeasonPickerButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                Text(title).font(.subheadline.weight(.bold))
                if enabled {
                    Image(systemName: "chevron.down").font(.caption2.weight(.heavy)).foregroundStyle(Palette.textSecondary)
                }
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .fixedSize()
        .accessibilityLabel("Season")
        .accessibilityValue(title)
        .accessibilityHint(enabled ? "Shows every season" : "")
        .accessibilityIdentifier("seasonPicker")
    }
}

/// The full-screen season list: seasons centred on black, the current one
/// large and white, the rest grey, each with its episode count and how much
/// is watched, and a round white close button. Esc closes it on the Mac.
struct SeasonListOverlay: View {
    let seasons: [SeasonChoice]
    let current: Int?
    let choose: (Int) -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(appeared ? 1 : 0).ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: Spacing.xl) {
                            ForEach(seasons) { s in row(s) }
                        }
                        .padding(.vertical, Spacing.xxxl)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geo.size.height - 120)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
                }
                .safeAreaInset(edge: .bottom) { closeButton.padding(.bottom, Spacing.xl) }
            }
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
        }
        .onAppear { withAnimation(Motion.standard(reduceMotion)) { appeared = true } }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
    }

    /// Fades out, then closes (the cover itself is presented without a slide).
    private func dismiss() { leave(then: close) }

    private func leave(then action: @escaping () -> Void) {
        withAnimation(.easeIn(duration: 0.18)) { appeared = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            action()
        }
    }

    private func row(_ s: SeasonChoice) -> some View {
        let isCurrent = s.number == current
        return Button { leave { choose(s.number) } } label: {
            VStack(spacing: 4) {
                Text(s.name)
                    .font(isCurrent ? .title.weight(.heavy) : .title3.weight(.semibold))
                    .foregroundStyle(isCurrent ? Palette.textPrimary : Color(white: 0.54))
                Text(s.caption)
                    .font(.footnote)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(SeasonRowStyle())
        .id(s.number)
        .accessibilityLabel("\(s.name), \(s.caption)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("season.\(s.number)")
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 56, height: 56)
                .background(.white, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("closeSeasons")
        .frame(maxWidth: .infinity)
    }
}

/// Grey names brighten under the pointer and dim while pressed.
private struct SeasonRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }

    struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .brightness(hovering ? 0.25 : 0)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { hovering = $0 }
                .animation(Motion.hover, value: hovering)
        }
    }
}
