import SwiftUI

/// Bluebox's palette: the OLED-black finish. Pages are true black, surfaces
/// are neutral greys (no navy, no glass), and one blue is kept for what
/// matters: highlights, selection, progress, links and the wordmark. Play is
/// white with black text.
///
/// Chrome text stays white at fixed levels so contrast holds over artwork:
/// `textPrimary` and `textSecondary` clear 4.5:1 on every surface here
/// (#A3A3A3 is 8:1 on black, 6.6:1 on `elevated`); `textTertiary` (#6B6B6B,
/// 3.9:1 on black) is for captions, hints and shortcuts only.
public enum Palette {
    /// App background: true black.
    public static let background = Color.black
    /// Bars and other chrome over the page (#0B0B0B).
    public static let chrome = Color(white: 0.043)
    /// Cards, sheets, grouped rows, menus (#161616).
    public static let surface = Color(white: 0.086)
    /// Raised controls, hovered rows, secondary buttons, skeletons' highlight (#232323).
    public static let elevated = Color(white: 0.137)
    /// Hairlines and dividers.
    public static let separator = Color.white.opacity(0.08)
    /// The faint edge around panels and menus.
    public static let edge = Color.white.opacity(0.07)

    // The accent follows Settings › Appearance › Theme Colour (`ThemeAccent`).
    // Reading one inside a view's body observes the choice, so a change
    // repaints everything that uses it, the wordmark included.

    /// Brand blue (#3D7BFF) by default: progress, selection, badges, links, the wordmark.
    public static var brand: Color { ThemeStore.shared.accent.brand }
    /// Lighter brand for text and glyphs on black (6.9:1 on `background` for blue).
    public static var brandBright: Color { ThemeStore.shared.accent.bright }
    /// Pressed/darker brand state.
    public static var brandDeep: Color { ThemeStore.shared.accent.deep }
    /// The wash behind a hovered or highlighted menu row.
    public static var wash: Color { ThemeStore.shared.accent.brand.opacity(0.22) }
    /// Kept for older call sites: the dark end of hero gradients and glows,
    /// now neutral so the finish stays black and grey.
    public static let navy = Color(white: 0.043)
    /// The top of the faint wash on Home and the title page (neutral grey).
    public static let navyGlow = Color(white: 0.11)

    public static let textPrimary = Color.white
    /// #A3A3A3.
    public static let textSecondary = Color(white: 0.64)
    /// #6B6B6B.
    public static let textTertiary = Color(white: 0.42)
    /// Errors stay neutral-on-black with an icon rather than introducing red.
    public static let warning = Color.white.opacity(0.85)

    /// Secondary buttons ("My List", "Releases"): solid raised grey, no glass.
    public static let glassFill = Color(white: 0.137)
    public static let glassFillPressed = Color(white: 0.20)
}

/// Settings › Appearance › Theme Colour: the one accent colour, from a short
/// list picked to hold up on true black (each `bright` clears 4.5:1 on it).
/// Blue is Bluebox's own; the rest recolour the wordmark and, where the
/// platform allows, the app icon (`hueRotation` from the blue icon).
public enum ThemeAccent: String, CaseIterable, Identifiable, Sendable {
    case blue, indigo, purple, pink, red, orange, amber, green, teal, graphite
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .blue: "Bluebox Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .amber: "Amber"
        case .green: "Green"
        case .teal: "Teal"
        case .graphite: "Graphite"
        }
    }

    public var brand: Color {
        switch self {
        case .blue: Color(red: 0.24, green: 0.48, blue: 1.0)
        case .indigo: Color(red: 0.40, green: 0.40, blue: 1.0)
        case .purple: Color(red: 0.62, green: 0.36, blue: 0.98)
        case .pink: Color(red: 0.96, green: 0.32, blue: 0.62)
        case .red: Color(red: 0.94, green: 0.26, blue: 0.27)
        case .orange: Color(red: 1.0, green: 0.50, blue: 0.16)
        case .amber: Color(red: 0.93, green: 0.70, blue: 0.16)
        case .green: Color(red: 0.20, green: 0.74, blue: 0.40)
        case .teal: Color(red: 0.10, green: 0.70, blue: 0.75)
        case .graphite: Color(white: 0.62)
        }
    }

    public var bright: Color {
        switch self {
        case .blue: Color(red: 0.43, green: 0.61, blue: 1.0)
        case .indigo: Color(red: 0.56, green: 0.56, blue: 1.0)
        case .purple: Color(red: 0.74, green: 0.56, blue: 1.0)
        case .pink: Color(red: 1.0, green: 0.52, blue: 0.74)
        case .red: Color(red: 1.0, green: 0.47, blue: 0.47)
        case .orange: Color(red: 1.0, green: 0.64, blue: 0.38)
        case .amber: Color(red: 1.0, green: 0.82, blue: 0.40)
        case .green: Color(red: 0.40, green: 0.86, blue: 0.56)
        case .teal: Color(red: 0.36, green: 0.84, blue: 0.88)
        case .graphite: Color(white: 0.80)
        }
    }

    public var deep: Color {
        switch self {
        case .blue: Color(red: 0.16, green: 0.36, blue: 0.84)
        case .indigo: Color(red: 0.28, green: 0.28, blue: 0.82)
        case .purple: Color(red: 0.46, green: 0.24, blue: 0.80)
        case .pink: Color(red: 0.78, green: 0.20, blue: 0.48)
        case .red: Color(red: 0.76, green: 0.16, blue: 0.18)
        case .orange: Color(red: 0.84, green: 0.38, blue: 0.08)
        case .amber: Color(red: 0.76, green: 0.54, blue: 0.08)
        case .green: Color(red: 0.12, green: 0.56, blue: 0.28)
        case .teal: Color(red: 0.04, green: 0.52, blue: 0.58)
        case .graphite: Color(white: 0.44)
        }
    }

    /// Turns the blue app icon into this colour: degrees round the colour
    /// wheel (CIHueAdjust's, tuned by eye) from the icon's blue, and how much
    /// colour to keep. tools/make-theme-icons.swift uses the same numbers.
    public var iconHueRotation: Double {
        switch self {
        case .blue, .graphite: 0
        case .indigo: 12
        case .purple: 28
        case .pink: 88
        case .red: 118
        case .orange: 142
        case .amber: 160
        case .green: -85
        case .teal: -45
        }
    }

    public var iconSaturation: Double { self == .graphite ? 0 : 1 }

    /// The alternate app icon's name (iOS asset catalog), nil for the main icon.
    public var alternateIconName: String? { self == .blue ? nil : "AppIcon-\(rawValue.capitalized)" }
}

