import DesignSystem
import Playback
import Subtitles
import SwiftUI

/// The pages inside the Audio & Subtitles card: Style (look and position),
/// Timing and Second line. Every change shows on the video straight away
/// (with a sample line when nothing is being said).

// MARK: - Second line

/// A second language under the first, from a subtitle file.
struct SecondLinePage: View {
    let session: PlayerSession
    @Binding var style: SubtitleStyle
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlayerPageHeader("Second Line", onBack: onBack)
            if session.externalSubtitles.isEmpty {
                Text(session.snapshot.embeddedSubtitles.isEmpty
                     ? "Add or download a subtitle file to show a second language under the first."
                     : "A second line comes from a subtitle file: the player shows one subtitle track from inside the video at a time. Add or download a file in another language.")
                    .font(.footnote).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let labels = TrackLabel.labels(for: session.externalSubtitles)
                VStack(spacing: 2) {
                    PanelPickRow(title: "Off", symbol: "nosign", selected: session.secondarySubtitleID == nil) {
                        session.selectSecondarySubtitle(nil)
                    }
                    ForEach(session.externalSubtitles) { t in
                        PanelPickRow(title: labels[t.id]?.title ?? t.label, detail: labels[t.id]?.detail, symbol: "doc.text",
                                     selected: session.secondarySubtitleID == t.id) {
                            session.selectSecondarySubtitle(t.id)
                        }
                    }
                }
                if session.secondarySubtitleID != nil {
                    PanelSlider(title: "Size", value: $style.secondaryScale, range: 0.5...1.2, defaultValue: SubtitleStyle().secondaryScale,
                                format: { "\(Int(($0 * 100).rounded()))%" })
                    ColorSwatches(title: "Colour", color: $style.secondaryColor)
                }
            }
        }
    }
}

// MARK: - Timing

/// Subtitle timing: the delay (steps, a slider, keys), "Match a Line" (one
/// or two lines you heard), and fixes for subtitles that drift.
struct SubtitleTimingPage: View {
    let session: PlayerSession
    let onBack: () -> Void
    @State private var subtitleFPS = 25.0
    @State private var videoFPS = 24000.0 / 1001
    @State private var showsDrift = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerPageHeader("Timing", onBack: onBack) {
                if !session.subtitleOffset.isDefault {
                    Button("Reset All") { session.resetSubtitleOffset() }
                        .font(.caption.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle()).foregroundStyle(Palette.brandBright)
                }
            }
            if !session.canAdjustSubtitleTiming {
                Text(session.subtitleSelection == .off
                     ? "Turn on subtitles to adjust their timing."
                     : "This video's own subtitles play in step with it here, so their timing can't be moved. Add a subtitle file to retime it.")
                    .font(.footnote).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Only Bluebox's own lines can be shown here (VLC draws the video's in the picture).
                if session.canRetimeSubtitleLines { nowShowing }
                ValueDial(title: "Subtitle delay", value: session.subtitleOffset.seconds, range: -10...10, defaultValue: 0,
                          fine: 0.1, coarse: 1, format: Self.delayText, meaning: Self.meaning, keys: ("{", "}"),
                          stepLabel: { String(format: $0 > 0 ? "+%g s" : "−%g s", abs($0)) }) { new in
                    session.nudgeSubtitles(by: new - session.subtitleOffset.seconds)
                }
                if session.canRetimeSubtitleLines {
                    matchLine
                    drift
                } else {
                    Text("Match a Line and drift fixes need the lines themselves, so they work with subtitle files.")
                        .font(.caption).foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func delayText(_ s: Double) -> String {
        abs(s) < 0.05 ? "0.0 s" : String(format: s > 0 ? "+%.1f s" : "−%.1f s", abs(s))
    }

    static func meaning(_ s: Double) -> String {
        if abs(s) < 0.05 { return "As timed in the subtitles" }
        return String(format: "Subtitles show %.1f s %@", abs(s), s > 0 ? "later" : "earlier")
    }

    /// The line on screen now, so a nudge can be judged against the voice.
    @ViewBuilder private var nowShowing: some View {
        let line = session.subtitleText?.replacingOccurrences(of: "\n", with: " ")
        HStack(spacing: 6) {
            Image(systemName: "captions.bubble").font(.caption).foregroundStyle(Palette.textTertiary)
            Text(line ?? "No line on screen right now")
                .font(.caption).italic(line == nil)
                .foregroundStyle(line == nil ? Palette.textTertiary : Palette.textPrimary)
                .lineLimit(1)
        }
        .animation(nil, value: line)
    }

    /// Pick the line you just heard: it starts now. A second pick later fixes drift too.
    @ViewBuilder private var matchLine: some View {
        PanelSection("Match a Line", accessory: {
            if session.pendingSyncPoint != nil {
                Button("Cancel") { session.clearPendingSync() }
                    .font(.caption.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle()).foregroundStyle(Palette.brandBright)
            }
        }) {
            Text(session.pendingSyncPoint == nil
                 ? "When you hear a line, tap it here: Bluebox moves the subtitles so it starts now."
                 : "Done. If they slip again later, tap another line then and Bluebox fixes the drift as well.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            let cues = Array(nearby.prefix(5))
            if cues.isEmpty {
                Text("No lines near this point.").font(.caption).foregroundStyle(Palette.textTertiary)
            } else {
                VStack(spacing: 2) {
                    ForEach(cues, id: \.self) { cue in
                        PanelPickRow(title: cue.text.replacingOccurrences(of: "\n", with: " "),
                                     detail: Formatters.duration(cue.start), selected: false) { session.syncCue(cue) }
                    }
                }
            }
        }
    }

    /// The lines just before now, most recent first.
    private var nearby: [SubtitleCue] {
        let now = session.snapshot.position
        let all = session.nearbyCues
        let before = all.filter { session.subtitleOffset.playerTime(forCueTime: $0.start) <= now + 1 }
        return (before.isEmpty ? all : before).reversed()
    }

    @ViewBuilder private var drift: some View {
        DisclosureGroup(isExpanded: $showsDrift) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("For subtitles that start in sync and slowly slip: they were made for another frame rate.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                BlueboxPicker("Subtitles made for", selection: $subtitleFPS, options: SubtitleSyncFrameRates.options)
                    .font(.subheadline)
                BlueboxPicker("Video is", selection: $videoFPS, options: SubtitleSyncFrameRates.options)
                    .font(.subheadline)
                PanelActionButton(title: "Convert Frame Rate", symbol: "arrow.left.arrow.right") {
                    session.convertSubtitleFrameRate(subtitleFPS: subtitleFPS, videoFPS: videoFPS)
                }
                .disabled(abs(subtitleFPS - videoFPS) < 0.001)
                PanelSlider(title: "Pace", value: Binding(get: { session.subtitleOffset.scale }, set: { session.setSubtitleSpeed($0) }),
                            range: SubtitleOffset.scaleRange, defaultValue: 1, format: { String(format: "%.3f×", $0) })
            }
            .padding(.top, Spacing.s)
        } label: {
            HStack {
                Text("Slipping Out of Sync?").font(.subheadline.weight(.semibold))
                if abs(session.subtitleOffset.scale - 1) > 0.0005 {
                    Text(String(format: "%.3f×", session.subtitleOffset.scale)).font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Palette.brandBright)
                }
            }
        }
        .tint(Palette.textSecondary)
    }
}

