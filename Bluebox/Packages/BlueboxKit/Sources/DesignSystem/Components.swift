import Domain
import SwiftUI

// MARK: - Artwork

/// Remote artwork with a branded generative fallback (used when TMDB has no
/// image, the network is down, or the sample catalog is active).
public struct ArtworkView: View {
    let url: URL?
    let fallbackTitle: String
    let kind: Artwork.Kind
    let pixelWidth: Int
    let showsFallbackTitle: Bool
    @State private var image: CGImage?
    @State private var failed = false

    /// - Parameter showsFallbackTitle: false where the screen already shows the title over the art.
    public init(url: URL?, fallbackTitle: String, kind: Artwork.Kind, pixelWidth: Int, showsFallbackTitle: Bool = true) {
        self.url = url; self.fallbackTitle = fallbackTitle; self.kind = kind; self.pixelWidth = pixelWidth
        self.showsFallbackTitle = showsFallbackTitle
    }

    public var body: some View {
        // A poster decoded before (scrolled back into view, another screen)
        // draws in this first frame, with no placeholder flash or fade.
        let shown = url.flatMap { ImagePipeline.shared.cachedNow($0, maxPixelWidth: pixelWidth) } ?? image
        ZStack {
            if let image = shown {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                GeneratedArtwork(title: fallbackTitle, kind: kind, showsTitle: showsFallbackTitle && (url == nil || failed))
            }
        }
        .clipped()
        .task(id: url) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let hit = ImagePipeline.shared.cachedNow(url, maxPixelWidth: pixelWidth) {
            // CGImage isn't Equatable: an unconditional write re-renders the cell.
            if image !== hit { image = hit }
            return
        }
        do {
            let img = try await ImagePipeline.shared.image(for: url, maxPixelWidth: pixelWidth)
            withAnimation(Motion.appear) { image = img }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

/// Deterministic black-and-blue gradient with the title set in type, so cards
/// without artwork still look intentional.
public struct GeneratedArtwork: View {
    let title: String
    let kind: Artwork.Kind
    let showsTitle: Bool

    public init(title: String, kind: Artwork.Kind, showsTitle: Bool = true) {
        self.title = title; self.kind = kind; self.showsTitle = showsTitle
    }

    /// Greedy word wrap by character count, at most four lines.
    static func lines(_ title: String, width: Int) -> [String] {
        var out: [String] = []
        for word in title.split(separator: " ").map(String.init) {
            if let last = out.last, last.count + 1 + word.count <= width { out[out.count - 1] = last + " " + word }
            else { out.append(word) }
        }
        if out.count > 4 { out = Array(out.prefix(3)) + [out.dropFirst(3).joined(separator: " ")] }
        return out
    }

    private var seed: UInt64 {
        // FNV-1a: stable across launches, unlike `hashValue`.
        title.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    public var body: some View {
        let s = seed
        let hue = 0.58 + Double(s % 60) / 1000          // 0.58–0.64: a cool tint only
        let brightness = 0.18 + Double((s >> 8) % 14) / 100
        let angle = Angle.degrees(Double((s >> 16) % 360))
        ZStack {
            LinearGradient(
                colors: [Color(hue: hue, saturation: 0.12, brightness: brightness), Color(white: 0.08), .black],
                startPoint: UnitPoint(x: 0.5 + 0.5 * cos(angle.radians), y: 0),
                endPoint: .bottom
            )
            RadialGradient(colors: [Color(white: 1).opacity(0.10), .clear],
                           center: UnitPoint(x: Double((s >> 24) % 100) / 100, y: 0.25), startRadius: 0, endRadius: 220)
            if showsTitle {
                // Whole words per line, each shrinking to fit, so a long word
                // never breaks with a hyphen ("Ele-phants").
                VStack(spacing: 2) {
                    ForEach(Array(Self.lines(title, width: kind == .poster ? 11 : 18).enumerated()), id: \.offset) { _, line in
                        Text(line).lineLimit(1).minimumScaleFactor(0.5)
                    }
                }
                .font(kind == .poster ? .headline : .title3)
                .fontWeight(.heavy)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.4), radius: 6)
                .padding(Spacing.m)
            }
        }
    }
}

// MARK: - Progress

public struct ProgressStrip: View {
    let fraction: Double
    public init(fraction: Double) { self.fraction = fraction }
    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.28))
                Rectangle().fill(Palette.brand).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent watched")
    }
}

