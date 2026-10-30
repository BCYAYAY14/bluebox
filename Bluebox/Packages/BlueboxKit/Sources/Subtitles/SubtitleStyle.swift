import Foundation

/// An sRGB color with alpha, stored as plain numbers so styles sync and persist.
public struct RGBA: Hashable, Codable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = Self.unit(r); self.g = Self.unit(g); self.b = Self.unit(b); self.a = Self.unit(a)
    }
    static func unit(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }

    public static let white = RGBA(1, 1, 1)
    public static let black = RGBA(0, 0, 0)
    public static let lightGray = RGBA(0.82, 0.82, 0.84)
    public static let lightBlue = RGBA(0.66, 0.82, 1)
    public static let yellow = RGBA(1, 0.92, 0.3)
}

/// The look of subtitles Bluebox draws (external files and embedded text tracks).
///
/// Sizes and margins are fractions of the video's height and width, so text
/// keeps its proportions in a small window, full screen, or Picture in Picture.
public struct SubtitleStyle: Hashable, Codable, Sendable {
    public enum FontDesign: String, Codable, Sendable, CaseIterable { case system, rounded, serif, monospaced }
    public enum Weight: String, Codable, Sendable, CaseIterable { case regular, medium, semibold, bold, heavy }
    public enum Alignment: String, Codable, Sendable, CaseIterable { case leading, center, trailing }
    /// Which part of the picture the subtitles hold to. Middle centres them
    /// vertically (the distance from the edge doesn't apply).
    public enum Anchor: String, Codable, Sendable, CaseIterable { case bottom, middle, top }

    public var design: FontDesign = .system
    /// An installed font family; overrides `design` when set and available.
    public var fontName: String?
    /// Text height as a fraction of the video height (VLC-style relative size).
    public var relativeSize: Double = 0.045
    public var weight: Weight = .semibold
    public var italic = false
    public var textColor: RGBA = .white
    /// Outline thickness in points at 1080p (0 = none).
    public var outlineWidth: Double = 1  // a thin dark edge, with the shadow: legible on bright scenes
    public var outlineColor: RGBA = .black
    public var shadow = true
    public var shadowOpacity: Double = 0.9
    /// Box behind the text; opacity 0 = no box.
    public var backgroundColor: RGBA = .black
    public var backgroundOpacity: Double = 0
    public var alignment: Alignment = .center
    public var anchor: Anchor = .bottom
    /// Distance from the anchored edge, as a fraction of the video height.
    public var verticalMargin: Double = 0.06
    /// Side margins, as a fraction of the video width.
    public var horizontalMargin: Double = 0.08
    /// Sideways shift from the aligned position, as a fraction of the video
    /// width (set by dragging the subtitles on the video; 0 = not moved).
    public var horizontalOffset: Double = 0
    /// Extra space between lines, as a fraction of the text size.
    public var lineSpacing: Double = 0.05
    /// Move bottom subtitles up while the player controls are showing.
    public var avoidControls = true
    /// The second subtitle track (dual subtitles) is drawn at this scale and color.
    public var secondaryScale: Double = 0.85
    public var secondaryColor: RGBA = .yellow
    public var preferredLanguage: String? = nil
    public var secondaryLanguage: String? = nil
    /// Hide Sound Cues: [bracketed] and (parenthesised) cues, ♪ lyrics and
    /// "NAME:" labels left out of the lines Bluebox draws (see `SoundCues`).
    public var hidesSoundCues = false
    /// Looks saved with "Save Current", shown after the presets.
    public var savedLooks: [SavedLook] = []

    public init() {}

    /// Point size for a video of the given height.
    public func pointSize(forHeight h: Double) -> Double {
        max(9, min(h * Self.clampSize(relativeSize), 160))
    }

    public static func clampSize(_ s: Double) -> Double { s.isFinite ? min(max(s, 0.02), 0.12) : 0.045 }

    // MARK: Position

    public static let defaultMargin = 0.06

    /// True when the subtitles sit where they start out: bottom centre.
    public var isDefaultPosition: Bool {
        anchor == .bottom && alignment == .center && abs(verticalMargin - Self.defaultMargin) < 0.001 && abs(horizontalOffset) < 0.001
    }

    /// Back to bottom centre, keeping the look.
    public mutating func resetPosition() {
        anchor = .bottom; alignment = .center; verticalMargin = Self.defaultMargin; horizontalOffset = 0
    }

    /// Pins the subtitles to one of nine spots (the anchor grid): the edge
    /// and side, at the usual distance, with any dragged shift cleared.
    public mutating func pin(_ anchor: Anchor, _ alignment: Alignment) {
        self.anchor = anchor; self.alignment = alignment; horizontalOffset = 0
        if anchor != .middle, verticalMargin > 0.3 { verticalMargin = Self.defaultMargin }
    }

