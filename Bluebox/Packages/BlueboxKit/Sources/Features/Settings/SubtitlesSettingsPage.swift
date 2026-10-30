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
                SubtitlePresetGrid(style: $app.subtitleStyle, columns: 3)
                    .padding(.vertical, 4)
                    .settingsRow("Subtitle Style")
            } header: {
                Text("Presets")
            } footer: {
                Text("A preset sets the font, size, colour, outline and box. Save Current keeps your own look; right-click or long-press it to rename or delete it.")
            }

            Section("Font") {
                SubtitleFontList(style: $app.subtitleStyle)
                    .padding(.vertical, 4)
                SubtitleWeightPicker(style: $app.subtitleStyle)
            }

            Section {
                SubtitleLookRows(style: $app.subtitleStyle)
                    .padding(.vertical, 4)
                Toggle("Hide Sound Cues", isOn: $app.subtitleStyle.hidesSoundCues)
            } header: {
                Text("Look")
            } footer: {
                Text("Sizes follow the picture, so subtitles look the same in a window, full screen or Picture in Picture. Hide Sound Cues leaves out [sounds], (sighs), ♪ lyrics and “NAME:” labels.")
            }

            Section {
                SubtitlePositionPad(style: $app.subtitleStyle)
                    .padding(.vertical, 4)
                Toggle("Move Up for Player Controls", isOn: $app.subtitleStyle.avoidControls)
                Button("Reset Style", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset subtitle style?", isPresented: $confirmReset, titleVisibility: .visible) {
                        Button("Reset Style", role: .destructive) { resetStyle() }
                    } message: {
                        Text("Font, size, colours and position go back to the defaults. Your languages and saved looks stay.")
                    }
            } header: {
                Text("Position")
            } footer: {
                Text("Drag the bar, the subtitles on the preview, or the subtitles on the video while it plays. While the controls show, subtitles under them move up just enough to clear them.")
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

            SubtitleSitesSection()

            Section {
                Toggle("Search Automatically", isOn: $settings.autoSearchSubtitles)
                    .disabled(!app.hasOpenSubtitlesKey)
                    .settingsRow("Search Automatically")
            } footer: {
                Text(autoSearchFooter)
            }
        }
    }

    private func resetStyle() {
        var fresh = SubtitleStyle()
        fresh.preferredLanguage = app.subtitleStyle.preferredLanguage
        fresh.secondaryLanguage = app.subtitleStyle.secondaryLanguage
        fresh.savedLooks = app.subtitleStyle.savedLooks
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
