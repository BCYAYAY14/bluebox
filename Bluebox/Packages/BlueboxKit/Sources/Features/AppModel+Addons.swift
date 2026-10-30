//
//  AppModel+Addons.swift
//  Bluebox
//
//  Written for Bluebox from public documentation (the Stremio add-on SDK's
//  protocol docs). Your add-on list (add by link, presets, order, on and
//  off), their health, and what ranking needs from the rest of the app: the
//  device's decoders and screen, the audio language, and runtimes.
//

import Addons
import AVFoundation
import Domain
import Foundation
import Observation
import Persistence

extension AppModel {
    /// Gives the add-on source what ranking needs, and keeps it current.
    /// Called once at start.
    func configureAddonRanking() async {
        await addons.setDevice(DeviceProfile.current())
        await addons.setAudioLanguage(settings.preferredAudioLanguage)
        await addons.setRuntimeProvider { [weak self] key in
            await self?.addonRuntimeMinutes(key)
        }
        observeAudioLanguageForRanking()
        let addons = addons
        // HDR eligibility changes with the screen (a Mac's external display, Low Power Mode).
        NotificationCenter.default.addObserver(forName: AVPlayer.eligibleForHDRPlaybackDidChangeNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in await addons.setDevice(DeviceProfile.current()) }
        }
    }

    private func observeAudioLanguageForRanking() {
        withObservationTracking {
            _ = settings.preferredAudioLanguage
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.addons.setAudioLanguage(self.settings.preferredAudioLanguage)
                self.observeAudioLanguageForRanking()
            }
        }
    }

    private func addonRuntimeMinutes(_ key: MediaKey) async -> Int? {
        guard let detail = try? await metadata.detail(for: key.seriesKey ?? key) else { return nil }
        if let numbers = key.episodeNumbers,
           let season = try? await metadata.season(numbers.season, of: key.seriesKey ?? key),
           let episode = season.episodes.first(where: { $0.number == numbers.episode }), let minutes = episode.runtimeMinutes {
            return minutes
        }
        return detail.runtimeMinutes
    }

    // MARK: Your add-ons

    /// The saved add-on settings with each add-on link read from the Keychain.
    /// Settings from before links moved there (1.0.14 and earlier) are fixed
    /// up on the way: each link goes to the Keychain and preferences keep
    /// only its origin (security review BB-06).
    static func loadAddonSettings(prefs: PreferencesStore, secrets: any SecretStore) -> AddonSettings {
        let saved = prefs.value(AddonSettings.self, for: PreferenceKey.addons) ?? AddonSettings()
        var (settings, moved) = saved.movingLinksOut()
        for (id, link) in moved { try? secrets.write(link, for: SecretAccount.addonLink(id)) }
        if !moved.isEmpty { prefs.set(settings, for: PreferenceKey.addons) }
        for addon in settings.addons {
            guard case .custom = addon.kind,
                  let link = (try? secrets.read(SecretAccount.addonLink(addon.id))).flatMap({ $0 }), !link.isEmpty else { continue }
            settings.customLinks[addon.id] = link
        }
        return settings
    }

    /// Checks the add-on behind a pasted link (`stremio://…` or `https://…/manifest.json`)
    /// and adds it to the end of the list. Throws `AddonError` with a message to show.
    @discardableResult
    public func addAddon(link: String) async throws -> InstalledAddon {
        let (base, manifest) = try await addons.inspectAddon(link: link)
        let duplicate = addonSettings.addons.first { addonSettings.customLinks[$0.id] == base.absoluteString }
        if let duplicate { throw AddonError.alreadyInstalled(duplicate.name) }
        let addon = InstalledAddon.custom(base: base, manifest: manifest)
        try? secrets.write(base.absoluteString, for: SecretAccount.addonLink(addon.id))
        var settings = addonSettings
        settings.addons.append(addon)
        settings.customLinks[addon.id] = base.absoluteString
        setAddonSettings(settings)
        return addon
    }

    /// Gives an add-on added by link its link again, on a device that has the
    /// add-on but not the link (Sync API Keys off). The link must be for the
    /// same host. Throws `AddonError` with a message to show.
    public func setAddonLink(_ id: String, link: String) async throws {
        guard let addon = addonSettings.addons.first(where: { $0.id == id }), case .custom(let origin) = addon.kind else { return }
        let (base, _) = try await addons.inspectAddon(link: link)
        guard AddonURL.origin(base.absoluteString) == origin else { throw AddonError.wrongAddonHost(AddonURL.displayHost(origin)) }
        try? secrets.write(base.absoluteString, for: SecretAccount.addonLink(id))
        var settings = addonSettings
        settings.customLinks[id] = base.absoluteString
        setAddonSettings(settings)
    }

    public func addPreset(_ preset: AddonPreset) {
        var settings = addonSettings
        settings.addPreset(preset)
        setAddonSettings(settings)
    }

    public func removeAddon(_ id: String) {
        var settings = addonSettings
        settings.addons.removeAll { $0.id == id }
        if settings.customLinks.removeValue(forKey: id) != nil { try? secrets.write(nil, for: SecretAccount.addonLink(id)) }
        setAddonSettings(settings)
        Task { await addons.resetHealth(id) }
    }

    public func setAddon(_ id: String, enabled: Bool) {
        var settings = addonSettings
        guard let i = settings.addons.firstIndex(where: { $0.id == id }) else { return }
        settings.addons[i].isEnabled = enabled
        setAddonSettings(settings)
    }

    public func moveAddons(from offsets: IndexSet, to destination: Int) {
        var settings = addonSettings
        settings.addons.move(fromOffsets: offsets, toOffset: destination)
        setAddonSettings(settings)
    }

    /// How each add-on has answered since launch, by `InstalledAddon.id`.
    public func addonHealth() async -> [String: AddonHealth] {
        await addons.addonHealth()
    }

    /// Ends a skip so the add-on is asked again on the next search.
    public func retryAddon(_ id: String) async {
        await addons.resetHealth(id)
    }

    /// The release group and resolution last played for this show, for the picker's "Same group" badge.
    public func showChoice(for key: MediaKey) async -> ShowChoice? {
        await addons.showChoice(for: key)
    }

    public func forgetShowChoices() {
        let addons = addons
        Task { await addons.forgetShowChoices() }
    }
}
