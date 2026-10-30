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
    /// The family VLC draws the video's own text tracks with (see
    /// `resolvedFontFamily`), in the chosen weight (VLC has only bold or not).
    func font(size: Double) -> Font {
        .custom(resolvedFontFamily, fixedSize: size).weight(swiftUIWeight)
    }

    var swiftUIWeight: Font.Weight {
        switch weight { case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold; case .heavy: .heavy }
    }

    var textAlignment: TextAlignment {
        switch alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }

    var frameAlignment: SwiftUI.Alignment {
        switch alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
}

/// A style's font as one picker value: "design:serif" or a family name.
enum SubtitleFonts {
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
