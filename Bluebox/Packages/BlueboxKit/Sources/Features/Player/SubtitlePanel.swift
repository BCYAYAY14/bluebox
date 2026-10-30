import DesignSystem
import Playback
import Subtitles
import SwiftUI

/// The pages inside the Audio & Subtitles card: Style (look and position),
/// Timing and Second line. Every change shows on the video straight away
/// (with a sample line when nothing is being said).

// MARK: - Second line

/// A second language under the first, from a subtitle file or a text track
/// in the video that Bluebox draws (VLC with MKV: SubRip, WebVTT, plain ASS).
struct SecondLinePage: View {
    let session: PlayerSession
    @Binding var style: SubtitleStyle
    let onBack: () -> Void

    /// Embedded tracks that can be a second line: drawn by Bluebox, and not the first line.
    private var embeddedCandidates: [MediaTrack] {
        let primary: String? = if case .embedded(let id) = session.subtitleSelection { id } else { nil }
        return session.snapshot.embeddedSubtitles.filter { $0.drawnByBluebox && $0.id != primary }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlayerPageHeader("Second Line", onBack: onBack)
            let candidates = session.externalSubtitles + embeddedCandidates
            if candidates.isEmpty {
                Text(session.snapshot.embeddedSubtitles.isEmpty
                     ? "Add or download a subtitle file to show a second language under the first."
                     : "A second line comes from a subtitle file, or a plain text track in an MKV. Add or download a file in another language.")
                    .font(.footnote).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let labels = TrackLabel.labels(for: candidates)
                VStack(spacing: 2) {
                    PanelPickRow(title: "Off", symbol: "nosign", selected: session.secondarySubtitleID == nil) {
                        session.selectSecondarySubtitle(nil)
                    }
                    ForEach(candidates) { t in
                        PanelPickRow(title: labels[t.id]?.title ?? t.label, detail: labels[t.id]?.detail,
                                     symbol: t.isExternal ? "doc.text" : "film",
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

// MARK: - Lines

/// Every line of the subtitles with its time: the one on screen highlighted
/// and kept in view, a search that filters them, and a click that plays from
/// a line. A file's lines are all there; a track in the video lists what's
/// been read so far.
struct SubtitleLinesPage: View {
    let session: PlayerSession
    let onBack: () -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    var body: some View {
        let cues = session.subtitleCues
        let offset = session.subtitleOffset
        let shown = SubtitleLines.search(cues, query: query)
        let current = SubtitleLines.currentIndex(cues, at: session.snapshot.position, offset: offset)
        VStack(alignment: .leading, spacing: 8) {
            PlayerPageHeader("Lines", onBack: onBack)
            if session.subtitleSelection == .off {
                note("Turn on subtitles to see their lines.")
            } else if cues.isEmpty {
                note(session.knowsAllSubtitleCues ? "This subtitle file has no lines."
                     : "This track's lines appear here as Bluebox reads them. Styled and picture subtitles are drawn by the player, so they aren't listed.")
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Palette.textTertiary)
                    TextField("Search lines", text: $query)
                        .textFieldStyle(.plain).font(.subheadline)
                        .focused($searching)
                        .accessibilityIdentifier("lines.search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textTertiary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear Search")
                    }
                }
                .padding(.horizontal, 8).frame(height: PanelMetrics.control)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(shown, id: \.self) { i in
                                lineRow(cues[i], time: offset.playerTime(forCueTime: cues[i].start), current: i == current)
                                    .id(i)
                            }
                        }
                    }
                    .frame(height: PanelMetrics.dense ? 180 : 300)
                    .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
                    // Follows the playhead, unless a search is narrowing the list.
                    .onChange(of: current) { _, new in
                        guard query.isEmpty, let new else { return }
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) }
                    }
                }
                if shown.isEmpty { note("No line has “\(query)”.") }
                if !session.knowsAllSubtitleCues {
                    Text("Lines from the video's own track appear as they're read.")
                        .font(.caption).foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    private func lineRow(_ cue: SubtitleCue, time: TimeInterval, current: Bool) -> some View {
        Button { Task { await session.jump(to: cue) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Formatters.duration(max(0, time)))
                    .font(.caption.monospacedDigit()).foregroundStyle(current ? Palette.brandBright : Palette.textTertiary)
                    .frame(minWidth: 44, alignment: .leading)
                Text(cue.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.subheadline.weight(current ? .semibold : .regular))
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background {
                if current { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.brand.opacity(0.22)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .accessibilityLabel("\(Formatters.duration(max(0, time))), \(cue.text)")
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityHint("Plays from this line")
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
    /// The player's, so a sync carries on when this page or the card closes.
    @Environment(SubtitleAudioSync.self) private var sharedSync: SubtitleAudioSync?
    @State private var ownSync = SubtitleAudioSync()
    private var audioSync: SubtitleAudioSync { sharedSync ?? ownSync }

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
                if session.canRetimeSubtitleLines || !session.subtitleCues.isEmpty { syncToAudio }
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

    /// Sync to the Audio: Bluebox listens and sets the timing; says what it did, with Undo.
    @ViewBuilder private var syncToAudio: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelActionButton(title: audioSync.isRunning ? progressTitle : "Sync to the Audio", symbol: "waveform") {
                if audioSync.isRunning { audioSync.cancel() } else { audioSync.start(session) }
            }
            .accessibilityIdentifier("timing.syncToAudio")
            .accessibilityHint(audioSync.isRunning ? "Stops listening" : "Listens to the speech and lines the subtitles up")
            switch audioSync.phase {
            case .idle, .listening, .matching:
                Text(audioSync.isRunning ? "Listening on this device. Tap again to stop."
                     : "Listens to a couple of minutes of speech and lines the subtitles up, drift included.")
                    .font(.caption).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .done(let offset, _, let drift):
                HStack(spacing: 6) {
                    Label("Synced · \(offset.label)" + (drift ? ", drift fixed" : ""), systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Palette.brandBright)
                    Spacer(minLength: 0)
                    Button("Undo") { audioSync.undo(session) }
                        .font(.caption.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle()).foregroundStyle(Palette.brandBright)
                }
            case .failed(let message):
                Text(ui: message).font(.caption).foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var progressTitle: String {
        switch audioSync.phase {
        case .listening(let part, let total): total > 1 ? "Listening… \(part) of \(total)" : "Listening…"
        case .matching: "Matching…"
        default: "Sync to the Audio"
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

enum SubtitleSyncFrameRates {
    static let all: [(String, Double)] = [("23.976", 24000.0 / 1001), ("24", 24), ("25", 25), ("29.97", 30000.0 / 1001), ("30", 30)]
    static var options: [BlueboxPickerOption<Double>] { all.map { BlueboxPickerOption("\($0.0) fps", value: $0.1) } }
}

// MARK: - Style

/// Subtitle Style: a panel beside the video (the picture moves left to make
/// room), so every change shows on the real video, which can keep playing.
/// Presets, font, look and position in one scroll; the same pieces as
/// Settings › Subtitles.
struct SubtitleStyleInspector: View {
    @Binding var style: SubtitleStyle
    let session: PlayerSession
    let onClose: () -> Void
    static let width: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Subtitle Style").font(.headline)
                Spacer(minLength: 4)
                if style.withoutPreferences != style.resetLook().withoutPreferences {
                    Button("Reset") { withAnimation(.smooth(duration: 0.3)) { style = style.resetLook() } }
                        .font(.subheadline.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle()).foregroundStyle(Palette.brandBright)
                        .help("Back to the standard look and position")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold))
                        .frame(width: PanelMetrics.control, height: PanelMetrics.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlayerQuietButtonStyle())
                .foregroundStyle(Palette.textSecondary)
                .accessibilityLabel("Close Subtitle Style")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let note = SubtitleStyleNote.current(session) {
                        Label(note, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PanelSection("Presets") { SubtitlePresetGrid(style: $style) }
                    PanelSection("Font") {
                        SubtitleFontList(style: $style)
                        SubtitleWeightPicker(style: $style)
                    }
                    PanelSection("Look") { SubtitleLookRows(style: $style) }
                    PanelSection("Position") {
                        SubtitlePositionPad(style: $style)
                        Toggle("Move Up for Controls", isOn: $style.avoidControls)
                            .font(.subheadline).toggleStyle(.switch).tint(Palette.brand)
                    }
                    Toggle(isOn: $style.hidesSoundCues) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Hide Sound Cues").font(.subheadline)
                            Text("Leaves out [sounds], (sighs), ♪ lyrics and “NAME:” labels.")
                                .font(.caption).foregroundStyle(Palette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch).tint(Palette.brand)
                    .accessibilityIdentifier("style.hideSoundCues")
                    Text(PanelMetrics.showsShortcuts ? "You can also drag subtitles on the video; − and = resize them."
                         : "You can also drag subtitles on the video, and pinch to resize.")
                        .font(.caption).foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Held to the panel's width: a row that would like more shrinks rather than spill.
                .frame(width: Self.width - 28, alignment: .leading)
                .padding(14)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Palette.surface.ignoresSafeArea())
        .overlay(alignment: .leading) { Rectangle().fill(Palette.edge).frame(width: 1).ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subtitle Style")
        .accessibilityIdentifier("subtitleStyleInspector")
    }
}

/// A grid row: the title, then its control filling the rest of the line.
struct StyleRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) { self.title = title; self.control = control() }

    var body: some View {
        GridRow {
            Text(ui: title).font(.subheadline).foregroundStyle(Palette.textSecondary)
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
        .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                    Text(ui: title)
                        .font(PanelMetrics.chipFont)
                        .frame(maxWidth: .infinity, minHeight: PanelMetrics.control - 4)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(on ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                        .background(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelPressStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
        s.hidesSoundCues = false; s.savedLooks = []
        return s
    }

    /// The standard look and position, keeping the languages and second line.
    func resetLook() -> SubtitleStyle {
        var s = SubtitleStyle()
        s.preferredLanguage = preferredLanguage; s.secondaryLanguage = secondaryLanguage
        s.secondaryScale = secondaryScale; s.secondaryColor = secondaryColor; s.hidesSoundCues = hidesSoundCues
        s.savedLooks = savedLooks
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
                Text(ui: title).font(.subheadline)
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
                        .frame(minWidth: 28, idealWidth: 34, maxWidth: 40, minHeight: 34)
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
                .frame(minWidth: 28, idealWidth: 34, maxWidth: 40, minHeight: 34)
                .help("Custom Colour")
                .accessibilityLabel("Custom \(title)")
        }
    }
}
