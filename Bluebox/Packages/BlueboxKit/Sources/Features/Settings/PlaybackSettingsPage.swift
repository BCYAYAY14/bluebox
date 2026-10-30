import DesignSystem
import Domain
import SkipSegments
import SwiftUI

/// Settings › Player (everyone on this device): a live player frame, then
/// which player, where playback starts, the transport controls, the Up Next
/// countdown and sound. Autoplay and the audio language belong to each
/// profile (`ProfilePlaybackPage`, `ProfileLanguagesPage`).
struct PlaybackSettingsPage: View {
    @Environment(AppModel.self) private var app
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        @Bindable var app = app
        @Bindable var settings = app.settings
        SettingsForm(.playback) {
            PlaybackPreview(skipBack: settings.skipBackSeconds, skipForward: settings.skipForwardSeconds,
                            speed: app.defaultSpeed,
                            engine: settings.enginePreference == .preferVLC ? "VLC" : settings.enginePreference == .avPlayerOnly ? "AVPlayer" : "Automatic",
                            upNext: settings.autoplayNextEpisode ? settings.upNextCountdown : nil)
        } content: {
            Section {
                SettingsPicker("Player", selection: $settings.enginePreference,
                               options: AppSettings.EnginePreference.allCases.map { .init($0.title, value: $0) })
                    .settingsRow("Player")
            } footer: {
                Text(engineFooter)
            }

            Section {
                SettingsPicker("Start Playing", selection: $settings.resumeBehavior,
                               options: AppSettings.ResumeBehavior.allCases.map { .init($0.title, value: $0) })
                    .settingsRow("Start Playing")
                SettingsPicker("Default Speed", selection: $app.defaultSpeed,
                               options: Self.speeds.map { .init(speedLabel($0), value: $0) })
                    .settingsRow("Default Speed")
            } header: {
                Text("Starting Playback")
            } footer: {
                Text("“Where I Left Off” resumes anything watched for more than 30 seconds.")
            }

            Section {
                SettingsPicker("Skip Back", selection: $settings.skipBackSeconds,
                               options: AppSettings.skipIntervals.map { .init("\($0) seconds", value: $0) })
                    .settingsRow("Skip Back")
                SettingsPicker("Skip Forward", selection: $settings.skipForwardSeconds,
                               options: AppSettings.skipIntervals.map { .init("\($0) seconds", value: $0) })
                    .settingsRow("Skip Forward")
            } header: {
                Text("Controls")
            } footer: {
                #if os(macOS)
                Text("For the skip buttons and the Left and Right Arrow keys.")
                #else
                Text("For the skip buttons, and the arrow keys on a keyboard.")
                #endif
            }

            Section {
                SettingsPicker("Skip Intro", selection: $settings.skipIntroMode,
                               options: SkipSegmentPlanner.Mode.allCases.map { .init($0.title, value: $0) })
                    .settingsRow("Skip Intro")
                SettingsPicker("Skip Recap", selection: $settings.skipRecapMode,
                               options: SkipSegmentPlanner.Mode.allCases.map { .init($0.title, value: $0) })
                    .settingsRow("Skip Recap")
                SettingsPicker("Skip Credits", selection: $settings.skipCreditsMode,
                               options: SkipSegmentPlanner.Mode.allCases.map { .init($0.title, value: $0) })
                    .settingsRow("Skip Credits")
                SettingsLink("Always Skipping", value: countLabel(settings.showSkipRules.always.count)) {
                    AlwaysSkipListPage()
                }
                .settingsRow("Always Skipping")
                SettingsLink("Shows with Skipping Off", value: countLabel(settings.skipDisabledShows.count)) {
                    SkipShowListPage(title: "Skipping Off", keys: $settings.skipDisabledShows,
                                     footer: "Skip Intro and Skip Credits don't appear for these. Swipe to remove one, or turn skipping back on from the player.")
                }
                .settingsRow("Shows with Skipping Off")
            } header: {
                Text("Skipping")
            } footer: {
                Text("Show Button offers Skip Intro and Next Episode; Automatic skips without asking. Automatic credits move on to the next episode only when the profile's Autoplay is on. Always Skipping lists the shows you chose \u{201C}Always for this show\u{201D} for; they skip without asking, whatever these say.")
            }

            Section {
                SettingsLink("Shows Ignoring Community Times", value: countLabel(settings.crowdSkipDisabledShows.count)) {
                    SkipShowListPage(title: "Ignoring Community Times", keys: $settings.crowdSkipDisabledShows,
                                     footer: "These shows only skip using the file's own chapters. Swipe to remove one and use community times again.")
                }
                .settingsRow("Community Intro Timestamps")
            } header: {
                Text("Community Intro Timestamps")
            } footer: {
                Text("Intro and credits times shared on TheIntroDB and IntroDB fill in when a file has no chapters. Mark a wrong time from the player.")
            }

            Section {
                SettingsPicker("Countdown", selection: $settings.upNextCountdown,
                               options: AppSettings.countdowns.map { .init("\($0) seconds", value: $0) })
                    .settingsRow("Countdown")
            } header: {
                Text("Episodes")
            } footer: {
                Text("How long Up Next counts down before the next episode. Whether it plays on is each profile's choice, in its Playback.")
            }

            Section {
                Toggle("Dialogue Boost", isOn: $settings.dialogueBoost)
                    .settingsRow("Dialogue Boost")
                Toggle("Night Mode", isOn: $settings.nightMode)
                    .settingsRow("Night Mode")
            } header: {
                Text("Audio")
            } footer: {
                Text("Dialogue Boost lifts speech; Night Mode evens out loud and quiet scenes. You can also change these for each video in the player's Tools. The audio language is each profile's, in Languages.")
            }

            Section {
                EqualizerEditor(settings: Binding(get: { app.equalizer }, set: { app.equalizer = $0 }), onCommit: {})
                    .padding(.vertical, 6)
                    .settingsRow("Equaliser")
            } header: {
                Text("Equaliser · \(app.currentProfile.name)")
            } footer: {
                Text("Plays with every video \(app.currentProfile.name) watches, and syncs. Change it while watching in Tools › Sound. HLS streams play without it.")
            }

            Section {
                Toggle("Always Open in Infuse", isOn: $settings.alwaysOpenInInfuse)
                    .settingsRow("Always Open in Infuse")
            } header: {
                Text("External Player")
            } footer: {
                Text(infuseFooter)
            }

            Section {
                Toggle("Preview Thumbnails While Scrubbing", isOn: $settings.scrubThumbnails)
                    .settingsRow("Preview Thumbnails While Scrubbing")
                Toggle("Handoff", isOn: $settings.handoff)
                    .settingsRow("Handoff")
            } header: {
                Text("Player")
            } footer: {
                Text("Handoff offers what's playing to your other Apple devices, to pick up where you are.")
            }

            Section {
                Toggle("Autoplay Previews", isOn: Bindable(app.features).autoplayPreviews)
                    .settingsRow("Autoplay Previews")
            } header: {
                Text("Previews")
            } footer: {
                Text("Home's hero plays a muted trailer. Previews never play on mobile data or in Low Data Mode.")
            }

            Section {
                Toggle("Scrobble What You Watch", isOn: Bindable(app.trakt).scrobbles)
                    .settingsRow("Scrobble What You Watch")
            } header: {
                Text("Trakt")
            } footer: {
                Text(app.trakt.isConnected
                     ? "Trakt shows what you're watching as it plays, and adds it to your history when you finish."
                     : "Connect Trakt in Account & Sync to scrobble.")
            }

            #if os(iOS)
            Section {
                SettingsLink("Streaming on Mobile Data", value: settings.mobileData.streaming.title) {
                    MobileDataSettingsPage()
                }
                .settingsRow("Stream over Cellular")
            } header: {
                Text("Network")
            }
            #endif
        }
    }

    private var engineFooter: String {
        switch app.settings.enginePreference {
        case .automatic:
            "AVPlayer plays MP4 and MOV with Picture in Picture and AirPlay. VLC plays MKV, AVI, WebM and the rest."
        case .preferVLC:
            "VLC plays everything it can. Picture in Picture and AirPlay aren't available with VLC."
        case .avPlayerOnly:
            "Only AVPlayer is used, so MKV, AVI and WebM won't play."
        }
    }

    private var infuseFooter: String {
        #if os(macOS)
        let reach = "Debrid links, direct links, torrents and downloads open in Infuse; Bluebox keeps serving torrents while Infuse plays them."
        #else
        let reach = "Debrid links, direct links, torrents and downloads open in Infuse. For torrents and downloads, Bluebox keeps running in the background to serve the video, until Infuse has left it alone for 15 minutes."
        #endif
        let missing = Infuse.isInstalled ? "" : " Infuse isn't installed on this device, so everything plays in Bluebox for now."
        return reach + " Bluebox doesn't see what you watch there, so progress, Up Next and Trakt don't update." + missing
    }

    private func speedLabel(_ s: Float) -> String { s == 1 ? "Normal" : String(format: "%g×", s) }

    private func countLabel(_ n: Int) -> String { n == 0 ? "None" : "\(n)" }
}

