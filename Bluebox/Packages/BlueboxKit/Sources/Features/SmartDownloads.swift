import Addons
import Domain
import Downloads
import Foundation

/// Smart Downloads (Netflix's): watch a downloaded show and the next
/// episodes download on Wi‑Fi while watched ones are deleted (with Undo),
/// so a show's downloads keep up with you. It follows every watch: the
/// player closing on a downloaded or streamed episode, and (Settings ›
/// Downloads › Follow Watching on Other Devices) progress synced from other
/// devices or Trakt. Defaults live in Settings › Downloads; each show can
/// override them in its Download Rules card (`DownloadSettings.rule(for:)`).
enum SmartDownloads {
    /// Episode size assumed for the storage budget before a release is picked.
    static let assumedEpisodeBytes: Int64 = 1_500_000_000

    /// The `keep` episodes after `key`, in order, crossing into the next season.
    static func nextEpisodes(after key: MediaKey, seasons: [SeasonSummary], keep: Int) -> [MediaKey] {
        guard let series = key.seriesKey, let start = key.episodeNumbers else { return [] }
        var (s, e) = (start.season, start.episode)
        var out: [MediaKey] = []
        while out.count < max(keep, 0), let (ns, ne) = SeriesCursor.next(after: s, e, seasons: seasons),
              let next = series.episode(season: ns, episode: ne) {
            out.append(next)
            (s, e) = (ns, ne)
        }
        return out
    }

    /// Of `wanted`, the ones to fetch: not already downloaded or on the way
    /// (a paused or failed one counts as missing), and only while the limit allows.
    static func toFetch(_ wanted: [MediaKey], existing: (MediaKey) -> [DownloadRecord],
                        usedBytes: Int64, limit: Int64?) -> [MediaKey] {
        if let limit, usedBytes >= limit { return [] }
        return missing(wanted, existing: existing)
    }

    /// Of `wanted`, the ones with no download that's done or on the way.
    static func missing(_ wanted: [MediaKey], existing: (MediaKey) -> [DownloadRecord]) -> [MediaKey] {
        wanted.filter { key in !existing(key).contains { $0.state != .paused && !$0.isFailed } }
    }

    /// Finished film downloads whose watch ended more than `afterDays` ago.
    static func filmsToDelete(_ records: [DownloadRecord], finished: [MediaKey: Date], afterDays: Int?,
                              now: Date = .now) -> [DownloadRecord] {
        guard let afterDays else { return [] }
        return records.filter { r in
            guard r.state == .completed, let key = r.mediaKey, key.isMovie, let at = finished[key] else { return false }
            return now.timeIntervalSince(at) >= Double(afterDays) * 86_400
        }
    }

    // MARK: A show

    /// What one show's downloads should become, given how far you've watched.
    struct SeriesPlan: Equatable {
        /// Episodes to download, in order.
        var fetch: [MediaKey] = []
        /// Finished downloads of episodes you've watched.
        var delete: [DownloadRecord] = []
    }

    /// The episode you're up to is the one after the last one you finished
    /// (latest by date); the `rule.keepNext` from there should be on the
    /// device, and watched ones go when the rule deletes after watching.
    /// A show you haven't finished an episode of is left alone.
    static func seriesPlan(records: [DownloadRecord], progress: [MediaKey: WatchProgress], seasons: [SeasonSummary],
                           rule: DownloadRule) -> SeriesPlan {
        guard rule.smartDownloads else { return SeriesPlan() }
        let watched = progress.values.filter { $0.isCompleted && $0.key.episodeNumbers != nil }
        guard let anchor = watched.max(by: { $0.updatedAt < $1.updatedAt })?.key else { return SeriesPlan() }
        let wanted = nextEpisodes(after: anchor, seasons: seasons, keep: rule.keepNext)
            .filter { progress[$0]?.isCompleted != true }
        let byKey = Dictionary(grouping: records.filter { $0.mediaKey != nil }, by: { $0.mediaKey! })
        var plan = SeriesPlan(fetch: missing(wanted, existing: { byKey[$0] ?? [] }))
        if rule.deleteAfterWatching {
            plan.delete = records.filter { r in
                guard r.state == .completed, let key = r.mediaKey else { return false }
                return progress[key]?.isCompleted == true && !wanted.contains(key)
            }
            .sorted { ($0.mediaKey?.episodeNumbers.map { $0.season * 10_000 + $0.episode } ?? 0)
                < ($1.mediaKey?.episodeNumbers.map { $0.season * 10_000 + $0.episode } ?? 0) }
        }
        return plan
    }

    // MARK: Storage budget

    /// Watched downloads to delete so `neededBytes` more fits under `limit`:
    /// the oldest watched first, never anything unwatched (only `watched`
    /// is offered). Empty when it already fits; nil when even deleting every
    /// watched download wouldn't make enough room (then nothing should go).
    static func makeRoom(neededBytes: Int64, usedBytes: Int64, limit: Int64?,
                         watched: [(record: DownloadRecord, watchedAt: Date)]) -> [DownloadRecord]? {
        guard let limit else { return [] }
        var over = usedBytes + neededBytes - limit
        guard over > 0 else { return [] }
        var out: [DownloadRecord] = []
        for item in watched.sorted(by: { $0.watchedAt < $1.watchedAt }) where item.record.state == .completed {
            out.append(item.record)
            over -= size(item.record)
            if over <= 0 { return out }
        }
        return nil
    }

