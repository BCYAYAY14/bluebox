import DesignSystem
import Domain
import Playback
import SkipSegments
import SwiftUI

/// A page inside the Tools card.
enum ToolsPage: String, CaseIterable {
    case picture, sound, audioDelay, sleep, skip, shortcuts
}

/// Tools: nine tiles that show their state. Settings (Picture, Sound, Audio
/// delay, Sleep timer, Skip intros) open as a page inside the card; actions
/// (Repeat A–B, Save frame, Jump to time, Stats) just run. Subtitles live in
/// Audio & Subtitles.
struct ToolsPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: PlayerSession
    let skip: SkipController
    /// Tiles per row (three: the card stays narrow beside the video).
    let columns: Int
    let statsShown: Bool
    let onToggleStats: () -> Void
    let onLoop: () -> Void
    let onSnapshot: () -> Void
    let onJump: () -> Void
    @State private var page: ToolsPage?

    init(session: PlayerSession, skip: SkipController, columns: Int, statsShown: Bool, initialPage: ToolsPage? = nil,
         onToggleStats: @escaping () -> Void, onLoop: @escaping () -> Void,
         onSnapshot: @escaping () -> Void, onJump: @escaping () -> Void) {
        self.session = session; self.skip = skip; self.columns = columns; self.statsShown = statsShown
        self.onToggleStats = onToggleStats; self.onLoop = onLoop; self.onSnapshot = onSnapshot; self.onJump = onJump
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        Group {
            if let page {
                pageView(page)
                    .transition(reduceMotion ? .opacity : .push(from: .trailing))
            } else {
                grid
                    .transition(reduceMotion ? .opacity : .push(from: .leading))
            }
        }
        .animation(Motion.snappy(reduceMotion), value: page)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolsPanel")
    }

    private func open(_ p: ToolsPage?) { page = p }

    // MARK: Grid

    private var grid: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlayerCardHeader("Tools") {
                KeyCap("T")
                if PanelMetrics.showsShortcuts {
                    Button { open(.shortcuts) } label: {
                        Image(systemName: "keyboard").font(.subheadline)
                            .frame(width: PanelMetrics.control, height: PanelMetrics.control)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlayerQuietButtonStyle())
                    .foregroundStyle(Palette.textSecondary)
                    .help("Keyboard Shortcuts")
                    .accessibilityLabel("Keyboard Shortcuts")
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                ToolTile(symbol: "crop", title: "Picture", value: pictureValue, isOn: !session.videoFraming.isDefault || !session.videoAdjustments.isDefault) { open(.picture) }
                ToolTile(symbol: "waveform", title: "Sound", value: soundValue, isOn: soundOn) { open(.sound) }
                ToolTile(symbol: "timer", title: "Audio Delay", value: session.supportsAudioDelay ? Self.delayLabel(session.audioDelay) : "VLC only",
                         isOn: session.audioDelay != 0) { open(.audioDelay) }
                ToolTile(symbol: "moon.zzz", title: "Sleep Timer", value: sleepValue, isOn: session.sleepTimer != .off) { open(.sleep) }
                ToolTile(symbol: "forward.end", title: "Skip Intros", value: app.settings.skipIntroMode.title,
                         isOn: app.settings.skipIntroMode != .off) { open(.skip) }
                ToolTile(symbol: "repeat", title: "Repeat A–B", value: loopValue, isOn: session.loopStart != nil, shortcut: "L", action: onLoop)
                ToolTile(symbol: "camera", title: "Save Frame", value: Self.actionHint("S", touch: "Save"), isOn: false, shortcut: "S", action: onSnapshot)
                ToolTile(symbol: "clock.arrow.circlepath", title: "Jump to Time", value: Self.actionHint("J", touch: "Go to…"), isOn: false,
                         shortcut: "J", action: onJump)
                ToolTile(symbol: "info.circle", title: "Stats", value: statsShown ? "On" : "Off", isOn: statsShown, action: onToggleStats)
            }
        }
    }

    static func actionHint(_ key: String, touch: String) -> String {
        PanelMetrics.showsShortcuts ? key : touch
    }

    static func delayLabel(_ s: TimeInterval) -> String {
        let ms = Int((s * 1000).rounded())
        return ms == 0 ? "0 ms" : String(format: "%+d ms", ms)
    }

    private var pictureValue: String {
        let f = session.videoFraming
        var parts: [String] = []
        if f.aspect != .auto { parts.append(f.aspect.label) }
        if f.crop != .auto { parts.append("Crop \(f.crop.label)") }
        if f.scaling != .fit { parts.append(f.scaling.rawValue.capitalized) }
        if f.zoom > 1.001 { parts.append("\(Int((f.zoom * 100).rounded()))%") }
        if f.quarterTurns % 4 != 0 { parts.append("\(Int(f.rotationDegrees))°") }
        if !session.videoAdjustments.isDefault { parts.append("Adjusted") }
        return parts.isEmpty ? "Fit" : parts.prefix(2).joined(separator: " · ")
    }

    private var soundOn: Bool { session.audioEffects.isActive }
    private var soundValue: String {
        let fx = session.audioEffects
        var parts: [String] = []
        if fx.dialogueBoost { parts.append("Voice") }
        if fx.nightMode { parts.append("Night") }
        if fx.equalizer.isAudible { parts.append(fx.equalizer.preset?.title ?? "EQ") }
        return parts.isEmpty ? "Normal" : parts.joined(separator: " · ")
    }

    private var sleepValue: String {
        switch session.sleepTimer {
        case .off: "Off"
        case .endOfItem: "End of video"
        case .at(let date): "\(max(1, Int((date.timeIntervalSinceNow / 60).rounded(.up)))) min left"
        }
    }

    private var loopValue: String {
        switch (session.loopStart, session.loopEnd) {
        case (nil, _): "Off"
        case (let a?, nil): "A \(Formatters.duration(a))"
        case (let a?, let b?): "\(Formatters.duration(a))–\(Formatters.duration(b))"
        }
    }

    // MARK: Pages

    @ViewBuilder private func pageView(_ p: ToolsPage) -> some View {
        let back = { open(nil) }
        switch p {
        case .picture: PicturePage(session: session, onBack: back)
        case .sound: SoundPage(session: session, onBack: back)
        case .audioDelay: AudioDelayPage(session: session, onBack: back)
        case .sleep: SleepPage(session: session, onBack: back)
        case .skip: SkipPage(session: session, skip: skip, onBack: back)
        case .shortcuts: ShortcutsPage(onBack: back)
        }
    }
}