extension SubtitleStyle {
    /// True when this is exactly the preset's look (so its chip shows as chosen).
    func matches(_ preset: Preset) -> Bool { applying(preset) == self }
}

enum SubtitleSyncFrameRates {
    static let all: [(String, Double)] = [("23.976", 24000.0 / 1001), ("24", 24), ("25", 25), ("29.97", 30000.0 / 1001), ("30", 30)]
    static var options: [BlueboxPickerOption<Double>] { all.map { BlueboxPickerOption("\($0.0) fps", value: $0.1) } }
}

// MARK: - Style

/// What the style does to the subtitles showing now, said once at the top of
/// the page (in place of notes scattered through it).
struct SubtitleStyleStatus: Equatable {
    enum Kind: Equatable { case info, limited }
    let kind: Kind
    let text: String
    /// VLC's text look waits for a reopen of the stream; this offers it now.
    var canApplyNow = false

    @MainActor
    static func current(_ session: PlayerSession) -> SubtitleStyleStatus? {
        switch session.subtitleSelection {
        case .off:
            return SubtitleStyleStatus(kind: .info, text: "Subtitles are off. The sample above shows how they'll look.")
        case .external:
            return nil  // Bluebox draws files: everything shows straight away
        case .embedded(let id):
            guard let track = session.snapshot.embeddedSubtitles.first(where: { $0.id == id }) else { return nil }
            if track.isBitmap {
                return SubtitleStyleStatus(kind: .limited, text: "This track is made of pictures (\(track.format ?? "PGS or VobSub")), so it keeps the look it came with. Pick a text track or a subtitle file to restyle.")
            }
            guard session.snapshot.drawsEmbeddedSubtitles else { return nil }
            if track.keepsOwnStyle {
                return SubtitleStyleStatus(kind: .limited, text: "This track (ASS) brings its own fonts, colours and positions, which the video draws as they are. For your style, pick another track of this language (SRT) or a subtitle file.")
            }
            if session.snapshot.subtitleRestylePending {
                return SubtitleStyleStatus(kind: .info, text: "Size shows straight away. Font, colour, edges and position show when you close this card (the video reopens where it is).", canApplyNow: true)
            }
            return SubtitleStyleStatus(kind: .info, text: "Size shows straight away. Font, colour, edges and position reopen the video where it is.")
        }
    }
}

