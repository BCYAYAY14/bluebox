import DesignSystem
import Domain
import Persistence
import Subtitles
import SwiftUI

// MARK: - Values for any profile

/// One profile's own settings, read and written for any profile: the current
/// one through the live objects (so the player follows at once), others
/// straight to their keys.
struct ProfileSettingsValues: Equatable {
    var audioLanguage: String?
    var autoplayNextEpisode: Bool
    var subtitleStyle: SubtitleStyle
}

extension AppModel {
    func profileSettings(_ id: String) -> ProfileSettingsValues {
        if id == currentProfileID {
            return ProfileSettingsValues(audioLanguage: settings.preferredAudioLanguage,
                                         autoplayNextEpisode: settings.autoplayNextEpisode, subtitleStyle: subtitleStyle)
        }
        return ProfileSettingsValues(
            audioLanguage: prefs.value(String.self, for: ProfileSettingKey.audioLanguage(id)),
            autoplayNextEpisode: prefs.value(Bool.self, for: ProfileSettingKey.autoplayNextEpisode(id)) ?? true,
            subtitleStyle: prefs.value(SubtitleStyle.self, for: ProfileSettingKey.subtitleStyle(id)) ?? SubtitleStyle())
    }

    func setProfileSettings(_ v: ProfileSettingsValues, for id: String) {
        if id == currentProfileID {
            if settings.preferredAudioLanguage != v.audioLanguage { settings.preferredAudioLanguage = v.audioLanguage }
            if settings.autoplayNextEpisode != v.autoplayNextEpisode { settings.autoplayNextEpisode = v.autoplayNextEpisode }
            if subtitleStyle != v.subtitleStyle { subtitleStyle = v.subtitleStyle }
            return
        }
        prefs.set(v.audioLanguage, for: ProfileSettingKey.audioLanguage(id))
        prefs.set(v.autoplayNextEpisode, for: ProfileSettingKey.autoplayNextEpisode(id))
        prefs.set(v.subtitleStyle, for: ProfileSettingKey.subtitleStyle(id))
    }

    /// "Español, autoplay on" for the editor's Languages and Playback row.
    func profileSettingsSummary(_ id: String) -> String {
        let v = profileSettings(id)
        let language = v.audioLanguage.map(SettingsLanguages.name) ?? "Original audio"
        return "\(language), autoplay \(v.autoplayNextEpisode ? "on" : "off")"
    }
}

/// "Only for Brian", at the top of a profile page: whose settings these are.
struct ProfileOwnerCaption: View {
    let profile: Profile
    var note: String?

    var body: some View {
        HStack(spacing: Spacing.s) {
            ProfileBadge(symbol: profile.symbol, color: profile.color, size: 18)
            Text(note ?? "Only for \(profile.name)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profileOwnerCaption")
    }
}

// MARK: - Languages

/// Settings › (profile) › Languages: the audio track and subtitle languages
/// this profile prefers. Also opens from the profile editor for any profile.
struct ProfileLanguagesPage: View {
    @Environment(AppModel.self) private var app
    /// nil: the current profile.
    var profileID: String?
    @State private var values: ProfileSettingsValues?

    private var id: String { profileID ?? app.currentProfileID }
    private var profile: Profile { app.profiles.first { $0.id == id } ?? app.currentProfile }

    var body: some View {
        SettingsForm(.languages) {
            Section {
                ProfileOwnerCaption(profile: profile)
            }
            Section {
                SettingsPicker("Audio Language", selection: binding(\.audioLanguage),
                               groups: [[.init("File's Default", value: nil)], SettingsLanguages.options])
                    .settingsRow("Audio Language")
            } header: {
                Text("Audio")
            } footer: {
                Text("Picked when a video has several audio tracks.")
            }
            Section {
                SettingsPicker("Subtitles", selection: binding(\.subtitleStyle.preferredLanguage),
                               groups: [[.init("Off", value: nil)], SettingsLanguages.options])
                    .settingsRow("Preferred Language")
                SettingsPicker("Second Language", selection: binding(\.subtitleStyle.secondaryLanguage),
                               groups: [[.init("Off", value: nil)], SettingsLanguages.options])
                    .disabled(current.subtitleStyle.preferredLanguage == nil)
                    .settingsRow("Second Language")
            } header: {
                Text("Subtitles")
            } footer: {
                Text("Turns subtitles on when a video has your language. A second language shows underneath, for learning.")
            }
            if profileID != nil && profileID != app.currentProfileID {
                Section {
                    Toggle("Autoplay Next Episode", isOn: binding(\.autoplayNextEpisode))
                } header: {
                    Text("Playback")
                }
            }
        }
        .onAppear { values = app.profileSettings(id) }
    }

    private var current: ProfileSettingsValues { values ?? app.profileSettings(id) }

    private func binding<T>(_ path: WritableKeyPath<ProfileSettingsValues, T>) -> Binding<T> {
        Binding {
            // The current profile reads live, so the player and this page agree.
            (id == app.currentProfileID ? app.profileSettings(id) : current)[keyPath: path]
        } set: { new in
            var v = id == app.currentProfileID ? app.profileSettings(id) : current
            v[keyPath: path] = new
            values = v
            app.setProfileSettings(v, for: id)
        }
    }
}

// MARK: - Playback

/// Settings › (profile) › Playback: what happens when an episode ends, for this profile.
struct ProfilePlaybackPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        SettingsForm(.myPlayback) {
            Section {
                ProfileOwnerCaption(profile: app.currentProfile)
            }
            Section {
                Toggle("Autoplay Next Episode", isOn: $settings.autoplayNextEpisode)
                    .settingsRow("Autoplay Next Episode")
            } header: {
                Text("Episodes")
            } footer: {
                Text(settings.autoplayNextEpisode
                     ? "Up Next counts down, then plays the next episode. The countdown's length is in Player, for everyone."
                     : "Playback stops when an episode ends.")
            }
            Section {
                SettingsLink("Player", value: SettingsPage.everyoneTitle) { PlaybackSettingsPage() }
            } footer: {
                Text("The player, skipping, speed and sound are the same for everyone.")
            }
        }
    }
}

// Hidden Titles: `HiddenTitlesSettingsPage` (Home recommendations), already kept
// per profile in Persistence/HiddenTitlesStore.swift. SettingsPage.hiddenTitles opens it.
