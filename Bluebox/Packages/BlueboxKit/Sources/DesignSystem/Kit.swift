import Domain
import SwiftUI

// MARK: - Environment hooks

public extension EnvironmentValues {
    /// Whether a title or episode has a finished download on this device.
    /// Set once near the root; cards read it to draw a "Downloaded" badge.
    /// The default says no, so screens work before downloads are wired up.
    @Entry var isDownloaded = DownloadedLookup(revision: 0) { _ in false }
}

/// Answers "is this downloaded?". Compared by `revision` (bump it when
/// downloads change), so views reading it don't re-render on every update.
public struct DownloadedLookup: Equatable, Sendable {
    let revision: Int
    let check: @MainActor @Sendable (MediaKey) -> Bool

    public init(revision: Int, check: @escaping @MainActor @Sendable (MediaKey) -> Bool) {
        self.revision = revision; self.check = check
    }

    @MainActor public func callAsFunction(_ key: MediaKey) -> Bool { check(key) }

    public static func == (a: Self, b: Self) -> Bool { a.revision == b.revision }
}

/// Runs `content` in its own body, so whatever Observable state it reads
/// (download progress, say) re-renders only this view, not the screen
/// that built it.
public struct ObservationScope<Content: View>: View {
    let content: () -> Content
    public init(@ViewBuilder _ content: @escaping () -> Content) { self.content = content }
    public var body: some View { content() }
}

// MARK: - Skeletons

/// A loading placeholder, the shape of what's coming, with a soft highlight
/// sweeping across it. Reduce Motion shows it still.
///
/// Put `.shimmering()` on a whole skeleton (a shelf, a row) rather than on
/// each block: one sweep then crosses every block in it together, which reads
/// calmer, and costs one animation instead of dozens. Blocks inside a
/// shimmering container don't add their own.
public struct SkeletonBlock: View {
    let width: CGFloat?
    let height: CGFloat?
    let radius: CGFloat

    public init(width: CGFloat? = nil, height: CGFloat? = nil, radius: CGFloat = Radius.card) {
        self.width = width; self.height = height; self.radius = radius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Palette.surface)
            .frame(width: width, height: height)
            .shimmering()
            .accessibilityHidden(true)
    }
}

public extension View {
    /// Sweeps a soft highlight across the view, masked to its shape. Inside
    /// another shimmering view this does nothing (the outer sweep covers it).
    func shimmering(active: Bool = true) -> some View { modifier(Shimmer(active: active)) }
}

extension EnvironmentValues {
    /// True inside a view that already shimmers.
    @Entry var shimmerProvided = false
}

/// The sweep is a plain offset animation that repeats on the render server:
/// no per-frame view updates (the old version re-ran a `TimelineView` body 30
/// times a second for every block on screen). The highlight is faint, and it
/// spends part of each cycle off the edge, which gives the pause between sweeps.
struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shimmerProvided) private var provided

    /// One crossing, including the stretch off the far edge that reads as a rest.
    static let period: Double = 1.9

    func body(content: Content) -> some View {
        if active && !reduceMotion && !provided {
            content
                .environment(\.shimmerProvided, true)
                .overlay {
                    ShimmerSweep()
                        .mask(content.environment(\.shimmerProvided, true))
                        .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

private struct ShimmerSweep: View {
    @State private var moving = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let band = min(max(w * 0.45, 90), 420)
            LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                   .init(color: .white.opacity(0.055), location: 0.5),
                                   .init(color: .white.opacity(0), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: band, height: geo.size.height)
                // Travels well past the far edge, so ~30% of each cycle is a rest.
                .offset(x: moving ? w + band * 1.6 : -band)
                .animation(.easeInOut(duration: Shimmer.period).repeatForever(autoreverses: false), value: moving)
        }
        .onAppear { moving = true }
    }
}

// MARK: - Buttons

/// The shared pressed state for anything tappable that draws its own look
/// (cards, tiles, icon buttons): a slight shrink and dim the instant a finger
/// lands on iOS, a dim on Mac (hover does the rest there). With `haptic`, a
/// light tap on touch-down on iOS, for buttons that act (download, cancel),
/// not for cards that only navigate.
public struct PressableStyle: ButtonStyle {
    let haptic: Bool
    let scale: CGFloat
    /// - Parameter scale: how far it shrinks while pressed; 1 for full-width rows, which only dim.
    public init(haptic: Bool = false, scale: CGFloat = 0.96) { self.haptic = haptic; self.scale = scale }
    public func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration, haptic: haptic, scale: scale)
    }

    struct PressBody: View {
        let configuration: Configuration
        let haptic: Bool
        let scale: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                #if os(iOS)
                .scaleEffect(configuration.isPressed ? scale : 1)
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
                #else
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                #endif
                .animation(Motion.press, value: configuration.isPressed)
                .pressHaptic(haptic ? configuration.isPressed : false)
        }
    }
}

