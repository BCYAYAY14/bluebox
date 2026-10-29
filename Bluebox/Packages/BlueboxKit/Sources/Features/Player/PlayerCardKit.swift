import DesignSystem
import SwiftUI

/// The cards that open from the bottom bar. One is open at a time; each is
/// anchored to the control that opened it.
enum PlayerPanelKind: String, CaseIterable, Identifiable {
    case tracks, episodes, speed, tools, chapters
    var id: String { rawValue }

    /// The card's width before it's fitted to the stage.
    func width(compact: Bool) -> CGFloat {
        switch self {
        case .tracks: compact ? 400 : 360
        case .episodes: 520
        case .speed: compact ? 280 : 300
        case .tools: compact ? 580 : 320
        case .chapters: 300
        }
    }
}

/// The menus' solid panel (DECISIONS.md 5): the raised grey, a hairline edge
/// and a soft shadow, with a 12 pt radius.
enum PlayerCardMetrics {
    static let radius: CGFloat = 12
    static let padding: CGFloat = 10
    static let tileRadius: CGFloat = 9
}

extension View {
    func playerCardSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: PlayerCardMetrics.radius, style: .continuous)
        return self
            .background(shape.fill(Palette.surface))
            .overlay(shape.strokeBorder(Palette.edge))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.5), radius: 16, y: 12)
            .environment(\.colorScheme, .dark)
    }
}

/// A card's heading: its title, an optional value on the right ("1.15×"), and
/// a back chevron on pages inside the card.
struct PlayerCardHeader<Trailing: View>: View {
    let title: String
    var onBack: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    /// A card's first page. (Pages inside it use `PlayerPageHeader`, so a
    /// trailing closure can never be taken for the back action.)
    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.onBack = nil; self.trailing = trailing()
    }

    fileprivate init(title: String, back: @escaping () -> Void, trailing: Trailing) {
        self.title = title; self.onBack = back; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward").font(.subheadline.weight(.bold))
                        Text(title).font(.subheadline.weight(.bold))
                    }
                    .frame(minHeight: PanelMetrics.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlayerQuietButtonStyle())
                .accessibilityLabel("Back")
                .accessibilityHint(title)
            } else {
                Text(title).font(.subheadline.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: Spacing.s)
            trailing
        }
        .padding(.bottom, 4)
    }
}

/// A page's heading inside a card: a back chevron with the page's title.
struct PlayerPageHeader<Trailing: View>: View {
    let title: String
    let onBack: () -> Void
    let trailing: Trailing

    init(_ title: String, onBack: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.onBack = onBack; self.trailing = trailing()
    }

    var body: some View { PlayerCardHeader(title: title, back: onBack, trailing: trailing) }
}

/// A row that opens a page: "Aa Style ›", "Timing +0.4 s ›".
struct PlayerPageChip: View {
    let title: String
    var value: String?
    var symbol: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.caption.weight(.semibold)) }
                Text(title)
                if let value { Text(value).foregroundStyle(Palette.brandBright).monospacedDigit() }
                Image(systemName: "chevron.forward").font(.caption2.weight(.bold)).foregroundStyle(Palette.textSecondary)
            }
            .font(PanelMetrics.chipFont)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(minHeight: PanelMetrics.control)
            .background(Color.white.opacity(hovering ? 0.1 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
            .contentShape(Capsule())
        }
        .buttonStyle(PanelPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

/// Text that dims while pressed and brightens on hover: back links, small actions.
struct PlayerQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration) }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.5 : hovering ? 1 : 0.9)
                .onHover { hovering = $0 }
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

// MARK: - Bar buttons

enum PlayerBarMetrics {
    #if os(macOS)
    /// Mac: a 32 pt button around a 16 pt glyph.
    static let button: CGFloat = 32
    static let glyph: CGFloat = 16
    static let target: CGFloat = 32
    #else
    static let button: CGFloat = 36
    static let glyph: CGFloat = 18
    /// Touch: the full 44 pt target around the smaller visible button.
    static let target: CGFloat = 44
    #endif
    static let radius: CGFloat = 7
}

/// The bar's buttons: a white glyph, a soft square on hover (Mac), a press
/// that dims and shrinks, and a lighter square while its card is open.
struct PlayerBarButtonStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, isOn: isOn) }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let isOn: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let fill: Double = configuration.isPressed ? 0.26 : isOn ? 0.2 : hovering && isEnabled ? 0.12 : 0
            configuration.label
                .frame(minWidth: PlayerBarMetrics.button, minHeight: PlayerBarMetrics.button)
                .background(RoundedRectangle(cornerRadius: PlayerBarMetrics.radius, style: .continuous).fill(.white.opacity(fill)))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
                .opacity(isEnabled ? 1 : 0.35)
                .frame(minWidth: PlayerBarMetrics.target, minHeight: PlayerBarMetrics.target)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Motion.hover, value: hovering)
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.press, value: isOn)
        }
    }
}

/// A glyph-only bar button with its tooltip (and shortcut) and accessibility label.
struct PlayerBarButton: View {
    let symbol: String
    let label: String
    var shortcut: String?
    var isOn = false
    var glyph: CGFloat = PlayerBarMetrics.glyph
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .frame(width: PlayerBarMetrics.button, height: PlayerBarMetrics.button)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PlayerBarButtonStyle(isOn: isOn))
        .accessibilityLabel(label)
        .help(shortcut.map { "\(label) (\($0))" } ?? label)
    }
}

/// A thin divider between the bar's groups.
struct PlayerBarDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 16).padding(.horizontal, 3)
            .accessibilityHidden(true)
    }
}

// MARK: - Buffering

/// Stands in for play while the video waits: a ring that fills to the point
/// where playback resumes, its percentage inside, and the speed or peers
/// under it. Without a measure it spins (still with Reduce Motion).
struct BufferingRing: View {
    let fraction: Double?
    let caption: String?
    var size: CGFloat = 46
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 3)
                if let fraction {
                    Circle().trim(from: 0, to: max(fraction, 0.02))
                        .stroke(Palette.brand, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: fraction)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: size * 0.26, weight: .bold)).monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.2), value: Int(fraction * 100))
                } else {
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 300 : -60))
                        .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                        .onAppear { spin = true }
                }
            }
            .frame(width: size, height: size)
            if let caption {
                Text(caption)
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .shadow(color: .black.opacity(0.7), radius: 3)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.2), value: caption)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([caption ?? "Loading", fraction.map { "\(Int(($0 * 100).rounded())) percent" }].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("loadingStatus")
    }
}