/// Subtitle look and position: a live sample, what applies to this track,
/// then Look (preset, text, font, edges) and Position (the anchor grid).
struct SubtitleStylePage: View {
    @Binding var style: SubtitleStyle
    let session: PlayerSession
    let onBack: () -> Void
    @State private var tab: Tab = .look
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// A phone on its side: the card is short, so the sample is a strip.
    private var short: Bool { verticalSizeClass == .compact }
    #else
    private var short: Bool { false }
    #endif

    enum Tab: String, CaseIterable { case look = "Look", position = "Position" }

    init(style: Binding<SubtitleStyle>, session: PlayerSession, startsOnPosition: Bool = false, onBack: @escaping () -> Void) {
        _style = style; self.session = session; self.onBack = onBack
        _tab = State(initialValue: startsOnPosition ? .position : .look)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerPageHeader("Subtitle Style", onBack: onBack) {
                if style.withoutPreferences != SubtitleStyle().withoutPreferences {
                    Button("Reset All") { withAnimation(.smooth(duration: 0.3)) { style = style.resetLook() } }
                        .font(.caption.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle()).foregroundStyle(Palette.brandBright)
                        .help("Back to the standard look and position")
                }
            }
            SubtitleSample(style: style, height: short ? 50 : nil)
            if let status = SubtitleStyleStatus.current(session) { statusView(status) }
            PanelSegments(selection: $tab, options: Tab.allCases.map { ($0.rawValue, $0) })
            // Swapped at once: a cross-fade showed both tabs over each other for a moment.
            switch tab {
            case .look: SubtitleLookSection(style: $style)
            case .position: SubtitlePositionSection(style: $style)
            }
        }
    }

    private func statusView(_ status: SubtitleStyleStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: status.kind == .limited ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(status.kind == .limited ? Palette.warning : Palette.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(status.text)
                    .font(.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status.canApplyNow {
                    Button("Apply Now") { session.applySubtitleStyleNow() }
                        .font(.caption.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle()).foregroundStyle(Palette.brandBright)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A line of sample text on a dark frame, in the current look and where it
/// sits on the picture, so a change shows here even before the video takes it.
struct SubtitleSample: View {
    let style: SubtitleStyle
    /// A fixed height (short screens); otherwise a 16:5 strip of the card's width.
    var height: CGFloat? = nil

    var body: some View {
        Group {
            if let height {
                frame.frame(maxWidth: .infinity).frame(height: height)
            } else {
                frame.aspectRatio(16 / 5, contentMode: .fit).frame(maxWidth: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .animation(.smooth(duration: 0.25), value: style)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subtitle sample")
    }

    private var frame: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: Alignment(horizontal: style.frameAlignment.horizontal, vertical: vertical)) {
                LinearGradient(colors: [Color(white: 0.32), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                // Sized as on a picture about twice the sample's height, so it reads like the real thing.
                SubtitleText(text: "Where are we going?", style: style, videoHeight: max(h, 110) * 2.2)
                    .padding(.horizontal, style.horizontalMargin * geo.size.width)
                    .offset(y: offset(h))
            }
        }
    }

    private var vertical: VerticalAlignment {
        switch style.anchor { case .bottom: .bottom; case .middle: .center; case .top: .top }
    }

    private func offset(_ h: Double) -> Double {
        // The sample frame is shorter than a picture: half the margin reads right.
        let m = min(style.verticalMargin, 0.3) * h * 0.8
        switch style.anchor { case .bottom: return -m - 4; case .middle: return 0; case .top: return m + 4 }
    }
}

/// Two or three choices in a track, the chosen one raised (a segmented control in the cards' look).
struct PanelSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(String, Value)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { title, value in
                let on = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(PanelMetrics.chipFont)
                        .frame(maxWidth: .infinity, minHeight: PanelMetrics.control - 4)
                        .foregroundStyle(on ? Color.black : Palette.textPrimary)
                        .background(on ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelPressStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Preset, size and colour, font, and the edge (shadow, box, outline).
struct SubtitleLookSection: View {
    @Binding var style: SubtitleStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelSection("Preset") {
                // Wraps, so none is cut off at the panel's edge.
                ChipFlow(items: SubtitleStyle.Preset.allCases) { p in
                    PanelChip(title: p.title, selected: style.matches(p)) { style = style.applying(p) }
                }
            }
            PanelSection("Text", accessory: {
                if PanelMetrics.showsShortcuts {
                    HStack(spacing: 3) { KeyCap("−"); KeyCap("=") }.help("Smaller (−) or larger (=)")
                }
            }) {
                PanelSlider(title: "Size", value: $style.relativeSize, range: 0.02...0.12, defaultValue: SubtitleStyle().relativeSize,
                            format: { "\(Int(($0 / 0.045 * 100).rounded()))%" })
                ColorSwatches(title: "Colour", color: $style.textColor)
            }
            PanelSection("Font") {
                BlueboxPicker("Font", selection: SubtitleFonts.binding($style), groups: SubtitleFonts.pickerGroups)
                    .font(.subheadline)
                HStack(spacing: 6) {
                    ForEach([SubtitleStyle.Weight.regular, .semibold, .heavy], id: \.self) { w in
                        PanelChip(title: w == .regular ? "Light" : w == .semibold ? "Medium" : "Bold",
                                  selected: style.weight.band == w.band) { style.weight = w }
                    }
                    Spacer(minLength: Spacing.s)
                    PanelChip(title: "Italic", selected: style.italic) { style.italic.toggle() }
                }
            }
            PanelSection("Edge") {
                HStack(spacing: 6) {
                    PanelChip(title: "None", selected: !style.shadow && style.backgroundOpacity < 0.01) {
                        style.shadow = false; style.backgroundOpacity = 0
                    }
                    PanelChip(title: "Shadow", selected: style.shadow && style.backgroundOpacity < 0.01) {
                        style.shadow = true; style.backgroundOpacity = 0
                    }
                    PanelChip(title: "Box", selected: style.backgroundOpacity >= 0.01) {
                        style.shadow = false; style.backgroundOpacity = max(style.backgroundOpacity, 0.75)
                    }
                }
                if style.backgroundOpacity >= 0.01 {
                    PanelSlider(title: "Box Opacity", value: $style.backgroundOpacity, range: 0.05...1, format: { "\(Int(($0 * 100).rounded()))%" })
                }
                PanelSlider(title: "Outline", value: $style.outlineWidth, range: 0...6, defaultValue: SubtitleStyle().outlineWidth,
                            format: { $0 < 0.1 ? "Off" : String(format: "%.1f pt", $0) })
                if style.outlineWidth >= 0.1 {
                    ColorSwatches(title: "Outline Colour", color: $style.outlineColor, choices: [.black, RGBA(0.1, 0.1, 0.3), .white])
                }
            }
        }
    }
}

extension SubtitleStyle.Weight {
    /// Light, medium or bold: the three weights the card offers.
    var band: Int {
        switch self { case .regular: 0; case .medium, .semibold: 1; case .bold, .heavy: 2 }
    }
}

extension SubtitleStyle {
    /// The look and position only (languages are preferences, not style).
    var withoutPreferences: SubtitleStyle {
        var s = self; s.preferredLanguage = nil; s.secondaryLanguage = nil; s.secondaryScale = 0; s.secondaryColor = .white
        return s
    }

    /// The standard look and position, keeping the languages and second line.
    func resetLook() -> SubtitleStyle {
        var s = SubtitleStyle()
        s.preferredLanguage = preferredLanguage; s.secondaryLanguage = secondaryLanguage
        s.secondaryScale = secondaryScale; s.secondaryColor = secondaryColor
        return s
    }
}

/// A row of colour dots plus the system colour picker.
struct ColorSwatches: View {
    let title: String
    @Binding var color: RGBA
    var choices: [RGBA] = [.white, .yellow, .lightBlue, .lightGray, RGBA(0.55, 1, 0.6)]

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline)
            Spacer(minLength: Spacing.s)
            ForEach(choices, id: \.self) { c in
                let selected = abs(c.r - color.r) + abs(c.g - color.g) + abs(c.b - color.b) < 0.02
                Button { color = RGBA(c.r, c.g, c.b, color.a) } label: {
                    Circle().fill(c.color)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white.opacity(0.35)))
                        .padding(3)
                        .overlay(Circle().strokeBorder(Palette.brandBright, lineWidth: selected ? 2 : 0))
                        .frame(width: max(PanelMetrics.control, 28), height: max(PanelMetrics.control, 28))
                        .contentShape(Circle())
                }
                .buttonStyle(PanelPressStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            // Any other colour: the system picker, in a dot like the rest.
            let custom = !choices.contains { abs($0.r - color.r) + abs($0.g - color.g) + abs($0.b - color.b) < 0.02 }
            ColorPicker(title, selection: Binding(get: { color.color }, set: { color = RGBA($0) }), supportsOpacity: true)
                .labelsHidden()
                .opacity(0.02)
                .frame(width: 22, height: 22)
                .background {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .overlay(Circle().fill(custom ? color.color : .clear).padding(5))
                        .allowsHitTesting(false)
                }
                .clipShape(Circle())
                .padding(3)
                .overlay(Circle().strokeBorder(Palette.brandBright, lineWidth: custom ? 2 : 0).allowsHitTesting(false))
                .frame(width: max(PanelMetrics.control, 28), height: max(PanelMetrics.control, 28))
                .help("Custom Colour")
                .accessibilityLabel("Custom \(title)")
        }
    }
}

// MARK: - Position

/// Where the subtitles sit: one of nine spots on a small picture (the
/// anchor), how far from the edge, and whether they move for the controls.
struct SubtitlePositionSection: View {
    @Binding var style: SubtitleStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelSection("Anchor", accessory: {
                if !style.isDefaultPosition {
                    Button("Reset") { withAnimation(.smooth(duration: 0.3)) { style.resetPosition() } }
                        .font(.caption.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle()).foregroundStyle(Palette.brandBright)
                }
            }) {
                HStack(alignment: .center, spacing: 12) {
                    SubtitleAnchorGrid(style: $style)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(placeName).font(.subheadline.weight(.semibold))
                        Text("Subtitles hold to this spot. Longer lines grow away from the edge.")
                            .font(.caption).foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if style.anchor != .middle {
                PanelSlider(title: "Distance from Edge", value: $style.verticalMargin, range: 0...0.3, defaultValue: SubtitleStyle.defaultMargin,
                            format: { "\(Int(($0 * 100).rounded()))%" })
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Move Up for Controls", isOn: $style.avoidControls).font(.subheadline).tint(Palette.brand)
                    .disabled(style.anchor != .bottom)
                Text(style.anchor != .bottom ? "Only subtitles at the bottom move for the controls."
                     : style.avoidControls ? "Bottom subtitles rise above the timeline while it shows."
                     : "Subtitles stay put; the controls may cover them.")
                    .font(.caption).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(PanelMetrics.showsShortcuts ? "You can also drag subtitles on the video, and pinch to resize them."
                 : "You can also drag subtitles on the video, and pinch them to resize.")
                .font(.caption).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var placeName: String {
        if abs(style.horizontalOffset) > 0.001 { return "Where you dragged them" }
        let v = switch style.anchor { case .bottom: "Bottom"; case .middle: "Middle"; case .top: "Top" }
        let h = switch style.alignment { case .leading: "Left"; case .center: "Centre"; case .trailing: "Right" }
        return style.anchor == .middle && style.alignment == .center ? "Centre" : "\(v) \(h)"
    }
}

/// Nine spots on a miniature picture; the chosen one shows a subtitle bar.
struct SubtitleAnchorGrid: View {
    @Binding var style: SubtitleStyle
    private let rows: [SubtitleStyle.Anchor] = [.top, .middle, .bottom]
    private let columns: [SubtitleStyle.Alignment] = [.leading, .center, .trailing]

    var body: some View {
        let cell = max(PanelMetrics.control, 30)
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(rows, id: \.self) { a in
                GridRow {
                    ForEach(columns, id: \.self) { al in
                        let on = style.anchor == a && style.alignment == al && abs(style.horizontalOffset) < 0.001
                        Button { withAnimation(.smooth(duration: 0.3)) { style.pin(a, al) } } label: {
                            ZStack {
                                if on {
                                    Capsule().fill(Palette.brandBright).frame(width: cell * 0.62, height: 5)
                                } else {
                                    Circle().fill(.white.opacity(0.35)).frame(width: 5, height: 5)
                                }
                            }
                            .frame(width: cell * 1.1, height: cell * 0.72)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PanelPressStyle())
                        .accessibilityLabel(Self.name(a, al))
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .help(Self.name(a, al))
                    }
                }
            }
        }
        .padding(3)
        .background(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.12)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.2)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subtitle anchor")
    }

    static func name(_ a: SubtitleStyle.Anchor, _ al: SubtitleStyle.Alignment) -> String {
        let v = switch a { case .bottom: "Bottom"; case .middle: "Middle"; case .top: "Top" }
        let h = switch al { case .leading: "left"; case .center: "centre"; case .trailing: "right" }
        return "\(v) \(h)"
    }
}
