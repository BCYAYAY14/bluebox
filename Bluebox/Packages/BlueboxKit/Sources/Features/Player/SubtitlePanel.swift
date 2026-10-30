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

/// Subtitle look: a sample line, presets, then size, colour, background,
/// outline and position, one row each. Every one shows on the video at once,
/// for the video's own text tracks too. Font and weight are in Settings ›
/// Subtitles (the video's own tracks take them from the next video).
struct SubtitleStylePage: View {
    @Binding var style: SubtitleStyle
    let session: PlayerSession
    let onBack: () -> Void
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// A phone on its side: the card is short, so the sample is a thin strip.
    private var short: Bool { verticalSizeClass == .compact }
    #else
    private var short: Bool { false }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: short ? 8 : 12) {
            PlayerPageHeader("Subtitle Style", onBack: onBack) {
                if style.withoutPreferences != style.resetLook().withoutPreferences {
                    Button("Reset") { withAnimation(.smooth(duration: 0.3)) { style = style.resetLook() } }
                        .font(.caption.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle()).foregroundStyle(Palette.brandBright)
                        .help("Back to the standard look and position")
                }
            }
            // On a phone on its side the video beside the card shows every change.
            if !short { SubtitleSample(style: style, height: 60) }
            if let note = SubtitleStyleNote.current(session) {
                Label(note, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ChipFlow(items: SubtitleStyle.Preset.allCases) { p in
                PanelChip(title: p.title, selected: style.matches(p)) { style = style.applying(p) }
            }
            // Labels in one column as wide as the longest, controls filling the rest.
            Grid(alignment: .leading, horizontalSpacing: Spacing.s, verticalSpacing: short ? 6 : 10) {
                StyleRow("Size") { SubtitleSizeStepper(size: $style.relativeSize) }
                StyleRow("Colour") { ColorSwatches(title: "Colour", color: $style.textColor, showsTitle: false) }
                StyleRow("Background") {
                    PanelSegments(selection: Binding(get: { style.backgroundChoice }, set: { style.backgroundChoice = $0 }),
                                  options: SubtitleStyle.BackgroundChoice.allCases.map { ($0.title, $0) })
                }
                StyleRow("Outline") {
                    PanelSegments(selection: Binding(get: { style.outlineChoice }, set: { style.outlineChoice = $0 }),
                                  options: SubtitleStyle.OutlineChoice.allCases.map { ($0.title, $0) })
                }
                StyleRow("Position") {
                    PanelSegments(selection: Binding(get: { style.positionChoice }, set: { c in withAnimation(.smooth(duration: 0.3)) { style.positionChoice = c } }),
                                  options: SubtitleStyle.PositionChoice.allCases.map { ($0.title, $0) })
                }
            }
            Text(PanelMetrics.showsShortcuts ? "Drag subtitles on the video to move them; − and = resize."
                 : "Drag subtitles on the video to move them, pinch to resize.")
                .font(.caption).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A grid row: the title, then its control filling the rest of the line.
struct StyleRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) { self.title = title; self.control = control() }

    var body: some View {
        GridRow {
            Text(title).font(.subheadline).foregroundStyle(Palette.textSecondary)
                .lineLimit(1).fixedSize()
            control.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Size in steps: smaller, the size as a percentage, larger.
struct SubtitleSizeStepper: View {
    @Binding var size: Double
    private static let step = 0.005

    var body: some View {
        HStack(spacing: 2) {
            button("textformat.size.smaller", label: "Smaller", by: -Self.step)
            Text("\(Int((size / SubtitleStyle().relativeSize * 100).rounded()))%")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .frame(minWidth: 52)
                .contentTransition(.numericText())
                .onTapGesture(count: 2) { size = SubtitleStyle().relativeSize }
            button("textformat.size.larger", label: "Larger", by: Self.step)
        }
        .padding(2)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Size")
        .accessibilityValue("\(Int((size / SubtitleStyle().relativeSize * 100).rounded())) percent")
        .accessibilityAdjustableAction { d in
            switch d { case .increment: change(Self.step); case .decrement: change(-Self.step); @unknown default: break }
        }
    }

    private func button(_ symbol: String, label: String, by d: Double) -> some View {
        Button { change(d) } label: {
            Image(systemName: symbol).font(.subheadline.weight(.semibold))
                .frame(width: PanelMetrics.control + 6, height: PanelMetrics.control - 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .disabled(d < 0 ? size <= 0.02 + 0.0001 : size >= 0.12 - 0.0001)
        .accessibilityLabel(label)
    }

    private func change(_ d: Double) {
        withAnimation(.snappy(duration: 0.2)) { size = SubtitleStyle.clampSize(((size + d) / Self.step).rounded() * Self.step) }
    }
}

/// The one thing worth saying about the track showing now: when the style
/// can't reach it.
enum SubtitleStyleNote {
    @MainActor
    static func current(_ session: PlayerSession) -> String? {
        guard case .embedded(let id) = session.subtitleSelection,
              let track = session.snapshot.embeddedSubtitles.first(where: { $0.id == id }) else { return nil }
        if track.isBitmap { return "This track is pictures (\(track.format ?? "PGS")), so it keeps its own look." }
        if session.snapshot.drawsEmbeddedSubtitles, track.keepsOwnStyle { return "This ASS track keeps its own look. Size still applies." }
        return nil
    }
}

extension SubtitleStyle {
    enum BackgroundChoice: CaseIterable, Hashable {
        case none, shade, box
        var title: String { switch self { case .none: "None"; case .shade: "Shade"; case .box: "Box" } }
        var opacity: Double { switch self { case .none: 0; case .shade: 0.4; case .box: 0.75 } }
    }

    var backgroundChoice: BackgroundChoice {
        get { backgroundOpacity < 0.01 ? .none : backgroundOpacity < 0.6 ? .shade : .box }
        set { backgroundOpacity = newValue.opacity; if newValue != .none { backgroundColor = .black } }
    }

    enum OutlineChoice: CaseIterable, Hashable {
        case off, thin, thick
        var title: String { switch self { case .off: "Off"; case .thin: "Thin"; case .thick: "Thick" } }
        var width: Double { switch self { case .off: 0; case .thin: 1; case .thick: 2.5 } }
    }

    var outlineChoice: OutlineChoice {
        get { outlineWidth < 0.1 ? .off : outlineWidth < 1.5 ? .thin : .thick }
        set { outlineWidth = newValue.width; if newValue != .off { outlineColor = .black } }
    }

    enum PositionChoice: CaseIterable, Hashable {
        case bottom, higher, top
        var title: String { switch self { case .bottom: "Bottom"; case .higher: "Higher"; case .top: "Top" } }
    }

    static let higherMargin = 0.16

    /// The nearest of the three; a dragged spot shows as the one it's closest to.
    var positionChoice: PositionChoice {
        get {
            switch anchor {
            case .top: .top
            case .middle: .higher
            case .bottom: verticalMargin > (Self.defaultMargin + Self.higherMargin) / 2 ? .higher : .bottom
            }
        }
        set {
            alignment = .center; horizontalOffset = 0
            switch newValue {
            case .bottom: anchor = .bottom; verticalMargin = Self.defaultMargin
            case .higher: anchor = .bottom; verticalMargin = Self.higherMargin
            case .top: anchor = .top; verticalMargin = Self.defaultMargin
            }
        }
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
    /// Off when a row already names it (Subtitle Style).
    var showsTitle = true

    var body: some View {
        HStack(spacing: PanelMetrics.dense ? 2 : 6) {
            if showsTitle {
                Text(title).font(.subheadline)
                Spacer(minLength: Spacing.s)
            }
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
