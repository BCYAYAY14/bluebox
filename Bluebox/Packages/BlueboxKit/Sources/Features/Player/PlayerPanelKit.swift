import DesignSystem
import SwiftUI

/// Building blocks for the player's cards: titled sections, chips for short
/// option lists, sliders with a value and a reset, and key caps that show
/// Mac shortcuts. Touch targets are 44 pt on iOS and compact (28 pt) on the Mac.
@MainActor
enum PanelMetrics {
    #if os(iOS)
    /// A phone on its side: the cards are short, so their controls are
    /// tighter (34 pt, still easy to hit) and their type a step smaller.
    /// Set by the player from its stage height.
    static var dense = false
    static var control: CGFloat { dense ? 34 : 44 }
    static var chipFont: Font { dense ? .footnote.weight(.semibold) : .subheadline.weight(.semibold) }
    /// The big number in a dial (speed, delays).
    static var valueFont: Font { dense ? .title3.weight(.bold) : .title2.weight(.bold) }
    static let showsShortcuts = false
    #else
    static let dense = false
    static let control: CGFloat = 28
    static let chipFont = Font.callout.weight(.medium)
    static let valueFont = Font.title2.weight(.bold)
    static let showsShortcuts = true
    #endif
    static let cardRadius: CGFloat = 14
    static let padding: CGFloat = 14
}

/// A titled group on a card page: a small caps heading, then its controls.
/// No box of its own: the card is the surface.
struct PanelSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title; self.accessory = accessory(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold)).tracking(0.8)
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: Spacing.s)
                accessory
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One choice in a short list (speed, aspect, crop…): a capsule, filled blue when selected.
struct PanelChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PanelMetrics.chipFont)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, PanelMetrics.dense ? 10 : 12)
                .frame(minWidth: PanelMetrics.control, minHeight: PanelMetrics.control)
                .foregroundStyle(selected ? Color.black : Palette.textPrimary)
                .background(selected ? Color.white : Color.white.opacity(hovering ? 0.1 : 0), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0 : 0.22)))
                .contentShape(Capsule())
        }
        .buttonStyle(PanelPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Chips that wrap onto as many lines as they need.
struct ChipFlow<Item: Hashable, Chip: View>: View {
    let items: [Item]
    @ViewBuilder let chip: (Item) -> Chip

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { chip($0) }
        }
    }
}

/// A plain left-to-right wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// A slider with its title and value on one line, and a reset when it's moved.
struct PanelSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var defaultValue: Double? = nil
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.s) {
                Text(title).font(.subheadline)
                Spacer(minLength: Spacing.s)
                Text(format(value)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.textSecondary)
                if let defaultValue {
                    Button { value = defaultValue } label: {
                        Image(systemName: "arrow.counterclockwise").font(.caption.weight(.bold))
                            .frame(width: PanelMetrics.control * 0.8, height: PanelMetrics.control * 0.8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PanelPressStyle())
                    .foregroundStyle(Palette.textSecondary)
                    .opacity(abs(value - defaultValue) > 0.0001 ? 1 : 0)
                    .disabled(abs(value - defaultValue) <= 0.0001)
                    .accessibilityLabel("Reset \(title)")
                    .help("Reset \(title)")
                }
            }
            Group {
                if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
            }
            .tint(Palette.brand)
            .controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityValue(format(value))
        }
    }
}

/// A list row you pick from (tracks): title, optional detail, and a check.
struct PanelPickRow: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                if let symbol {
                    Image(systemName: symbol).font(.footnote).foregroundStyle(Palette.textSecondary).frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(2)
                    if let detail { Text(detail).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1) }
                }
                Spacer(minLength: Spacing.s)
                Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(Palette.brandBright)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: PanelMetrics.control + 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Palette.brand.opacity(0.22) : .white.opacity(hovering ? 0.08 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PanelPressStyle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A full-width secondary action inside a card.
struct PanelActionButton: View {
    let title: String
    let symbol: String
    var shortcut: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: Spacing.s) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: Spacing.s)
                if let shortcut { KeyCap(shortcut) }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: PanelMetrics.control + 4)
            .background(.white.opacity(hovering ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PanelPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

/// A keyboard shortcut drawn as a key (Mac only; nothing on iOS).
struct KeyCap: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        if PanelMetrics.showsShortcuts {
            Text(keys)
                .font(.caption2.weight(.semibold)).monospaced()
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.18)))
                .accessibilityLabel("Shortcut \(keys)")
        }
    }
}

