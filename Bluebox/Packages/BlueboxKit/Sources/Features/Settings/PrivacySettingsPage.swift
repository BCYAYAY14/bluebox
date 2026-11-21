import DesignSystem
import Downloads
import SwiftUI
#if os(iOS)
import UIKit
#endif

extension SettingsPage {
    /// "This Mac" (iPhone, iPad): the section for switches that stay on the device.
    @MainActor static var thisDeviceTitle: String {
        #if os(macOS)
        "This Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
        #endif
    }
}

/// Settings › Privacy & Features (decision 18): every feature that could feel
/// invasive, with a switch and a plain account of what it does. Grouped by
/// whose choice it is: the profile's, the account's, or this device's.
struct PrivacySettingsPage: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SearchHistoryPreference.key) private var savesSearchHistory = true
    @State private var confirmClearSearches = false

    var body: some View {
        @Bindable var switches = app.featureSwitches
        SettingsForm(.privacy) {
            // The profile's own switches have their own page in the profile's group.
            Section {
                SettingsPageLink("Statistics, Spoiler Guard and Taste Rows", page: .profileFeatures)
            } header: {
                SettingsScopeHeader(scope: .profile(app.currentProfile))
            } footer: {
                Text("Each profile chooses these for itself, on its Features page.")
            }

            AISettingsSection()

            Section {
                FeatureToggle("Release Alerts", isOn: releaseAlerts,
                              detail: "Every 12 hours at most, asks your add-ons about films on My List that had nothing to play, and tells you when one appears, or when a release is ready on your debrid service. Asks for permission to notify you when you turn it on.")
                    .settingsRow("Release Alerts")
                // What Smart Downloads may do on its own is on Downloads, beside Smart Downloads.
                SettingsPageLink("What Smart Downloads Does on Its Own", page: .downloads)
                    .settingsRow("What Smart Downloads Does on Its Own")
            } header: {
                Text("Your Account")
            } footer: {
                Text("The same on every device signed in to your account.")
            }

            Section {
                FeatureToggle("Save Search History", isOn: $savesSearchHistory,
                              detail: "Search lists what you searched for recently, with the top result's picture. Off: nothing new is remembered.")
                    .settingsRow("Save Search History")
                Button("Clear Search History", role: .destructive) { confirmClearSearches = true }
                    .settingsRow("Clear Search History")
                    .confirmationDialog("Clear search history for every profile on this device?",
                                        isPresented: $confirmClearSearches, titleVisibility: .visible) {
                        Button("Clear Search History", role: .destructive) {
                            app.clearSearchHistory()
                            app.showToast(AppToast("Search History Cleared", style: .success))
                        }
                    }
            } header: {
                Text("Search")
            } footer: {
                Text("Recent searches stay on this device, one list per profile.")
            }

            Section {
                #if os(iOS)
                FeatureToggle("Downloads Live Activity", isOn: $switches.liveActivity,
                              detail: "Shows download progress on the Lock Screen and in the Dynamic Island.")
                    .settingsRow("Downloads Live Activity")
                #endif
                FeatureToggle("Allow Remote Control of This Device", isOn: $switches.allowRemoteControl,
                              detail: "Your other devices signed in to your account can play, pause and seek what's playing here.")
                    .settingsRow("Allow Remote Control of This Device")
                FeatureToggle("Use This Device as a Remote", isOn: $switches.useAsRemote,
                              detail: "Offers to control what's playing on your other devices, over your own Supabase project.")
                    .settingsRow("Use This Device as a Remote")
            } header: {
                Text(SettingsPage.thisDeviceTitle)
            } footer: {
                Text("These stay on this device: another device can't change what this one allows.")
            }
        }
    }

    /// Turning alerts on asks for notification permission there and then.
    private var releaseAlerts: Binding<Bool> {
        Binding { app.featureSwitches.releaseAlerts } set: { on in
            app.featureSwitches.releaseAlerts = on
            if on { Task { await app.releaseAlertsTurnedOn() } }
        }
    }
}

