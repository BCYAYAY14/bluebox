import Addons
import DesignSystem
import Domain
import Downloads
import Foundation
import Playback
import TorrentStreaming

// MARK: - Season progress

/// One season's downloads at a glance: the bar under the season picker
/// ("Downloading Season 2 · 3 of 8 · 41%") and the season card on Downloads.
/// Episodes still being looked up (`preparing`) count as not started.
struct SeasonDownloadStatus: Equatable {
    var total = 0
    var completed = 0
    var downloading = 0
    var queued = 0
    var paused = 0
    var failed = 0
    var preparing = 0
    /// 0…1 over the whole season: by bytes once every size is known, else
    /// each episode counts the same.
    var fraction: Double = 0
    var receivedBytes: Int64 = 0
    /// What the finished and known-size episodes add up to.
    var knownBytes: Int64 = 0

    init(records: [DownloadRecord], preparing: Int = 0) {
        self.preparing = preparing
        total = records.count + preparing
        var sizedTotal: Int64 = 0, sizedReceived: Int64 = 0, allSized = preparing == 0
        var perEpisode = 0.0
        for r in records {
            switch r.state {
            case .completed: completed += 1
            case .downloading: downloading += 1
            case .queued: queued += 1
            case .paused: paused += 1
            case .failed: failed += 1
            }
            let done = r.state == .completed
            perEpisode += done ? 1 : (r.fraction ?? 0)
            receivedBytes += done ? (r.expectedBytes ?? r.receivedBytes) : r.receivedBytes
            if let e = r.expectedBytes, e > 0 {
                sizedTotal += e
                sizedReceived += done ? e : min(r.receivedBytes, e)
            } else if !done {
                allSized = false
            }
            knownBytes += done ? (r.expectedBytes ?? r.receivedBytes) : (r.expectedBytes ?? 0)
        }
        if total == 0 {
            fraction = 0
        } else if allSized, sizedTotal > 0 {
            fraction = Double(sizedReceived) / Double(sizedTotal)
        } else {
            fraction = perEpisode / Double(total)
        }
        fraction = min(max(fraction, 0), 1)
    }

    var isEmpty: Bool { total == 0 }
    /// Something is still to come without the user doing anything.
    var inProgress: Bool { downloading + queued + preparing > 0 }
    var isComplete: Bool { total > 0 && completed == total }
    /// Stopped by the user (or failed) with nothing else running.
    var isStopped: Bool { !inProgress && paused + failed > 0 }
    /// Episodes not finished: what Cancel takes away.
    var unfinished: Int { total - completed }

    /// "3 of 8 · 41%", "Paused · 3 of 8", "8 episodes · 9.4 GB".
    var detail: String {
        let percent = "\(Int((fraction * 100).rounded(.down)))%"
        if isComplete { return total == 1 ? "1 episode" : "\(total) episodes" }
        if preparing == total { return "Finding releases…" }
        if inProgress { return "\(completed) of \(total) · \(percent)" }
        if failed > 0, paused == 0 { return "\(failed) failed · \(completed) of \(total)" }
        return "Paused · \(completed) of \(total) · \(percent)"
    }
}

// MARK: - Asking first

/// Whether Download Season asks before it starts: a big season, a season
/// that won't fit, or any season on mobile data.
enum SeasonDownloadCheck: Equatable {
    case none
    case large(bytes: Int64, episodes: Int)
    case mobileData(bytes: Int64, episodes: Int, wifiOnly: Bool)
    case notEnoughSpace(bytes: Int64, free: Int64, episodes: Int)

    /// Anything past this asks first, on Wi‑Fi too (about four 1080p episodes).
    static let largeBytes: Int64 = 5_000_000_000

    static func check(bytes: Int64, episodes: Int, onMobileData: Bool, wifiOnly: Bool, freeBytes: Int64?) -> Self {
        guard episodes > 0 else { return .none }
        if let freeBytes, bytes > freeBytes { return .notEnoughSpace(bytes: bytes, free: freeBytes, episodes: episodes) }
        if onMobileData { return .mobileData(bytes: bytes, episodes: episodes, wifiOnly: wifiOnly) }
        if bytes >= largeBytes { return .large(bytes: bytes, episodes: episodes) }
        return .none
    }
}

/// A whole-season (or "remaining") download the user asked for, waiting on a confirmation.
struct SeasonDownloadRequest: Identifiable, Equatable {
    let seriesKey: MediaKey
    let season: Int
    let seasonName: String
    let seriesName: String
    let episodes: [Episode]
    let bytes: Int64
    let check: SeasonDownloadCheck
    var id: String { SeasonDownloadRequest.jobID(seriesKey, season) }

