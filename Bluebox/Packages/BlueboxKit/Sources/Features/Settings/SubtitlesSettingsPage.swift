import DesignSystem
import Subtitles
import SwiftUI

/// Settings › (profile) › Subtitles: a live frame, then the look and
/// placement, which are the profile's own, then timing and online search,
/// which everyone on the device shares. Languages are on the profile's
/// Languages page. Every change shows on the frame at once.
struct SubtitlesSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var confirmReset = false

    var body: some View {
        @Bindable var app = app
        @Bindable var settings = app.settings
        SettingsForm(.subtitles) {
            SubtitleStylePreview(style: $app.subtitleStyle)
        } content: {
            Section {
                ProfileOwnerCaption(profile: app.currentProfile,
                                    note: "The style is only for \(app.currentProfile.name). Timing and online search are for \(SettingsPage.everyoneTitle.lowercased()).")
            }

            Section {
                SettingsPicker("Preset", selection: presetBinding,
                               options: [.init("Custom", value: nil)] + SubtitleStyle.Preset.allCases.map { .init($0.title, value: $0) })
                    .settingsRow("Subtitle Style")
                SettingsPicker("Font", selection: fontBinding, groups: [
                    [.init("System", value: "design:system"), .init("Rounded", value: "design:rounded"),
                     .init("Serif", value: "design:serif"), .init("Monospaced", value: "design:monospaced")],
                    SubtitleFonts.available.map { .init($0, value: $0) },
                ])
                SettingsSlider("Size", value: $app.subtitleStyle.relativeSize, in: 0.02...0.12) {
                    "\(Int(($0 / 0.045 * 100).rounded()))%"
                }
                SettingsPicker("Weight", selection: Binding(get: { app.subtitleStyle.isBold ? SubtitleStyle.Weight.bold : .regular },
                                                            set: { app.subtitleStyle.weight = $0 }),
                               options: [.init("Regular", value: .regular), .init("Bold", value: .bold)])
                SettingsColorRow(title: "Colour", color: $app.subtitleStyle.textColor)
                SettingsSlider("Outline", value: $app.subtitleStyle.outlineWidth, in: 0...6) {
                    $0 < 0.1 ? "Off" : String(format: "%.1f pt", $0)
                }
                Toggle("Shadow", isOn: $app.subtitleStyle.shadow)
                SettingsSlider("Background Box", value: $app.subtitleStyle.backgroundOpacity, in: 0...1) {
                    $0 < 0.01 ? "Off" : "\(Int(($0 * 100).rounded()))%"
                }
                Button("Reset Style", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset subtitle style?", isPresented: $confirmReset, titleVisibility: .visible) {
                        Button("Reset Style", role: .destructive) { resetStyle() }
                    } message: {
                        Text("Font, size, colours and position go back to the defaults. Your languages stay.")
                    }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Sizes follow the picture, so subtitles look the same in a window, full screen or Picture in Picture. Subtitles inside a playing video take a new font, weight or shadow from the next video; the rest changes at once.")
            }

            Section {
                SettingsPicker("Position", selection: $app.subtitleStyle.anchor,
                               options: [.init("Bottom", value: .bottom), .init("Middle", value: .middle), .init("Top", value: .top)])
                SettingsPicker("Alignment", selection: $app.subtitleStyle.alignment, options: [
                    .init("Left", value: .leading, systemImage: "text.alignleft"),
                    .init("Centre", value: .center, systemImage: "text.aligncenter"),
                    .init("Right", value: .trailing, systemImage: "text.alignright"),
                ])
                SettingsSlider("Distance from Edge", value: $app.subtitleStyle.verticalMargin, in: 0...0.5) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                Toggle("Move Up for Player Controls", isOn: $app.subtitleStyle.avoidControls)
                Button("Reset Position") { app.subtitleStyle.resetPosition() }
                    .disabled(app.subtitleStyle.isDefaultPosition)
            } header: {
                Text("Placement")
            } footer: {
                Text("Or drag the subtitles on the preview, or on the video while it plays.")
            }

            if app.subtitleStyle.secondaryLanguage != nil {
                Section {
                    SettingsSlider("Size", value: $app.subtitleStyle.secondaryScale, in: 0.5...1.2) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                    SettingsColorRow(title: "Colour", color: $app.subtitleStyle.secondaryColor)
                } header: {
                    Text("Second Language")
                }
            }

            Section {
                Stepper(value: Binding(get: { settings.defaultSubtitleDelay },
                                       set: { settings.defaultSubtitleDelay = ($0 * 10).rounded() / 10 }),
                        in: -10...10, step: 0.1) {
                    LabeledContent("Default Delay", value: delayLabel(settings.defaultSubtitleDelay))
                }
                .settingsRow("Default Delay")
                if settings.defaultSubtitleDelay != 0 {
                    Button("Reset Delay") { settings.defaultSubtitleDelay = 0 }
                }
            } header: {
                Text("Timing · Everyone")
            } footer: {
                Text("Positive values show subtitles later. Fine-tune one video in the player with [ and ].")
            }

            OpenSubtitlesSection()

            Section {
                Toggle("Search Automatically", isOn: $settings.autoSearchSubtitles)
                    .disabled(!app.hasOpenSubtitlesKey)
                    .settingsRow("Search Automatically")
            } footer: {
                Text(autoSearchFooter)
            }
        }
    }

    private var presetBinding: Binding<SubtitleStyle.Preset?> {
        Binding {
            SubtitleStyle.Preset.allCases.first { app.subtitleStyle.applying($0) == app.subtitleStyle }
        } set: { preset in
            if let preset { app.subtitleStyle = app.subtitleStyle.applying(preset) }
        }
    }

    private var fontBinding: Binding<String> {
        Binding {
            app.subtitleStyle.fontName ?? "design:\(app.subtitleStyle.design.rawValue)"
        } set: { v in
            if v.hasPrefix("design:") {
                app.subtitleStyle.fontName = nil
                app.subtitleStyle.design = .init(rawValue: String(v.dropFirst(7))) ?? .system
            } else {
                app.subtitleStyle.fontName = v
            }
        }
    }

    private func resetStyle() {
        var fresh = SubtitleStyle()
        fresh.preferredLanguage = app.subtitleStyle.preferredLanguage
        fresh.secondaryLanguage = app.subtitleStyle.secondaryLanguage
        app.subtitleStyle = fresh
    }

    private var autoSearchFooter: String {
        if !app.hasOpenSubtitlesKey { return "Add an OpenSubtitles API key above to search automatically." }
        if app.subtitleStyle.preferredLanguage == nil { return "Choose a subtitle language in Languages first; automatic search looks for it." }
        return "When a video has nothing in your language, Bluebox adds the best match from OpenSubtitles. Each counts toward your daily limit."
    }

    private func delayLabel(_ d: Double) -> String {
        if abs(d) < 0.05 { return "None" }
        return String(format: "%+.1f s", d)
    }
}