/// A list of shows (series or film keys) that opted out of something; swipe or
/// use Remove to take one off.
struct SkipShowListPage: View {
    @Environment(AppModel.self) private var app
    let title: String
    @Binding var keys: Set<String>
    let footer: String
    @State private var names: [String: String] = [:]

    var body: some View {
        let sorted = keys.sorted { (names[$0] ?? $0).localizedStandardCompare(names[$1] ?? $1) == .orderedAscending }
        List {
            Section {
                if sorted.isEmpty {
                    Text("None").foregroundStyle(Palette.textSecondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(sorted, id: \.self) { key in
                    HStack {
                        Text(names[key] ?? "…").foregroundStyle(Palette.textPrimary)
                        Spacer()
                        Button("Remove") { withAnimation(Motion.snappy(false)) { _ = keys.remove(key) } }
                            .buttonStyle(TextActionStyle())
                            .accessibilityLabel("Remove \(names[key] ?? "show")")
                    }
                    .frame(minHeight: SettingsMetrics.rowHeight - 8)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(SettingsMetrics.hairline)
                    .swipeActions { Button("Remove", role: .destructive) { keys.remove(key) } }
                }
            } footer: {
                Text(footer).font(.footnote).foregroundStyle(Palette.textSecondary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(title)
        .task(id: keys) {
            for key in keys where names[key] == nil {
                names[key] = await app.title(for: MediaKey(rawValue: key))?.name ?? key
            }
        }
    }
}

/// Settings › Picture: the brightness, contrast and saturation every video starts with.
struct PictureSettingsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        SettingsForm(.picture) {
            SettingsVideoPreview(picture: settings.pictureDefaults) { _ in EmptyView() }
        } content: {
            Section {
                SettingsSlider("Brightness", value: $settings.pictureDefaults.brightness, in: -0.5...0.5) {
                    String(format: "%+.0f", $0 * 100)
                }
                .settingsRow("Brightness")
                SettingsSlider("Contrast", value: $settings.pictureDefaults.contrast, in: 0.5...1.5) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                .settingsRow("Contrast")
                SettingsSlider("Saturation", value: $settings.pictureDefaults.saturation, in: 0...2) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                .settingsRow("Saturation")
                Button("Reset Picture") { settings.pictureDefaults = PictureDefaults() }
                    .disabled(settings.pictureDefaults.isDefault)
            } header: {
                Text("Every Video Starts With")
            } footer: {
                Text("Change them for one video from the player’s Tools. Not applied to HLS streams, which can’t be adjusted.")
            }
        }
    }
}
