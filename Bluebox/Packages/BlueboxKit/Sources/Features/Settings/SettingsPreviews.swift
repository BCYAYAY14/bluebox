import DesignSystem
import Domain
import Subtitles
import SwiftUI

// The live video frames on the look-and-feel pages (Subtitles, Picture,
// Playback). A still from the catalogue (a trending backdrop with TMDB, the
// sample catalogue's generated art without it) with the page's settings drawn
// over it, so every change shows at once.

/// A 16:9 frame with a catalogue still, picture adjustments, and an overlay.
struct SettingsVideoPreview<Overlay: View>: View {
    var picture = PictureDefaults()
    @ViewBuilder var overlay: (CGSize) -> Overlay

    var body: some View {
        GeometryReader { geo in
            ZStack {
                SettingsPreviewStill()
                    .brightness(picture.brightness)
                    .contrast(picture.contrast)
                    .saturation(picture.saturation)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                overlay(geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: 640)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.edge))
        .overlay(alignment: .topTrailing) {
            Text("Live Preview")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(Spacing.s)
                .accessibilityHidden(true)
        }
    }
}

/// The still: loaded once per launch and shared by every preview.
struct SettingsPreviewStill: View {
    @Environment(AppModel.self) private var app
    @State private var still: StillChoice? = SettingsPreviewStill.cached

    struct StillChoice: Sendable, Equatable {
        let name: String
        let url: URL?
    }

    @MainActor static var cached: StillChoice?

    var body: some View {
        ZStack {
            if let still, still.url != nil {
                ArtworkView(url: still.url, fallbackTitle: still.name, kind: .backdrop, pixelWidth: 1280,
                            showsFallbackTitle: false)
            } else {
                // No artwork (sample catalogue, or offline): a painted dusk scene with
                // enough colour and light for picture changes to show.
                SettingsPreviewScene()
            }
            // A dark grade over the lower part, where subtitles and controls sit, so
            // white text is judged against a frame like a film's, not a bright poster.
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.6), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .task {
            guard still == nil else { return }
            let choice = await Self.darkestStill(app: app)
            Self.cached = choice
            still = choice
        }
        .accessibilityHidden(true)
    }

    /// The darkest of the first few trending backdrops, judged on the lower
    /// part of the frame where subtitles sit. Bright ones (cream poster
    /// collages are common) lose to the painted scene, which is dark at the bottom.
    private static func darkestStill(app: AppModel) async -> StillChoice {
        let titles = (try? await app.metadata.list(.trending, page: 1).items) ?? []
        var best: (title: Title, luminance: Double)?
        for t in titles.filter({ $0.backdrop != nil }).prefix(8) {
            guard let thumb = app.imageURL(t.backdrop, width: 300),
                  let image = try? await ImagePipeline.shared.image(for: thumb, maxPixelWidth: 64),
                  let l = lowerLuminance(image) else { continue }
            if best == nil || l < best!.luminance { best = (t, l) }
            if l < 0.15 { break }  // dark enough; stop downloading
        }
        guard let best, best.luminance < 0.4 else { return StillChoice(name: "Bluebox", url: nil) }
        return StillChoice(name: best.title.name, url: app.imageURL(best.title.backdrop, width: 1280))
    }

    /// Mean luminance (0–1) of the bottom 40% of an image, from a 16×9 sample.
    nonisolated static func lowerLuminance(_ image: CGImage) -> Double? {
        let w = 16, h = 9
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // Rows run top to bottom in memory; take the last four (the lower 40%).
        var total = 0.0
        var count = 0
        for y in (h - 4)..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                total += 0.2126 * r + 0.7152 * g + 0.0722 * b
                count += 1
            }
        }
        return count == 0 ? nil : total / Double(count)
    }
}