// MARK: - Cards

public struct PosterCard: View {
    let title: String
    let url: URL?
    let width: CGFloat
    let progress: Double?
    let badge: String?
    let isDownloaded: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(title: String, url: URL?, width: CGFloat, progress: Double? = nil, badge: String? = nil, isDownloaded: Bool = false) {
        self.title = title; self.url = url; self.width = width; self.progress = progress; self.badge = badge
        self.isDownloaded = isDownloaded
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            ArtworkView(url: url, fallbackTitle: title, kind: .poster, pixelWidth: Int(width * 2))
                .frame(width: width, height: width * 1.5)
            if let progress { ProgressStrip(fraction: progress) }
        }
        .overlay(alignment: .topLeading) {
            if let badge { BadgeView(text: badge).padding(Spacing.s) }
        }
        .overlay(alignment: .topTrailing) {
            if isDownloaded { DownloadedBadge().padding(6) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(hovering ? Palette.brandBright.opacity(0.7) : .white.opacity(0.06), lineWidth: hovering ? 1.5 : 1))
        .scaleEffect(hovering && !reduceMotion ? 1.08 : 1)
        .modifier(HoverShadow(on: hovering))
        .animation(Motion.cardZoom(reduceMotion), value: hovering)
        .modifier(HoverHighlight(on: $hovering))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([progress.map { "\(Int(($0 * 100).rounded())) percent watched" }, isDownloaded ? "Downloaded" : nil]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

public struct LandscapeCard: View {
    let title: String
    let subtitle: String?
    let url: URL?
    let width: CGFloat
    let progress: Double?
    let showsPlayGlyph: Bool
    let isDownloaded: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(title: String, subtitle: String? = nil, url: URL?, width: CGFloat, progress: Double? = nil,
                showsPlayGlyph: Bool = false, isDownloaded: Bool = false) {
        self.title = title; self.subtitle = subtitle; self.url = url; self.width = width
        self.progress = progress; self.showsPlayGlyph = showsPlayGlyph; self.isDownloaded = isDownloaded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ZStack(alignment: .bottom) {
                // The title is printed under the card, so generated art stays wordless.
                ArtworkView(url: url, fallbackTitle: title, kind: .backdrop, pixelWidth: Int(width * 2), showsFallbackTitle: false)
                    .frame(width: width, height: width * 9 / 16)
                if showsPlayGlyph {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.black.opacity(0.5), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                        .scaleEffect(hovering && !reduceMotion ? 1.1 : 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let progress { ProgressStrip(fraction: progress) }
            }
            .frame(width: width, height: width * 9 / 16)
            .overlay(alignment: .topTrailing) {
                if isDownloaded { DownloadedBadge().padding(6) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(hovering ? Palette.brandBright.opacity(0.7) : .white.opacity(0.06), lineWidth: hovering ? 1.5 : 1))
            .scaleEffect(hovering && !reduceMotion ? 1.05 : 1)
            .modifier(HoverShadow(on: hovering))
            .animation(Motion.cardZoom(reduceMotion), value: hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.cardTitle).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .modifier(HoverHighlight(on: $hovering))
        .accessibilityElement(children: .combine)
    }
}

public struct BadgeView: View {
    let text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.heavy))
            .tracking(0.6)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Palette.brand, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .foregroundStyle(.white)
    }
}

// MARK: - Rows

/// Horizontally scrolling row with a header. Generic over its items so the
/// same component serves posters, landscape cards, Top 10 and cast.
///
/// Pass `itemWidth` to get Netflix's paging arrows at the row's edges when a
/// pointer hovers (Mac, iPad with a trackpad); a mouse wheel can't scroll
/// sideways, so on the Mac these are the way through a row.
public struct ShelfRow<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    let inset: CGFloat
    let itemWidth: CGFloat?
    let seeAll: (() -> Void)?
    let card: (Item) -> Card
    @State private var leading: Item.ID?
    @State private var hovering = false
    @State private var rowWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ title: String, items: [Item], inset: CGFloat, itemWidth: CGFloat? = nil, seeAll: (() -> Void)? = nil,
                @ViewBuilder card: @escaping (Item) -> Card) {
        self.title = title; self.items = items; self.inset = inset; self.itemWidth = itemWidth
        self.seeAll = seeAll; self.card = card
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader(title, action: seeAll)
                .padding(.horizontal, inset)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Spacing.cardGap) {
                    ForEach(items) { card($0).modifier(RaiseOnHover()) }
                }
                .scrollTargetLayout()
                .padding(.horizontal, inset)
                .padding(.vertical, Spacing.s)  // room for hover scale
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .scrollPosition(id: $leading, anchor: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .overlay { if itemWidth != nil { pager } }
        }
        .onHover { hovering = $0 }
    }

