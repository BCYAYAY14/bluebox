import Addons
import Domain
import Downloads
import DownloadsActivity
import Foundation
import Persistence
import Playback
import TorrentStreaming
#if os(iOS)
import BackgroundTasks
#endif

// MARK: - Downloads

extension AppModel {
    static let streamHoldReason = "Waits while you stream this release"

    /// Wires the queue to libtorrent (torrents) and the sources (fresh links). Called from init.
    func configureDownloads() {
        let manager = downloads
        let torrents = torrentDownloads
        let registry = registry
        let addonsID = addons.id
        let base = downloads.directory
        manager.resolveResource = { variant in
            // Debrid releases' IDs are their links; asking the add-on source
            // for anything else would start a stream.
            if variant.sourceID == addonsID {
                guard let url = URL(string: variant.id), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    throw SourceError.notFound
                }
                return PlaybackResource(variant: variant, url: url)
            }
            return try await registry.resolve(variant)
        }
        manager.external = ExternalDownloadRunner(
            start: { record in
                guard let torrent = StremioSource.torrent(fromVariantID: record.origin.id) else {
                    manager.externalFailed(record.id, message: "This torrent link isn't valid.")
                    return
                }
                let id = record.id
                let folder = torrents.folder(for: id)
                // The episode picks its file out of a season pack (whose variants carry no file index).
                let episode = record.mediaKey?.episodeNumbers.map { EpisodeNumber(season: $0.season, episode: $0.episode) }
                await torrents.start(id: id, magnet: torrent.magnet, fileIndex: torrent.fileIndex, episode: episode) { event in
                    switch event {
                    case .connecting:
                        manager.externalConnecting(id)
                    case .progress(let p):
                        manager.externalProgress(id, receivedBytes: p.receivedBytes, totalBytes: p.totalBytes,
                                                 bytesPerSecond: p.bytesPerSecond, peers: p.peers)
                    case .completed(let relative):
                        let file = folder.appending(path: relative)
                        let name = String(file.path.dropFirst(base.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        manager.externalCompleted(id, fileName: name)
                    case .failed(let message):
                        manager.externalFailed(id, message: message)
                    }
                }
            },
            stop: { id in await torrents.pause(id) },
            delete: { id in await torrents.delete(id) })
    }

    /// Starts the queue (unfinished downloads resume) once sources are registered.
    func startDownloadQueue() {
        announceDownloadChanges()  // baseline: what was already finished or failed isn't news
        loadUpgradeOffers()
        let keep = Set(downloads.all().filter(\.isTorrent).map(\.id))
        let torrents = torrentDownloads
        let manager = downloads
        Task { [weak self] in
            await torrents.pruneFolders(keeping: keep)
            manager.activate()
            self?.finishUpgrades()  // swaps that completed while Bluebox wasn't running
            await self?.sweepWatchedFilms()
            await self?.dailyUpgradeCheck()
        }
        DownloadPowerMonitor.shared.start(manager: downloads)
        downloadLifecycle.isPlaying = { [weak self] in self?.activePlayer?.snapshot.status.isActive == true }  // buffering too
        downloadLifecycle.isPlayerOpen = { [weak self] in self?.activePlayer != nil }
        downloadLifecycle.start(manager: downloads)
        downloadsPresence.liveActivityEnabled = { [weak self] in self?.featureSwitches.liveActivity == true }
        downloadsPresence.currentState = { [manager] in DownloadsActivityState.summary(manager.all(), live: manager.liveStats) }
        downloadsPresence.start()
    }

    // MARK: Background (iOS)

    /// The processing task that resumes torrent downloads while the device
    /// charges (Info.plist › BGTaskSchedulerPermittedIdentifiers; DownloadLifecycle).
    public static let downloadResumeTaskID = "app.bluebox.downloads.resume"

    /// Registers the download processing task. Call once, before the app
    /// finishes launching (the app delegate does).
    public static func registerBackgroundDownloadTask() {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: downloadResumeTaskID, using: nil) { task in
            nonisolated(unsafe) let task = task
            Task { @MainActor in
                guard let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
                await handleBackgroundDownloads(processing)
            }
        }
        #endif
    }

    #if os(iOS)
    /// Runs the processing task: uses the running app, or opens the library
    /// and starts the download queue just for it.
    static func handleBackgroundDownloads(_ task: BGProcessingTask) async {
        let app: AppModel
        if let current { app = current } else {
            guard let fresh = try? await AppModel.liveReadingSecrets() else { task.setTaskCompleted(success: false); return }
            current = fresh
            app = fresh
        }
        app.downloadLifecycle.adoptProcessingTask(task)
        await app.bootstrap()  // starts the queue once; nothing if the app is already running
        app.downloadLifecycle.beginProcessing()
    }
    #endif