    /// Bytes a download takes (or will once finished).
    static func size(_ r: DownloadRecord) -> Int64 { r.expectedBytes ?? r.receivedBytes }

    // MARK: Picking a release

    /// The release a download uses when Bluebox picks: the add-ons' order
    /// (best first), within the rule's quality cap and per-episode size cap,
    /// preferring the rule's audio language among the top few. Nothing fits:
    /// a download you asked for takes the best anyway; an automatic one
    /// (`strict`) waits for a release that fits.
    static func pickRelease(_ ranked: [AddonRelease], rule: DownloadRule, strict: Bool) -> AddonRelease? {
        let live = ranked.filter { $0.isDebrid || ($0.seeders ?? 1) > 0 }
        let fitting = live.filter { fits($0, rule: rule) }
        guard !fitting.isEmpty else { return strict ? nil : (live.first ?? ranked.first) }
        if let lang = rule.audioLanguage,
           let match = fitting.prefix(5).first(where: { r in r.info.languages.contains { AppModel.sameLanguage($0, lang) } }) {
            return match
        }
        return fitting.first
    }

    /// Within the quality cap and, for episodes, the size cap. Unknown sizes and resolutions pass.
    static func fits(_ r: AddonRelease, rule: DownloadRule) -> Bool {
        if let cap = rule.quality.maxResolution.flatMap(StremioSource.resolutionLevel),
           let level = StremioSource.resolutionLevel(r.resolution), level > cap { return false }
        if let max = rule.maxEpisodeBytes, let size = r.sizeBytes, size > max { return false }
        return true
    }
}

/// Keeps Smart Downloads from working on one show twice at once (the player
/// closing and a sync landing together), and folds bursts of synced
/// progress into one pass.
@MainActor
final class SmartDownloadsRunner {
    static let shared = SmartDownloadsRunner()
    var busy: Set<MediaKey> = []
    var followTask: Task<Void, Never>?
}

extension AppModel {
    /// The show's own rule (its Download Rules card), or nil to use the defaults.
    func setShowDownloadRule(_ rule: ShowDownloadRule?, for series: MediaKey) {
        var s = downloadSettings
        let raw = (series.seriesKey ?? series).rawValue
        s.showRules[raw] = rule.flatMap { $0.isEmpty ? nil : $0 }
        if rule == nil { s.smartDownloadsOff.remove(raw) }
        setDownloadSettings(s)
    }

    /// After the player closes on a finished title, downloaded or streamed:
    /// a show tops up and deletes what you've watched (Undo in the toast); a
    /// film goes now if Settings says right away, else at the next sweep.
    func downloadsAfterWatching(_ key: MediaKey) async {
        guard let progress = try? await store.progress(for: key), progress.isCompleted else { return }
        if let series = key.seriesKey {
            await followWatching(series: series, announce: true)
        } else if downloadSettings.smartDownloads, downloadSettings.allowsDeleting,
                  downloadSettings.deleteWatchedFilmsAfterDays == 0, let record = downloads.completedRecord(for: key) {
            deleteDownloadWithUndo(record, title: "Deleted after watching", message: record.title)
        }
    }

