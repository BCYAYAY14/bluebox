import DesignSystem
import Subtitles
import SwiftUI

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color) {
        let c = color.resolve(in: EnvironmentValues())
        self.init(Double(c.red), Double(c.green), Double(c.blue), Double(c.opacity))
    }
}

extension SubtitleStyle {
    func font(size: Double) -> Font {
        let w: Font.Weight = switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
        var f: Font
        if let name = fontName, SubtitleFonts.isInstalled(name) {
            f = .custom(name, fixedSize: size).weight(w)
        } else {
            let d: Font.Design = switch design {
            case .system: .default
            case .rounded: .rounded
            case .serif: .serif
            case .monospaced: .monospaced
            }
            f = .system(size: size, weight: w, design: d)
        }
        return italic ? f.italic() : f
    }

    var textAlignment: TextAlignment {
        switch alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }

    var frameAlignment: SwiftUI.Alignment {
        switch alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
}

/// Font families offered for subtitles (filtered to what's installed).
enum SubtitleFonts {
    static let candidates = ["Helvetica Neue", "Avenir Next", "Futura", "Gill Sans", "Optima", "Georgia", "Palatino",
                             "Baskerville", "Arial", "Verdana", "Trebuchet MS", "Menlo", "Courier New", "American Typewriter",
                             "Marker Felt", "Chalkboard SE"]

    static var available: [String] { candidates.filter(isInstalled) }

    /// The font menu's choices: the four system designs, then installed families.
    static var pickerGroups: [[BlueboxPickerOption<String>]] {
        [[BlueboxPickerOption("System", value: "design:system"), BlueboxPickerOption("Rounded", value: "design:rounded"),
          BlueboxPickerOption("Serif", value: "design:serif"), BlueboxPickerOption("Monospaced", value: "design:monospaced")],
         available.map { BlueboxPickerOption($0, value: $0) }]
    }

    /// Reads and writes a style's font as one picker value ("design:serif" or a family name).
    static func binding(_ style: Binding<SubtitleStyle>) -> Binding<String> {
        Binding(get: { style.wrappedValue.fontName ?? "design:\(style.wrappedValue.design.rawValue)" }, set: { v in
            if v.hasPrefix("design:") {
                style.wrappedValue.fontName = nil
                style.wrappedValue.design = .init(rawValue: String(v.dropFirst(7))) ?? .system
            } else {
                style.wrappedValue.fontName = v
            }
        })
    }

    static func isInstalled(_ family: String) -> Bool {
        #if os(macOS)
        NSFontManager.shared.availableFontFamilies.contains(family)
        #else
        UIFont.familyNames.contains(family)
        #endif
    }
}

/// One subtitle block drawn with the full style: font, outline, shadow and box.
struct SubtitleText: View {
    let text: String
    let style: SubtitleStyle
    /// Height of the visible video, which subtitle sizes are relative to.
    var videoHeight: Double = 720
    var secondary = false

    var body: some View {
        let size = style.pointSize(forHeight: videoHeight) * (secondary ? style.secondaryScale : 1)
        let color = secondary ? style.secondaryColor.color : style.textColor.color
        let outline = style.outlineWidth * videoHeight / 1080
        let base = Text(text)
            .font(style.font(size: size))
            .lineSpacing(size * style.lineSpacing)
            .multilineTextAlignment(style.textAlignment)
        ZStack {
            if outline > 0.2 {
                // An outline drawn as offset copies: crisp at any size, no Core Text needed.
                ForEach(Array(Self.outlineOffsets.enumerated()), id: \.offset) { _, o in
                    base.foregroundStyle(style.outlineColor.color).offset(x: o.x * outline, y: o.y * outline)
                }
            }
            base.foregroundStyle(color)
        }
        .shadow(color: style.shadow ? .black.opacity(style.shadowOpacity) : .clear, radius: max(1, size * 0.08), x: 0, y: size * 0.03)
        .padding(.horizontal, style.backgroundOpacity > 0 ? size * 0.35 : 0)
        .padding(.vertical, style.backgroundOpacity > 0 ? size * 0.12 : 0)
        .background(style.backgroundColor.color.opacity(style.backgroundOpacity), in: RoundedRectangle(cornerRadius: size * 0.18))
        .accessibilityLabel("Subtitle: \(text)")
    }

    static let outlineOffsets: [CGPoint] = (0..<12).map { i in
        let a = Double(i) / 12 * 2 * .pi
        return CGPoint(x: cos(a), y: sin(a))
    }
}

/// Every subtitle look option, with a live preview. Used in Settings and in the player.
struct SubtitleAppearanceEditor: View {
    @Binding var style: SubtitleStyle
    var showsPreview = true

