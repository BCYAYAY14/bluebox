import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The lines to draw into the video picture while Picture in Picture or
/// AirPlay is on (the overlay can't follow the picture there).
public struct SubtitleBurnIn: Equatable, Sendable {
    public var primary: String?
    public var secondary: String?
    public var style: SubtitleStyle

    public init(primary: String?, secondary: String?, style: SubtitleStyle) {
        self.primary = primary; self.secondary = secondary; self.style = style
    }

    public var isEmpty: Bool { (primary ?? "").isEmpty && (secondary ?? "").isEmpty }

    /// A drawn block and where it goes on the frame.
    public struct Rendered: @unchecked Sendable {
        public let image: CGImage
        /// The block's lower-left corner, from the frame's lower-left (Core Image's space).
        public let origin: CGPoint
        /// The block's upper-left corner, from the frame's upper-left (VLC's logo position).
        public var topLeft: CGPoint { CGPoint(x: origin.x, y: frame.height - origin.y - CGFloat(image.height)) }
        let frame: CGSize
    }

    /// Draws the lines in the style (font, size, colour, outline, shadow, box)
    /// for a frame of `frame` pixels, placed as the style says (edge, margin,
    /// alignment, sideways shift). Nil when there's nothing to draw.
    public func render(frame: CGSize) -> Rendered? {
        guard !isEmpty, frame.width >= 16, frame.height >= 16 else { return nil }
        let h = Double(frame.height), w = Double(frame.width)
        let size = style.pointSize(forHeight: h)
        let maxWidth = max(40, w * (1 - 2 * style.horizontalMargin))
        // The second line sits on the far side from the edge, as in the overlay.
        var blocks: [(String, Double, RGBA)] = []
        let second = secondary.flatMap { $0.isEmpty ? nil : ($0, size * style.secondaryScale, style.secondaryColor) }
        let first = primary.flatMap { $0.isEmpty ? nil : ($0, size, style.textColor) }
        if style.anchor == .top { blocks = [first, second].compactMap { $0 } } else { blocks = [second, first].compactMap { $0 } }

        let outline = style.outlineWidth * h / 1080
        let padX = style.backgroundOpacity > 0 ? size * 0.35 : 0, padY = style.backgroundOpacity > 0 ? size * 0.12 : 0
        let shadowRoom = style.shadow ? size * 0.12 : 0
        let gap = size * 0.25
        let laid = blocks.map { text, pt, color in layout(text, size: pt, color: color, maxWidth: maxWidth) }
        let textWidth = laid.map(\.size.width).max() ?? 0
        let textHeight = laid.map(\.size.height).reduce(0, +) + gap * Double(max(0, laid.count - 1))
        let margin = outline + shadowRoom + 2
        let width = Int((textWidth + 2 * padX + 2 * margin).rounded(.up))
        let height = Int((textHeight + 2 * padY * Double(laid.count) + 2 * margin).rounded(.up))
        guard width > 0, height > 0, let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top to bottom: Core Graphics counts up from the bottom.
        var top = Double(height) - margin
        for block in laid {
            let blockHeight = block.size.height + 2 * padY
            let x: Double = switch style.alignment {
            case .leading: margin
            case .center: (Double(width) - block.size.width - 2 * padX) / 2
            case .trailing: Double(width) - margin - block.size.width - 2 * padX
            }
            let box = CGRect(x: x, y: top - blockHeight, width: block.size.width + 2 * padX, height: blockHeight)
            if style.backgroundOpacity > 0 {
                ctx.setFillColor(style.backgroundColor.cg(alpha: style.backgroundOpacity))
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: size * 0.18, cornerHeight: size * 0.18, transform: nil))
                ctx.fillPath()
            }
            draw(block, in: ctx, at: CGPoint(x: box.minX + padX, y: box.minY + padY), outline: outline, size: size)
            top -= blockHeight + gap
        }
        guard let image = ctx.makeImage() else { return nil }

        // Where the block goes on the frame.
        let blockW = Double(width), blockH = Double(height)
        let left = w * style.horizontalMargin, right = w * (1 - style.horizontalMargin)
        var x: Double = switch style.alignment {
        case .leading: left - margin
        case .center: (w - blockW) / 2
        case .trailing: right - blockW + margin
        }
        x += style.horizontalOffset * w
        x = min(max(x, 0), max(0, w - blockW))
        let m = style.verticalMargin * h
        let y: Double = switch style.anchor {
        case .bottom: m - margin
        case .middle: (h - blockH) / 2
        case .top: h - m - blockH + margin
        }
        return Rendered(image: image, origin: CGPoint(x: x.rounded(), y: min(max(y, 0), max(0, h - blockH)).rounded()), frame: frame)
    }

    /// The block as PNG data (for players that take an image file).
    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: Text

    struct Laid {
        let frame: CTFrame
        let size: CGSize
        let string: NSAttributedString
        let pointSize: Double
    }

    private func layout(_ text: String, size: Double, color: RGBA, maxWidth: Double) -> Laid {
        let string = attributed(text, size: size, fill: color.cg(alpha: color.a), stroke: nil)
        let setter = CTFramesetterCreateWithAttributedString(string)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let measured = CGSize(width: ceil(fit.width), height: ceil(fit.height))
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: measured), transform: nil), nil)
        return Laid(frame: frame, size: measured, string: string, pointSize: size)
    }

    private func draw(_ block: Laid, in ctx: CGContext, at origin: CGPoint, outline: Double, size: Double) {
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        let path = CGPath(rect: CGRect(origin: .zero, size: block.size), transform: nil)
        if style.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.03), blur: max(1, size * 0.08),
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: style.shadowOpacity))
        }
        if outline > 0.2 {
            // The stroke is centred on the glyph edge: twice the width shows the outline's width outside it.
            let percent = 2 * outline / block.pointSize * 100
            let stroked = attributed(block.string.string, size: block.pointSize, fill: style.outlineColor.cg(alpha: 1),
                                     stroke: (style.outlineColor.cg(alpha: 1), percent))
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(stroked), CFRange(), path, nil), ctx)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
        CTFrameDraw(block.frame, ctx)
        ctx.restoreGState()
    }

    private func attributed(_ text: String, size: Double, fill: CGColor, stroke: (CGColor, Double)?) -> NSAttributedString {
        var traits: CTFontSymbolicTraits = style.isBold ? .traitBold : []
        if style.italic { traits.insert(.traitItalic) }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: style.resolvedFontFamily,
            kCTFontTraitsAttribute: [kCTFontSymbolicTrait: traits.rawValue],
        ] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        var alignment: CTTextAlignment = switch style.alignment { case .leading: .left; case .center: .center; case .trailing: .right }
        var spacing = CGFloat(size * style.lineSpacing)
        let settings = [
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: &alignment),
            CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: &spacing),
        ]
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): CTParagraphStyleCreate(settings, settings.count),
        ]
        if let (color, width) = stroke {
            attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color
            attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = width
        }
        return NSAttributedString(string: text, attributes: attrs)
    }
}

extension RGBA {
    func cg(alpha: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
}