    /// Progress changed outside the player: synced from another device,
    /// Trakt, or marked watched by hand. Every show with downloads catches up
    /// (just the shows of `keys` when given), and watched films are swept.
    /// Several changes in a row run once, after a moment.
    func downloadsFollowProgress(_ keys: [MediaKey]? = nil, fromOtherDevice: Bool) {
        let settings = downloadSettings
        guard settings.smartDownloads, !fromOtherDevice || settings.followOtherDevices else { return }
        let runner = SmartDownloadsRunner.shared
        runner.followTask?.cancel()
        runner.followTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let pending = PendingDownloadDeletes.shared
            let all = self.downloads.all().filter { !pending.contains($0.id) }
            var shows = Set(all.compactMap { $0.mediaKey?.seriesKey })
            if let keys { shows.formIntersection(keys.map { $0.seriesKey ?? $0 }) }
            for series in shows.sorted(by: { $0.rawValue < $1.rawValue }) where !Task.isCancelled {
                await self.followWatching(series: series, announce: !fromOtherDevice)
            }
            if !Task.isCancelled { await self.sweepWatchedFilms() }
        }
    }

    /// One show: download the next episodes and delete the watched ones,
    /// making room under the storage limit first.
    /// - Parameter announce: you just watched here, so deletions come with Undo; synced ones get one summary toast.
    func followWatching(series: MediaKey, announce: Bool) async {
        let runner = SmartDownloadsRunner.shared
        guard runner.busy.insert(series).inserted else { return }
        defer { runner.busy.remove(series) }
        let settings = downloadSettings
        let rule = settings.rule(for: series)
        let pending = PendingDownloadDeletes.shared
        let records = downloads.all().filter { $0.mediaKey?.seriesKey == series && !pending.contains($0.id) }
        guard rule.smartDownloads, !records.isEmpty,
              let detail = try? await metadata.detail(for: series) else { return }
        let progress = Dictionary(((try? await store.progress(forSeries: series)) ?? []).map { ($0.key, $0) },
                                  uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        let plan = SmartDownloads.seriesPlan(records: records, progress: progress, seasons: detail.seasons, rule: rule)
        let deleting = Set(plan.delete.map(\.id))
        let fetched = await topUp(plan.fetch, showName: detail.title.name, freeing: deleting)
        guard !plan.delete.isEmpty else { return }
        let next = fetched.first?.episodeNumbers.map { "S\($0.season)·E\($0.episode)" }
        let nextLine = next.map { "\($0) downloading on Wi‑Fi" }
        if plan.delete.count == 1, let r = plan.delete.first {
            deleteDownloadWithUndo(r, title: announce ? "Deleted after watching" : "Deleted a watched episode",
                                   message: [r.title, r.subtitle, nextLine].compactMap { $0 }.joined(separator: " · "))
        } else {
            deleteDownloadsWithUndo(plan.delete, title: "Deleted \(plan.delete.count) watched episodes")
        }
    }

    /// Queues `wanted` as automatic downloads (Wi‑Fi, download window, the
    /// rule's caps). Over the storage limit it first deletes the oldest
    /// watched downloads, never unwatched ones; what still doesn't fit waits.
    /// Returns the episodes it asked for.
    /// - Parameter freeing: downloads already on their way out, which don't count against the limit.
    @discardableResult
    func topUp(_ wanted: [MediaKey], showName: String, freeing: Set<String> = []) async -> [MediaKey] {
        guard !wanted.isEmpty else { return [] }
        let settings = downloadSettings
        let pending = PendingDownloadDeletes.shared
        let all = downloads.all().filter { !pending.contains($0.id) && !freeing.contains($0.id) }
        var fetch = wanted
        if let limit = settings.storageLimitBytes {
            let used = all.reduce(Int64(0)) { $0 + SmartDownloads.size($1) }
            let perEpisode = averageEpisodeBytes(all.filter { $0.mediaKey?.seriesKey == wanted.first?.seriesKey })
            var watched: [(record: DownloadRecord, watchedAt: Date)] = []
            if settings.allowsDeleting {
                for r in all where r.state == .completed {
                    guard let key = r.mediaKey, let p = try? await store.progress(for: key), p.isCompleted else { continue }
                    watched.append((r, p.updatedAt))
                }
            }
            // As many as fit, after deleting the fewest old watched downloads.
            var room: [DownloadRecord] = []
            while !fetch.isEmpty {
                if let r = SmartDownloads.makeRoom(neededBytes: perEpisode * Int64(fetch.count), usedBytes: used,
                                                   limit: limit, watched: watched) { room = r; break }
                fetch.removeLast()
            }
            if !room.isEmpty {
                deleteDownloads(room)
                showToast(AppToast(room.count == 1 ? "Made room: deleted a watched download"
                                                   : "Made room: deleted \(room.count) watched downloads",
                                   message: room.map { r in r.subtitle.map { "\(r.title) \($0)" } ?? r.title }
                                       .prefix(3).joined(separator: ", "), style: .info))
            }
            if fetch.count < wanted.count {
                Log.sources.info("Smart Downloads: \(wanted.count - fetch.count) episode(s) wait for room under the storage limit")
            }
        }
        for next in fetch {
            await startDownload(key: next, title: showName,
                                subtitle: next.episodeNumbers.map { "S\($0.season)·E\($0.episode)" }, automatic: true)
        }
        return fetch
    }

    /// Typical episode size for a show's downloads, for the budget before a release is picked.
    private func averageEpisodeBytes(_ records: [DownloadRecord]) -> Int64 {
        let sizes = records.compactMap(\.expectedBytes).filter { $0 > 0 }
        guard !sizes.isEmpty else { return SmartDownloads.assumedEpisodeBytes }
        return sizes.reduce(0, +) / Int64(sizes.count)
    }


    /// Deletes finished films watched longer ago than Settings › Downloads
    /// allows. Run when the queue starts and after synced progress.
    func sweepWatchedFilms() async {
        let settings = downloadSettings
        guard settings.smartDownloads, settings.allowsDeleting, let days = settings.deleteWatchedFilmsAfterDays else { return }
        var finished: [MediaKey: Date] = [:]
        for r in downloads.all() where r.state == .completed {
            guard let key = r.mediaKey, key.isMovie, let p = try? await store.progress(for: key), p.isCompleted else { continue }
            finished[key] = p.updatedAt
        }
        let pending = PendingDownloadDeletes.shared
        let old = SmartDownloads.filmsToDelete(downloads.all(), finished: finished, afterDays: days)
            .filter { !pending.contains($0.id) }
        guard !old.isEmpty else { return }
        deleteDownloads(old)
        showToast(AppToast(old.count == 1 ? "Removed a watched film" : "Removed \(old.count) watched films",
                           message: old.map(\.title).prefix(3).joined(separator: ", "), style: .info))
    }
}