/// One tile: a glyph, the tool's name and its state underneath (blue when on).
struct ToolTile: View {
    let symbol: String
    let title: String
    let value: String
    let isOn: Bool
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isOn ? Palette.brandBright : Palette.textPrimary)
                    .frame(height: 18)
                Text(ui: title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    .padding(.top, 3)
                Text(value).font(.caption2.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(isOn ? Palette.brandBright : Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: PlayerCardMetrics.tileRadius, style: .continuous)
                .fill(hovering && isEnabled ? Color(white: 0.18) : Palette.elevated))
            .contentShape(RoundedRectangle(cornerRadius: PlayerCardMetrics.tileRadius, style: .continuous))
        }
        .buttonStyle(PanelPressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(shortcut.map { "\(title) (\($0))" } ?? title)
    }
}

// MARK: - Picture

/// Aspect, crop, fit, zoom and pan, rotate and flip, frame stepping, and the
/// colour adjustments. Framing is drawn by SwiftUI (never libVLC's video
/// output, which deadlocked when changed from the main thread).
struct PicturePage: View {
    @Bindable var session: PlayerSession
    let onBack: () -> Void
    @State private var customCrop = false
    /// Frame (shape and size) or Colour (the adjustments).
    @State private var tab = Tab.frame

    enum Tab: Hashable { case frame, colour }

