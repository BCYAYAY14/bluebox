import Addons
import Domain
import Downloads
import Foundation
import TorrentStreaming

// Season packs: when a season is downloaded, an add-on often offers the
// whole season as one torrent. The season bar offers it beside Download
// Season, with both sizes. Each episode becomes its own download of the one
// torrent (libtorrent shares it; `TorrentDownloader` picks each episode's
// file by its name), so the queue, Undo and Smart Downloads work as usual.

enum SeasonPacks {
    /// A torrent of `season` as a whole: a name with the season ("S02",
    /// "Season 2", "S01-S04") and no episode. Add-ons put the torrent's name
    /// on the first line and the episode's file under it, so each line counts.
    static func isPack(_ r: AddonRelease, season: Int) -> Bool {
        guard r.infoHash != nil, r.url == nil else { return false }
        let lines = [r.name.replacingOccurrences(of: "\n", with: " ")] + r.title.split(whereSeparator: \.isNewline).map(String.init)
        return lines.contains { isPackName($0, season: season) }
    }

    static func isPackName(_ line: String, season: Int) -> Bool {
        let s = String(season)
        let episode = #"(?i)(?<![a-z0-9])s0*\#(s)[ ._-]?e\d{1,3}|(?<![0-9])0*\#(s)x\d{2,3}(?![0-9])"#
        if line.range(of: episode, options: .regularExpression) != nil { return false }
        let patterns = [
            #"(?i)(?<![a-z0-9])s0*\#(s)(?![0-9e])"#,                // S02, S2
            #"(?i)(?<![a-z0-9])season[ ._-]?0*\#(s)(?![0-9])"#,     // Season 2
            #"(?i)(?<![a-z0-9])s0*(\d{1,2})[ ._-]*-[ ._-]*s?0*(\d{1,2})(?![0-9e])"#,  // S01-S04
        ]
        for (i, p) in patterns.enumerated() {
            guard let range = line.range(of: p, options: .regularExpression) else { continue }
            if i < 2 { return true }
            // A range of seasons: this one has to be inside it.
            let nums = line[range].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count >= 2, (nums[0]...max(nums[0], nums[1])).contains(season) { return true }
        }
        return false
    }

    /// The pack to offer: the best-ranked healthy torrent pack within the rule.
    static func best(_ ranked: [AddonRelease], season: Int, rule: DownloadRule) -> AddonRelease? {
        ranked.first { r in
            isPack(r, season: season) && (r.seeders ?? 0) >= ReleaseRanker.healthySeeders
                && (rule.quality.maxResolution.flatMap(StremioSource.resolutionLevel).map { cap in
                    (StremioSource.resolutionLevel(r.resolution) ?? 0) <= cap } ?? true)
        }
    }

    /// One episode's download of a pack: "<info hash>:<negative number>".
    /// The negative index means "no file index, pick by episode", and keeps
    /// each episode's download ID apart.
    static func variantID(hash: String, season: Int, episode: Int) -> String {
        "\(hash.lowercased()):-\(season * 1_000 + episode + 1)"
    }
}

/// The season bar's pack offer: "Season pack · 1080p · 120 seeders", about
/// how big it is against downloading the episodes one by one.
struct SeasonPackOffer: Equatable, Identifiable {
    let release: AddonRelease
    let episodes: [Episode]
    /// The pack for these episodes, estimated from its episode file's size.
    let packBytes: Int64?
    /// What the episodes would take one by one (the page's estimate).
    let separateBytes: Int64
    var id: String { release.id }

    var label: String {
        ["Season pack", release.resolution, release.info.source?.title,
         release.seeders.map { "\($0) seeders" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// "About 9.1 GB, against 10.4 GB one by one."
    var comparison: String {
        let separate = SeasonActionPlan.sizeLabel(separateBytes)
        guard let packBytes else { return "Separate episodes: \(separate)" }
        return "\(SeasonActionPlan.sizeLabel(packBytes).capitalizedFirst), against \(separate) one by one"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension AppModel {
    /// A season pack for `episodes` of one season, from the add-ons' answer
    /// for the first of them (cached, and shared with Play), if one is healthy.
    func seasonPackOffer(series: MediaKey, season: Int, episodes: [Episode], separateBytes: Int64) async -> SeasonPackOffer? {
        guard episodes.count >= 2, addonSettings.isEnabled, TorrentStreamer.isAvailable, let first = episodes.first,
              let ranked = try? await addons.releases(for: first.key),
              let pack = SeasonPacks.best(ranked, season: season, rule: downloadSettings.rule(for: series)) else { return nil }
        // Add-ons give the requested episode's file size; the pack is about that many times over.
        let packBytes = pack.sizeBytes.map { $0 * Int64(episodes.count) }
        return SeasonPackOffer(release: pack, episodes: episodes, packBytes: packBytes, separateBytes: separateBytes)
    }

    /// Queues every episode from the one pack torrent, in order.
    func downloadSeasonPack(_ offer: SeasonPackOffer, seriesKey: MediaKey, seriesName: String) async {
        guard let hash = offer.release.infoHash else { return }
        let artwork = await title(for: seriesKey).flatMap { imageURL($0.poster, width: 120) }
        var queued = 0
        for ep in offer.episodes {
            if downloads.records(for: ep.key).contains(where: { !$0.isFailed && !PendingDownloadDeletes.shared.contains($0.id) }) { continue }
            let variant = MediaVariant(id: SeasonPacks.variantID(hash: hash, season: ep.seasonNumber, episode: ep.number),
                                       sourceID: addons.id, mediaKey: ep.key, displayName: offer.release.fileName,
                                       container: offer.release.container ?? "mkv", resolution: offer.release.resolution,
                                       sizeBytes: offer.release.sizeBytes, location: .remote, isDownloadable: true)
            do {
                try downloads.enqueue(variant, key: ep.key, title: seriesName, subtitle: "S\(ep.seasonNumber)·E\(ep.number)",
                                      artworkURL: artwork)
                queued += 1
            } catch DownloadError.alreadyInQueue {
                continue
            } catch {
                report(error, title: "Couldn't download the season pack", context: .download)
                return
            }
        }
        if queued > 0 {
            showToast(AppToast("Downloading the season pack", message: "\(seriesName) · \(queued) episode\(queued == 1 ? "" : "s") from one torrent",
                               style: .success))
            Task { _ = await EpisodeNotifications.requestPermission() }
        }
    }
}
