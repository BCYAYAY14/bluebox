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

    /// "Español, autoplay on" for the editor's Languages and Playback row. Each
    /// wording is a whole phrase so it translates as one; "File's Default" is
    /// what the Audio Language menu calls no choice.
    func profileSettingsSummary(_ id: String) -> String {
        let v = profileSettings(id)
        switch (v.audioLanguage.map(SettingsLanguages.name), v.autoplayNextEpisode) {
        case (let language?, true): return String(localized: "\(language), autoplay on")
        case (let language?, false): return String(localized: "\(language), autoplay off")
        case (nil, true): return String(localized: "File's Default, autoplay on")
        case (nil, false): return String(localized: "File's Default, autoplay off")
        }
    }
}

// MARK: - Languages

/// Settings › Language: the app's own language (this device), then the
/// audio track and subtitle languages this profile prefers. Also opens from
/// the profile editor for any profile, titled like the editor's row
/// ("Languages and Playback"): without the app's language, with its autoplay.
struct ProfileLanguagesPage: View {
    @Environment(AppModel.self) private var app
    /// nil: the current profile.
    var profileID: String?
    @State private var values: ProfileSettingsValues?

    /// The profile editor's row that opens this page for one profile.
    static let editorTitle = "Languages and Playback"

    private var id: String { profileID ?? app.currentProfileID }
    private var profile: Profile { app.profiles.first { $0.id == id } ?? app.currentProfile }

    var body: some View {
        Group {
            if profileID == nil {
                SettingsForm(.languages) {
                    AppLanguageSection()
                    profileSections
                }
            } else {
                // Not the Language page: no summary about the app's own language.
                SettingsForm(title: Self.editorTitle) {
                    profileSections
                    Section {
                        Toggle("Autoplay Next Episode", isOn: binding(\.autoplayNextEpisode))
                    } header: {
                        Text("Playback")
                    } footer: {
                        Text("Up Next counts down, then plays the next episode. Off: playback stops when an episode ends.")
                    }
                }
            }
        }
        .onAppear { values = app.profileSettings(id) }
    }

    @ViewBuilder private var profileSections: some View {
        Section {
            SettingsPicker("Audio Language", selection: binding(\.audioLanguage),
                           groups: [[.init("File's Default", value: nil)], SettingsLanguages.options])
                .settingsRow("Audio Language")
        } header: {
            SettingsScopeHeader("Audio", scope: .profile(profile))
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

// Hidden Titles: `HiddenTitlesSettingsPage` (Home recommendations), already kept
// per profile in Persistence/HiddenTitlesStore.swift. SettingsPage.hiddenTitles opens it.
