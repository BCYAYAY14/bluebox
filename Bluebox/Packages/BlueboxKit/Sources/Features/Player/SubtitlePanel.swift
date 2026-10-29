import DesignSystem
import Playback
import Subtitles
import SwiftUI

/// The pages inside the Audio & Subtitles card: Style (look and position),
/// Timing and Second line. Every change shows on the video straight away
/// (with a sample line when nothing is being said).

/// Picture subtitles can't be restyled; VLC's text ones restyle a moment after a change.
@MainActor
func subtitleStyleNote(_ session: PlayerSession) -> String? {
    guard case .embedded(let id) = session.subtitleSelection,
          let track = session.snapshot.embeddedSubtitles.first(where: { $0.id == id }) else { return nil }
    if track.isBitmap {
        return "This subtitle track is made of pictures (PGS or VobSub), so it keeps the look it came with. Style applies to text subtitles."
    }
    if session.snapshot.drawsEmbeddedSubtitles {
        return "Subtitles from the video take a new look a second after you stop adjusting. Italic and Left/Right alignment apply to subtitle files only."
    }
    return nil
}

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

/// Delay in fine steps, "sync to now" (one or two points), and frame-rate fixes.
struct SubtitleTimingPage: View {
    let session: PlayerSession
    let onBack: () -> Void
    @State private var subtitleFPS = 25.0
    @State private var videoFPS = 24000.0 / 1001
    @State private var showsDrift = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlayerPageHeader("Timing", onBack: onBack) {
                if !session.subtitleOffset.isDefault {
                    Button("Reset") { session.resetSubtitleOffset() }
                        .font(.caption.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle()).foregroundStyle(Palette.brandBright)
                }
            }
            if !session.canAdjustSubtitleTiming {
                Text(session.subtitleSelection == .off
                     ? "Turn on subtitles to adjust their timing."
                     : "Timing for subtitles inside the video works when the player draws them (VLC). Subtitle files can always be retimed.")
                    .font(.footnote).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                delay
                if session.canRetimeSubtitleLines {
                    syncToNow
                    drift
                } else {
                    Text("Sync to Now and drift fixes need the lines themselves, so they work with subtitle files.")
                        .font(.caption).foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var delay: some View {
        VStack(spacing: Spacing.s) {
            Text(session.subtitleOffset.label)
                .font(.title2.weight(.bold)).monospacedDigit()
                .foregroundStyle(session.subtitleOffset.isDefault ? Palette.textPrimary : Palette.brandBright)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Subtitle delay \(session.subtitleOffset.label)")
            HStack(spacing: 6) {
                step(-0.5, keys: nil)
                step(-0.1, keys: "{")
                step(0.1, keys: "}")
                step(0.5, keys: nil)
            }
            Text("Earlier ← → Later").font(.caption2).foregroundStyle(Palette.textTertiary)
        }
    }

    private func step(_ d: Double, keys: String?) -> some View {
        Button { withAnimation(.snappy(duration: 0.2)) { session.nudgeSubtitles(by: d) } } label: {
            VStack(spacing: 2) {
                Text(d > 0 ? String(format: "+%.1f", d) : String(format: "−%.1f", -d)).font(PanelMetrics.chipFont).monospacedDigit()
                if let keys { KeyCap(keys) } else if PanelMetrics.showsShortcuts { Color.clear.frame(height: 18) }
            }
            .frame(maxWidth: .infinity, minHeight: PanelMetrics.control + (PanelMetrics.showsShortcuts ? 18 : 0))
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PanelPressStyle())
        .accessibilityLabel(d > 0 ? "Show subtitles \(String(format: "%.1f", d)) seconds later" : "Show subtitles \(String(format: "%.1f", -d)) seconds earlier")
    }

    /// "Sync to now": pick the line you just heard; a second pick later fixes drift.
    @ViewBuilder private var syncToNow: some View {
        Divider().overlay(Palette.separator)
        VStack(alignment: .leading, spacing: 4) {
            Text("Sync to Now").font(.subheadline.weight(.semibold))
            Text(session.pendingSyncPoint == nil
                 ? "Pick the line you just heard. Bluebox moves the subtitles so it starts now."
                 : "Synced. Pick another line a few minutes later and Bluebox also fixes drift.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        let cues = Array(nearby.prefix(6))
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
        if session.pendingSyncPoint != nil {
            Button("Cancel Second Point") { session.clearPendingSync() }
                .font(.caption.weight(.semibold)).buttonStyle(.plain).foregroundStyle(Palette.brandBright)
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
                BlueboxPicker("Subtitles made for", selection: $subtitleFPS, options: SubtitleSyncFrameRates.options)
                    .font(.subheadline)
                BlueboxPicker("Video is", selection: $videoFPS, options: SubtitleSyncFrameRates.options)
                    .font(.subheadline)
                PanelActionButton(title: "Convert Frame Rate", symbol: "arrow.left.arrow.right") {
                    session.convertSubtitleFrameRate(subtitleFPS: subtitleFPS, videoFPS: videoFPS)
                }
                PanelSlider(title: "Speed", value: Binding(get: { session.subtitleOffset.scale }, set: { session.setSubtitleSpeed($0) }),
                            range: SubtitleOffset.scaleRange, defaultValue: 1, format: { String(format: "%.3f×", $0) })
            }
            .padding(.top, Spacing.s)
        } label: {
            Text("Drift & Frame Rate").font(.subheadline.weight(.semibold))
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

/// Presets, size, weight, colour, background and outline, the font, and
/// where the line sits (also by dragging it on the video).
struct SubtitleStylePage: View {
    @Binding var style: SubtitleStyle
    var note: String?
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerPageHeader("Subtitle Style", onBack: onBack)
            looks
            SubtitlePositionSection(style: $style)
        }
    }

    @ViewBuilder private var looks: some View {
        if let note {
            Label(note, systemImage: "info.circle")
                .font(.caption).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Wraps, so none is cut off at the panel's edge.
        ChipFlow(items: SubtitleStyle.Preset.allCases) { p in
            PanelChip(title: p.title, selected: style.matches(p)) { style = style.applying(p) }
        }
        HStack(spacing: 6) {
            PanelSlider(title: "Size", value: $style.relativeSize, range: 0.02...0.12, defaultValue: SubtitleStyle().relativeSize,
                        format: { "\(Int(($0 / 0.045 * 100).rounded()))%" })
            if PanelMetrics.showsShortcuts {
                HStack(spacing: 3) { KeyCap("−"); KeyCap("=") }
                    .help("Make subtitles smaller (−) or larger (=)")
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Weight").font(.subheadline)
            ChipFlow(items: SubtitleStyle.Weight.allCases) { w in
                PanelChip(title: w.rawValue.capitalized, selected: style.weight == w) { style.weight = w }
            }
        }
        ColorSwatches(title: "Colour", color: $style.textColor)
        VStack(alignment: .leading, spacing: 6) {
            Text("Background").font(.subheadline)
            HStack(spacing: 6) {
                PanelChip(title: "None", selected: !style.shadow && style.backgroundOpacity < 0.01 && style.outlineWidth < 0.1) {
                    style.shadow = false; style.backgroundOpacity = 0; style.outlineWidth = 0
                }
                PanelChip(title: "Shadow", selected: style.shadow && style.backgroundOpacity < 0.01) {
                    style.shadow = true; style.backgroundOpacity = 0
                }
                PanelChip(title: "Box", selected: style.backgroundOpacity >= 0.01) {
                    style.shadow = false; style.backgroundOpacity = max(style.backgroundOpacity, 0.75)
                }
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
        BlueboxPicker("Font", selection: SubtitleFonts.binding($style), groups: SubtitleFonts.pickerGroups)
        .font(.subheadline)
        Toggle("Italic", isOn: $style.italic).font(.subheadline).tint(Palette.brand)
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

struct SubtitlePositionSection: View {
    @Binding var style: SubtitleStyle

    var body: some View {
        PanelSection("Position", accessory: {
            if !style.isDefaultPosition {
                Button("Reset") { withAnimation(.smooth(duration: 0.3)) { style.resetPosition() } }
                    .font(.caption.weight(.semibold)).buttonStyle(PlayerQuietButtonStyle()).foregroundStyle(Palette.brandBright)
            }
        }) {
            Text("Drag the line on the video to move it. It snaps to the centre and to the usual spot at the top or bottom. Pinch it to resize.")
                .font(.caption).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                PanelChip(title: "Bottom", selected: style.anchor == .bottom) {
                    withAnimation(.smooth(duration: 0.3)) { style.anchor = .bottom }
                }
                PanelChip(title: "Top", selected: style.anchor == .top) {
                    withAnimation(.smooth(duration: 0.3)) { style.anchor = .top }
                }
                Spacer(minLength: Spacing.s)
                ForEach([(SubtitleStyle.Alignment.leading, "text.alignleft", "Left"), (.center, "text.aligncenter", "Centre"),
                         (.trailing, "text.alignright", "Right")], id: \.0) { a, symbol, label in
                    Button { style.alignment = a } label: {
                        Image(systemName: symbol)
                            .frame(width: PanelMetrics.control, height: PanelMetrics.control)
                            .background(style.alignment == a ? Palette.brand : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PanelPressStyle())
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(style.alignment == a ? .isSelected : [])
                }
            }
            PanelSlider(title: "Distance from Edge", value: $style.verticalMargin, range: 0...0.5, defaultValue: SubtitleStyle.defaultMargin,
                        format: { "\(Int(($0 * 100).rounded()))%" })
            Toggle("Move Up for Controls", isOn: $style.avoidControls).font(.subheadline).tint(Palette.brand)
        }
    }
}
