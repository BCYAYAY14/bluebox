import Domain
import Foundation
import Persistence
import Subtitles

/// Settings that belong to a profile (Settings › the profile group): the
/// audio language, Autoplay Next Episode, and the subtitle style with its
/// languages. Each lives under its own key per profile, so `AppSettings` and
/// `AppModel.subtitleStyle` keep owning their values and only the key moves.
public enum ProfileSettingKey {
    /// String? ISO 639-1 audio language.
    public static func audioLanguage(_ profileID: String) -> String { "bluebox.profile.\(profileID).audioLanguage" }
    /// Bool.
    public static func autoplayNextEpisode(_ profileID: String) -> String { "bluebox.profile.\(profileID).autoplayNext" }
    /// `SubtitleStyle` JSON, including the preferred and second subtitle languages.
    public static func subtitleStyle(_ profileID: String) -> String { "bluebox.profile.\(profileID).subtitleStyle" }
    /// `ShowSkipRules` JSON: the shows this profile always skips the intro, recap or credits of.
    public static func showSkipRules(_ profileID: String) -> String { "bluebox.profile.\(profileID).showSkipRules" }
    /// Bool: set once the shared values were copied into every profile.
    public static let migrated = "bluebox.profileSettings.migrated"
}

/// Before profiles had their own settings, these were shared. The first launch
/// with per-profile settings copies each shared value into every profile that
/// exists, so nobody's subtitles or audio change. Profiles added later start
/// from the defaults. The shared keys are left in place (an older build still reads them).
public enum ProfileSettingsMigration {
    public static func runIfNeeded(prefs: PreferencesStore, profileIDs: [String]) {
        guard prefs.value(Bool.self, for: ProfileSettingKey.migrated) != true else { return }
        let audio = prefs.value(String.self, for: PreferenceKey.preferredAudioLanguage)
        let autoplay = prefs.value(Bool.self, for: PreferenceKey.autoplayNextEpisode)
        let style = prefs.value(SubtitleStyle.self, for: PreferenceKey.subtitleStyle)
        for id in Set(profileIDs + [Profile.defaultID]) {
            if let audio, prefs.value(String.self, for: ProfileSettingKey.audioLanguage(id)) == nil {
                prefs.set(audio, for: ProfileSettingKey.audioLanguage(id))
            }
            if let autoplay, prefs.value(Bool.self, for: ProfileSettingKey.autoplayNextEpisode(id)) == nil {
                prefs.set(autoplay, for: ProfileSettingKey.autoplayNextEpisode(id))
            }
            if let style, prefs.value(SubtitleStyle.self, for: ProfileSettingKey.subtitleStyle(id)) == nil {
                prefs.set(style, for: ProfileSettingKey.subtitleStyle(id))
            }
        }
        prefs.set(true, for: ProfileSettingKey.migrated)
    }

    /// Every profile ID stored in preferences, removed ones included (they
    /// can come back from another device).
    static func storedProfileIDs(_ prefs: PreferencesStore) -> [String] {
        ProfileStore(prefs: prefs).allIDs()
    }
}