    var body: some View {
        if showsPreview {
            Section {
                SubtitlePreview(style: style).listRowInsets(EdgeInsets())
            }
        }
        Section("Presets") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(SubtitleStyle.Preset.allCases, id: \.self) { p in
                        Button(p.title) { style = style.applying(p) }.buttonStyle(.bordered)
                    }
                }
            }
        }
        Section("Text") {
            BlueboxPicker("Font", selection: SubtitleFonts.binding($style), groups: SubtitleFonts.pickerGroups)
            LabeledSlider("Size", value: $style.relativeSize, in: 0.02...0.12, format: { "\(Int(($0 / 0.045 * 100).rounded()))%" })
            BlueboxPicker("Weight", selection: $style.weight,
                          options: SubtitleStyle.Weight.allCases.map { BlueboxPickerOption($0.rawValue.capitalized, value: $0) })
            Toggle("Italic", isOn: $style.italic)
            ColorPicker("Color", selection: colorBinding(\.textColor), supportsOpacity: true)
            LabeledSlider("Line Spacing", value: $style.lineSpacing, in: 0...0.6, format: { "\(Int(($0 * 100).rounded()))%" })
        }
        Section("Outline & Shadow") {
            LabeledSlider("Outline", value: $style.outlineWidth, in: 0...6, format: { $0 < 0.1 ? "Off" : String(format: "%.1f pt", $0) })
            if style.outlineWidth >= 0.1 {
                ColorPicker("Outline Color", selection: colorBinding(\.outlineColor), supportsOpacity: false)
            }
            Toggle("Shadow", isOn: $style.shadow)
            if style.shadow {
                LabeledSlider("Shadow Strength", value: $style.shadowOpacity, in: 0.1...1, format: { "\(Int(($0 * 100).rounded()))%" })
            }
        }
        Section("Background") {
            LabeledSlider("Box Opacity", value: $style.backgroundOpacity, in: 0...1, format: { $0 < 0.01 ? "Off" : "\(Int(($0 * 100).rounded()))%" })
            if style.backgroundOpacity >= 0.01 {
                ColorPicker("Box Color", selection: colorBinding(\.backgroundColor), supportsOpacity: false)
            }
        }
        Section {
            Picker("Position", selection: $style.anchor) {
                Text("Bottom").tag(SubtitleStyle.Anchor.bottom)
                Text("Top").tag(SubtitleStyle.Anchor.top)
            }
            .pickerStyle(.segmented)
            Picker("Alignment", selection: $style.alignment) {
                Image(systemName: "text.alignleft").tag(SubtitleStyle.Alignment.leading).accessibilityLabel("Left")
                Image(systemName: "text.aligncenter").tag(SubtitleStyle.Alignment.center).accessibilityLabel("Center")
                Image(systemName: "text.alignright").tag(SubtitleStyle.Alignment.trailing).accessibilityLabel("Right")
            }
            .pickerStyle(.segmented)
            LabeledSlider("Distance from Edge", value: $style.verticalMargin, in: 0...0.5, format: { "\(Int(($0 * 100).rounded()))%" })
            LabeledSlider("Side Margins", value: $style.horizontalMargin, in: 0...0.3, format: { "\(Int(($0 * 100).rounded()))%" })
            Toggle("Move Up for Player Controls", isOn: $style.avoidControls)
            Button("Reset Position") { style.resetPosition() }
                .disabled(style.isDefaultPosition)
        } header: {
            Text("Placement")
        } footer: {
            Text("You can also drag subtitles anywhere on the video, and pinch them to resize.")
        }
        Section("Second Subtitle") {
            LabeledSlider("Size", value: $style.secondaryScale, in: 0.5...1.2, format: { "\(Int(($0 * 100).rounded()))%" })
            ColorPicker("Color", selection: colorBinding(\.secondaryColor), supportsOpacity: true)
        }
    }

    private func colorBinding(_ kp: WritableKeyPath<SubtitleStyle, RGBA>) -> Binding<Color> {
        Binding(get: { style[keyPath: kp].color }, set: { style[keyPath: kp] = RGBA($0) })
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, format: @escaping (Double) -> String) {
        self.title = title; _value = value; self.range = range; self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(Palette.textSecondary)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
        }
    }
}

struct SubtitlePreview: View {
    let style: SubtitleStyle
    var body: some View {
        GeometryReader { geo in
            ZStack {
                GeneratedArtwork(title: "Preview", kind: .backdrop, showsTitle: false)
                SubtitleOverlay(primary: "The tide comes in at midnight.\nWe leave before it turns.",
                                secondary: style.secondaryLanguage != nil ? "La marea sube a medianoche." : nil,
                                style: .constant(style), videoRect: CGRect(origin: .zero, size: geo.size), controlsVisible: false, editable: false)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityHidden(true)
    }
}
