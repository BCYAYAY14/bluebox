import DesignSystem
import Domain
import SkipSegments
import SwiftUI

/// Settings › Playback: a live player frame, then the profile's own
/// autoplay switch, then (for everyone on this device) which player, where
/// playback starts, the transport controls, the Up Next countdown and sound.
/// Headers say whose settings each run of sections is (`SettingsScopeHeader`).
/// The audio language is the profile's too, on Language (`ProfileLanguagesPage`).
struct PlaybackSettingsPage: View {
    @Environment(AppModel.self) private var app
    @AppStorage(WatchParty.bubblesKey) private var partyBubbles = true
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
                Toggle("Autoplay Next Episode", isOn: $settings.autoplayNextEpisode)
                    .settingsRow("Autoplay Next Episode")
            } header: {
                SettingsScopeHeader(scope: .profile(app.currentProfile))
            } footer: {
                Text(settings.autoplayNextEpisode
                     ? "Up Next counts down, then plays the next episode."
                     : "Playback stops when an episode ends.")
            }

            Section {
                SettingsPicker("Player", selection: $settings.enginePreference,
                               options: AppSettings.EnginePreference.allCases.map { .init($0.title, value: $0) })
                    .settingsRow("Player")
                Toggle("Preview Thumbnails While Scrubbing", isOn: $settings.scrubThumbnails)
                    .settingsRow("Preview Thumbnails While Scrubbing")
                Toggle("Handoff", isOn: $settings.handoff)
                    .settingsRow("Handoff")
                Toggle("Show Party Messages Over the Video", isOn: $partyBubbles)
                    .settingsRow("Show Party Messages Over the Video")
            } header: {
                SettingsScopeHeader("Player", scope: .everyone)
            } footer: {
                Text(engineFooter)
                Text("Handoff offers what's playing to your other Apple devices, to pick up where you are. In a Watch Party, while the chat is closed, the last two messages show over the film for a few seconds.")
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
                #if os(iOS)
                Toggle("Swipe Gestures", isOn: $settings.swipeGestures)
                    .settingsRow("Swipe Gestures")
                #endif
            } header: {
                Text("Controls")
            } footer: {
                #if os(macOS)
                Text("For the skip buttons and the Left and Right Arrow keys.")
                #else
                Text("Skip times are for the skip buttons, and the arrow keys on a keyboard. Swipe Gestures: swipe across the picture to seek, or up and down on the left for brightness and on the right for volume.")
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
                SettingsLink("Shows Ignoring Community Times", value: countLabel(settings.crowdSkipDisabledShows.count)) {
                    SkipShowListPage(title: "Ignoring Community Times", keys: $settings.crowdSkipDisabledShows,
                                     footer: "These shows only skip using the file's own chapters. Swipe to remove one and use community times again.")
                }
                .settingsRow("Community Intro Timestamps")
            } header: {
                Text("Skipping")
            } footer: {
                Text("Show Button offers Skip Intro and Next Episode; Automatic skips without asking. Automatic credits move on to the next episode only when the profile's Autoplay is on. Always Skipping lists the shows you chose \u{201C}Always for this show\u{201D} for; they skip without asking, whatever these say.")
                Text("Intro and credits times shared on TheIntroDB and IntroDB fill in when a file has no chapters. Mark a wrong time from the player.")
            }

            Section {
                SettingsPicker("Countdown", selection: $settings.upNextCountdown,
                               options: AppSettings.countdowns.map { .init("\($0) seconds", value: $0) })
                    .settingsRow("Countdown")
            } header: {
                Text("Episodes")
            } footer: {
                Text("How long Up Next counts down before the next episode. Whether it plays on is each profile's own choice, at the top of this page.")
            }

            Section {
                Toggle("Dialogue Boost", isOn: $settings.dialogueBoost)
                    .settingsRow("Dialogue Boost")
                Toggle("Night Mode", isOn: $settings.nightMode)
                    .settingsRow("Night Mode")
            } header: {
                Text("Audio")
            } footer: {
                Text("Dialogue Boost lifts speech; Night Mode evens out loud and quiet scenes. You can also change these for each video in the player's Tools. The audio language is each profile's, on the Language page.")
            }

            Section {
                EqualizerEditor(settings: Binding(get: { app.equalizer }, set: { app.equalizer = $0 }), onCommit: {})
                    .padding(.vertical, 6)
                    .settingsRow("Equaliser")
            } header: {
                SettingsScopeHeader("Equaliser", scope: .profile(app.currentProfile))
            } footer: {
                Text("Plays with every video this profile watches, and syncs. Change it while watching in Tools › Sound. HLS streams play without it.")
            }

            Section {
                SettingsPicker("Open Videos In", selection: $settings.openVideosIn, options: openVideosInOptions)
                    .settingsRow("Open Videos In")
            } header: {
                SettingsScopeHeader("External Player", scope: .everyone)
            } footer: {
                Text(externalPlayerFooter)
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
                SettingsPageLink("Streaming on Mobile Data", page: .mobileData, value: settings.mobileData.streaming.title)
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

    /// Bluebox, then the players installed here (and the one chosen, even if it's gone).
    private var openVideosInOptions: [BlueboxPickerOption<ExternalPlayer?>] {
        var players = ExternalPlayer.installed
        if let chosen = app.settings.openVideosIn, !players.contains(chosen) { players.append(chosen) }
        return [.init("Bluebox", value: nil)] + players.map { .init($0.name, value: $0) }
    }

    private var externalPlayerFooter: String {
        guard let player = app.settings.openVideosIn else {
            return ExternalPlayer.installed.isEmpty
                ? "Install Infuse or VLC to open videos in another player. Bluebox finds the ones on this device."
                : "Open In… on a title, a release or in the player hands one video to another app."
        }
        let name = player == .shareSheet ? "the app you pick" : player.name
        #if os(macOS)
        let reach = "Debrid links, direct links, torrents and downloads open in \(name); Bluebox keeps serving torrents while \(name) plays them."
        #else
        let reach = "Debrid links, direct links, torrents and downloads open in \(name). For torrents and downloads, Bluebox keeps running in the background to serve the video, until \(name) has left it alone for 15 minutes."
        #endif
        let missing = player.isInstalled ? "" : " \(player.name) isn't installed on this device, so everything plays in Bluebox for now."
        return reach + " Progress isn't tracked there: Bluebox doesn't see what you watch, so Continue Watching, Up Next and Trakt don't update." + missing
    }

    private func speedLabel(_ s: Float) -> String { s == 1 ? "Normal" : String(format: "%g×", s) }

    private func countLabel(_ n: Int) -> String { n == 0 ? "None" : "\(n)" }
}

/// A list of shows (series or film keys) that opted out of something; swipe or
/// use Remove to take one off.
struct SkipShowListPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        Button("Remove") { withAnimation(Motion.snappy(reduceMotion)) { _ = keys.remove(key) } }
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