    /// Applies where a dragged subtitle block was dropped (see `SubtitlePlacement`).
    public mutating func place(_ p: SubtitlePlacement) {
        anchor = p.anchor; verticalMargin = p.verticalMargin; horizontalOffset = p.horizontalOffset
    }

    /// How far (a fraction of the picture's height) the edge of bottom subtitles
    /// sits from the bottom while something covers `covered` of it there (the
    /// player's bar): its own distance when that already clears it, else just
    /// above. Top subtitles likewise under `coveredTop`. Middle never moves. One
    /// rule for every renderer, so nothing jumps as a margin crosses a threshold.
    public func restingMargin(coveredBottom: Double, coveredTop: Double = 0) -> Double {
        switch anchor {
        case .middle: 0
        case .bottom: avoidControls ? max(verticalMargin, coveredBottom) : verticalMargin
        case .top: avoidControls ? max(verticalMargin, coveredTop) : verticalMargin
        }
    }

    // MARK: Looks and presets

    /// What a preset sets: the type and how it stands off the picture. Position,
    /// languages and Hide Sound Cues are left alone.
    public struct Look: Hashable, Codable, Sendable {
        public var design: FontDesign = .system
        public var fontName: String?
        public var relativeSize: Double = 0.045
        public var weight: Weight = .semibold
        public var textColor: RGBA = .white
        public var outlineWidth: Double = 1
        public var shadow = true
        public var backgroundOpacity: Double = 0
        public init() {}
    }

    public var look: Look {
        get {
            var l = Look()
            l.design = design; l.fontName = fontName; l.relativeSize = relativeSize; l.weight = weight
            l.textColor = textColor; l.outlineWidth = outlineWidth; l.shadow = shadow; l.backgroundOpacity = backgroundOpacity
            return l
        }
        set {
            design = newValue.design; fontName = newValue.fontName; relativeSize = Self.clampSize(newValue.relativeSize)
            weight = newValue.weight; italic = false; textColor = newValue.textColor
            outlineWidth = newValue.outlineWidth; outlineColor = .black
            shadow = newValue.shadow; shadowOpacity = 0.9
            backgroundColor = .black; backgroundOpacity = newValue.backgroundOpacity
        }
    }

    /// Bluebox's looks. Standard is the default style.
    public enum Preset: String, CaseIterable, Sendable {
        case standard, cinema, boxed, boldOutline, largePrint

        public var title: String {
            switch self {
            case .standard: "Standard"
            case .cinema: "Cinema"
            case .boxed: "Boxed"
            case .boldOutline: "Bold Outline"
            case .largePrint: "Large Print"
            }
        }

        public var look: Look {
            var l = Look()
            switch self {
            case .standard: break
            case .cinema:
                l.design = .serif; l.weight = .medium; l.relativeSize = 0.047
                l.textColor = RGBA(0.96, 0.95, 0.9); l.outlineWidth = 0
            case .boxed:
                l.weight = .medium; l.outlineWidth = 0; l.shadow = false; l.backgroundOpacity = 0.75
            case .boldOutline:
                l.weight = .bold; l.relativeSize = 0.048; l.outlineWidth = 2.5
            case .largePrint:
                l.fontName = "Atkinson Hyperlegible"; l.weight = .bold; l.relativeSize = 0.062
                l.outlineWidth = 0; l.shadow = false; l.backgroundOpacity = 0.55
            }
            return l
        }
    }

