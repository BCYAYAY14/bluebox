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

    var body: some View {
        @Bindable var switches = app.featureSwitches
        SettingsForm(.privacy) {
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
                Text(HomeRowTitles.name(app.currentProfile) == "You" ? "This Profile" : app.currentProfile.name)
            } footer: {
                Text("These follow the profile to your other devices.")
            }

            Section {
                FeatureToggle("Release Alerts", isOn: releaseAlerts,
                              detail: "Every 12 hours at most, asks your add-ons about films on My List that had nothing to play, and tells you when one appears, or when a release is ready on your debrid service. Asks for permission to notify you when you turn it on.")
                    .settingsRow("Release Alerts")
                FeatureToggle("Smart Downloads Can Delete Watched Downloads", isOn: download(\.allowsDeleting),
                              detail: "To make room for the next episodes, Smart Downloads may delete episodes you've finished. It never deletes anything you haven't watched.")
                    .settingsRow("Smart Downloads Can Delete Watched Downloads")
                FeatureToggle("Follow Watching on Other Devices", isOn: download(\.followOtherDevices),
                              detail: "What you watch on your other devices, or on Trakt, counts here too: Smart Downloads tops up and cleans up after it.")
                    .settingsRow("Follow Watching on Other Devices")
            } header: {
                Text("Your Account")
            } footer: {
                Text("The same on every device signed in to your account.")
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
                Text("\(app.currentProfile.name)\u{2019}s hours, top shows and genres, and the Year in Bluebox.")
            }
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
                Text(title).foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .accessibilityHint(detail)
    }
}

extension PrivacySettingsPage {
    /// These two live in `DownloadSettings` (Smart Downloads reads them, and
    /// Settings › Downloads shows them too), so both pages flip the same value.
    fileprivate func download(_ keyPath: WritableKeyPath<DownloadSettings, Bool>) -> Binding<Bool> {
        Binding { app.downloadSettings[keyPath: keyPath] } set: { value in
            var s = app.downloadSettings
            s[keyPath: keyPath] = value
            app.setDownloadSettings(s)
        }
    }
}