/// A dusk over hills and water, drawn in code, for the preview when there's no still.
struct SettingsPreviewScene: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.32), Color(red: 0.55, green: 0.25, blue: 0.45),
                                        Color(red: 0.98, green: 0.55, blue: 0.30)],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.62))
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.92, blue: 0.7), Color(red: 1, green: 0.7, blue: 0.35)],
                                         center: .center, startRadius: 0, endRadius: h * 0.12))
                    .frame(width: h * 0.24, height: h * 0.24)
                    .position(x: w * 0.68, y: h * 0.52)
                    .blur(radius: 1)
                hills(w: w, h: h, base: 0.62, peaks: [0.50, 0.42, 0.55, 0.47, 0.58], color: Color(red: 0.24, green: 0.13, blue: 0.30))
                hills(w: w, h: h, base: 0.66, peaks: [0.60, 0.54, 0.63, 0.56], color: Color(red: 0.10, green: 0.07, blue: 0.16))
                LinearGradient(colors: [Color(red: 0.62, green: 0.32, blue: 0.38), Color(red: 0.05, green: 0.06, blue: 0.14)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: h * 0.34)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Capsule().fill(Color(red: 1, green: 0.8, blue: 0.55).opacity(0.55))
                    .frame(width: h * 0.2, height: 2)
                    .position(x: w * 0.68, y: h * 0.72)
                Capsule().fill(Color(red: 1, green: 0.8, blue: 0.55).opacity(0.3))
                    .frame(width: h * 0.12, height: 2)
                    .position(x: w * 0.68, y: h * 0.77)
            }
        }
        .accessibilityHidden(true)
    }

    private func hills(w: Double, h: Double, base: Double, peaks: [Double], color: Color) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: h * base))
            for (i, peak) in peaks.enumerated() {
                let x = w * Double(i + 1) / Double(peaks.count)
                let mid = w * (Double(i) + 0.5) / Double(peaks.count)
                p.addQuadCurve(to: CGPoint(x: x, y: h * base), control: CGPoint(x: mid, y: h * (2 * peak - base)))
            }
            p.addLine(to: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: 0, y: h))
            p.closeSubpath()
        }
        .fill(color)
    }
}

// MARK: - Subtitles

/// Subtitles in the current style; drag them on the frame to move them.
struct SubtitleStylePreview: View {
    @Binding var style: SubtitleStyle

    var body: some View {
        SettingsVideoPreview { size in
            SubtitleOverlay(primary: "I've been looking for you.\nAll this time.",
                            secondary: style.secondaryLanguage != nil ? "Te he estado buscando." : nil,
                            style: $style, videoRect: CGRect(origin: .zero, size: size),
                            controlsVisible: false, editable: true)
        }
        .accessibilityElement()
        .accessibilityLabel("Subtitle preview")
        .accessibilityHint("Drag the subtitles to move them.")
    }
}

// MARK: - Playback

/// A player frame showing the skip buttons, speed, engine and Up Next as set.
struct PlaybackPreview: View {
    let skipBack: Int
    let skipForward: Int
    let speed: Float
    let engine: String
    let upNext: Int?

    var body: some View {
        SettingsVideoPreview { size in
            let compact = size.width < 420
            ZStack {
                Color.black.opacity(0.28)
                HStack(spacing: compact ? 34 : 56) {
                    skipSymbol("gobackward", skipBack)
                    Image(systemName: "pause.fill").font(.system(size: compact ? 30 : 40))
                    skipSymbol("goforward", skipForward)
                }
                .foregroundStyle(.white)
                VStack {
                    HStack {
                        chip(engine)
                        Spacer()
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        Spacer()
                        if let upNext {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill").font(.caption2)
                                Text("Next Episode in \(upNext)").font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white))
                        }
                    }
                    .padding(.bottom, Spacing.s)
                    HStack(spacing: Spacing.s) {
                        Capsule().fill(.white.opacity(0.3)).frame(height: 3)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in Capsule().fill(Palette.brand).frame(width: g.size.width * 0.38) }
                            }
                        Text(speed == 1 ? "1×" : String(format: "%g×", speed))
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(.white)
                    }
                }
                .padding(compact ? Spacing.m : Spacing.l)
            }
        }
    }

    private func skipSymbol(_ base: String, _ seconds: Int) -> some View {
        let name = "\(base).\(seconds)"
        return Image(systemName: [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? name : base)
            .font(.system(size: 26, weight: .regular))
            .contentTransition(.symbolEffect(.replace))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.55)))
    }
}

// MARK: - Colour swatches

/// A row of colour choices with a custom colour at the end.
struct SettingsColorRow: View {
    let title: String
    @Binding var color: RGBA
    var choices: [RGBA] = [.white, .yellow, .lightBlue, RGBA(0.62, 0.94, 0.66), .lightGray]

    var body: some View {
        HStack(spacing: Spacing.m) {
            Text(title)
            Spacer(minLength: Spacing.s)
            ForEach(choices, id: \.self) { c in
                let selected = Self.close(c, color)
                Button { color = RGBA(c.r, c.g, c.b, color.a) } label: {
                    Circle().fill(c.color)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.black.opacity(0.25)))
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? Palette.brand : .clear, lineWidth: 2))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(Self.name(c))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            // A Bluebox swatch on Mac, where the system well rings itself in the system accent.
            BrandColorWell(title: title, color: Binding(get: { color.color }, set: { color = RGBA($0) }))
                .frame(width: 32, height: 32)
        }
    }

    static func close(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(a.r - b.r) < 0.02 && abs(a.g - b.g) < 0.02 && abs(a.b - b.b) < 0.02
    }

    static func name(_ c: RGBA) -> String {
        switch c {
        case .white: "White"
        case .yellow: "Yellow"
        case .lightBlue: "Light Blue"
        case .lightGray: "Light Grey"
        default: "Green"
        }
    }
}