    static func jobID(_ series: MediaKey, _ season: Int) -> String { "\(series.rawValue)#\(season)" }

    var title: String {
        switch check {
        case .mobileData: "Download on mobile data?"
        case .notEnoughSpace: "Not enough space for \(seasonName)"
        default: "Download \(seasonName)?"
        }
    }

    var message: String {
        let n = episodes.count == 1 ? "1 episode" : "\(episodes.count) episodes"
        let size = SeasonActionPlan.sizeLabel(bytes)
        switch check {
        case .none, .large:
            return "\(n), \(size). Downloads continue in the background and you can cancel them from here or Downloads."
        case .mobileData(_, _, let wifiOnly):
            return wifiOnly
                ? "\(n), \(size). You're on mobile data and downloads are set to Wi‑Fi only, so they'll wait for Wi‑Fi unless you start them now."
                : "\(n), \(size), on mobile data. That can use a lot of your plan."
        case .notEnoughSpace(_, let free, _):
            return "\(n) need \(size) and this device has \(Formatters.bytes(free)) free. Downloads stop when space runs out."
        }
    }
}

// MARK: - AppModel

extension AppModel {
    /// Episodes looked up ahead of the one being queued.
    static let seasonLookAhead = 2

    /// Downloads of a season in any state, leaving out ones waiting out their Undo.
    func seasonDownloads(_ series: MediaKey, season: Int) -> [DownloadRecord] {
        _ = downloadsRevision
        let pending = PendingDownloadDeletes.shared
        return downloads.all().filter { r in
            guard let key = r.mediaKey, key.seriesKey == series, key.episodeNumbers?.season == season else { return false }
            return !pending.contains(r.id)
        }
    }

    /// Episodes of a season whose download is being looked up right now.
    func preparingCount(_ series: MediaKey, season: Int) -> Int {
        preparingDownloads.filter { $0.seriesKey == series && $0.episodeNumbers?.season == season }.count
    }

    /// True while Download Season is still queueing this season's episodes.
    func isQueueingSeason(_ series: MediaKey, season: Int) -> Bool {
        seasonJobs.contains(SeasonDownloadRequest.jobID(series, season))
    }

    /// What a download of `key` fetches: the source's own file, or the add-ons' best release.
    func downloadTarget(for key: MediaKey) async throws -> (variant: MediaVariant, resource: PlaybackResource?) {
        guard let variant = await downloadableVariant(for: key) else { throw DownloadError.notDownloadable }
        guard variant.sourceID == addons.id else { return (variant, nil) }
        guard let release = try await downloadRelease(for: key, strict: false) else { throw SeasonDownloadError.noRelease }
        if release.magnet != nil, !release.isDebrid, !TorrentStreamer.isAvailable {
            throw TorrentStreamError.unavailableOnThisPlatform
        }
        let v = await addons.variant(for: release, key: key)
        return (v, release.url.map { PlaybackResource(variant: v, url: $0) })
    }

