import Addons
import Domain
import Downloads
import Foundation
import Observation
import Persistence
import Playback

// "Better version available": a downloaded title gets a better release
// later (1080p where you have 720p, a WEB-DL where you have a CAM). The
// download shows it with Swap, which downloads the new release and deletes
// the old one once it's in. Checks are opportunistic and light: a title's
// page opening, and one pass a day over a few downloads, each title at most
// once a day, all from the add-on answers Play already caches.

/// Whether a release is a real step up from a download.
enum DownloadUpgrade {
    /// What a download is, read from its saved release name and resolution.
    static func info(of r: DownloadRecord) -> ReleaseInfo {
        var info = ReleaseNameParser.parse(r.origin.displayName)
        if let res = r.origin.resolution { info.resolution = res }
        return info
    }

    /// Better: a higher resolution, or at least the same resolution from a
    /// proper source (WEB, Blu-ray) where you have a cinema copy (CAM, TS).
    /// Only releases that start or download reliably (cached or direct
    /// links, healthy torrents), within the title's download rule, and not
    /// the release you already have.
    static func isBetter(_ candidate: AddonRelease, than current: ReleaseInfo, currentID: String, rule: DownloadRule) -> Bool {
        guard candidate.id != currentID, SmartDownloads.fits(candidate, rule: rule), isReliable(candidate) else { return false }
        let have = StremioSource.resolutionLevel(current.resolution)
        let offer = StremioSource.resolutionLevel(candidate.resolution)
        let properSource = candidate.info.source.map { !$0.isPreRelease } ?? false
        // A cinema copy is no upgrade, whatever its resolution.
        if candidate.info.source?.isPreRelease == true { return false }
        if let have, let offer, offer > have { return true }
        if current.source?.isPreRelease == true, properSource, (offer ?? 0) >= (have ?? 0) { return true }
        return false
    }

    static func isReliable(_ r: AddonRelease) -> Bool {
        r.isDebrid ? r.cache != .uncached : (r.seeders ?? 0) >= ReleaseRanker.healthySeeders
    }

    /// The best upgrade among `ranked` (the add-ons' order), if any.
    static func best(_ ranked: [AddonRelease], for r: DownloadRecord, rule: DownloadRule) -> AddonRelease? {
        let current = info(of: r)
        // The same torrent, as another file index or as a debrid link to it, is the same release.
        let hash = DownloadRecord.infoHash(fromVariantID: r.origin.id)
            ?? URL(string: r.origin.id)?.pathComponents.first { $0.count == 40 && $0.allSatisfy(\.isHexDigit) }?.lowercased()
        return ranked.first { c in
            (hash == nil || c.contentHash != hash) && isBetter(c, than: current, currentID: r.origin.id, rule: rule)
        }
    }

