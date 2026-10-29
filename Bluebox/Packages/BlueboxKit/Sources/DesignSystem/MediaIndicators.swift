import SwiftUI

// Small shared marks for progress and download state: the episode download
// ring, the blue check on finished posters, the bar along a poster's bottom
// edge, quality badges and swarm health. All in the OLED-black finish.

/// A circular progress ring (downloads). Track in raised grey, progress in
/// blue from twelve o'clock, round caps.
public struct ProgressRing: View {
    let fraction: Double
    let lineWidth: CGFloat
    let tint: Color

    public init(fraction: Double, lineWidth: CGFloat = 2.5, tint: Color = Palette.brand) {
        self.fraction = fraction; self.lineWidth = lineWidth; self.tint = tint
    }

    public var body: some View {
        ZStack {
            Circle().stroke(Color(white: 0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0.02), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: fraction)
        }
        .padding(lineWidth / 2)
    }
}

/// The small blue check on a finished download's poster.
public struct CheckDot: View {
    let size: CGFloat
    public init(size: CGFloat = 18) { self.size = size }
    public var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.brand, in: Circle())
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .accessibilityLabel("Downloaded")
    }
}

/// A thin bar along the bottom edge of artwork: a faint white track with the
/// filled part in `tint`. Linear, so progress never springs.
public struct EdgeProgressBar: View {
    let fraction: Double
    let height: CGFloat
    let tint: Color

    public init(fraction: Double, height: CGFloat = 3, tint: Color = Palette.brand) {
        self.fraction = fraction; self.height = height; self.tint = tint
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.22))
                Rectangle().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.25), value: fraction)
        .accessibilityHidden(true)
    }
}

/// A release's quality ("4K", "1080p") in a fixed-width box: raised grey, or
/// blue for the release Play would use.
public struct QualityBadge: View {
    let text: String
    let highlighted: Bool
    public init(_ text: String, highlighted: Bool = false) { self.text = text; self.highlighted = highlighted }
    public var body: some View {
        Text(text)
            .font(.caption.weight(.heavy))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(minWidth: 52)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .foregroundStyle(.white)
            .background(highlighted ? Palette.brand : Palette.elevated,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// How healthy a torrent swarm is, for seeders text.
public enum SwarmHealth {
    /// Green.
    public static let good = Color(red: 0.36, green: 0.78, blue: 0.60)
    /// Amber.
    public static let fair = Color(red: 0.91, green: 0.71, blue: 0.36)
    /// Red.
    public static let poor = Color(red: 0.90, green: 0.42, blue: 0.40)

    public static func color(seeders: Int) -> Color {
        seeders >= 100 ? good : seeders >= 20 ? fair : poor
    }
}

/// "✓ WATCHED": a small dark tag over a thumbnail's corner.
public struct WatchedTag: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy))
            Text("WATCHED").font(.system(size: 9, weight: .heavy)).tracking(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5).padding(.vertical, 2.5)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityLabel("Watched")
    }
}
