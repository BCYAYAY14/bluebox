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

    /// Brand blue (#3D7BFF): progress, selection, badges, links, the wordmark.
    public static let brand = Color(red: 0.24, green: 0.48, blue: 1.0)
    /// Lighter blue for text and glyphs on black (6.9:1 on `background`).
    public static let brandBright = Color(red: 0.43, green: 0.61, blue: 1.0)
    /// Pressed/darker brand state.
    public static let brandDeep = Color(red: 0.16, green: 0.36, blue: 0.84)
    /// The blue wash behind a hovered or highlighted menu row.
    public static let wash = Color(red: 0.24, green: 0.48, blue: 1.0).opacity(0.22)
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

public extension View {
    /// Applies Bluebox's dark chrome to a screen.
    func blueboxScreen() -> some View {
        background(Palette.background.ignoresSafeArea())
            .foregroundStyle(Palette.textPrimary)
            .tint(Palette.brand)
    }
}