    // MARK: Paging arrows

    private var pageSize: Int {
        guard let itemWidth, itemWidth > 0 else { return 1 }
        return max(1, Int((rowWidth - inset * 2 + Spacing.cardGap) / (itemWidth + Spacing.cardGap)))
    }

    private var index: Int {
        leading.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
    }

    private var pager: some View {
        HStack {
            arrow("chevron.left", label: "Previous", visible: index > 0) { page(-1) }
            Spacer()
            arrow("chevron.right", label: "Next", visible: index + pageSize < items.count) { page(1) }
        }
        .opacity(hovering ? 1 : 0)
        .animation(Motion.hover, value: hovering)
    }

    private func arrow(_ symbol: String, label: String, visible: Bool, action: @escaping () -> Void) -> some View {
        let left = symbol.hasSuffix("left")
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.bold))
                .frame(width: max(inset, 36))
                .frame(maxHeight: .infinity)
                .background(LinearGradient(colors: [Palette.background.opacity(0.85), Palette.background.opacity(0.3)],
                                           startPoint: left ? .leading : .trailing, endPoint: left ? .trailing : .leading))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible && hovering)
        .accessibilityLabel(label)
        .accessibilityHidden(true)  // VoiceOver swipes through the row itself
    }

    private func page(_ direction: Int) {
        let target = min(max(index + direction * pageSize, 0), max(items.count - 1, 0))
        guard items.indices.contains(target) else { return }
        withAnimation(Motion.spatial(reduceMotion)) { leading = items[target].id }
    }
}

// MARK: - Brand

/// Wordmark: the drawn BLUEBOX letters (`BlueboxLetters`) in brand blue over a
/// navy glow.
///
/// `size` is the type size the wordmark used to be set in: the letters' cap
/// height is 0.705 of it (as SF's is) and the view is a text line tall, so
/// layouts built around the old `Text` keep their spacing.
public struct BlueboxWordmark: View {
    let size: CGFloat
    public init(size: CGFloat = 28) { self.size = size }
    public var body: some View {
        BlueboxLetters.sized(size)
            .foregroundStyle(LinearGradient(colors: [Palette.brand, Palette.brandDeep],
                                            startPoint: .top, endPoint: .bottom))
            .shadow(color: Palette.navy, radius: size * 0.3)
            .accessibilityElement()
            .accessibilityLabel("Bluebox")
    }
}

extension BlueboxLetters {
    /// The letters at `size`-point type: cap height 0.705 × `size`, centred in
    /// a frame one text line (1.18 × `size`) tall and exactly as wide as the
    /// letters.
    static func sized(_ size: CGFloat) -> some View {
        let height = size * 0.705 / capHeightRatio
        return BlueboxLetters()
            .frame(width: height * aspectRatio, height: height)
            .padding(.vertical, (size * 1.18 - height) / 2)
    }
}

// MARK: - States

/// Empty, failed and offline states: a symbol in a soft disc, a title, a
/// line of explanation, and the next step: a white button (Netflix's "Find
/// Something to Watch"), with an optional second choice as a blue text link
/// under it.
///
/// One component for all three, so "nothing here", "couldn't load" and
/// "you're offline" look alike but can't be mistaken for each other: an empty
/// state has a blue symbol; a failure or the offline page, a grey one.
///
/// Every state should offer a way forward, so pass `actionTitle` and
/// `action` whenever there's somewhere useful to go (Try Again for a
/// failure, Go to Downloads offline).
public struct StateMessage: View {
    public enum Kind: Sendable, Equatable {
        /// Loaded fine, and there's nothing to show.
        case empty
        /// The load failed; the message says why and the action retries.
        case failed
        /// The device is offline and this screen needs the network.
        case offline
    }