/// A small text action inside a row ("Switch", "Remove", "Clear", a toast's
/// "Undo"): brand blue, grey when disabled, and a 44 pt hit area around the
/// word so it's easy to hit.
public struct TextActionStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { ActionBody(configuration: configuration) }

    struct ActionBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isEnabled ? Palette.brandBright : Palette.textTertiary)
                .padding(.horizontal, 6)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.55 : 1)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

extension View {
    /// A light impact as `pressed` turns true (iOS only).
    func pressHaptic(_ pressed: Bool) -> some View {
        #if os(iOS)
        sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: pressed) { _, now in now }
        #else
        self
        #endif
    }
}

// One button family (DECISIONS.md, UI review 2): three weights, used the
// same way on every screen.
// - Primary: white solid, black text. Play and Resume; one per screen.
// - Secondary: grey solid. Download, Start Over, Trailer, More Info, Cancel.
// - Tertiary: icon tiles (`ActionTileStyle`), in the order My List, Rate,
//   Trailer, Share, More.
// Blue marks state only (on, selected, progress), never a button's weight.

/// The primary button: solid white with black text, like Netflix's Play.
public struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth: Bool
    public init(fullWidth: Bool = false) { self.fullWidth = fullWidth }
    public func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, fullWidth: fullWidth)
    }
    struct PrimaryBody: View {
        let configuration: Configuration
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(Typography.button)
                .labelStyle(TightLabelStyle())
                .padding(.horizontal, Spacing.xl).padding(.vertical, 10)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
                .background(isEnabled ? Color.white.opacity(configuration.isPressed ? 0.78 : 1) : Palette.elevated,
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .foregroundStyle(isEnabled ? Color.black : Palette.textTertiary)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .pressHaptic(configuration.isPressed)
                .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                #if os(iOS)
                .hoverEffect(.highlight)
                #endif
        }
    }
}

/// The secondary button: solid grey (`Palette.glassFill`, the raised grey),
/// white text. No translucency: the finish has no glass.
public struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth: Bool
    public init(fullWidth: Bool = false) { self.fullWidth = fullWidth }
    public func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, fullWidth: fullWidth)
    }
    struct SecondaryBody: View {
        let configuration: Configuration
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(Typography.button)
                .labelStyle(TightLabelStyle())
                .padding(.horizontal, Spacing.l).padding(.vertical, 10)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
                .background(configuration.isPressed ? Palette.glassFillPressed : Palette.glassFill,
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .pressHaptic(configuration.isPressed)
                .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                #if os(iOS)
                .hoverEffect(.highlight)
                #endif
        }
    }
}

/// The secondary button's look for a label that isn't a plain button, such as
/// a `BlueboxMenu` trigger (the menu supplies the press feedback).
public struct SecondaryButtonLabel<Content: View>: View {
    let content: Content
    public init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .font(Typography.button)
            .labelStyle(TightLabelStyle())
            .padding(.horizontal, Spacing.l).padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(Palette.glassFill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// Earlier names, kept so older call sites build: Play is the primary
/// button, and the "glass" button was always the solid grey secondary.
public typealias PlayButtonStyle = PrimaryButtonStyle
public typealias GlassButtonStyle = SecondaryButtonStyle

/// The tertiary weight: an icon over a small caption, Netflix's "My List ·
/// Rate · Share" row. Always in the order My List, Rate, Trailer, Share, More.
public struct ActionTileStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }
    struct TileBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .labelStyle(TileLabelStyle())
                .frame(minWidth: 64, minHeight: 52)
                .padding(.vertical, Spacing.xs)
                .background(hovering ? Palette.elevated : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                #if os(iOS)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                #endif
                .animation(Motion.press, value: configuration.isPressed)
                .pressHaptic(configuration.isPressed)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Motion.hover, value: hovering)
        }
    }
}

struct TileLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 6) {
            configuration.icon.font(.title3.weight(.regular)).frame(height: 24)
            configuration.title.font(.caption2.weight(.medium)).foregroundStyle(Palette.textSecondary).lineLimit(1)
        }
    }
}

/// A label with a slightly tighter icon gap than the default.
public struct TightLabelStyle: LabelStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon; configuration.title }
    }
}

// MARK: - Chips

/// A capsule filter chip ("TV Shows", "Movies"), outlined until selected.
public struct CategoryChip: View {
    let title: String
    var systemImage: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    public init(_ title: String, systemImage: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.selected = selected; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let systemImage { Image(systemName: systemImage).font(.caption.weight(.bold)) }
            }
            .font(.subheadline.weight(selected ? .semibold : .medium))
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(selected ? Palette.brand.opacity(0.28) : (hovering ? Palette.glassFill : .clear), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Palette.brandBright.opacity(0.9) : .white.opacity(0.45), lineWidth: 1))
            .foregroundStyle(.white)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Section header

