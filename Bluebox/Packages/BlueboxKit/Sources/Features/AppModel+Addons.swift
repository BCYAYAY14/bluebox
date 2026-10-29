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

    /// Checks the add-on behind a pasted link (`stremio://…` or `https://…/manifest.json`)
    /// and adds it to the end of the list. Throws `AddonError` with a message to show.
    @discardableResult
    public func addAddon(link: String) async throws -> InstalledAddon {
        let (base, manifest) = try await addons.inspectAddon(link: link)
        let duplicate = addonSettings.addons.first {
            if case .custom(let existing) = $0.kind { return existing == base.absoluteString }
            return false
        }
        if let duplicate { throw AddonError.alreadyInstalled(duplicate.name) }
        let addon = InstalledAddon.custom(base: base, manifest: manifest)
        var settings = addonSettings
        settings.addons.append(addon)
        setAddonSettings(settings)
        return addon
    }

    public func addPreset(_ preset: AddonPreset) {
        var settings = addonSettings
        settings.addPreset(preset)
        setAddonSettings(settings)
    }

    public func removeAddon(_ id: String) {
        var settings = addonSettings
        settings.addons.removeAll { $0.id == id }
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