    let kind: Kind
    let systemImage: String
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?
    let secondaryActionTitle: String?
    let secondaryAction: (() -> Void)?

    public init(_ kind: Kind, systemImage: String? = nil, title: String, message: String? = nil,
                actionTitle: String? = nil, action: (() -> Void)? = nil,
                secondaryActionTitle: String? = nil, secondaryAction: (() -> Void)? = nil) {
        self.kind = kind
        self.systemImage = systemImage ?? Self.defaultSymbol(kind)
        self.title = title; self.message = message
        self.actionTitle = actionTitle; self.action = action
        self.secondaryActionTitle = secondaryActionTitle; self.secondaryAction = secondaryAction
    }

    /// An empty state with its own symbol.
    public init(systemImage: String, title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil,
                secondaryActionTitle: String? = nil, secondaryAction: (() -> Void)? = nil) {
        self.init(.empty, systemImage: systemImage, title: title, message: message, actionTitle: actionTitle, action: action,
                  secondaryActionTitle: secondaryActionTitle, secondaryAction: secondaryAction)
    }

    static func defaultSymbol(_ kind: Kind) -> String {
        switch kind {
        case .empty: "tray"
        case .failed: "exclamationmark.triangle"
        case .offline: "wifi.slash"
        }
    }

    @ViewBuilder private var symbol: some View {
        let image = Image(systemName: systemImage)
            .font(.system(size: 30, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 72, height: 72)
        switch kind {
        case .empty:
            image
                .foregroundStyle(Palette.brandBright)
                .background(Circle().fill(RadialGradient(colors: [Palette.navyGlow, Palette.navy.opacity(0.4)],
                                                         center: .center, startRadius: 0, endRadius: 40)))
                .overlay(Circle().strokeBorder(Palette.brand.opacity(0.25), lineWidth: 1))
        case .failed, .offline:
            // Grey, not blue: blue is for state you chose, and this isn't.
            image
                .foregroundStyle(Palette.textSecondary)
                .background(Circle().fill(Palette.elevated))
                .overlay(Circle().strokeBorder(Palette.edge, lineWidth: 1))
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.m) {
                symbol
                    .padding(.bottom, Spacing.xs)
                    .accessibilityHidden(true)
                Text(ui: title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(ui: message).font(.callout).foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(ui: actionTitle).lineLimit(1).frame(minWidth: 160)
                }
                .buttonStyle(PlayButtonStyle())
                .padding(.top, Spacing.xl)
            }
            if let secondaryActionTitle, let secondaryAction {
                Button(action: secondaryAction) {
                    Text(secondaryActionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.brandBright)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .padding(.top, actionTitle == nil ? Spacing.l : Spacing.xs)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xxl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stateMessage.\(kind)")
    }
}

/// "Couldn't refresh · Retry": a small pill over content that's still worth
/// showing after a reload failed (or while offline), in place of an error page.
public struct InlineNotice: View {
    let systemImage: String
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(systemImage: String = "exclamationmark.circle", _ text: String, actionTitle: String? = nil,
                action: (() -> Void)? = nil) {
        self.systemImage = systemImage; self.text = text; self.actionTitle = actionTitle; self.action = action
    }

    public var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Text("·").font(.footnote).foregroundStyle(Palette.textTertiary).accessibilityHidden(true)
                Button(action: action) {
                    Text(ui: actionTitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.brandBright)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("inlineNotice.action")
            }
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: 36)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.edge))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inlineNotice")
    }
}

/// Skeleton row shown while a shelf loads.
public struct ShelfPlaceholder: View {
    let inset: CGFloat
    let width: CGFloat
    let height: CGFloat

    public init(inset: CGFloat, width: CGFloat, height: CGFloat) { self.inset = inset; self.width = width; self.height = height }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SkeletonBlock(width: 180, height: 18, radius: 4)
            HStack(spacing: Spacing.cardGap) {
                ForEach(0..<8, id: \.self) { _ in
                    SkeletonBlock(width: width, height: height)
                }
            }
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .shimmering()
        .padding(.horizontal, inset)
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

public enum Formatters {
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "1h 52m", "48m"
    public static func runtime(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    public static func remaining(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded(.up))
        return m >= 60 ? "\(m / 60)h \(m % 60)m left" : "\(m)m left"
    }

