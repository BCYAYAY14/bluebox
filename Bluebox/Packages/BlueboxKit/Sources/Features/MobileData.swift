import Addons
import Domain
import Downloads
import Foundation
import Playback
import TorrentStreaming

// Mobile data: Settings › Mobile Data, the rules Play and downloads follow on
// mobile data, and the monthly counter. iPhone and iPad only; on the Mac
// `AppSettings.isOnMobileData` is always false, so none of this applies.
// Low Data Mode and expensive networks (a phone's hotspot) count as mobile data.

/// Settings › Mobile Data. Stored as JSON under `PreferenceKey.mobileData`;
/// missing fields take their defaults.
public struct MobileDataSettings: Codable, Sendable, Equatable {
    public enum Streaming: String, Codable, CaseIterable, Identifiable, Sendable {
        case allow, askFirst, never
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .allow: "Allow"
            case .askFirst: "Ask First"
            case .never: "Never"
            }
        }
    }

    public enum Quality: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Up to 720p, the smallest healthy release first.
        case dataSaver
        /// Up to 1080p.
        case automatic
        case best
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .dataSaver: "Data Saver"
            case .automatic: "Automatic"
            case .best: "Best Available"
            }
        }
        /// The highest resolution played on mobile data, or nil for no cap.
        public var cap: String? {
            switch self {
            case .dataSaver: "720p"
            case .automatic: "1080p"
            case .best: nil
            }
        }
    }

    public enum Torrents: String, Codable, CaseIterable, Identifiable, Sendable {
        case allow, debridOnly, never
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .allow: "Allow"
            case .debridOnly: "Debrid Only"
            case .never: "Never"
            }
        }
    }

    public var streaming: Streaming = .askFirst
    public var quality: Quality = .dataSaver
    public var torrents: Torrents = .debridOnly
    /// Seeding while on mobile data.
    public var allowUpload = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MobileDataSettings()
        streaming = (try? c.decodeIfPresent(Streaming.self, forKey: .streaming)) ?? d.streaming
        quality = (try? c.decodeIfPresent(Quality.self, forKey: .quality)) ?? d.quality
        torrents = (try? c.decodeIfPresent(Torrents.self, forKey: .torrents)) ?? d.torrents
        allowUpload = (try? c.decodeIfPresent(Bool.self, forKey: .allowUpload)) ?? d.allowUpload
    }

    /// How releases are ranked on mobile data. `dataSaver` forces Data Saver
    /// ("Play in Data Saver").
    public func ranking(dataSaver: Bool = false) -> MobileDataRanking {
        let q = dataSaver ? .dataSaver : quality
        return MobileDataRanking(maxResolution: q.cap, preferSmallest: q == .dataSaver,
                                 allowsTorrents: torrents == .allow, allowsDebrid: torrents != .never)
    }
}

/// Bytes Bluebox used on mobile data in one calendar month.
public struct MobileDataUsage: Codable, Sendable, Equatable {
    /// "2026-10".
    public var month: String
    public var streamingBytes: Int64 = 0
    public var downloadBytes: Int64 = 0
    /// When counting started (the 1st, or the last reset).
    public var since: Date

    public init(now: Date = .now) {
        month = Self.month(of: now)
        since = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
    }

    public var totalBytes: Int64 { streamingBytes + downloadBytes }

    /// This value, or a fresh count if the month has changed.
    public func current(now: Date = .now) -> MobileDataUsage {
        Self.month(of: now) == month ? self : MobileDataUsage(now: now)
    }