/// Dim and (on iOS) shrink slightly while pressed.
struct PanelPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            #if os(iOS)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            #endif
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// One number you tune by ear or eye (subtitle timing, audio delay, speed):
/// the value large, what it means in words, fine and coarse steps that repeat
/// while held, and a slider for big moves. The same in every card that has one.
struct ValueDial: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    /// Fine and coarse step sizes (the buttons are −coarse −fine +fine +coarse).
    let fine: Double
    let coarse: Double
    let format: (Double) -> String
    /// "Subtitles show 0.4 s later": what the value does, in words.
    let meaning: (Double) -> String
    /// Mac keys for the fine steps ("{" and "}").
    var keys: (String, String)? = nil
    var stepLabel: (Double) -> String = { String(format: "%+g", $0) }
    let set: (Double) -> Void

    private var isDefault: Bool { abs(value - defaultValue) < 0.0005 }

    var body: some View {
        VStack(spacing: PanelMetrics.dense ? 5 : 8) {
            VStack(spacing: 1) {
                Text(format(value))
                    .font(PanelMetrics.valueFont).monospacedDigit()
                    .foregroundStyle(isDefault ? Palette.textPrimary : Palette.brandBright)
                    .contentTransition(.numericText(value: value))
                Text(meaning(value))
                    .font(.caption).foregroundStyle(Palette.textSecondary)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("\(format(value)), \(meaning(value))")
            .accessibilityAdjustableAction { d in set(clamp(value + (d == .increment ? fine : -fine))) }
            HStack(spacing: 6) {
                step(-coarse, key: nil)
                step(-fine, key: keys?.0)
                step(fine, key: keys?.1)
                step(coarse, key: nil)
            }
            HStack(spacing: Spacing.s) {
                // No fill (a delay of zero sits in the middle, not at the start), with a tick at the default.
                Slider(value: Binding(get: { value }, set: { set(snap($0)) }), in: range)
                    .tint(.white.opacity(0.25))
                    .controlSize(.small)
                    .background(alignment: .leading) {
                        GeometryReader { g in
                            let f = (defaultValue - range.lowerBound) / (range.upperBound - range.lowerBound)
                            Capsule().fill(.white.opacity(0.6)).frame(width: 2, height: 10)
                                .position(x: 8 + (g.size.width - 16) * f, y: g.size.height / 2)
                        }
                        .allowsHitTesting(false)
                    }
                    .accessibilityHidden(true)
                Button { set(defaultValue) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.caption.weight(.bold))
                        .frame(width: PanelMetrics.control * 0.8, height: PanelMetrics.control * 0.8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelPressStyle())
                .foregroundStyle(Palette.textSecondary)
                .opacity(isDefault ? 0.3 : 1)
                .disabled(isDefault)
                .accessibilityLabel("Reset \(title)")
                .help("Reset \(title)")
            }
        }
        .padding(PanelMetrics.dense ? 6 : 8)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: PlayerCardMetrics.tileRadius, style: .continuous))
        .animation(.snappy(duration: 0.2), value: value)
    }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }
    /// The slider lands on fine steps, and on the default when near it.
    private func snap(_ v: Double) -> Double {
        let s = (v / fine).rounded() * fine
        return abs(s - defaultValue) < fine * 1.5 ? defaultValue : clamp(s)
    }

    private func step(_ d: Double, key: String?) -> some View {
        let next = clamp(value + d)
        return Button { set(next) } label: {
            VStack(spacing: 2) {
                Text(stepLabel(d)).font(PanelMetrics.chipFont).monospacedDigit()
                if let key { KeyCap(key) }
            }
            // All four the same height, whether or not they show a key.
            .frame(maxWidth: .infinity, minHeight: PanelMetrics.control + (keys != nil && PanelMetrics.showsShortcuts ? 16 : 0))
            .background(.white.opacity(abs(d) == coarse ? 0.06 : 0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PanelPressStyle())
        .buttonRepeatBehavior(.enabled)
        .disabled(abs(next - value) < 0.0001)
        .accessibilityLabel("\(title) \(stepLabel(d))")
    }
}