/// A row header with an optional "See All" chevron.
public struct SectionHeader: View {
    let title: String
    let action: (() -> Void)?
    public init(_ title: String, action: (() -> Void)? = nil) { self.title = title; self.action = action }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(title).font(Typography.rowTitle).lineLimit(1).accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.s)
            if let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text("See All").font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(Palette.brandBright)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("See All \(title)")
            }
        }
    }
}

// MARK: - Badges

/// Netflix's "TOP 10" square, in blue.
public struct TopTenBadge: View {
    public init() {}
    public var body: some View {
        VStack(spacing: -2) {
            Text("TOP").font(.system(size: 7, weight: .heavy))
            Text("10").font(.system(size: 12, weight: .black))
        }
        .foregroundStyle(.white)
        .frame(width: 22, height: 26)
        .background(Palette.brand, in: UnevenRoundedRectangle(bottomLeadingRadius: 3, topTrailingRadius: 3))
        .accessibilityLabel("Top 10")
    }
}

/// Marks a title with a finished download.
public struct DownloadedBadge: View {
    public init() {}
    public var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 16, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Palette.brand)
            .shadow(color: .black.opacity(0.5), radius: 3)
            .accessibilityLabel("Downloaded")
    }
}

/// A small outlined box for certification or quality ("TV-14", "HD", "4K").
public struct OutlineTag: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white.opacity(0.55), lineWidth: 1))
            .foregroundStyle(Palette.textSecondary)
    }
}

// MARK: - Top 10

/// A Top 10 entry: a huge outlined numeral with the poster tucked over its right edge.
public struct TopTenCard: View {
    let rank: Int
    let title: String
    let url: URL?
    let posterWidth: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(rank: Int, title: String, url: URL?, posterWidth: CGFloat) {
        self.rank = rank; self.title = title; self.url = url; self.posterWidth = posterWidth
    }

    public var body: some View {
        let h = posterWidth * 1.5
        HStack(spacing: -posterWidth * (rank >= 10 ? 0.2 : 0.14)) {
            RankNumeral(rank: rank, height: h)
            PosterCard(title: title, url: url, width: posterWidth)
        }
        .frame(height: h)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Number \(rank), \(title)")
    }
}

/// The numeral: navy fill with a blue outline (drawn as offset copies, which
/// keeps the stroke crisp at any size).
struct RankNumeral: View {
    let rank: Int
    let height: CGFloat

    var body: some View {
        let size = height * 0.92
        let text = Text("\(rank)").font(.system(size: size, weight: .black).width(rank >= 10 ? .compressed : .condensed))
        let w = max(2, size * 0.022)
        ZStack {
            ForEach(0..<12, id: \.self) { i in
                let a = Double(i) / 12 * 2 * .pi
                text.foregroundStyle(Palette.brandBright.opacity(0.9)).offset(x: cos(a) * w, y: sin(a) * w)
            }
            text.foregroundStyle(LinearGradient(colors: [Palette.navy, Palette.background], startPoint: .top, endPoint: .bottom))
        }
        .tracking(rank >= 10 ? -size * 0.08 : 0)
        .lineLimit(1)
        .fixedSize()
        .frame(height: height, alignment: .bottom)
        .offset(y: size * 0.1)
        .accessibilityHidden(true)
    }
}

// MARK: - Haptics

public extension View {
    /// A light tap when `trigger` changes (iOS only; a no-op elsewhere).
    func tapHaptic<T: Equatable>(_ trigger: T) -> some View {
        #if os(iOS)
        sensoryFeedback(.impact(weight: .light), trigger: trigger)
        #else
        self
        #endif
    }

    /// A selection tick when `trigger` changes (iOS only).
    func selectionHaptic<T: Equatable>(_ trigger: T) -> some View {
        #if os(iOS)
        sensoryFeedback(.selection, trigger: trigger)
        #else
        self
        #endif
    }

    /// A success haptic when `trigger` changes (iOS only).
    func successHaptic<T: Equatable>(_ trigger: T) -> some View {
        #if os(iOS)
        sensoryFeedback(.success, trigger: trigger)
        #else
        self
        #endif
    }
}

// MARK: - Glow

/// The faint wash at the top of Home and the title page when there's no hero
/// art: a neutral grey that fades to black (the OLED finish has no blue glow).
public struct NavyGlow: View {
    let height: CGFloat
    public init(height: CGFloat) { self.height = height }
    public var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(stops: [.init(color: Palette.navyGlow, location: 0), .init(color: Palette.navy.opacity(0.7), location: 0.45),
                                   .init(color: Palette.background, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
