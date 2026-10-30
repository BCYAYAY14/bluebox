import DesignSystem
import Subtitles
import SwiftUI

/// The pieces of the subtitle style editor, shared by the player's Subtitle
/// Style panel and Settings › Subtitles so the two work the same way. Colours
/// are semantic (primary, background), so they read in the player's dark panel
/// and in Settings in light or dark.

// MARK: - Presets

/// Bluebox's looks, then the ones you saved, as rounded buttons (each name in
/// its own type), and Save Current. A preset stays chosen until you change
/// something it sets.
struct SubtitlePresetGrid: View {
    @Binding var style: SubtitleStyle
    var columns = 2
    @State private var renaming: SubtitleStyle.SavedLook?
    @State private var newName = ""

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(SubtitleStyle.Preset.allCases, id: \.self) { p in
                button(p.title, look: p.look, selected: style.matches(p)) { style = style.applying(p) }
                    .accessibilityIdentifier("subtitlePreset.\(p.rawValue)")
            }
            ForEach(style.savedLooks) { saved in
                button(saved.name, look: saved.look, selected: style.look == saved.look) { style.look = saved.look }
                    .contextMenu {
                        Button("Rename…") { newName = saved.name; renaming = saved }
                        Button("Update to Current Look") { update(saved.id) { $0.look = style.look } }
                        Button("Delete", role: .destructive) { style.savedLooks.removeAll { $0.id == saved.id } }
                    }
            }
            if !isSaved {
                Button { withAnimation(.snappy(duration: 0.2)) { style.saveCurrentLook() } } label: {
                    Label("Save Current", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: PanelMetrics.control + 4)
                        .foregroundStyle(.secondary)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelPressStyle())
                .help("Keep this look as a preset of your own")
            }
        }
        .alert("Rename Look", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let id = renaming?.id, !name.isEmpty { update(id) { $0.name = name } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    /// The current look is already a preset or saved look: nothing to save.
    private var isSaved: Bool {
        SubtitleStyle.Preset.allCases.contains { style.matches($0) } || style.savedLooks.contains { $0.look == style.look }
    }

    private func update(_ id: UUID, _ change: (inout SubtitleStyle.SavedLook) -> Void) {
        guard let i = style.savedLooks.firstIndex(where: { $0.id == id }) else { return }
        change(&style.savedLooks[i])
    }

    private func button(_ title: String, look: SubtitleStyle.Look, selected: Bool, action: @escaping () -> Void) -> some View {
        var sample = SubtitleStyle(); sample.look = look
        return Button(action: action) {
            Text(title)
                .font(sample.font(size: 13))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: PanelMetrics.control + 4)
                .foregroundStyle(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.08))))
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Fonts

/// Fonts that read well as subtitles, each name in itself: the three designs,
/// the two Bluebox brings, then the installed families; "All Fonts…" for the rest.
struct SubtitleFontList: View {
    @Binding var style: SubtitleStyle

    static var choices: [(title: String, value: String, bundled: Bool)] {
        [("System", "design:system", false), ("Serif", "design:serif", false), ("Rounded", "design:rounded", false)]
            + SubtitleFontCatalog.bundled.filter(SubtitleFontCatalog.isInstalled).map { ($0, $0, true) }
            + SubtitleFontCatalog.suggested.filter(SubtitleFontCatalog.isInstalled).map { ($0, $0, false) }
    }

    var body: some View {
        let selection = SubtitleFonts.binding($style)
        let choices = Self.choices
        let other = !choices.contains { $0.value == selection.wrappedValue }
        VStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element.value) { i, c in
                if i > 0 { Divider().opacity(0.5) }
                row(c.title, family: family(c.value), bundled: c.bundled, selected: selection.wrappedValue == c.value) {
                    selection.wrappedValue = c.value
                }
            }
            if other, let name = style.fontName {
                Divider().opacity(0.5)
                row(name, family: name, bundled: false, selected: true) {}
            }
            Divider().opacity(0.5)
            Menu {
                ForEach(SubtitleFontCatalog.allFamilies, id: \.self) { f in
                    Button(f) { selection.wrappedValue = f }
                }
            } label: {
                Text("All Fonts…").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.brandBright)
                    .frame(maxWidth: .infinity, minHeight: PanelMetrics.control, alignment: .leading)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func family(_ value: String) -> String {
        guard value.hasPrefix("design:") else { return value }
        return SubtitleStyle.family(for: .init(rawValue: String(value.dropFirst(7))) ?? .system)
    }

    private func row(_ title: String, family: String, bundled: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.custom(family, size: 15)).lineLimit(1)
                Spacer(minLength: 4)
                if bundled { Text("Bluebox").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Palette.brandBright) }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: PanelMetrics.control)
            .background(selected ? Palette.brand.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Regular, Semibold or Bold.
struct SubtitleWeightPicker: View {
    @Binding var style: SubtitleStyle

    var body: some View {
        PanelSegments(selection: Binding(get: { style.weight.band }, set: { style.weight = [.regular, .semibold, .bold][$0] }),
                      options: [("Regular", 0), ("Semibold", 1), ("Bold", 2)])
    }
}

// MARK: - Look

/// Size, colour, background and outline, one row each.
struct SubtitleLookRows: View {
    @Binding var style: SubtitleStyle

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Spacing.s, verticalSpacing: 10) {
            StyleRow("Size") { SubtitleSizeStepper(size: $style.relativeSize) }
            StyleRow("Colour") { ColorSwatches(title: "Colour", color: $style.textColor, showsTitle: false) }
            StyleRow("Background") {
                PanelSegments(selection: Binding(get: { style.backgroundChoice }, set: { style.backgroundChoice = $0 }),
                              options: SubtitleStyle.BackgroundChoice.allCases.map { ($0.title, $0) })
            }
            StyleRow("Outline") {
                PanelSegments(selection: Binding(get: { style.outlineChoice }, set: { style.outlineChoice = $0 }),
                              options: SubtitleStyle.OutlineChoice.allCases.map { ($0.title, $0) })
            }
        }
    }
}

