import Addons
import Domain
@testable import Features
import Foundation
import Persistence
import Testing

@MainActor
@Suite struct SettingsTests {
    private func prefs() -> PreferencesStore {
        PreferencesStore(defaults: UserDefaults(suiteName: "settings.\(UUID().uuidString)")!)
    }

    @Test func newSettingsPersistUnderTheirOwnKeys() {
        let p = prefs()
        let s = AppSettings(prefs: p)
        #expect(s.skipBackSeconds == 10 && s.autoplayNextEpisode && s.enginePreference == .automatic)
        s.skipBackSeconds = 30
        s.enginePreference = .preferVLC
        s.preferredAudioLanguage = "ja"
        s.allowCellularStreaming = false
        let reloaded = AppSettings(prefs: p)
        #expect(reloaded.skipBackSeconds == 30)
        #expect(reloaded.enginePreference == .preferVLC)
        #expect(reloaded.preferredAudioLanguage == "ja")
        #expect(reloaded.allowCellularStreaming == false)
        #expect(p.value(Int.self, for: PreferenceKey.skipBackSeconds) == 30)
    }

    @Test func resetAllSettingsKeepsSecretsAndSources() throws {
        let p = prefs()
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(), prefs: p, forceSample: true)
        app.defaultSpeed = 1.5
        app.settings.upNextCountdown = 30
        var addons = app.addonSettings
        addons.maxPeers = 150
        app.setAddonSettings(addons)
        app.setDebridKey("secret")
        app.resetAllSettings()
        #expect(app.defaultSpeed == 1)
        #expect(app.settings.upNextCountdown == 10)
        #expect(app.addonSettings == AddonSettings())
        #expect(app.debridKey == "secret")
    }

    @Test func languageCodesMatchAcrossForms() {
        #expect(AppModel.sameLanguage("eng", "en"))
        #expect(AppModel.sameLanguage("en-US", "en"))
        #expect(!AppModel.sameLanguage("spa", "en"))
    }

    @Test func searchFindsByTitleAndKeyword() {
        #expect(SettingsSearchIndex.search("skip").first?.page == .playback)
        #expect(SettingsSearchIndex.search("real-debrid").first?.title == "Debrid Service")
        #expect(SettingsSearchIndex.search("clear stream").first?.title == "Clear Stream Cache")
        #expect(SettingsSearchIndex.search("   ").isEmpty)
    }

    @Test func addonOrderIsYourOrder() {
        var s = AddonSettings()
        s.addons = [.preset(.stremthru), .preset(.torrentio), .preset(.stremthru)]
        let resolved = s.resolvedAddons(debridKey: "")
        #expect(resolved.count == 2)
        #expect(resolved.first?.base.absoluteString.contains("stremthru") == true)
    }

    @Test func resetKeepsAddonsAddedByLink() throws {
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(), prefs: prefs(), forceSample: true)
        var addons = app.addonSettings
        addons.addons.append(InstalledAddon(id: "custom.x", kind: .custom(base: "https://addon.example/x"), name: "Mine"))
        addons.maxPeers = 150
        app.setAddonSettings(addons)
        app.resetAllSettings()
        #expect(app.addonSettings.maxPeers == 80)
        #expect(app.addonSettings.addons.map(\.id) == AddonSettings().addons.map(\.id) + ["custom.x"])
    }
}
