import DesignSystem
import Domain
import Subtitles
import SwiftUI

// The live video frames on the look-and-feel pages (Subtitles, Picture,
// Playback). A dusk scene drawn in code with the page's settings drawn over
// it, so every change shows at once.

/// A 16:9 frame with the dusk scene, picture adjustments, and an overlay.
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

/// The still: the painted dusk scene, the same on every page and with or
/// without a catalogue, so a change is judged against the same frame each time.
struct SettingsPreviewStill: View {
    var body: some View {
        ZStack {
            // Enough colour and light for picture changes to show.
            SettingsPreviewScene()
            // A dark grade over the lower part, where subtitles and controls sit, so
            // white text is judged against a frame like a film's, not a bright sky.
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.6), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// A dusk over hills and water, drawn in code: every preview's frame.
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
            Text(ui: title)
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