/// Settings › (profile) › Features: the switches that are each profile's own
/// choice, and follow it to your other devices. They were on Privacy &
/// Features, which is otherwise everyone's on the device.
struct ProfileFeaturesSettingsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var switches = app.featureSwitches
        SettingsForm(.profileFeatures) {
            Section {
                FeatureToggle("Statistics", isOn: $switches.statistics,
                              detail: "Hours watched, top shows and genres, and your Year in Bluebox, worked out on this device from your watch progress. Off: nothing is worked out and My Bluebox is hidden.")
                    .settingsRow("Statistics")
                if switches.statistics {
                    SettingsLink("My Bluebox") { StatisticsPage() }
                        .settingsRow("My Bluebox")
                }
                FeatureToggle("Spoiler Guard", isOn: $switches.spoilerGuard,
                              detail: "Blurs the pictures and hides the synopses of episodes you haven't watched yet. Press Show on one to see it.")
                    .settingsRow("Spoiler Guard")
                FeatureToggle("Rows Based on Your Taste", isOn: $switches.tasteRows,
                              detail: "Top Picks and Because You Watched on Home, and genre rows in the order you like them, from what this profile watches and rates. Worked out on this device. Off: Home shows the same rows for everyone.")
                    .settingsRow("Rows Based on Your Taste")
            } header: {
                SettingsScopeHeader(scope: .profile(app.currentProfile))
            } footer: {
                Text("These follow the profile to your other devices.")
            }
        }
    }
}

/// Settings › Profiles: the way into My Bluebox for the profile that's
/// watching. Gone while Statistics is off.
struct StatisticsLinkSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.featureSwitches.statistics {
            Section {
                SettingsLink("My Bluebox", value: "Statistics") { StatisticsPage() }
                    .settingsRow("My Bluebox")
            } footer: {
                Text("Hours watched, top shows and genres, and the Year in Bluebox, for the profile that's watching.")
            }
        }
    }
}

/// AI: everything in Bluebox that uses it (only subtitles), all on this
/// device, with the sheet from first launch, the switches and Whisper's
/// download. The switches follow the account, like the rest of Settings.
private struct AISettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var showsSheet = false
    @State private var whisperBytes: Int64 = 0
    private var whisper: WhisperModel { .shared }

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Button { showsSheet = true } label: {
                HStack {
                    Text("What Bluebox's AI Does").foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .settingsRow("What Bluebox's AI Does")
            FeatureToggle("Offer to Generate Subtitles", isOn: $settings.offersGeneratedSubtitles,
                          detail: "When a long video has no subtitles in your language, a notice offers to write them from its sound. Generate Subtitles is always in the player's Subtitles card.")
                .settingsRow("Offer to Generate Subtitles")
            FeatureToggle("Allow Whisper", isOn: $settings.allowsWhisper,
                          detail: "Whisper, an open speech model, listens to languages Apple's speech recognition doesn't know. Downloaded the first time one needs it, with its size shown first. Off: only Apple's languages can be generated.")
                .settingsRow("Allow Whisper")
            LabeledContent("Whisper Model") {
                HStack(spacing: Spacing.s) {
                    switch whisper.state {
                    case .absent: Text("Not downloaded")
                    case .downloading(let fraction): Text("Downloading… \(Int(fraction * 100)) %")
                    case .ready:
                        Text(Formatters.bytes(whisperBytes))
                        Button("Delete", role: .destructive) { whisper.delete(); whisperBytes = 0 }
                    }
                }
            }
            .settingsRow("Whisper Model")
            FeatureToggle("Sync to the Audio", isOn: $settings.offersAudioSync,
                          detail: "On the player's Timing page: listens to a few minutes of speech and lines the subtitles up with it.")
                .settingsRow("Sync to the Audio")
        } header: {
            Text("AI")
        } footer: {
            Text("Bluebox uses AI only for subtitles, and it runs on this device: no audio, words or subtitles leave it. These switches are the same on every device signed in to your account.")
        }
        .task(id: whisper.state) { whisperBytes = whisper.bytesOnDisk }
        .sheet(isPresented: $showsSheet) {
            AITransparencySheet(showing: .everything) { showsSheet = false }
                .environment(app)
        }
    }
}

/// A switch with its name and, under it, what it does.
private struct FeatureToggle: View {
    let title: String
    @Binding var isOn: Bool
    let detail: String

    init(_ title: String, isOn: Binding<Bool>, detail: String) {
        self.title = title; self._isOn = isOn; self.detail = detail
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ui: title).foregroundStyle(Palette.textPrimary)
                Text(ui: detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .accessibilityHint(detail)
    }
}