    /// "1080p WEB-DL · 2.1 GB" for the offer.
    static func label(_ r: AddonRelease) -> String {
        [r.resolution, r.info.source?.title, r.sizeText].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A better release found for one download.
struct UpgradeOffer: Codable, Equatable, Sendable {
    let release: AddonRelease
    let foundAt: Date
    var label: String { DownloadUpgrade.label(release) }
}

/// Upgrade offers by download ID, and when each title was last checked.
/// Device-only (downloads are), kept across launches.
@MainActor @Observable
final class DownloadUpgrades {
    static let shared = DownloadUpgrades()
    static let checkEvery: TimeInterval = 86_400
    /// Downloads one daily pass looks at.
    static let perPass = 6
    static let offersKey = "bluebox.downloads.upgradeOffers"
    static let checkedKey = "bluebox.downloads.upgradeChecked"

    private(set) var offers: [String: UpgradeOffer] = [:]
    @ObservationIgnored var checked: [String: Date] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored var lastPass: Date?

    func offer(for id: String) -> UpgradeOffer? { offers[id] }

    func load(_ prefs: PreferencesStore) {
        guard !loaded else { return }
        loaded = true
        offers = prefs.value([String: UpgradeOffer].self, for: Self.offersKey) ?? [:]
        checked = prefs.value([String: Date].self, for: Self.checkedKey) ?? [:]
    }

    func set(_ offer: UpgradeOffer?, for id: String, prefs: PreferencesStore) {
        guard offers[id] != offer else { return }
        offers[id] = offer
        prefs.set(offers, for: Self.offersKey)
    }

    func markChecked(_ key: MediaKey, at date: Date = .now, prefs: PreferencesStore) {
        checked[key.rawValue] = date
        if checked.count > 500 {
            checked = Dictionary(uniqueKeysWithValues: checked.sorted { $0.value > $1.value }.prefix(400).map { ($0.key, $0.value) })
        }
        prefs.set(checked, for: Self.checkedKey)
    }

    /// Checked within the last day.
    func isFresh(_ key: MediaKey, now: Date = .now) -> Bool {
        checked[key.rawValue].map { now.timeIntervalSince($0) < Self.checkEvery } ?? false
    }

    /// Offers whose download is gone.
    func prune(keeping ids: Set<String>, prefs: PreferencesStore) {
        let stale = offers.keys.filter { !ids.contains($0) }
        guard !stale.isEmpty else { return }
        stale.forEach { offers[$0] = nil }
        prefs.set(offers, for: Self.offersKey)
    }
}

extension AppModel {
    /// The better release found for a finished download, if any. Views
    /// reading this refresh when offers change.
    func upgradeOffer(for r: DownloadRecord) -> UpgradeOffer? {
        r.state == .completed ? DownloadUpgrades.shared.offer(for: r.id) : nil
    }

    /// Loads saved offers before any screen asks (`startDownloadQueue`).
    func loadUpgradeOffers() { DownloadUpgrades.shared.load(prefs) }

    /// Looks for a better release of a finished add-on download, at most once
    /// a day per title (the title page calls this as it opens).
    func checkForUpgrade(_ key: MediaKey) async {
        let store = DownloadUpgrades.shared
        store.load(prefs)
        guard addonSettings.isEnabled, !store.isFresh(key),
              let r = downloads.completedRecord(for: key), r.origin.sourceID == addons.id || r.isTorrent else { return }
        store.markChecked(key, prefs: prefs)
        guard let ranked = try? await addons.releases(for: key) else { return }
        let best = DownloadUpgrade.best(ranked, for: r, rule: downloadSettings.rule(for: key))
        store.set(best.map { UpgradeOffer(release: $0, foundAt: .now) }, for: r.id, prefs: prefs)
    }

    /// Once a day: a few finished downloads, the longest unchecked first, a
    /// few seconds apart so the add-ons aren't hammered.
    func dailyUpgradeCheck() async {
        let store = DownloadUpgrades.shared
        store.load(prefs)
        let finished = downloads.all().filter { $0.state == .completed }
        store.prune(keeping: Set(finished.map(\.id)), prefs: prefs)
        if let last = store.lastPass, Date().timeIntervalSince(last) < DownloadUpgrades.checkEvery { return }
        store.lastPass = .now
        let due = finished.compactMap(\.mediaKey).filter { !store.isFresh($0) }
            .sorted { (store.checked[$0.rawValue] ?? .distantPast) < (store.checked[$1.rawValue] ?? .distantPast) }
        for key in due.prefix(DownloadUpgrades.perPass) {
            try? await Task.sleep(for: .seconds(4))
            await checkForUpgrade(key)
        }
    }

    /// Swap: downloads the better release; the old one is deleted when it's in.
    func swapDownload(_ r: DownloadRecord, to offer: UpgradeOffer) async {
        guard let key = r.mediaKey else { return }
        DownloadUpgrades.shared.set(nil, for: r.id, prefs: prefs)
        await download(offer.release, for: NowPlayingItem(key: key, title: r.title, subtitle: r.subtitle, artworkURL: r.artworkURL),
                       automatic: false, replaces: r.id)
        showToast(AppToast("Downloading the better version", message: "\(r.title) · \(offer.label). The current one stays until it's in.",
                           style: .info))
    }

    /// Deletes downloads that a finished upgrade replaces.
    func finishUpgrades() {
        let all = downloads.all()
        for r in all where r.state == .completed {
            guard let old = r.replaces, let replaced = downloads.record(id: old) else { continue }
            deleteDownloads([replaced])
            DownloadUpgrades.shared.set(nil, for: old, prefs: prefs)
            showToast(AppToast("Upgraded “\(r.title)”", message: [r.subtitle, r.origin.resolution].compactMap { $0 }.joined(separator: " · "),
                               style: .success))
        }
    }
}