/// The chosen accent, kept on this device. Observable, so `Palette.brand`
/// read inside a body redraws that view when it changes.
@Observable
public final class ThemeStore: @unchecked Sendable {
    public static let shared = ThemeStore()
    static let key = "bluebox.themeAccent"

    public var accent: ThemeAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: Self.key) }
    }

    init() {
        accent = UserDefaults.standard.string(forKey: Self.key).flatMap(ThemeAccent.init(rawValue:)) ?? .blue
    }
}

public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48

    /// Gap between cards in a row (Netflix keeps these tight).
    public static let cardGap: CGFloat = 8
    /// Vertical gap between Home rows.
    public static let rowGap: CGFloat = 28

    /// Horizontal page inset that scales with the container width.
    public static func pageInset(for width: CGFloat) -> CGFloat {
        switch width {
        case ..<500: 16
        case ..<900: 24
        case ..<1400: 40
        default: 56
        }
    }
}

public enum Radius {
    /// Posters and landscape cards.
    public static let card: CGFloat = 6
    /// Buttons, fields, chips' inner radius.
    public static let control: CGFloat = 8
    /// Large hero cards (iPhone Home), panels.
    public static let hero: CGFloat = 14
    public static let sheet: CGFloat = 16
    /// Thumbnails inside rows.
    public static let thumbnail: CGFloat = 4
}

/// The type scale. Every style is a text style, so it scales with Dynamic Type
/// on iOS; display styles add weight and the condensed width.
public enum Typography {
    /// The hero title over artwork.
    public static func display(compact: Bool) -> Font {
        (compact ? Font.largeTitle : .system(size: 52)).weight(.black).width(.condensed)
    }
    /// A title page's name when there's no logo art.
    public static let titleHero = Font.largeTitle.weight(.black).width(.condensed)
    /// Page titles under the top bar ("My List", "New & Hot").
    public static let pageTitle = Font.title.weight(.bold)
    /// Row headers on Home.
    public static let rowTitle = Font.title3.weight(.bold)
    /// Card titles, episode names.
    public static let cardTitle = Font.subheadline.weight(.semibold)
    /// Metadata lines (year · rating · runtime).
    public static let meta = Font.subheadline.weight(.medium)
    public static let body = Font.callout
    public static let caption = Font.caption
    /// Button labels.
    public static let button = Font.headline
}

/// Springs, per Apple's guidance: no bounce on chrome, short durations for
/// controls, a touch longer for spatial moves. Every helper takes Reduce Motion.
public enum Motion {
    /// Standard UI transition. Callers pass `reduceMotion` to drop movement.
    public static func standard(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.35)
    }
    /// Toggles, chips, buttons.
    public static func snappy(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.3)
    }
    /// Pages, heroes, larger spatial moves.
    public static func spatial(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.45)
    }
    public static let hover = Animation.easeOut(duration: 0.18)
    public static let press = Animation.snappy(duration: 0.2)
    /// Card zoom on hover: a quick, soft spring.
    public static func cardZoom(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.3)
    }
}

/// Card sizes derived from container width, keeping the 2:3 poster and 16:9
/// landscape ratios constant.
public struct CardMetrics: Sendable {
    public let posterWidth: CGFloat
    public let landscapeWidth: CGFloat
    public var posterHeight: CGFloat { posterWidth * 1.5 }
    public var landscapeHeight: CGFloat { landscapeWidth * 9 / 16 }
    /// Top 10 cards: a poster plus room for the numeral on its left.
    public var topTenWidth: CGFloat { posterWidth * 1.55 }

    public init(containerWidth w: CGFloat) {
        switch w {
        case ..<500: posterWidth = 108; landscapeWidth = 232
        case ..<900: posterWidth = 136; landscapeWidth = 272
        case ..<1400: posterWidth = 156; landscapeWidth = 310
        default: posterWidth = 180; landscapeWidth = 350
        }
    }
}

public extension Text {
    /// Words held in a `String` (a component's title, an enum's name) looked
    /// up in the app's strings (Apps/Shared/Localizable.xcstrings) like a
    /// literal would be. Not for catalog text such as a film's name.
    init(ui string: String) {
        if string.contains("%") {
            self.init(verbatim: string)
        } else {
            self.init(LocalizedStringKey(string))
        }
    }
}

public extension View {
    /// Applies Bluebox's dark chrome to a screen.
    func blueboxScreen() -> some View {
        background(Palette.background.ignoresSafeArea())
            .foregroundStyle(Palette.textPrimary)
            .tint(Palette.brand)
    }
}
