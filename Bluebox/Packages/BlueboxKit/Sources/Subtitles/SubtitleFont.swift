import CoreText
import Foundation

/// The one font both subtitle renderers use: Bluebox's own text (files, and
/// tracks AVPlayer hands over) and VLC's (the video's own text tracks).
///
/// VLC looks fonts up by family and knows only bold or not, and no italic, so
/// a style resolves to an installed family and bold or regular, and Bluebox
/// draws exactly that too. The designs map to families every Mac and iPhone
/// has (not San Francisco, which VLC can't load by name). A family chosen on
/// another device and missing here falls back to the design's, the same in both.
public extension SubtitleStyle {
    /// The installed family to draw with.
    var resolvedFontFamily: String {
        if let name = fontName, SubtitleFontCatalog.isInstalled(name) { return name }
        return Self.family(for: design)
    }

    /// Light and Medium draw regular; the heavier weights bold.
    var isBold: Bool { !(weight == .regular || weight == .medium) }

    static func family(for design: FontDesign) -> String {
        switch design {
        case .system: "Helvetica Neue"
        case .rounded: "Arial Rounded MT Bold"
        case .serif: "Georgia"
        case .monospaced: "Menlo"
        }
    }
}

/// The fonts subtitles can use: the ones Bluebox brings, and installed families.
public enum SubtitleFontCatalog {
    /// Fonts in the app (SIL OFL), the same on every device: Atkinson
    /// Hyperlegible (made for low vision) and Inter.
    public static let bundled = ["Atkinson Hyperlegible", "Inter"]

    /// Families that read well as subtitles, offered first (those installed here).
    public static let suggested = ["Helvetica Neue", "Avenir Next", "Futura", "Gill Sans", "Georgia", "Verdana", "Trebuchet MS"]

    /// Registered for this process on first use, so Core Text, SwiftUI and
    /// libVLC's Core Text font finder all see them by family name.
    private static let installed: Set<String> = {
        for url in Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
    }()

    /// Registers the bundled fonts (call once early, before any subtitle draws).
    public static func prepare() { _ = installed }

    public static func isInstalled(_ family: String) -> Bool { installed.contains(family) }

    /// Every installed family, for "All Fonts…".
    public static var allFamilies: [String] { installed.filter { !$0.hasPrefix(".") }.sorted() }
}