    /// The common ratios as segments; the rest in More.
    static let commonRatios: [VideoFraming.Ratio] = [.r16x9, .r4x3, .r2_39]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerPageHeader("Picture", onBack: onBack) {
                if tab == .frame ? !session.videoFraming.isDefault : !session.videoAdjustments.isDefault {
                    Button("Reset") {
                        if tab == .frame { session.videoFraming = VideoFraming() }
                        else if session.snapshot.supportsVideoAdjustments { session.setVideoAdjustments(VideoAdjustments()) }
                    }
                    .font(.caption.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle()).foregroundStyle(Palette.brandBright)
                    .help(tab == .frame ? "Back to the video's own shape and size" : "Back to the video's own colours")
                }
            }
            PanelSegments(selection: $tab, options: [("Frame", .frame), ("Colour", .colour)])
            if tab == .frame { frame } else { adjustments }
        }
        .animation(.snappy(duration: 0.2), value: tab)
    }

    @ViewBuilder private var frame: some View {
        PanelSection("Aspect", accessory: { KeyCap("A") }) {
            ratioChoice(selection: $session.videoFraming.aspect, none: "Auto")
        }
        PanelSection("Fit", accessory: { KeyCap("Z") }) {
            PanelSegments(selection: $session.videoFraming.scaling,
                          options: [("Fit", VideoFraming.Scaling.fit), ("Fill", .fill), ("Stretch", .stretch)])
            PanelSlider(title: "Zoom", value: Binding(get: { session.videoFraming.zoom }, set: { session.videoFraming.setZoom($0) }),
                        range: 1...4, defaultValue: 1, format: { "\(Int(($0 * 100).rounded()))%" })
            if session.videoFraming.zoom > 1 {
                PanelSlider(title: "Pan Sideways", value: $session.videoFraming.panX, range: -1...1, defaultValue: 0,
                            format: { String(format: "%.0f", $0 * 100) })
                PanelSlider(title: "Pan Up/Down", value: $session.videoFraming.panY, range: -1...1, defaultValue: 0,
                            format: { String(format: "%.0f", $0 * 100) })
            }
            Text(PanelMetrics.showsShortcuts ? "Pinch the trackpad to zoom; drag to pan while zoomed." : "Pinch the video to zoom; drag to pan while zoomed.")
                .font(.caption).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        PanelSection("Crop", accessory: { KeyCap("⇧C") }) {
            ratioChoice(selection: $session.videoFraming.crop, none: "None")
            DisclosureGroup(isExpanded: $customCrop) {
                VStack(spacing: Spacing.s) {
                    PanelSlider(title: "Top", value: $session.videoFraming.cropTop, range: 0...0.45, defaultValue: 0, format: pct)
                    PanelSlider(title: "Bottom", value: $session.videoFraming.cropBottom, range: 0...0.45, defaultValue: 0, format: pct)
                    PanelSlider(title: "Left", value: $session.videoFraming.cropLeft, range: 0...0.45, defaultValue: 0, format: pct)
                    PanelSlider(title: "Right", value: $session.videoFraming.cropRight, range: 0...0.45, defaultValue: 0, format: pct)
                }
                .padding(.top, Spacing.s)
            } label: {
                Text("Custom Crop").font(.subheadline.weight(.semibold))
            }
            .tint(Palette.textSecondary)
        }
        PanelSection("Rotate, Flip and Step") {
            HStack(spacing: 6) {
                iconButton("rotate.right", label: "Rotate (R)", isOn: session.videoFraming.quarterTurns % 4 != 0) { session.videoFraming.rotate() }
                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Flip Horizontally",
                           isOn: session.videoFraming.flipHorizontal) { session.videoFraming.flipHorizontal.toggle() }
                iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", label: "Flip Vertically",
                           isOn: session.videoFraming.flipVertical) { session.videoFraming.flipVertical.toggle() }
                Spacer(minLength: Spacing.s)
                iconButton("backward.frame", label: "Previous Frame (<)", isOn: false) { session.stepFrame(by: -1) }
                iconButton("forward.frame", label: "Next Frame (>)", isOn: false) { session.stepFrame(by: 1) }
            }
        }
    }

    /// Auto (or None), the common ratios, then More for the rest.
    private func ratioChoice(selection: Binding<VideoFraming.Ratio>, none: String) -> some View {
        let common = Self.commonRatios
        let rest = VideoFraming.Ratio.allCases.filter { $0 != .auto && !common.contains($0) }
        return PanelSegmentsWithMore(selection: selection,
                                     shown: [(none, .auto)] + common.map { ($0.label, $0) },
                                     more: rest.map { ($0.label, $0) })
    }

    private func iconButton(_ symbol: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: PanelMetrics.control + 6, height: PanelMetrics.control + 2)
                .foregroundStyle(isOn ? Color.black : Palette.textPrimary)
                .background(isOn ? Color.white : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(label)
    }

    @ViewBuilder private var adjustments: some View {
        let a = session.videoAdjustments
        PanelSection("Colour") {
            if session.snapshot.supportsVideoAdjustments {
                PanelSlider(title: "Brightness", value: adj(\.brightness), range: -1...1, defaultValue: 0, format: { String(format: "%+.0f", $0 * 100) })
                PanelSlider(title: "Contrast", value: adj(\.contrast), range: 0...2, defaultValue: 1, format: pct)
                PanelSlider(title: "Saturation", value: adj(\.saturation), range: 0...2, defaultValue: 1, format: pct)
                PanelSlider(title: "Hue", value: adj(\.hue), range: -180...180, defaultValue: 0, format: { String(format: "%+.0f°", $0) })
                PanelSlider(title: "Gamma", value: adj(\.gamma), range: 0.5...2, defaultValue: 1, format: { String(format: "%.2f", $0) })
                PanelSlider(title: "Sharpness", value: adj(\.sharpness), range: 0...2, defaultValue: 0, format: { String(format: "%.1f", $0) })
                Toggle("Invert Colours", isOn: Binding(get: { a.invert }, set: { var n = a; n.invert = $0; session.setVideoAdjustments(n) }))
                    .font(.subheadline).toggleStyle(.switch).tint(Palette.brand)
                Text("While adjustments are on, HDR video plays in standard range.").font(.caption).foregroundStyle(Palette.textTertiary)
            } else {
                Text("Picture adjustments aren't available for HLS streams. They work with files, direct links, downloads and torrents.")
                    .font(.footnote).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func adj(_ kp: WritableKeyPath<VideoAdjustments, Double>) -> Binding<Double> {
        Binding(get: { session.videoAdjustments[keyPath: kp] }, set: {
            var n = session.videoAdjustments; n[keyPath: kp] = $0; session.setVideoAdjustments(n)
        })
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

// MARK: - Sound

/// Dialogue Boost and Night Mode for this video (Settings › Playback sets the
/// defaults), and the equaliser, which is the profile's for every video.
struct SoundPage: View {
    @Environment(AppModel.self) private var app
    let session: PlayerSession
    let onBack: () -> Void

    var body: some View {
        let fx = session.audioEffects
        let supported = session.snapshot.supportsAudioEffects
        VStack(alignment: .leading, spacing: 10) {
            PlayerPageHeader("Sound", onBack: onBack) {
                if fx.dialogueBoost || fx.nightMode || fx.equalizer != EqualizerSettings() {
                    Button("Reset") { session.setAudioEffects(AudioEffects()); app.equalizer = EqualizerSettings() }
                        .font(.caption.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle()).foregroundStyle(Palette.brandBright)
                        .disabled(!supported)
                }
            }
            SoundToggle(title: "Dialogue Boost", detail: "Voices clearer over music and effects", symbol: "person.wave.2",
                        isOn: fx.dialogueBoost) { var n = fx; n.dialogueBoost = $0; session.setAudioEffects(n) }
                .disabled(!supported)
            SoundToggle(title: "Night Mode", detail: "Loud scenes quieter, quiet ones louder", symbol: "moon",
                        isOn: fx.nightMode) { var n = fx; n.nightMode = $0; session.setAudioEffects(n) }
                .disabled(!supported)
            PanelSection("Equaliser", accessory: {
                Text("\(app.currentProfile.name), every video").font(.caption).foregroundStyle(Palette.textTertiary).lineLimit(1)
            }) {
                EqualizerEditor(settings: Binding(get: { session.audioEffects.equalizer }, set: { eq in
                    var n = session.audioEffects; n.equalizer = eq; session.setAudioEffects(n)
                }), onCommit: { app.equalizer = session.audioEffects.equalizer })
                .disabled(!supported)
                .opacity(supported ? 1 : 0.5)
            }
            .padding(.top, 4)
            if !supported {
                Text("Not available for HLS streams. They work with files, downloads, torrents and direct links.")
                    .font(.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A preset menu and a switch, ten points joined by a curve (drag one up or
/// down; moving any makes it Custom), and Preamp. Every change is heard at
/// once; `onCommit` saves it when a drag ends or a preset is picked.
struct EqualizerEditor: View {
    @Binding var settings: EqualizerSettings
    let onCommit: () -> Void
    @State private var dragging: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BlueboxMenu(String(localized: "Equaliser")) {
                    for p in EqualizerPreset.allCases {
                        BlueboxMenuButton(p.title, checked: settings.preset == p) { settings = settings.applying(p); onCommit() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(settings.preset?.title ?? "Custom").font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: PanelMetrics.control - 4)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Equaliser preset, \(settings.preset?.title ?? "Custom")")
                Toggle("Equaliser", isOn: Binding(get: { settings.isOn }, set: { settings.isOn = $0; onCommit() }))
                    .labelsHidden().toggleStyle(.switch).tint(Palette.brand)
            }
            curve
                .opacity(settings.isOn ? 1 : 0.45)
            PanelSlider(title: "Preamp", value: Binding(get: { settings.preamp }, set: { settings.preamp = $0; settings.isOn = true }),
                        range: EqualizerSettings.preampRange, defaultValue: 0, format: Self.dB)
                .simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { _ in onCommit() })
        }
    }

    static func dB(_ v: Double) -> String { abs(v) < 0.05 ? "0 dB" : String(format: v > 0 ? "+%.1f dB" : "−%.1f dB", abs(v)) }

    static func hz(_ f: Double) -> String { f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))" }

    /// The ten points on a −12…+12 dB field, a line through them, and the
    /// frequencies under them. Dragging anywhere moves the nearest band.
    private var curve: some View {
        let bands = EqualizerSettings.frequencies.count
        let range = EqualizerSettings.gainRange
        return VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let inset: CGFloat = 9
                let x = { (i: Int) in inset + (w - inset * 2) * CGFloat(i) / CGFloat(bands - 1) }
                let y = { (g: Double) in inset + (h - inset * 2) * CGFloat((range.upperBound - g) / (range.upperBound - range.lowerBound)) }
                ZStack(alignment: .topLeading) {
                    Path { p in p.move(to: CGPoint(x: inset, y: h / 2)); p.addLine(to: CGPoint(x: w - inset, y: h / 2)) }
                        .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    ForEach(0..<bands, id: \.self) { i in
                        Path { p in p.move(to: CGPoint(x: x(i), y: inset)); p.addLine(to: CGPoint(x: x(i), y: h - inset)) }
                            .stroke(.white.opacity(0.08), lineWidth: 3)
                    }
                    Path { p in
                        for i in 0..<bands {
                            let pt = CGPoint(x: x(i), y: y(settings.gains[i]))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(Palette.brandBright, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    ForEach(0..<bands, id: \.self) { i in
                        Circle().fill(.white)
                            .frame(width: dragging == i ? 16 : 13, height: dragging == i ? 16 : 13)
                            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                            .position(x: x(i), y: y(settings.gains[i]))
                    }
                    if let i = dragging {
                        Text(Self.dB(settings.gains[i])).font(.caption2.weight(.bold)).monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.75), in: Capsule())
                            .position(x: min(max(x(i), 26), w - 26), y: max(y(settings.gains[i]) - 18, 8))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let i = dragging ?? Int(((v.startLocation.x - inset) / max(w - inset * 2, 1) * CGFloat(bands - 1)).rounded())
                        let band = min(max(i, 0), bands - 1)
                        dragging = band
                        let g = range.upperBound - Double((v.location.y - inset) / max(h - inset * 2, 1)) * (range.upperBound - range.lowerBound)
                        var n = settings
                        n.setGain((g * 2).rounded() / 2, band: band)  // half-dB steps
                        n.isOn = true
                        settings = n
                    }
                    .onEnded { _ in dragging = nil; onCommit() })
            }
            .frame(height: 120)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            // Each frequency under its point.
            GeometryReader { geo in
                let inset: CGFloat = 9, w = geo.size.width
                ForEach(Array(EqualizerSettings.frequencies.enumerated()), id: \.offset) { i, f in
                    Text(Self.hz(f)).font(.caption2.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                        .fixedSize()
                        .position(x: inset + (w - inset * 2) * CGFloat(i) / CGFloat(bands - 1), y: 7)
                }
            }
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Equaliser bands")
        .accessibilityValue(zip(EqualizerSettings.frequencies, settings.gains).map { "\(Self.hz($0)) hertz \(Self.dB($1))" }.joined(separator: ", "))
    }
}

/// A switch row with a symbol and a one-line explanation.
struct SoundToggle: View {
    let title: String
    let detail: String
    let symbol: String
    let isOn: Bool
    let set: @MainActor @Sendable (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        // The switch in its own trailing column, so every row's lines up (the Mac
        // otherwise puts it straight after the label).
        HStack(spacing: Spacing.s) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(isOn ? Palette.brandBright : Palette.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(ui: title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: Spacing.s)
            Toggle(title, isOn: Binding(get: { isOn }, set: set)).labelsHidden().toggleStyle(.switch)
        }
        .tint(Palette.brand)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .frame(minHeight: PanelMetrics.control + 8)
    }
}

// MARK: - Audio delay

struct AudioDelayPage: View {
    let session: PlayerSession
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlayerPageHeader("Audio Delay", onBack: onBack)
            if session.supportsAudioDelay {
                ValueDial(title: "Audio delay", value: session.audioDelay, range: -2...2, defaultValue: 0,
                          fine: 0.05, coarse: 0.25, format: ToolsPanel.delayLabel, meaning: Self.meaning,
                          stepLabel: { String(format: $0 > 0 ? "+%d" : "−%d", Int((abs($0) * 1000).rounded())) }) { session.setAudioDelay($0) }
                Text("Voices before lips move: play the sound later. Lips before voices: earlier. Steps are in milliseconds.")
                    .font(.caption).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Audio delay works when VLC plays the video (MKV and most torrents). This video plays with AVPlayer.")
                    .font(.footnote).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func meaning(_ s: Double) -> String {
        let ms = Int((abs(s) * 1000).rounded())
        return ms == 0 ? "Sound plays as recorded" : "Sound plays \(ms) ms \(s > 0 ? "later" : "earlier")"
    }
}

// MARK: - Sleep timer

struct SleepPage: View {
    let session: PlayerSession
    let onBack: () -> Void
    @State private var chosenMinutes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlayerPageHeader("Sleep Timer", onBack: onBack)
            PanelSegmentsWithMore(selection: Binding(get: { choice }, set: { set($0) }),
                                  shown: [("Off", 0), ("15 min", 15), ("30 min", 30), ("1 hr", 60)],
                                  more: [("45 min", 45), ("90 min", 90), ("End of Video", -1)])
            if case .at(let date) = session.sleepTimer {
                Text("Pauses at \(date.formatted(date: .omitted, time: .shortened)).").font(.caption).foregroundStyle(Palette.textSecondary)
            } else if session.sleepTimer == .endOfItem {
                Text("Pauses when this video ends, without playing the next.").font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var choice: Int {
        switch session.sleepTimer {
        case .off: 0
        case .endOfItem: -1
        case .at: chosenMinutes
        }
    }

    private func set(_ minutes: Int) {
        chosenMinutes = minutes
        switch minutes {
        case 0: session.setSleepTimer(.off)
        case -1: session.setSleepTimer(.endOfItem)
        default: session.setSleepTimer(.at(Date().addingTimeInterval(Double(minutes) * 60)))
        }
    }
}

// MARK: - Skip intros

/// Skip Intro & Credits: the modes, and per-show choices (community timestamps included).
struct SkipPage: View {
    @Environment(AppModel.self) private var app
    let session: PlayerSession
    let skip: SkipController
    let onBack: () -> Void

    var body: some View {
        let settings = app.settings
        VStack(alignment: .leading, spacing: 12) {
            PlayerPageHeader("Skip Intros", onBack: onBack)
            modeRow("Intros & Recaps", selection: settings.skipIntroMode) { settings.skipIntroMode = $0 }
            modeRow("Credits", selection: settings.skipCreditsMode) { settings.skipCreditsMode = $0 }
            if let key = session.item?.key {
                let show = key.seriesKey != nil ? "This Show" : "This Film"
                Toggle("Skip for \(show)", isOn: Binding(get: { settings.skipsAllowed(for: key) },
                                                         set: { settings.setSkipsAllowed($0, for: key) }))
                    .font(.subheadline).tint(Palette.brand)
                Toggle("Community Timestamps for \(show)", isOn: Binding(get: { settings.crowdSkipsAllowed(for: key) },
                                                              set: { settings.setCrowdSkipsAllowed($0, for: key); skip.reset() }))
                    .font(.subheadline).tint(Palette.brand)
                Text(sourceLine).font(.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modeRow(_ title: String, selection: SkipSegmentPlanner.Mode, set: @escaping (SkipSegmentPlanner.Mode) -> Void) -> some View {
        PanelSection(title) {
            PanelSegments(selection: Binding(get: { selection }, set: { set($0) }),
                          options: SkipSegmentPlanner.Mode.allCases.map { ($0.title, $0) })
        }
    }

    private var sourceLine: String {
        guard let result = skip.result else { return "Looking for intro and credits times…" }
        guard !result.sources.isEmpty else {
            return "No intro or credits times found for this video. Chapter markers, Jellyfin, TheIntroDB and IntroDB were checked."
        }
        let kinds = Set(result.segments.map(\.kind))
        let found = [(SkipSegment.Kind.recap, "recap"), (.intro, "intro"), (.credits, "credits")].filter { kinds.contains($0.0) }.map(\.1)
        return "Found \(ListFormatter.localizedString(byJoining: found)) from \(ListFormatter.localizedString(byJoining: result.sources.map(\.displayName)))."
    }
}

// MARK: - Shortcuts

/// Every player shortcut, so they can be discovered (Mac).
struct ShortcutsPage: View {
    let onBack: () -> Void

    static let all: [(String, String)] = [
        ("Space", "Play or pause"), ("← →", "Back or forward"), ("Hold →", "Play at 2× while held"),
        ("⇧← ⇧→", "Previous or next subtitle line"), ("0–9", "Jump to 0–90% of the video"),
        ("[ ]", "Slower or faster (0.05×)"), ("↑ ↓", "Volume"), ("M", "Mute"),
        ("F", "Full screen"), ("Esc", "Close a card, leave full screen, then close"),
        ("T", "Tools"), ("E", "Episodes"), ("V", "Next subtitle track"), ("C", "Subtitles off or back on"),
        ("B", "Next audio track"),
        ("{ }", "Subtitles earlier or later (0.1 s)"), ("− =", "Subtitle size"),
        ("A", "Aspect ratio"), ("⇧C", "Crop"), ("Z", "Zoom"), ("R", "Rotate"), ("< >", "Step one frame back or forward (also , .)"),
        ("L", "A–B repeat"), ("J", "Jump to time"), ("N P", "Next or previous chapter"),
        ("⇧N ⇧P", "Next or previous episode"), ("S", "Save frame"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlayerPageHeader("Keyboard Shortcuts", onBack: onBack)
            ForEach(Self.all, id: \.0) { keys, action in
                HStack {
                    Text(action).font(.subheadline)
                    Spacer(minLength: Spacing.s)
                    KeyCap(keys)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Stats

/// Stats for nerds, over the top-left of the video while Tools › Stats is on.
struct PlayerStatsOverlay: View {
    let session: PlayerSession
    let onClose: () -> Void
    @State private var diagnostics: PlaybackDiagnostics?

    var body: some View {
        let s = session.snapshot
        let d = diagnostics
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Stats").font(.caption.weight(.bold))
                Spacer(minLength: Spacing.m)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.1), in: Circle())
                        .frame(width: PanelMetrics.control, height: PanelMetrics.control)
                        .contentShape(Circle())
                }
                .buttonStyle(PanelPressStyle())
                .accessibilityLabel("Hide Stats")
            }
            row("Engine", d?.engine)
            row("Container", d?.container)
            row("Video", d?.videoCodec)
            row("Resolution", s.presentationSize == .zero ? nil : "\(Int(s.presentationSize.width)) × \(Int(s.presentationSize.height))")
            row("Data rate", d?.bitrate.map(PlaybackDiagnostics.formatBitrate))
            row("Buffered ahead", s.bufferedUntil > s.position ? String(format: "%.0f s", s.bufferedUntil - s.position) : nil)
            row("Dropped frames", d?.droppedFrames.map(String.init))
            row("Source", d?.source)
            row("Speed", PlaybackSpeed.label(s.rate))
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 230)
        .playerCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playerStats")
        .task {
            while !Task.isCancelled {
                diagnostics = session.engine.diagnostics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(ui: title).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Spacing.s)
            Text(value ?? "–").fontWeight(.medium).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
