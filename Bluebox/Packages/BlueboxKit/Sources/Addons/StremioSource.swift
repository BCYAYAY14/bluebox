//
//  StremioSource.swift
//  Bluebox
//
//  Written for Bluebox from public documentation (the Stremio add-on SDK's
//  protocol docs and the debrid services' APIs). Makes any catalog title
//  playable through Stremio add-ons: torrents stream through libtorrent,
//  debrid links play directly over HTTPS.
//
//  Availability is answered without waiting on the network (a title with an
//  IMDb ID is "available"), so opening a series page doesn't ask the add-ons
//  about every episode. A movie's releases are fetched in the background when
//  its availability is asked for (its page opens), so Play usually finds them
//  ready. The rest happens on Play, when `resolve` runs: every add-on is asked
//  at once (`AddonSearch`), duplicates merged, debrid cache checked where the
//  service allows, and the list ranked (`ReleaseRanker`). Torrents race in
//  small groups; the first whose peers answer plays.
//

import Domain
import Foundation
import TorrentStreaming

/// Shown by the player while a release is found and buffered.
public enum AddonPlaybackStatus: Sendable, Equatable {
    case searching
    /// Opening a debrid link or a release picked by hand.
    case trying(release: String)
    /// A torrent getting ready. `release` names the one playing, or how many
    /// are being tried at once while peers are found.
    case torrent(TorrentStreamStatus, release: String)
}