    public static func bytes(_ b: Int64) -> String { byteFormatter.string(fromByteCount: b) }

    /// "0 KB", not ByteCountFormatter's "Zero KB".
    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {  // formatting is thread-safe
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()
}


/// Profile colours. The first eight are the original blues (stored profiles
/// index into them); the other eight, added with the profile editor, are
/// muted so profiles can tell themselves apart without fighting the blue
/// accent. Sync keeps indexes 0–15.
public extension Palette {
    static let profileColors: [Color] = [
        Color(red: 0.16, green: 0.40, blue: 1.0), Color(red: 0.09, green: 0.25, blue: 0.72),
        Color(red: 0.30, green: 0.62, blue: 1.0), Color(red: 0.0, green: 0.55, blue: 0.85),
        Color(red: 0.36, green: 0.36, blue: 0.95), Color(red: 0.12, green: 0.18, blue: 0.45),
        Color(red: 0.45, green: 0.75, blue: 0.95), Color(red: 0.22, green: 0.30, blue: 0.60),
        // Teal, green, amber, orange, red, pink, purple, graphite.
        Color(red: 0.05, green: 0.58, blue: 0.56), Color(red: 0.22, green: 0.60, blue: 0.30),
        Color(red: 0.85, green: 0.62, blue: 0.12), Color(red: 0.88, green: 0.42, blue: 0.16),
        Color(red: 0.82, green: 0.24, blue: 0.27), Color(red: 0.86, green: 0.33, blue: 0.58),
        Color(red: 0.55, green: 0.32, blue: 0.86), Color(red: 0.38, green: 0.40, blue: 0.45),
    ]
    static func profileColor(_ i: Int) -> Color { profileColors[((i % profileColors.count) + profileColors.count) % profileColors.count] }
}

/// A profile's avatar as the picker, menus and top bar draw it: a rounded
/// square with a soft gradient of the profile colour and its symbol.
public struct ProfileBadge: View {
    let symbol: String
    let color: Int
    let size: CGFloat
    public init(symbol: String, color: Int, size: CGFloat) { self.symbol = symbol; self.color = color; self.size = size }
    public var body: some View {
        let c = Palette.profileColor(color)
        RoundedRectangle(cornerRadius: size * (size > 60 ? 0.12 : 0.2), style: .continuous)
            .fill(LinearGradient(colors: [c, c.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Image(systemName: symbol)
                .font(.system(size: size * (size > 60 ? 0.42 : 0.5), weight: .semibold))
                .foregroundStyle(.white.opacity(0.95)))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A round profile badge: colored disc with a symbol.
public struct ProfileAvatar: View {
    let symbol: String
    let color: Int
    let size: CGFloat
    public init(symbol: String, color: Int, size: CGFloat = 28) { self.symbol = symbol; self.color = color; self.size = size }
    public var body: some View {
        Circle().fill(Palette.profileColor(color))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}


/// Pointer hover on Mac and iPad. Like Netflix, a card only grows once the
/// pointer rests on it briefly, so sweeping across a row doesn't pop every card.
struct HoverHighlight: ViewModifier {
    @Binding var on: Bool
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.onHover { inside in
            pending?.cancel()
            if inside {
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    if !Task.isCancelled { on = true }
                }
            } else {
                on = false
            }
        }
    }
}

/// Draws the hovered card above its neighbours so its zoom isn't covered.
struct RaiseOnHover: ViewModifier {
    @State private var raised = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.zIndex(raised ? 1 : 0).onHover { inside in
            pending?.cancel()
            if inside {
                raised = true
            } else {
                // Stay on top until the card has finished shrinking back.
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    if !Task.isCancelled { raised = false }
                }
            }
        }
    }
}

/// The lift shadow under a hovered card. A 22-point shadow left on every card
/// at zero opacity still costs a blur pass per card per frame, so on iOS
/// (where most cards are never hovered) its radius drops to zero too.
struct HoverShadow: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        #if os(macOS)
        content.shadow(color: .black.opacity(on ? 0.75 : 0), radius: 22, y: 12)
        #else
        // Same view either way (no if/else), so hovering doesn't rebuild the card.
        content.shadow(color: .black.opacity(on ? 0.75 : 0), radius: on ? 22 : 0, y: on ? 12 : 0)
        #endif
    }
}