    /// Queues a season's episodes in order. Every row shows "preparing" at
    /// once; the add-on lookups run side by side (they're cached and shared
    /// with Play) while the queue fills in episode order. One toast at the
    /// end says what didn't work, instead of an alert per episode.
    ///
    /// - Parameter mobileData: true starts now even on mobile data, false
    ///   holds them for Wi‑Fi, nil follows Settings.
    func downloadSeason(_ episodes: [Episode], seriesKey: MediaKey, season: Int, seriesName: String,
                        mobileData: Bool? = nil) {
        let id = SeasonDownloadRequest.jobID(seriesKey, season)
        let wanted = episodes.filter { ep in
            !downloads.records(for: ep.key).contains { !$0.isFailed && !PendingDownloadDeletes.shared.contains($0.id) }
        }
        guard !wanted.isEmpty else { return }
        preparingDownloads.formUnion(wanted.map(\.key))
        seasonJobs.insert(id)
        let started = ContinuousClock.now
        seasonDownloadTasks[id]?.task.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                // A newer Download Season for this season owns the entry (and its rows) now.
                if self.seasonDownloadTasks[id]?.token == token {
                    self.preparingDownloads.subtract(wanted.map(\.key))
                    self.seasonJobs.remove(id)
                    self.seasonDownloadTasks[id] = nil
                }
            }
            let artwork = await self.title(for: seriesKey).flatMap { self.imageURL($0.poster, width: 120) }
            // Look a few episodes ahead side by side (each add-on search is several
            // requests), and queue them strictly in episode order.
            typealias Target = Task<Result<(MediaVariant, PlaybackResource?), Error>, Never>
            var targets: [Target?] = Array(repeating: nil, count: wanted.count)
            func lookUp(_ i: Int) {
                guard i < wanted.count, targets[i] == nil else { return }
                let key = wanted[i].key
                targets[i] = Task { [weak self] in
                    guard let self else { return .failure(CancellationError()) }
                    do { return .success(try await self.downloadTarget(for: key)) } catch { return .failure(error) }
                }
            }
            var failed: [(Episode, Error)] = []
            var heldForWiFi = 0
            for (i, ep) in wanted.enumerated() {
                for ahead in i...(i + Self.seasonLookAhead) { lookUp(ahead) }
                guard !Task.isCancelled, let target = targets[i] else { targets.forEach { $0?.cancel() }; return }
                let result = await target.value
                if Task.isCancelled { targets.forEach { $0?.cancel() }; return }
                defer { self.preparingDownloads.remove(ep.key) }
                do {
                    let (variant, resource) = try result.get()
                    let record = try self.downloads.enqueue(variant, key: ep.key, title: seriesName,
                                                            subtitle: "S\(ep.seasonNumber)·E\(ep.number)",
                                                            artworkURL: artwork, resource: resource)
                    if let mobileData { self.downloads.setMobileData(record.id, allowed: mobileData) }
                    if self.mobileDataDownloadNotice(for: record, title: seriesName) != nil, mobileData != true { heldForWiFi += 1 }
                } catch DownloadError.alreadyInQueue {
                    continue
                } catch {
                    failed.append((ep, error))
                }
            }
            Log.sources.info("Season download queued \(wanted.count - failed.count) of \(wanted.count) in \(String(describing: ContinuousClock.now - started), privacy: .public)")
            self.announceSeasonDownload(queued: wanted.count - failed.count, failed: failed, heldForWiFi: heldForWiFi,
                                        seriesKey: seriesKey, season: season, seriesName: seriesName)
            if failed.count < wanted.count { Task { _ = await EpisodeNotifications.requestPermission() } }
        }
        seasonDownloadTasks[id] = (token, task)
    }

    private func announceSeasonDownload(queued: Int, failed: [(Episode, Error)], heldForWiFi: Int,
                                        seriesKey: MediaKey, season: Int, seriesName: String) {
        if !failed.isEmpty {
            let eps = failed.map(\.0)
            let codes = eps.prefix(4).map { "E\($0.number)" }.joined(separator: ", ") + (eps.count > 4 ? "…" : "")
            let reason = UserFacingError.message(for: failed[0].1, context: .download)
            let title = queued == 0 ? "Couldn't download season \(season)"
                                    : "Couldn't download \(eps.count) of \(eps.count + queued) episodes"
            showToast(AppToast(title, message: "\(codes): \(reason)", style: .error, actionTitle: "Try Again") { [weak self] in
                self?.downloadSeason(eps, seriesKey: seriesKey, season: season, seriesName: seriesName)
            })
        } else if heldForWiFi > 0 {
            showToast(AppToast("Will download on Wi‑Fi", message: "\(seriesName) · \(heldForWiFi) episode\(heldForWiFi == 1 ? "" : "s") queued",
                               style: .info))
        }
    }

    /// Stops a season: no more episodes get queued, and every unfinished one
    /// is canceled at once, with Undo. Finished episodes stay.
    func cancelSeasonDownload(_ series: MediaKey, season: Int, seasonName: String) {
        let id = SeasonDownloadRequest.jobID(series, season)
        seasonDownloadTasks[id]?.task.cancel()
        seasonDownloadTasks[id] = nil
        seasonJobs.remove(id)
        preparingDownloads = preparingDownloads.filter { !($0.seriesKey == series && $0.episodeNumbers?.season == season) }
        let unfinished = seasonDownloads(series, season: season).filter { $0.state != .completed }
        deleteDownloadsWithUndo(unfinished, title: "\(seasonName) downloads canceled")
    }

    func pauseSeasonDownload(_ series: MediaKey, season: Int) {
        seasonDownloads(series, season: season).filter(\.isActive).forEach { downloads.pause($0.id) }
    }

    func resumeSeasonDownload(_ series: MediaKey, season: Int) {
        seasonDownloads(series, season: season).filter { $0.state == .paused || $0.isFailed }.forEach { downloads.resume($0.id) }
    }
}

enum SeasonDownloadError: LocalizedError {
    case noRelease
    var errorDescription: String? { "The add-ons didn't find a release of this." }
}