public actor StremioSource: MediaSource {
    public nonisolated let id = SourceID("addons")
    public nonisolated let kind = SourceKind.addons
    public nonisolated let displayName = "Torrents & Debrid"
    public nonisolated let capabilities: SourceCapabilities = [.play, .download]

    /// The variant ID that means "pick the best release when playing".
    public static let bestReleaseID = "best"

    /// Releases tried on Play before giving up.
    static let maxAttempts = 6
    /// Answers younger than this are used as they are.
    static let freshFor: TimeInterval = 5 * 60
    /// Older answers (up to this age) are used while a fresh search runs in the background.
    static let usableFor: TimeInterval = 30 * 60

    private var settings: AddonSettings
    private var debridKey: String
    private let imdbID: @Sendable (MediaKey) async -> String?
    private let streamer: TorrentStreamer
    private let client: AddonClient
    private let health: AddonHealthMonitor
    private let choices: any ShowChoiceStore
    private var status: (@Sendable (AddonPlaybackStatus) -> Void)?
    /// Set while on mobile data: caps quality and limits torrents (Settings › Mobile Data).
    private var mobileData: MobileDataRanking?
    private var device: DeviceProfile = .typical
    private var audioLanguage: String?
    private var runtime: (@Sendable (MediaKey) async -> Int?)?

    private struct CacheEntry {
        var releases: [AddonRelease]
        var fetched: Date
        var generation: Int
    }

    /// Releases per catalog key as the add-ons returned them (merged, not
    /// ranked), so the picker and Play agree. Ranked when read, so a change of
    /// network or screen re-ranks them.
    private var cache: [MediaKey: CacheEntry] = [:]
    /// Searches in flight, so a prefetch and Play share one request.
    private var inflight: [MediaKey: Task<[AddonRelease], Error>] = [:]
    /// Releases by variant ID, so `resolve` can find what a picked variant stands for.
    private var known: [String: AddonRelease] = [:]
    /// What the debrid service said about hashes it was asked about.
    private var debridCached: [String: Bool] = [:]
    private var runtimes: [MediaKey: Int] = [:]
    /// Bumped when settings change, so late answers from old searches are dropped.
    private var generation = 0

    public init(settings: AddonSettings, debridKey: String,
                imdbID: @escaping @Sendable (MediaKey) async -> String?,
                client: AddonClient = AddonClient(),
                choices: any ShowChoiceStore = UserDefaultsShowChoiceStore()) {
        self.settings = settings
        self.debridKey = debridKey
        self.imdbID = imdbID
        self.client = client
        self.choices = choices
        self.health = AddonHealthMonitor()
        self.streamer = TorrentStreamer(settings: settings.streamSettings)
    }

    public func update(settings: AddonSettings, debridKey: String) async {
        let searchChanged = settings.resolvedAddons(debridKey: debridKey) != self.settings.resolvedAddons(debridKey: self.debridKey)
            || settings.debrid != self.settings.debrid || debridKey != self.debridKey
        if searchChanged {
            cache = [:]
            debridCached = [:]
            inflight.values.forEach { $0.cancel() }
            inflight = [:]
            generation += 1
        }
        self.settings = settings
        self.debridKey = debridKey
        await streamer.update(settings: settings.streamSettings)
    }

    /// On mobile data, the limits releases are ranked with; nil on Wi‑Fi.
    public func setMobileData(_ ranking: MobileDataRanking?) {
        mobileData = ranking
    }

    /// What this device decodes and displays (`DeviceProfile.current()`).
    public func setDevice(_ profile: DeviceProfile) {
        device = profile
    }

    /// Settings › Playback › Audio Language (ISO 639-1), preferred when ranking.
    public func setAudioLanguage(_ code: String?) {
        audioLanguage = code
    }

    /// A title's runtime in minutes, for judging size per minute.
    public func setRuntimeProvider(_ provider: (@Sendable (MediaKey) async -> Int?)?) {
        runtime = provider
    }

    public func setStatusHandler(_ handler: (@Sendable (AddonPlaybackStatus) -> Void)?) {
        status = handler
    }

    /// Torrent streaming needs libtorrent. Without it, only debrid links play.
    public nonisolated var canStreamTorrents: Bool { TorrentStreamer.isAvailable }

    // MARK: MediaSource

    public func catalog() async throws -> [MediaVariant] { [] }

    public func variants(for key: MediaKey) async throws -> [MediaVariant] {
        guard settings.isEnabled, !settings.resolvedAddons(debridKey: debridKey).isEmpty else { return [] }
        guard canStreamTorrents || hasDebrid else { return [] }
        guard await imdbID(key.seriesKey ?? key) != nil else { return [] }
        // A movie's page is open: look its releases up now so Play needn't wait.
        // Episodes are skipped; a series page asks about many at once.
        if settings.prefetchReleases, key.seriesKey == nil { prefetch(key) }
        return [MediaVariant(id: Self.bestReleaseID, sourceID: id, mediaKey: key,
                             displayName: "Best release", location: .remote, isDownloadable: hasDebrid || canStreamTorrents)]
    }

    public func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        guard let key = variant.mediaKey else { throw SourceError.notFound }
        if variant.id != Self.bestReleaseID {
            // A release picked earlier (maybe before a relaunch): play exactly that one.
            guard let release = known[variant.id] ?? Self.release(fromVariant: variant) else {
                throw SourceError.notFound
            }
            let played = try await play([release], key: key)
            remember(played.release, for: key)
            return played.resource
        }
        status?(.searching)
        let candidates = Array(try await rankedReleases(for: key).prefix(Self.maxAttempts))
        guard !candidates.isEmpty else { throw SourceError.notFound }

        // Links that start at once go one at a time. Torrents race in groups:
        // the first of a group whose peers answer plays; if a whole group is
        // dead, the next group goes.
        var remaining = candidates[...]
        var lastError: Error = SourceError.notFound
        while let first = remaining.first {
            let group: [AddonRelease] = first.isDebrid
                ? [first]
                : Array(remaining.prefix { !$0.isDebrid }.prefix(max(1, settings.streamSettings.raceWidth)))
            remaining = remaining.dropFirst(group.count)
            do {
                let played = try await play(group, key: key)
                remember(played.release, for: key)
                return played.resource
            } catch let error as TorrentStreamError where error.suggestsFallback {
                lastError = error
            }
        }
        throw lastError
    }

    public func testConnection() async -> SourceHealth {
        // Sintel (openly licensed), which every general add-on has.
        let addons = settings.resolvedAddons(debridKey: debridKey)
        guard !addons.isEmpty else { return SourceHealth(ok: false, message: AddonError.noAddons.localizedDescription) }
        do {
            let outcome = try await AddonSearch.run(addons, request: StreamRequest(imdbID: "tt1727587"), client: client,
                                                    health: health, timing: timing(waitForAll: true))
            let found = outcome.releases.count
            var message = found == 0 ? "The add-ons answered, but found nothing." : "\(found) releases found for a test film."
            if !outcome.errors.isEmpty {
                let names = Dictionary(uniqueKeysWithValues: addons.map { ($0.id, $0.name) })
                message += " " + outcome.errors.map { "\(names[$0.key] ?? $0.key): \($0.value)" }.sorted().joined(separator: ", ") + "."
            }
            return SourceHealth(ok: found > 0, message: message)
        } catch {
            return SourceHealth(ok: false, message: error.localizedDescription)
        }
    }

    // MARK: Add-ons

    /// Reads and checks the manifest behind a pasted link. Throws `AddonError`.
    public func inspectAddon(link: String) async throws -> (base: URL, manifest: AddonManifest) {
        let base = try AddonURL.base(from: link)
        let manifest = try await client.manifest(base: base, timeout: TimeInterval(max(settings.addonTimeoutSeconds, 5)))
        return (base, manifest)
    }

    /// Each add-on's record since launch, by `InstalledAddon.id`.
    public func addonHealth() async -> [String: AddonHealth] {
        await health.all()
    }

    /// Forgets an add-on's record and ends any skip.
    public func resetHealth(_ addonID: String) async {
        await health.reset(addonID)
    }

    // MARK: Releases

    /// All releases for the picker, best first. `refresh` asks the add-ons
    /// again instead of using the last answer.
    public func releases(for key: MediaKey, refresh: Bool = false) async throws -> [AddonRelease] {
        if refresh, inflight[key] == nil { cache[key] = nil }
        return try await rankedReleases(for: key)
    }

    /// Starts looking a title's releases up in the background (ignored when fresh or in flight).
    public func prefetch(_ key: MediaKey) {
        if let hit = cache[key], Date().timeIntervalSince(hit.fetched) < Self.freshFor { return }
        guard inflight[key] == nil else { return }
        startSearch(key)
    }

    /// The release group and resolution last played for this show, if remembered.
    public func showChoice(for key: MediaKey) -> ShowChoice? {
        guard settings.rememberShowChoices, let series = key.seriesKey else { return nil }
        return choices.choice(for: series)
    }

    /// Records the release chosen for an episode, so the next one prefers its group.
    public func remember(_ release: AddonRelease, for key: MediaKey) {
        guard settings.rememberShowChoices, let series = key.seriesKey else { return }
        let choice = ShowChoice(release)
        guard choice.isUseful else { return }
        choices.remember(choice, for: series)
    }

    public func forgetShowChoices() {
        choices.forgetAll()
    }

    /// Wraps a release as a variant for `AppModel.play(_:variant:)` and downloads.
    public func variant(for release: AddonRelease, key: MediaKey) -> MediaVariant {
        known[release.id] = release
        return MediaVariant(id: release.id, sourceID: id, mediaKey: key, displayName: release.fileName,
                            container: release.container ?? "mkv", resolution: release.resolution,
                            sizeBytes: release.sizeBytes, location: .remote,
                            isDownloadable: release.isDebrid || canStreamTorrents)
    }

    /// The release a download should use: the best debrid link, else the best torrent.
    public func bestRelease(for key: MediaKey) async throws -> AddonRelease? {
        try await rankedReleases(for: key).first
    }

    /// The release Play would pick with these mobile data limits (nil: as on Wi‑Fi),
    /// for the "You're on mobile data" estimate.
    public func bestRelease(for key: MediaKey, mobileData ranking: MobileDataRanking?) async throws -> AddonRelease? {
        let found = try await foundReleases(for: key)
        return ReleaseRanker.rank(withDebridState(found), context: await context(for: key, mobileData: ranking)).first
    }

    /// Torrent variants are "<info hash>:<file index>"; this turns one back
    /// into a magnet link, so a download can resume after relaunch.
    public nonisolated static func torrent(fromVariantID id: String) -> (magnet: String, fileIndex: Int?)? {
        let parts = id.split(separator: ":")
        guard parts.count == 2, parts[0].count == 40, parts[0].allSatisfy(\.isHexDigit) else { return nil }
        let index = Int(parts[1]).flatMap { $0 >= 0 ? $0 : nil }
        return ("magnet:?xt=urn:btih:\(parts[0])", index)
    }

    /// Rebuilds a saved release variant ("<info hash>:<file index>" or a debrid
    /// URL) when it isn't in memory any more, e.g. after a relaunch.
    static func release(fromVariant variant: MediaVariant) -> AddonRelease? {
        if let torrent = torrent(fromVariantID: variant.id) {
            let hash = String(variant.id.split(separator: ":")[0]).lowercased()
            return AddonRelease(id: variant.id, title: variant.displayName, name: variant.displayName,
                                infoHash: hash, fileIndex: torrent.fileIndex, trackers: [], seeders: nil,
                                sizeText: nil, resolution: variant.resolution, container: variant.container, url: nil,
                                filename: variant.displayName)
        }
        if let url = URL(string: variant.id), url.scheme == "https" || url.scheme == "http" {
            return AddonRelease(id: variant.id, title: variant.displayName, name: variant.displayName,
                                infoHash: nil, fileIndex: nil, trackers: [], seeders: nil, sizeText: nil,
                                resolution: variant.resolution, container: variant.container, url: url,
                                filename: variant.displayName)
        }
        return nil
    }

    /// Stops the torrent that is streaming, if any. `waitForTeardown` waits
    /// until libtorrent has saved its resume data (on quit).
    public func stopStreaming(waitForTeardown: Bool = false) async {
        await streamer.stop(waitForTeardown: waitForTeardown)
    }

    public func streamStats() async -> SwarmStats {
        await streamer.stats()
    }

    /// Plays a debrid link, or races a group of torrents and plays the first that answers.
    private func play(_ group: [AddonRelease], key: MediaKey) async throws -> (resource: PlaybackResource, release: AddonRelease) {
        guard let first = group.first else { throw SourceError.notFound }
        if let url = first.url {
            status?(.trying(release: first.fileName))
            await streamer.stop()
            return (PlaybackResource(variant: variant(for: first, key: key), url: url), first)
        }
        let torrents = group.filter { $0.magnet != nil }
        guard !torrents.isEmpty else { throw SourceError.notFound }
        let names = torrents.map(\.fileName)
        let report = status
        let label = names.count == 1 ? names[0] : "Trying \(names.count) releases at once"
        let chosenName = LockedValue(label)
        let (url, chosen, subtitles) = try await streamer.start(
            candidates: torrents.map {
                TorrentCandidate(magnet: $0.magnet!, fileIndex: $0.fileIndex,
                                 episode: key.episodeNumbers.map { EpisodeNumber(season: $0.season, episode: $0.episode) })
            }
        ) { torrentStatus in
            if case .starting(let index) = torrentStatus, names.indices.contains(index) {
                chosenName.set(names[index])
            }
            report?(.torrent(torrentStatus, release: chosenName.get()))
        }
        let release = torrents.indices.contains(chosen) ? torrents[chosen] : torrents[0]
        return (PlaybackResource(variant: variant(for: release, key: key), url: url,
                                 externalSubtitles: subtitles.map(Self.externalSubtitle)), release)
    }

    /// A subtitle file from the torrent, as the player lists it (under its
    /// language, tagged Torrent: the id says where it's from).
    static func externalSubtitle(_ file: TorrentSubtitleFile) -> ExternalSubtitle {
        let fileName = (file.path as NSString).lastPathComponent
        return ExternalSubtitle(id: ExternalSubtitle.torrentPrefix + file.path, url: file.url, languageCode: file.name.languageCode,
                                label: file.name.label(fallback: fileName), format: file.format)
    }

    // MARK: Searching

    private func rankedReleases(for key: MediaKey) async throws -> [AddonRelease] {
        let found = try await foundReleases(for: key)
        return ReleaseRanker.rank(withDebridState(found), context: await context(for: key, mobileData: mobileData))
    }

    func context(for key: MediaKey, mobileData: MobileDataRanking?) async -> RankingContext {
        RankingContext(settings: settings, canStreamTorrents: canStreamTorrents, mobileData: mobileData, device: device,
                       audioLanguage: audioLanguage, runtimeMinutes: await runtimeMinutes(key).map(Double.init),
                       showChoice: showChoice(for: key))
    }

    private func runtimeMinutes(_ key: MediaKey) async -> Int? {
        if let hit = runtimes[key] { return hit }
        let minutes = await runtime?(key) ?? (key.episodeNumbers != nil ? 45 : 110)
        runtimes[key] = minutes
        return minutes
    }

    private func foundReleases(for key: MediaKey) async throws -> [AddonRelease] {
        if let hit = cache[key] {
            let age = Date().timeIntervalSince(hit.fetched)
            if age < Self.freshFor { return hit.releases }
            if age < Self.usableFor {
                // Use it now; a fresh answer replaces it in the background.
                if inflight[key] == nil { startSearch(key) }
                return hit.releases
            }
        }
        let task = inflight[key] ?? startSearch(key)
        return try await task.value
    }

    @discardableResult
    private func startSearch(_ key: MediaKey) -> Task<[AddonRelease], Error> {
        let task = Task { try await self.search(key) }
        inflight[key] = task
        return task
    }

    private func timing(waitForAll: Bool = false) -> SearchTiming {
        let perAddon = TimeInterval(min(max(settings.addonTimeoutSeconds, 3), 30))
        return waitForAll ? SearchTiming(perAddon: perAddon, grace: perAddon, softDeadline: perAddon)
                          : SearchTiming(perAddon: perAddon)
    }

    private func search(_ key: MediaKey) async throws -> [AddonRelease] {
        defer { inflight[key] = nil }
        guard let imdb = await imdbID(key.seriesKey ?? key) else { throw SourceError.notFound }
        let numbers = key.episodeNumbers
        let request = StreamRequest(imdbID: imdb, season: numbers?.season, episode: numbers?.episode)
        let addons = settings.resolvedAddons(debridKey: debridKey)
        guard !addons.isEmpty else { throw AddonError.noAddons }
        let started = generation
        let outcome = try await AddonSearch.run(addons, request: request, client: client, health: health,
                                                timing: timing()) { [weak self] late in
            await self?.lateAnswer(late, key: key, generation: started)
        }
        guard started == generation else { throw CancellationError() }
        await checkDebridCache(outcome.releases)
        store(outcome.releases, key: key)
        return outcome.releases
    }

    /// A slower add-on answered after the search returned: fold it in.
    private func lateAnswer(_ releases: [AddonRelease], key: MediaKey, generation started: Int) async {
        guard started == generation else { return }
        await checkDebridCache(releases)
        store(releases, key: key)
    }

    /// Per searched key (a movie or an episode), whether anything found starts
    /// at once or is 4K, for Search's "Playable now" and "4K" chips. Only
    /// what's already in memory: no requests.
    public func cachedOffers() -> [MediaKey: ReleaseOffer] {
        cache.mapValues { entry in
            ReleaseOffer(instant: entry.releases.contains(where: \.startsInstantly),
                         uhd: entry.releases.contains { QualityTier(resolution: $0.resolution) == .uhd })
        }
    }

    private func store(_ releases: [AddonRelease], key: MediaKey) {
        cache[key] = CacheEntry(releases: releases, fetched: Date(), generation: generation)
        for release in releases { known[release.id] = release }
    }

    /// Asks TorBox or Premiumize about hashes it hasn't been asked about.
    private func checkDebridCache(_ releases: [AddonRelease]) async {
        guard settings.checkDebridCache, settings.debrid.canCheckCache, hasDebrid else { return }
        let hashes = Set(releases.filter(\.isDebrid).compactMap(\.contentHash)).filter { debridCached[$0] == nil }
        guard !hashes.isEmpty else { return }
        guard let cached = await DebridCacheCheck.cached(Array(hashes), service: settings.debrid, key: debridKey,
                                                         client: client, timeout: 3) else { return }
        for hash in hashes { debridCached[hash] = cached.contains(hash) }
    }

    private func withDebridState(_ releases: [AddonRelease]) -> [AddonRelease] {
        guard !debridCached.isEmpty else { return releases }
        let checked = Set(debridCached.keys)
        let cached = Set(debridCached.filter(\.value).keys)
        return DebridCacheCheck.apply(cached, checked: checked, to: releases)
    }

    // MARK: Helpers

    public static func resolutionLevel(_ resolution: String?) -> Int? {
        switch resolution {
        case "480p": 1
        case "720p": 2
        case "1080p", "1440p": 3
        case "2160p": 4
        default: nil
        }
    }

    private var hasDebrid: Bool { settings.hasDebrid(debridKey) }
}

/// A value the status callback updates from libtorrent's threads.
private final class LockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ new: T) { lock.withLock { value = new } }
}
