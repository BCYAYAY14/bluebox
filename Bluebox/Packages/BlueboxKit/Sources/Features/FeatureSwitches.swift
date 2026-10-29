import Domain
import Foundation
import Observation
import Persistence

/// Settings › Privacy & Features (decision 18): one switch for every feature
/// that could feel invasive, each saying what it does.
///
/// Three kinds of scope, because "whose" differs:
/// - The current profile's (statistics, spoiler guard, taste-based rows):
///   they're about one person's viewing, so they follow the profile and sync
///   with it (`bluebox.profile.<id>.<name>`).
/// - The account's (release alerts, Smart Downloads deleting, following other
///   devices): the same on every device, synced.
/// - This device's (Live Activity, remote control either way): what one
///   device lets others do to it shouldn't be decided on another device, so
///   they never leave it.
///
/// Each switch has its own key, so adding one never disturbs another.
@Observable
@MainActor
public final class FeatureSwitches {
    // MARK: The current profile's

    /// My Bluebox statistics. Off: nothing is computed and the page is hidden.
    public var statistics: Bool { didSet { saveProfile(statistics, Key.statistics) } }
    /// Blur stills and hide synopses of episodes not watched yet.
    public var spoilerGuard: Bool { didSet { saveProfile(spoilerGuard, Key.spoilerGuard) } }
    /// Top Picks, Because You Watched and genre rows ordered by taste on Home.
    public var tasteRows: Bool { didSet { saveProfile(tasteRows, Key.tasteRows) } }

    // MARK: The account's

    /// Notify when a film on My List gets streams or a debrid-cached release.
    public var releaseAlerts: Bool { didSet { save(releaseAlerts, Key.releaseAlerts) } }
    // Smart Downloads deleting and following other devices are in
    // `DownloadSettings` (allowsDeleting, followOtherDevices), which syncs.

    // MARK: This device's

    /// Download progress on the Lock Screen and in the Dynamic Island (iPhone).
    public var liveActivity: Bool { didSet { save(liveActivity, Key.liveActivity) } }
    /// Other devices signed in to the account may control this device's player.
    public var allowRemoteControl: Bool { didSet { save(allowRemoteControl, Key.allowRemoteControl) } }
    /// This device offers to control another device's player.
    public var useAsRemote: Bool { didSet { save(useAsRemote, Key.useAsRemote) } }

    /// Whose per-profile switches these are.
    @ObservationIgnored public private(set) var profileID: String
    @ObservationIgnored private let prefs: PreferencesStore
    /// Set while reading stored values back in: a missing key stays missing
    /// rather than being written as a default (which settings sync would
    /// stamp as a fresh change and push over another device's choice).
    @ObservationIgnored private var loading = false

    /// What a fresh install starts with: on where it's harmless and local,
    /// off where it reaches out (notifications) or lets another device in.
    public enum Defaults {
        public static let statistics = true
        public static let releaseAlerts = false
        public static let spoilerGuard = false
        public static let tasteRows = true
        public static let liveActivity = true
        public static let allowRemoteControl = false
        public static let useAsRemote = true
    }

    /// UserDefaults keys. Account and device switches are whole keys; profile
    /// switches are suffixes after `bluebox.profile.<id>`.
    public enum Key {
        public static let statistics = "statistics"
        public static let spoilerGuard = "spoilerGuard"
        public static let tasteRows = "tasteRows"
        public static let releaseAlerts = "bluebox.features.releaseAlerts"
        public static let liveActivity = "bluebox.features.liveActivity"
        public static let allowRemoteControl = "bluebox.features.allowRemoteControl"
        public static let useAsRemote = "bluebox.features.useAsRemote"

        public static func profile(_ profileID: String, _ name: String) -> String { "bluebox.profile.\(profileID).\(name)" }
    }

    /// Account switches that sync (settings sync's preference keys).
    static let syncedKeys: Set<String> = [Key.releaseAlerts]
    /// Profile switches that sync (settings sync's profile suffixes).
    static let syncedProfileSuffixes = [Key.statistics, Key.spoilerGuard, Key.tasteRows].map { ".\($0)" }

    public init(prefs: PreferencesStore, profileID: String = Profile.defaultID) {
        self.prefs = prefs
        self.profileID = profileID
        statistics = prefs.value(Bool.self, for: Key.profile(profileID, Key.statistics)) ?? Defaults.statistics
        spoilerGuard = prefs.value(Bool.self, for: Key.profile(profileID, Key.spoilerGuard)) ?? Defaults.spoilerGuard
        tasteRows = prefs.value(Bool.self, for: Key.profile(profileID, Key.tasteRows)) ?? Defaults.tasteRows
        releaseAlerts = prefs.value(Bool.self, for: Key.releaseAlerts) ?? Defaults.releaseAlerts
        liveActivity = prefs.value(Bool.self, for: Key.liveActivity) ?? Defaults.liveActivity
        allowRemoteControl = prefs.value(Bool.self, for: Key.allowRemoteControl) ?? Defaults.allowRemoteControl
        useAsRemote = prefs.value(Bool.self, for: Key.useAsRemote) ?? Defaults.useAsRemote
    }

    /// Switches the per-profile values to another profile's.
    func loadProfile(_ id: String) {
        profileID = id
        reload(\.statistics, Key.profile(id, Key.statistics), Defaults.statistics)
        reload(\.spoilerGuard, Key.profile(id, Key.spoilerGuard), Defaults.spoilerGuard)
        reload(\.tasteRows, Key.profile(id, Key.tasteRows), Defaults.tasteRows)
    }

    /// Re-reads every stored switch: another device changed some (settings sync).
    func reloadFromPreferences() {
        reload(\.releaseAlerts, Key.releaseAlerts, Defaults.releaseAlerts)
        reload(\.liveActivity, Key.liveActivity, Defaults.liveActivity)
        reload(\.allowRemoteControl, Key.allowRemoteControl, Defaults.allowRemoteControl)
        reload(\.useAsRemote, Key.useAsRemote, Defaults.useAsRemote)
        loadProfile(profileID)
    }

    /// Every switch back to its default (this profile's, the account's and this device's).
    public func resetToDefaults() {
        statistics = Defaults.statistics
        spoilerGuard = Defaults.spoilerGuard
        tasteRows = Defaults.tasteRows
        releaseAlerts = Defaults.releaseAlerts
        liveActivity = Defaults.liveActivity
        allowRemoteControl = Defaults.allowRemoteControl
        useAsRemote = Defaults.useAsRemote
    }

    /// Assigns only when the value differs, so observers don't redraw and
    /// `didSet` doesn't write the same value back.
    private func reload(_ path: ReferenceWritableKeyPath<FeatureSwitches, Bool>, _ key: String, _ fallback: Bool) {
        let v = prefs.value(Bool.self, for: key) ?? fallback
        guard self[keyPath: path] != v else { return }
        loading = true
        defer { loading = false }
        self[keyPath: path] = v
    }

    private func save(_ value: Bool, _ key: String) {
        if !loading { prefs.set(value, for: key) }
    }
    private func saveProfile(_ value: Bool, _ name: String) {
        if !loading { prefs.set(value, for: Key.profile(profileID, name)) }
    }
}