    /// A look the user saved ("Save Current"), kept with the profile's style so it syncs.
    public struct SavedLook: Hashable, Codable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var look: Look
        public init(id: UUID = UUID(), name: String, look: Look) { self.id = id; self.name = name; self.look = look }
    }

    /// Applies a preset's look; the position, languages and saved looks stay.
    public func applying(_ preset: Preset) -> SubtitleStyle {
        var s = self; s.look = preset.look; return s
    }

    /// True when the type and box are exactly the preset's.
    public func matches(_ preset: Preset) -> Bool { look == preset.look }

    /// The current look saved under the next free "My Look n" name.
    public mutating func saveCurrentLook() {
        let taken = Set(savedLooks.map(\.name))
        let name = (1...).lazy.map { "My Look \($0)" }.first { !taken.contains($0) }!
        savedLooks.append(SavedLook(name: name, look: look))
    }

    // MARK: Codable (older saved styles had size/color/background/position presets)

    enum CodingKeys: String, CodingKey {
        case design, fontName, relativeSize, weight, italic, textColor, outlineWidth, outlineColor, shadow, shadowOpacity
        case backgroundColor, backgroundOpacity, alignment, anchor, verticalMargin, horizontalMargin, horizontalOffset, lineSpacing
        case avoidControls, secondaryScale, secondaryColor, preferredLanguage, secondaryLanguage, hidesSoundCues, savedLooks
        case size, color, background, position
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? d }
        let base = SubtitleStyle()
        design = v(.design, base.design); fontName = v(.fontName, base.fontName)
        relativeSize = v(.relativeSize, base.relativeSize); weight = v(.weight, base.weight); italic = v(.italic, base.italic)
        textColor = v(.textColor, base.textColor); outlineWidth = v(.outlineWidth, base.outlineWidth)
        outlineColor = v(.outlineColor, base.outlineColor); shadow = v(.shadow, base.shadow)
        shadowOpacity = v(.shadowOpacity, base.shadowOpacity); backgroundColor = v(.backgroundColor, base.backgroundColor)
        backgroundOpacity = v(.backgroundOpacity, base.backgroundOpacity); alignment = v(.alignment, base.alignment)
        anchor = v(.anchor, base.anchor); verticalMargin = v(.verticalMargin, base.verticalMargin)
        horizontalMargin = v(.horizontalMargin, base.horizontalMargin); lineSpacing = v(.lineSpacing, base.lineSpacing)
        horizontalOffset = v(.horizontalOffset, base.horizontalOffset)
        avoidControls = v(.avoidControls, base.avoidControls); secondaryScale = v(.secondaryScale, base.secondaryScale)
        secondaryColor = v(.secondaryColor, base.secondaryColor)
        preferredLanguage = v(.preferredLanguage, base.preferredLanguage); secondaryLanguage = v(.secondaryLanguage, base.secondaryLanguage)
        hidesSoundCues = v(.hidesSoundCues, base.hidesSoundCues)
        savedLooks = v(.savedLooks, base.savedLooks)
        // Legacy presets.
        if let size: String = v(.size, nil) {
            relativeSize = ["small": 0.035, "medium": 0.045, "large": 0.055, "extraLarge": 0.07][size] ?? relativeSize
        }
        if let color: String = v(.color, nil) {
            textColor = ["lightGray": RGBA.lightGray, "lightBlue": RGBA.lightBlue][color] ?? .white
        }
        if let bg: String = v(.background, nil) {
            shadow = bg == "shadow"; backgroundOpacity = bg == "box" ? 0.75 : 0
        }
        if let pos: String = v(.position, nil) {
            anchor = pos == "top" ? .top : .bottom
            if pos == "raised" { verticalMargin = 0.18 }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(design, forKey: .design); try c.encodeIfPresent(fontName, forKey: .fontName)
        try c.encode(relativeSize, forKey: .relativeSize); try c.encode(weight, forKey: .weight); try c.encode(italic, forKey: .italic)
        try c.encode(textColor, forKey: .textColor); try c.encode(outlineWidth, forKey: .outlineWidth)
        try c.encode(outlineColor, forKey: .outlineColor); try c.encode(shadow, forKey: .shadow)
        try c.encode(shadowOpacity, forKey: .shadowOpacity); try c.encode(backgroundColor, forKey: .backgroundColor)
        try c.encode(backgroundOpacity, forKey: .backgroundOpacity); try c.encode(alignment, forKey: .alignment)
        try c.encode(anchor, forKey: .anchor); try c.encode(verticalMargin, forKey: .verticalMargin)
        try c.encode(horizontalMargin, forKey: .horizontalMargin); try c.encode(lineSpacing, forKey: .lineSpacing)
        try c.encode(horizontalOffset, forKey: .horizontalOffset)
        try c.encode(avoidControls, forKey: .avoidControls); try c.encode(secondaryScale, forKey: .secondaryScale)
        try c.encode(secondaryColor, forKey: .secondaryColor)
        try c.encodeIfPresent(preferredLanguage, forKey: .preferredLanguage); try c.encodeIfPresent(secondaryLanguage, forKey: .secondaryLanguage)
        try c.encode(hidesSoundCues, forKey: .hidesSoundCues)
        if !savedLooks.isEmpty { try c.encode(savedLooks, forKey: .savedLooks) }
    }
}

/// Loads subtitle files from disk or the network with format detection.
public struct SubtitleLoader: Sendable {
    let fetch: @Sendable (URL) async throws -> Data

    public init(fetch: @escaping @Sendable (URL) async throws -> Data = SubtitleLoader.defaultFetch) {
        self.fetch = fetch
    }

    public static let defaultFetch: @Sendable (URL) async throws -> Data = { url in
        if url.isFileURL { return try Data(contentsOf: url) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubtitleError.unreadable
        }
        // Guard against being handed a video or an HTML error page.
        guard data.count < 20_000_000 else { throw SubtitleError.unreadable }
        return data
    }

    public func load(_ url: URL, format: SubtitleFormat? = nil) async throws -> SubtitleTimeline {
        guard let fmt = format ?? SubtitleFormat(fileExtension: url.pathExtension) else {
            throw SubtitleError.unsupportedFormat(url.pathExtension)
        }
        return try SubtitleParser.parse(try await fetch(url), format: fmt)
    }
}