    static func month(of date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

/// Settings › Picture: brightness, contrast and saturation every video starts with.
public struct PictureDefaults: Codable, Sendable, Equatable {
    /// −1…1, 0 = unchanged.
    public var brightness = 0.0
    /// 0…2, 1 = unchanged.
    public var contrast = 1.0
    /// 0…2, 1 = unchanged.
    public var saturation = 1.0

    public init() {}
    public var isDefault: Bool { self == PictureDefaults() }

    public var adjustments: VideoAdjustments {
        var a = VideoAdjustments()
        a.brightness = brightness; a.contrast = contrast; a.saturation = saturation
        a.clamp()
        return a
    }
}

/// "You're on mobile data": what's about to play and what it would cost.
public struct MobileDataPrompt: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let title: String
    public let subtitle: String?
    /// "1080p", or nil when unknown.
    public let quality: String?
    public let bytes: Int64?
    public let dataSaverQuality: String?
    public let dataSaverBytes: Int64?
    public let minutes: Int?
    /// Offer "Download on Wi‑Fi Later" (the source allows downloading).
    public let canDownload: Bool
}

public enum MobileDataChoice: Sendable {
    case play, playInDataSaver, downloadLater, cancel
}

// MARK: - AppModel

extension AppModel {
    /// Wires Settings › Mobile Data to the network monitor, the add-on ranking,
    /// the download queue and the monthly counter. Called once from `init`.
    func startMobileData() {
        settings.onNetworkChange = { [weak self] old, new in self?.networkChangedForMobileData(old: old, new: new) }
        settings.onMobileDataChange = { [weak self] in self?.applyMobileDataRules() }
        applyMobileDataRules()
        let monitor = MobileDataMeter()
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                await self.meter(monitor)
            }
        }
    }

    /// Pushes the current rules to the add-ons (ranking) and the download queue.
    func applyMobileDataRules() {
        let mobile = settings.isOnMobileData
        let rules = settings.mobileData
        let ranking = mobile ? rules.ranking(dataSaver: settings.dataSaverForThisPlayback) : nil
        let addons = addons
        Task { await addons.setMobileData(ranking) }
        downloads.setTorrentsAllowedOnMobileData(rules.torrents == .allow)
        TorrentStreamer.setUploadOnMobileData(rules.allowUpload)
    }

    private func networkChangedForMobileData(old: NetworkPathInfo, new: NetworkPathInfo) {
        applyMobileDataRules()
        guard settings.mobileDataApplies else { return }
        if new.isMobileData, !old.isMobileData, activePlayer != nil, isStreamingRemotely {
            settings.networkSwitchedToCellularDuringPlayback = true
        } else if !new.isMobileData {
            settings.networkSwitchedToCellularDuringPlayback = false
        }
    }

    // MARK: Hooks for the player

    /// True when Wi‑Fi dropped to mobile data while a stream plays. The player
    /// shows "Now using mobile data" with Continue, Lower Quality and Pause.
    public var networkSwitchedToCellularDuringPlayback: Bool { settings.networkSwitchedToCellularDuringPlayback }

    /// Continue (or Pause, after pausing): hides the banner for this stream.
    public func dismissMobileDataBanner() {
        settings.networkSwitchedToCellularDuringPlayback = false
    }

    /// Lower Quality: plays the same title again in Data Saver from where it was.
    /// The player closes and reopens on the smaller release.
    public func lowerQualityForMobileData() async {
        settings.networkSwitchedToCellularDuringPlayback = false
        guard let session = activePlayer, let item = session.item else { return }
        await closePlayer()
        settings.dataSaverForThisPlayback = true
        applyMobileDataRules()
        await play(item, resume: true)
    }

    // MARK: Play

    /// Called by `play` before a remote stream resolves. Applies Settings ›
    /// Mobile Data: torrent rules, and "Ask first" (the sheet). Returns false
    /// when playback shouldn't go ahead.
    func mobileDataAllowsPlaying(_ item: NowPlayingItem, variant: MediaVariant) async -> Bool {
        settings.dataSaverForThisPlayback = false
        defer { applyMobileDataRules() }
        guard settings.isOnMobileData, variant.location == .remote else { return true }
        let rules = settings.mobileData
        if variant.sourceID == addons.id {
            let pickedTorrent = DownloadRecord.infoHash(fromVariantID: variant.id) != nil
            let hasDebrid = addonSettings.debrid.requiresKey && !debridKey.trimmingCharacters(in: .whitespaces).isEmpty
            switch rules.torrents {
            case .never:
                alert = AppAlert(title: "Torrents are off on mobile data",
                                 message: "Connect to Wi‑Fi to play “\(item.title)”, or allow torrents in Settings › Mobile Data.")
                return false
            case .debridOnly where pickedTorrent || !hasDebrid:
                alert = AppAlert(title: "Peer-to-peer is off on mobile data",
                                 message: hasDebrid
                                    ? "This release streams peer to peer. Pick a debrid release, connect to Wi‑Fi, or allow torrents in Settings › Mobile Data."
                                    : "Mobile data plays debrid links only, and no debrid service is set up. Connect to Wi‑Fi, or allow torrents in Settings › Mobile Data.")
                return false
            default:
                break
            }
        }
        guard rules.streaming == .askFirst, !settings.skipsMobileDataPrompt else { return true }
        let prompt = await mobileDataPrompt(for: item, variant: variant)
        let choice = await withCheckedContinuation { (answer: CheckedContinuation<MobileDataChoice, Never>) in
            settings.promptAnswer?.resume(returning: .cancel)
            settings.promptAnswer = answer
            settings.mobileDataPrompt = prompt
        }
        switch choice {
        case .play:
            return true
        case .playInDataSaver:
            settings.dataSaverForThisPlayback = true
            return true
        case .downloadLater:
            await downloadOnWiFiLater(item)
            return false
        case .cancel:
            return false
        }
    }

    /// The sheet's answer (or a swipe down, which is Cancel).
    public func answerMobileDataPrompt(_ choice: MobileDataChoice, dontAskAgain: Bool = false) {
        if dontAskAgain, choice == .play || choice == .playInDataSaver { settings.skipsMobileDataPrompt = true }
        settings.mobileDataPrompt = nil
        let answer = settings.promptAnswer
        settings.promptAnswer = nil
        answer?.resume(returning: choice)
    }

    private func mobileDataPrompt(for item: NowPlayingItem, variant: MediaVariant) async -> MobileDataPrompt {
        let rules = settings.mobileData
        var quality = variant.resolution, bytes = variant.sizeBytes
        var saverQuality: String?, saverBytes: Int64?
        if variant.sourceID == addons.id, variant.id == StremioSource.bestReleaseID {
            let addons = addons
            let key = item.key
            let (normal, saver) = await Self.withTimeout(seconds: 6) {
                async let a = try? addons.bestRelease(for: key, mobileData: rules.ranking())
                async let b = try? addons.bestRelease(for: key, mobileData: rules.ranking(dataSaver: true))
                return await (a, b)
            } ?? (nil, nil)
            quality = normal?.resolution ?? quality
            bytes = normal?.sizeBytes ?? bytes
            saverQuality = saver?.resolution
            saverBytes = saver?.sizeBytes
        }
        let minutes = await runtimeMinutes(item.key)
        return MobileDataPrompt(title: item.title, subtitle: item.subtitle, quality: quality, bytes: bytes,
                                dataSaverQuality: saverQuality, dataSaverBytes: saverBytes, minutes: minutes,
                                canDownload: variant.isDownloadable)
    }

    private func runtimeMinutes(_ key: MediaKey) async -> Int? {
        guard let detail = try? await metadata.detail(for: key.seriesKey ?? key) else { return nil }
        if let numbers = key.episodeNumbers,
           let season = try? await metadata.season(numbers.season, of: key.seriesKey ?? key),
           let episode = season.episodes.first(where: { $0.number == numbers.episode }), let m = episode.runtimeMinutes {
            return m
        }
        return detail.runtimeMinutes
    }

    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// "Download on Wi‑Fi Later": queues the title, held for Wi‑Fi even if Wi‑Fi Only is off.
    func downloadOnWiFiLater(_ item: NowPlayingItem) async {
        let before = Set(downloads.records(for: item.key).map(\.id))
        await startDownload(key: item.key, title: item.title, subtitle: item.subtitle)
        guard let record = downloads.records(for: item.key).first(where: { !before.contains($0.id) }) else { return }
        downloads.setMobileData(record.id, allowed: false)
        showToast(AppToast("Will download on Wi‑Fi", message: "“\(item.title)” starts when you're on Wi‑Fi.", style: .info))
    }

    // MARK: Downloads

    /// "Will start on Wi‑Fi", with Download Now, for a download queued on
    /// mobile data while Wi‑Fi Only (or the torrent rule) holds it back.
    func mobileDataDownloadNotice(for record: DownloadRecord, title: String) -> AppToast? {
        guard settings.isOnMobileData, record.allowsMobileData == nil else { return nil }
        let heldForTorrent = record.isTorrent && settings.mobileData.torrents != .allow
        guard downloadSettings.wifiOnly || heldForTorrent else { return nil }
        let id = record.id
        let why = downloadSettings.wifiOnly ? "Downloads are set to Wi‑Fi only." : "Torrents don't download on mobile data."
        return AppToast("Will start on Wi‑Fi", message: "“\(title)” is queued. \(why)", style: .info,
                        actionTitle: "Download Now") { [weak self] in
            self?.downloads.setMobileData(id, allowed: true)
            self?.showToast(AppToast("Downloading on mobile data", message: "“\(title)”", style: .success))
        }
    }

    // MARK: Counting

    /// Resets Data Used This Month.
    public func resetMobileDataUsage() {
        settings.dataUsage = MobileDataUsage()
    }

    /// True while the player streams something from the network (not a file on this device).
    var isStreamingRemotely: Bool {
        guard let variant = settings.streamingVariant else { return false }
        return variant.location == .remote
    }

    /// Notes what's streaming, for the counter and the network-switch banner.
    func noteStreaming(_ variant: MediaVariant) {
        settings.streamingVariant = variant
    }

    /// Adds what was used on mobile data since the last sample: torrent streams
    /// (libtorrent's bytes in and out), other streams (estimated from how far
    /// the player has buffered and the file's size), and downloads (bytes received).
    fileprivate func meter(_ meter: MobileDataMeter) async {
        let mobile = settings.isOnMobileData
        // On Wi‑Fi with nothing playing there's nothing to count: skip the
        // walk over every download (this runs every 2 s for the app's life).
        // Forgetting the baselines means the first sample on mobile data
        // starts from zero instead of counting what came in over Wi‑Fi.
        if !mobile, activePlayer == nil, settings.streamingVariant == nil {
            meter.downloads = [:]
            meter.torrentBytes = nil
            meter.bufferedUntil = nil
            if settings.networkSwitchedToCellularDuringPlayback { settings.networkSwitchedToCellularDuringPlayback = false }
            if settings.dataSaverForThisPlayback { settings.dataSaverForThisPlayback = false; applyMobileDataRules() }
            return
        }
        var streamed: Int64 = 0
        var downloaded: Int64 = 0

        // Downloads: growth of each record's received bytes.
        var now: [String: Int64] = [:]
        for r in downloads.all() where r.state == .downloading || r.state == .queued { now[r.id] = r.receivedBytes }
        for (id, bytes) in now { downloaded += max(0, bytes - (meter.downloads[id] ?? bytes)) }
        meter.downloads = now

        // Streams.
        if let session = activePlayer, let variant = settings.streamingVariant, variant.location == .remote {
            if variant.sourceID == addons.id, DownloadRecord.infoHash(fromVariantID: variant.id) != nil {
                let stats = await addons.streamStats()
                let total = stats.downloadedBytes + stats.uploadedBytes
                streamed += max(0, total - (meter.torrentBytes ?? total))
                meter.torrentBytes = total
            } else if let size = variant.sizeBytes, let duration = session.snapshot.duration, duration > 0 {
                let buffered = max(session.snapshot.bufferedUntil, session.snapshot.position)
                let last = meter.bufferedUntil ?? buffered
                if buffered > last { streamed += Int64(Double(size) * (buffered - last) / duration) }
                meter.bufferedUntil = max(buffered, last)
            }
        } else {
            meter.torrentBytes = nil
            meter.bufferedUntil = nil
            if activePlayer == nil {
                settings.streamingVariant = nil
                if settings.dataSaverForThisPlayback { settings.dataSaverForThisPlayback = false; applyMobileDataRules() }
                settings.networkSwitchedToCellularDuringPlayback = false
            }
        }

        var usage = settings.dataUsage.current()
        guard mobile, streamed + downloaded > 0 else {
            if usage != settings.dataUsage { settings.dataUsage = usage }
            return
        }
        usage.streamingBytes += streamed
        usage.downloadBytes += downloaded
        settings.dataUsage = usage
    }
}

/// The last values the counter saw.
@MainActor
private final class MobileDataMeter {
    var downloads: [String: Int64] = [:]
    var torrentBytes: Int64?
    var bufferedUntil: TimeInterval?
}