// MARK: - Position

/// A small picture with the subtitles as a bar: drag it up or down and it snaps
/// to Top, Middle and Bottom (anywhere else is a distance from the nearer edge),
/// with the alignment underneath. The same model as dragging on the video.
struct SubtitlePositionPad: View {
    @Binding var style: SubtitleStyle
    @State private var dragY: Double?
    @State private var candidate: SubtitlePlacement?
    private static let barHeight = 0.14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let h = geo.size.height, w = geo.size.width
                let barW = w * 0.44, barH = h * Self.barHeight
                let midY = (dragY ?? restingMidY) * h
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: [Color(white: 0.34), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    ForEach(Array(snapLines.enumerated()), id: \.offset) { _, line in
                        let y = line.y * h
                        Path { p in p.move(to: CGPoint(x: w * 0.05, y: y)); p.addLine(to: CGPoint(x: w * 0.95, y: y)) }
                            .stroke(line.on ? Palette.brandBright : .white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        Text(line.title).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                            .position(x: w - 24, y: y - 8)
                    }
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white)
                        .frame(width: barW, height: barH)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.brandBright, lineWidth: dragY == nil ? 0 : 2))
                        .position(x: barX(w: w, barW: barW), y: midY)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let y = min(max(v.location.y / h, Self.barHeight / 2), 1 - Self.barHeight / 2)
                        dragY = y
                        candidate = placement(midY: y)
                    }
                    .onEnded { _ in
                        if let candidate { withAnimation(.snappy(duration: 0.2)) { style.place(candidate) } }
                        dragY = nil; candidate = nil
                    })
                #if os(macOS)
                .pointerStyle(dragY == nil ? .grabIdle : .grabActive)
                #endif
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.12)))
            .selectionHaptic(candidate?.snappedY == true)
            .accessibilityElement()
            .accessibilityLabel("Subtitle position")
            .accessibilityValue(positionDescription)
            .accessibilityAdjustableAction { d in
                let order: [SubtitleStyle.Anchor] = [.bottom, .middle, .top]
                let i = order.firstIndex(of: style.anchor) ?? 0
                let next = d == .increment ? min(i + 1, 2) : max(i - 1, 0)
                style.pin(order[next], style.alignment)
                if order[next] != .middle { style.verticalMargin = SubtitleStyle.defaultMargin }
            }
            Grid(alignment: .leading, horizontalSpacing: Spacing.s, verticalSpacing: 10) {
                StyleRow("Alignment") {
                    PanelSegments(selection: Binding(get: { style.alignment }, set: { a in
                        withAnimation(.snappy(duration: 0.2)) { style.alignment = a; style.horizontalOffset = 0 }
                    }), options: [("Left", .leading), ("Centre", .center), ("Right", .trailing)])
                }
            }
        }
    }

    /// The bar's centre at rest, as a fraction of the height.
    private var restingMidY: Double {
        switch style.anchor {
        case .middle: 0.5
        case .bottom: 1 - style.verticalMargin - Self.barHeight / 2
        case .top: style.verticalMargin + Self.barHeight / 2
        }
    }

    private func barX(w: Double, barW: Double) -> Double {
        switch style.alignment {
        case .leading: style.horizontalMargin * w + barW / 2
        case .center: w / 2
        case .trailing: w - style.horizontalMargin * w - barW / 2
        }
    }

    private func placement(midY: Double) -> SubtitlePlacement {
        let block = CGRect(x: 0.5 - 0.22, y: midY - Self.barHeight / 2, width: 0.44, height: Self.barHeight)
        var p = SubtitlePlacement.dropping(block: block, alignment: .center, horizontalMargin: style.horizontalMargin)
        p.horizontalOffset = style.horizontalOffset  // the pad moves up and down only
        return p
    }

    private var snapLines: [(y: Double, title: String, on: Bool)] {
        let m = SubtitleStyle.defaultMargin, half = Self.barHeight / 2
        let c = candidate
        return [(m + half, "Top", c?.anchor == .top && c?.snappedY == true),
                (0.5, "Middle", c?.anchor == .middle),
                (1 - m - half, "Bottom", c?.anchor == .bottom && c?.snappedY == true)]
    }

    private var positionDescription: String {
        switch style.anchor {
        case .middle: "Middle"
        case .bottom: abs(style.verticalMargin - SubtitleStyle.defaultMargin) < 0.001 ? "Bottom" : "\(Int((style.verticalMargin * 100).rounded()))% from the bottom"
        case .top: abs(style.verticalMargin - SubtitleStyle.defaultMargin) < 0.001 ? "Top" : "\(Int((style.verticalMargin * 100).rounded()))% from the top"
        }
    }
}