    public func setDownloadSettings(_ settings: DownloadSettings) {
        downloadSettings = settings
        prefs.set(settings, for: PreferenceKey.downloadSettings)
        downloads.update(settings: settings)
    }

    /// True when `key` (a movie or episode) is saved on this device and plays
    /// offline. For a series key, true when any of its episodes is. Views that
    /// call this refresh as downloads change.
    public func isDownloaded(_ key: MediaKey) -> Bool {
        _ = downloadsRevision
        return downloads.isDownloaded(key)
    }

    /// The newest download of `key`, in any state.
    public func download(for key: MediaKey) -> DownloadRecord? {
        _ = downloadsRevision
        return downloads.records(for: key).sorted { $0.createdAt > $1.createdAt }.first
    }

    /// The offline copy of `key`, if one is saved.
    func downloadedVariant(for key: MediaKey) -> MediaVariant? {
        downloads.completedRecord(for: key).map { DownloadsSource(manager: downloads).variant($0) }
    }

    /// The offline copy of exactly this release, if it was downloaded.
    func downloadedCopy(of variant: MediaVariant) -> MediaVariant? {
        guard variant.location != .downloaded, let r = downloads.record(for: variant), r.state == .completed else { return nil }
        return DownloadsSource(manager: downloads).variant(r)
    }

    /// The variant a download of `key` would use, if any source allows it.
    public func downloadableVariant(for key: MediaKey) async -> MediaVariant? {
        let candidates = await availability(for: key).variants.filter { $0.isDownloadable && $0.location == .remote }
        return chooseVariant(candidates, for: key)
    }

    /// - Parameter automatic: Bluebox is downloading this by itself (Smart
    ///   Downloads, new episodes): it keeps to the download window and Wi‑Fi,
    ///   only takes a release within the quality and size caps, and fails
    ///   quietly (in the log) instead of with an alert.
    public func startDownload(key: MediaKey, title: String, subtitle: String? = nil, automatic: Bool = false) async {
        // The button shows "preparing" at once, while a release is found.
        preparingDownloads.insert(key)
        defer { preparingDownloads.remove(key) }
        guard let variant = await downloadableVariant(for: key) else {
            if automatic {
                Log.sources.info("Automatic download skipped: nothing downloadable for \(key.rawValue, privacy: .public)")
            } else {
                alert = AppAlert(title: "Can't download", message: DownloadError.notDownloadable.localizedDescription)
            }
            return
        }
        if variant.sourceID == addons.id {
            await downloadFromAddons(key: key, title: title, subtitle: subtitle, automatic: automatic)
            return
        }
        await enqueueDownload(variant, key: key, title: title, subtitle: subtitle, automatic: automatic)
    }

    /// Downloads one release the user picked: debrid over HTTPS, torrents with libtorrent.
    public func download(_ release: AddonRelease, for item: NowPlayingItem) async {
        await download(release, for: item, automatic: false)
    }

    /// - Parameter replaces: the download this one upgrades (Swap); it goes once this one finishes.
    func download(_ release: AddonRelease, for item: NowPlayingItem, automatic: Bool, replaces: String? = nil) async {
        if release.magnet != nil, !release.isDebrid, !TorrentStreamer.isAvailable {
            if !automatic {
                alert = AppAlert(title: "Can't download", message: TorrentStreamError.unavailableOnThisPlatform.localizedDescription)
            }
            return
        }
        let variant = await addons.variant(for: release, key: item.key)
        let resource = release.url.map { PlaybackResource(variant: variant, url: $0) }
        await enqueueDownload(variant, key: item.key, title: item.title, subtitle: item.subtitle, resource: resource,
                              automatic: automatic, replaces: replaces)
    }

    /// The release a download of `key` takes when Bluebox picks: the add-ons'
    /// order within the title's download rule (quality cap, size cap, audio
    /// language). `strict` (automatic downloads) gives nil rather than break the caps.
    func downloadRelease(for key: MediaKey, strict: Bool) async throws -> AddonRelease? {
        SmartDownloads.pickRelease(try await addons.releases(for: key), rule: downloadSettings.rule(for: key), strict: strict)
    }

