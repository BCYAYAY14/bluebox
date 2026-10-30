import Addons
import Foundation
@testable import Features
import Persistence
import Testing
import TestingSupport

/// Add-on links live in the Keychain, not preferences (security review BB-06).
@MainActor
@Suite struct AddonLinkKeychainTests {
    let full = "https://comet.example/eyJkZWJyaWRBcGlLZXkiOiJzZWNyZXQifQ"

    @Test func linksSavedByEarlierVersionsMoveToTheKeychain() throws {
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "addonlinks.\(UUID().uuidString)")!)
        let secrets = MemorySecretStore()
        var old = AddonSettings()
        old.addons.append(InstalledAddon(id: "custom.1", kind: .custom(base: full), name: "Comet"))
        prefs.set(old, for: PreferenceKey.addons)

        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: secrets, prefs: prefs,
                           http: AccountStubServer(), forceSample: true)
        #expect(try secrets.read(SecretAccount.addonLink("custom.1")) == full)
        #expect(app.addonSettings.customLinks["custom.1"] == full)
        #expect(app.addonSettings.resolvedAddons(debridKey: "").contains { $0.base.absoluteString == full })
        let saved = String(decoding: prefs.rawData(for: PreferenceKey.addons) ?? Data(), as: UTF8.self)
        #expect(!saved.contains("eyJkZWJyaWRBcGlLZXkiOiJzZWNyZXQifQ"))
        #expect(saved.contains("comet.example"))

        app.removeAddon("custom.1")
        #expect(try secrets.read(SecretAccount.addonLink("custom.1")) == nil)
    }
}
