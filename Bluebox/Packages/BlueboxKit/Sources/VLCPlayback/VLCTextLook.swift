import Foundation
import Subtitles
import VLCVariables

/// A subtitle style as VLC's text renderer variables, set on a player.
///
/// VLC's freetype renderer reads the colour, the box and the outline
/// thickness each time it draws, so those change on the picture at once (from
/// the next line on screen). `sub-margin` is also passed to the running video
/// outputs, which move the text straight away. The font, weight, opacity,
/// outline colour and shadow are read when the renderer starts (the next
/// video), and the alignment when the subtitle decoder starts (the engine
/// restarts it on the same track).
struct VLCTextLook: Equatable {
    var font: String
    var bold: Bool
    var color: Int
    var opacity: Int
    var outline: Int
    var outlineColor: Int
    var shadowOpacity: Int
    var backgroundColor: Int
    var backgroundOpacity: Int
    /// Pixels of a 1080-line picture above VLC's own bottom margin.
    var margin: Int
    /// VLC's text decoder: 0 centre, 1 left, 2 right.
    var align: Int

    init(_ style: SubtitleStyle) {
        func rgb(_ c: RGBA) -> Int { Int(c.r * 255) << 16 | Int(c.g * 255) << 8 | Int(c.b * 255) }
        func alpha(_ a: Double) -> Int { Int((min(max(a, 0), 1) * 255).rounded()) }
        font = style.resolvedFontFamily
        bold = style.isBold
        color = rgb(style.textColor)
        opacity = alpha(style.textColor.a)
        outline = switch style.outlineWidth { case ..<0.1: 0; case ..<1.5: 2; case ..<3.5: 4; default: 6 }
        outlineColor = rgb(style.outlineColor)
        shadowOpacity = style.shadow ? alpha(style.shadowOpacity * 0.8) : 0
        backgroundColor = rgb(style.backgroundColor)
        backgroundOpacity = alpha(style.backgroundOpacity)
        // VLC only places text up from the bottom: middle and top are reached by
        // raising it (a typical line's height is allowed for the text).
        let line = 0.06
        let fromBottom: Double = switch style.anchor {
        case .bottom: style.verticalMargin
        case .middle: 0.5 - line / 2
        case .top: 1 - style.verticalMargin - line
        }
        margin = max(0, Int(((fromBottom - SubtitleStyle.defaultMargin) * 1080).rounded()))
        align = switch style.alignment { case .leading: 1; case .trailing: 2; case .center: 0 }
    }

    /// Sets on `player` (a `libvlc_media_player_t *`) what differs from `old`
    /// (everything when nil). False when the player isn't libVLC 4's as expected
    /// (nothing is set then, and subtitles keep VLC's default look).
    @discardableResult
    func apply(to player: UnsafeMutableRawPointer, changedFrom old: VLCTextLook?) -> Bool {
        guard bluebox_vlc_set_integer(player, "freetype-color", Int64(color)) else { return false }
        func int(_ name: String, _ v: Int, _ was: Int?) {
            if v != was { _ = bluebox_vlc_set_integer(player, name, Int64(v)) }
        }
        if font != old?.font { _ = bluebox_vlc_set_string(player, "freetype-font", font) }
        if bold != old?.bold { _ = bluebox_vlc_set_bool(player, "freetype-bold", bold) }
        int("freetype-color", color, old?.color)
        int("freetype-opacity", opacity, old?.opacity)
        int("freetype-outline-thickness", outline, old?.outline)
        int("freetype-outline-color", outlineColor, old?.outlineColor)
        // Always opaque: no outline is thickness 0, which changes live (opacity doesn't).
        if old == nil { _ = bluebox_vlc_set_integer(player, "freetype-outline-opacity", 255) }
        int("freetype-shadow-opacity", shadowOpacity, old?.shadowOpacity)
        if old == nil {
            _ = bluebox_vlc_set_integer(player, "freetype-shadow-color", 0)
            _ = bluebox_vlc_set_float(player, "freetype-shadow-angle", -90)
        }
        int("freetype-background-color", backgroundColor, old?.backgroundColor)
        int("freetype-background-opacity", backgroundOpacity, old?.backgroundOpacity)
        int("subsdec-align", align, old?.align)
        if margin != old?.margin {
            _ = bluebox_vlc_set_integer(player, "sub-margin", Int64(margin))
            _ = bluebox_vlc_set_vout_integer(player, "sub-margin", Int64(margin))
        }
        // libass (ASS tracks) finds no system fonts by itself: without a folder,
        // a track whose video carries no fonts shows nothing at all.
        if old == nil, let fonts = SubtitleFontFolder.path { _ = bluebox_vlc_set_string(player, "ssa-fontsdir", fonts) }
        return true
    }
}

/// A folder of links to the fonts ASS subtitles usually ask for, for libass.
///
/// libass in this libVLC build has no system font lookup, only `ssa-fontsdir`,
/// and it reads every file in that folder into memory each time an ASS
/// subtitle decoder starts. So it gets a small folder (about 25 MB): Helvetica
/// Neue (libass's fallback for any font it can't find) and the common Windows
/// families. The large CJK collections (over 100 MB together) made picking a
/// track stall for seconds; ASS releases in those scripts carry their fonts.
enum SubtitleFontFolder {
    static let wanted = [
        "HelveticaNeue.ttc", "Arial.ttf", "Arial Bold.ttf", "Arial Italic.ttf", "Arial Bold Italic.ttf",
        "Times New Roman.ttf", "Times New Roman Bold.ttf", "Times New Roman Italic.ttf",
        "Verdana.ttf", "Verdana Bold.ttf", "Trebuchet MS.ttf", "Trebuchet MS Bold.ttf", "Georgia.ttf", "Georgia Bold.ttf",
        "Tahoma.ttf", "Tahoma Bold.ttf", "Comic Sans MS.ttf", "Comic Sans MS Bold.ttf", "Impact.ttf",
    ]
    static let searched = ["/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/System/Library/Fonts/Core",
                           "/System/Library/Fonts/CoreAddition", "/System/Library/Fonts/CoreUI", "/Library/Fonts"]

    /// Made once per launch; nil when no font could be linked.
    static let path: String? = {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appending(path: "SubtitleFonts", directoryHint: .isDirectory)
        try? fm.removeItem(at: dir)  // system fonts move between OS versions: link afresh
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        var linked = 0
        for name in wanted {
            guard let source = searched.lazy.map({ "\($0)/\(name)" }).first(where: fm.isReadableFile(atPath:)) else { continue }
            if (try? fm.createSymbolicLink(atPath: dir.appending(path: name).path, withDestinationPath: source)) != nil { linked += 1 }
        }
        return linked > 0 ? dir.path : nil
    }()
}