    /// Downloads the best release for a title within its download rule: a
    /// debrid link if there is one, otherwise a torrent.
    func downloadFromAddons(key: MediaKey, title: String, subtitle: String?, automatic: Bool = false) async {
        do {
            guard let release = try await downloadRelease(for: key, strict: automatic) else {
                if automatic {
                    Log.sources.info("Automatic download skipped: no release within the caps for \(key.rawValue, privacy: .public)")
                } else {
                    alert = AppAlert(title: "Can't download", message: "The add-ons didn't find a release of this.")
                }
                return
            }
            await download(release, for: NowPlayingItem(key: key, title: title, subtitle: subtitle), automatic: automatic)
        } catch {
            if automatic {
                Log.sources.error("Automatic download failed (\(key.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                return
            }
            report(error, title: "Couldn't download “\(title)”", context: .addons) { [weak self] in
                await self?.downloadFromAddons(key: key, title: title, subtitle: subtitle)
            }
        }
    }

    private func enqueueDownload(_ variant: MediaVariant, key: MediaKey, title: String, subtitle: String?,
                                 resource: PlaybackResource? = nil, automatic: Bool = false, replaces: String? = nil) async {
        let artwork = await self.title(for: key.seriesKey ?? key).flatMap { imageURL($0.poster, width: 120) }
        do {
            let record = try downloads.enqueue(variant, key: key, title: title, subtitle: subtitle, artworkURL: artwork,
                                               resource: resource, automatic: automatic, replaces: replaces)
            if automatic { return }  // quiet: it waits for Wi‑Fi and the download window by design
            // No "Downloading…" toast: the button turns into progress and the tab's badge goes up.
            // Only the case where it won't start yet is worth saying.
            if let notice = mobileDataDownloadNotice(for: record, title: title) {  // "Will start on Wi‑Fi" (MobileData.swift)
                showToast(notice)
            }
            // The first download is when "Downloaded" alerts start to matter; iOS asks only once.
            Task { _ = await EpisodeNotifications.requestPermission() }
        } catch DownloadError.alreadyInQueue {
            // Already downloading: nothing changes, so nothing to say.
        } catch DownloadError.alreadyDownloaded {
            if !automatic { alert = AppAlert(title: "Already downloaded", message: "This release is already in Downloads.") }
        } catch {
            if automatic {
                Log.sources.error("Automatic download not queued (\(title, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            } else {
                report(error, title: "Couldn't start the download", context: .download)
            }
        }
    }

    /// Says when a download finishes or fails while you're elsewhere in the app.
    /// Only changes seen during this launch count; the first call just records.
    func announceDownloadChanges() {
        let now = Dictionary(downloads.all().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        defer { lastDownloadStates = now.mapValues(\.state) }
        guard let before = lastDownloadStates else { return }
        for (id, record) in now {
            guard let old = before[id], old != record.state else { continue }
            let name = record.subtitle.map { "\(record.title) · \($0)" } ?? record.title
            switch record.state {
            case .completed where old == .downloading:
                if record.replaces != nil {
                    finishUpgrades()
                } else {
                    showToast(AppToast("Downloaded “\(name)”", style: .success, actionTitle: "Play") { [weak self] in
                        Task { await self?.playDownload(record) }
                    })
                }
                if record.isTorrent && downloadLifecycle.isInBackground { DownloadLifecycle.notifyFinished(record) }
                Task { await fetchSubtitles(for: record) }
            case .failed(let message) where old == .downloading || old == .queued:
                Log.sources.error("Download failed (\(record.title, privacy: .public)): \(message, privacy: .public)")
                showToast(AppToast("Download failed: \(name)", message: message, style: .error, actionTitle: "Retry") { [weak self] in
                    self?.downloads.resume(id)
                })
            default:
                break
            }
        }
    }

    /// Queues the next `count` episodes after `key` that aren't downloaded or
    /// queued yet. Returns how many it asked for.
    @discardableResult
    public func downloadNextEpisodes(after key: MediaKey, count: Int = 3) async -> Int {
        guard let seriesKey = key.seriesKey, let start = key.episodeNumbers,
              let detail = try? await metadata.detail(for: seriesKey) else { return 0 }
        var (s, e) = start
        var added = 0
        var checked = 0
        while added < count, checked < count + 20, let (ns, ne) = SeriesCursor.next(after: s, e, seasons: detail.seasons) {
            (s, e) = (ns, ne)
            checked += 1
            guard let next = seriesKey.episode(season: ns, episode: ne) else { break }
            if downloads.records(for: next).contains(where: { $0.state != .paused && !$0.isFailed }) { continue }
            await startDownload(key: next, title: detail.title.name, subtitle: "S\(ns)·E\(ne)")
            added += 1
        }
        return added
    }

    /// "Download Next 3 Episodes" from a menu: says what it did, so the tap
    /// never seems to do nothing (the queue may be on another tab, or the
    /// show may have nothing left).
    func downloadNextEpisodesAnnounced(after key: MediaKey, count: Int = 3, showTitle: String) async {
        showToast(AppToast("Finding the next episodes…", message: showTitle, style: .info))
        let added = await downloadNextEpisodes(after: key, count: count)
        showToast(added == 0
                  ? AppToast("Nothing more to download", message: "\(showTitle): the following episodes are already downloaded or not out yet.",
                             style: .info)
                  : AppToast("Downloading \(added) more episode\(added == 1 ? "" : "s")", message: showTitle, style: .success))
    }

    public func pauseDownload(_ r: DownloadRecord) { downloads.pause(r.id) }

    /// Resumes a paused download or retries a failed one.
    public func resumeDownload(_ r: DownloadRecord) async { downloads.resume(r.id) }

    public func prioritizeDownload(_ r: DownloadRecord) { downloads.prioritize(r.id) }

    /// The queue screen's drag to reorder.
    func reorderDownloads(_ ids: [String]) { downloads.reorder(ids) }

    public func pauseAllDownloads() { downloads.queue().filter(\.isActive).forEach { downloads.pause($0.id) } }

    public func resumeAllDownloads() {
        downloads.queue().filter { $0.state == .paused || $0.isFailed }.forEach { downloads.resume($0.id) }
    }

    /// Finished downloads you've watched to the end.
    public func watchedDownloads() async -> [DownloadRecord] {
        var watched: [DownloadRecord] = []
        for r in downloads.all() where r.state == .completed {
            guard let key = r.mediaKey, let p = try? await store.progress(for: key), p.isCompleted else { continue }
            watched.append(r)
        }
        return watched
    }

    /// Plays a finished download from the device.
    public func playDownload(_ r: DownloadRecord) async {
        let key = r.mediaKey ?? MediaKey(rawValue: "url:\(r.id)")
        await play(NowPlayingItem(key: key, title: r.title, subtitle: r.subtitle, artworkURL: r.artworkURL),
                   variant: DownloadsSource(manager: downloads).variant(r))
    }

    // After watching: Smart Downloads (SmartDownloads.swift).

    /// A torrent download is queued or running (iOS, where they need the app running).
    public var torrentDownloadsActive: Bool {
        #if os(iOS)
        _ = downloadsRevision
        return downloads.hasActiveTorrents
        #else
        return false
        #endif
    }

    /// Torrent downloads only run while Bluebox is open (iOS, with Keep
    /// Downloading in the Background off).
    public var torrentDownloadsNeedApp: Bool {
        torrentDownloadsActive && !downloadSettings.keepDownloadingInBackground
    }

    /// Streaming and downloading the same release share one torrent in the
    /// engine (each asks for its own file), so downloads no longer step aside
    /// while a stream plays. Set to true to hold them anyway.
    static let holdDownloadsWhileStreaming = false

    /// Before streaming, downloads of the same release (or, for "best
    /// release", of the same title) can step aside; they continue when the
    /// player closes. Off: see `holdDownloadsWhileStreaming`.
    func holdTorrentDownloads(before variant: MediaVariant, key: MediaKey) async {
        guard Self.holdDownloadsWhileStreaming, variant.sourceID == addons.id else { return }
        let tokens: [String]
        if let hash = DownloadRecord.infoHash(fromVariantID: variant.id) {
            tokens = [hash]
        } else {
            tokens = downloads.records(for: key).filter { $0.isTorrent && $0.state != .completed }.map(\.id)
        }
        for token in tokens where !streamHolds.contains(token) {
            streamHolds.append(token)
            await downloads.hold(token, reason: Self.streamHoldReason)
        }
    }

    /// Once the stream's release is known, hold downloads of exactly it and let others go.
    func holdTorrentDownloads(streaming variant: MediaVariant) async {
        guard Self.holdDownloadsWhileStreaming else { return }
        let keep = DownloadRecord.infoHash(fromVariantID: variant.id).map { [$0] } ?? []
        for token in streamHolds where !keep.contains(token) { downloads.releaseHold(token) }
        streamHolds = keep
        for token in keep { await downloads.hold(token, reason: Self.streamHoldReason) }
    }

    func releaseTorrentDownloadHolds() {
        let tokens = streamHolds
        streamHolds = []
        tokens.forEach { downloads.releaseHold($0) }
    }
}
