//
//  ReleaseRanker.swift
//  Bluebox
//
//  Written for Bluebox from public documentation (Apple's VideoToolbox and
//  AVFoundation references for what a device decodes and displays). Orders
//  releases from every add-on the way Play tries them, merges duplicates,
//  and remembers the group chosen for a show.
//

import AVFoundation
import Foundation
import VideoToolbox

// MARK: - Device

/// What this device decodes in hardware and what its screen shows.
public struct DeviceProfile: Sendable, Equatable {
    public var decodesHEVC: Bool
    public var decodesAV1: Bool
    public var displaysHDR: Bool
    public var displaysDolbyVision: Bool

    public init(decodesHEVC: Bool, decodesAV1: Bool, displaysHDR: Bool, displaysDolbyVision: Bool) {
        self.decodesHEVC = decodesHEVC; self.decodesAV1 = decodesAV1
        self.displaysHDR = displaysHDR; self.displaysDolbyVision = displaysDolbyVision
    }

    /// A recent Apple device on an SDR screen: HEVC yes, AV1 no, no HDR.
    public static let typical = DeviceProfile(decodesHEVC: true, decodesAV1: false, displaysHDR: false, displaysDolbyVision: false)

    /// Asks VideoToolbox and AVFoundation. HDR depends on the current screen
    /// (a Mac's external display, Low Power Mode), so ask again when it changes.
    @MainActor public static func current() -> DeviceProfile {
        let hdr = AVPlayer.eligibleForHDRPlayback
        return DeviceProfile(decodesHEVC: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                             decodesAV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
                             displaysHDR: hdr,
                             // Apple's HDR screens all show Dolby Vision; it needs the HEVC decoder.
                             displaysDolbyVision: hdr && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))
    }
}

// MARK: - Show memory

/// The release last chosen for a show, so the next episode prefers the same kind.
public struct ShowChoice: Codable, Sendable, Equatable {
    public var group: String?
    public var resolution: String?
    public var bingeGroup: String?
    public var addonID: String?
    public var chosenAt: Date

    public init(group: String?, resolution: String?, bingeGroup: String?, addonID: String?, chosenAt: Date = Date()) {
        self.group = group; self.resolution = resolution; self.bingeGroup = bingeGroup
        self.addonID = addonID; self.chosenAt = chosenAt
    }

    public init(_ release: AddonRelease, at date: Date = Date()) {
        self.init(group: release.group, resolution: release.resolution, bingeGroup: release.bingeGroup,
                  addonID: release.addonID, chosenAt: date)
    }

    /// Worth remembering: says something more specific than "1080p".
    public var isUseful: Bool { group != nil || bingeGroup != nil }
}

/// How closely a release matches a show's remembered choice.
public enum ChoiceMatch: Int, Comparable, Sendable {
    /// The add-on's binge group: the same pack, or the same kind of release by its own reckoning.
    case bingeGroup = 0
    /// Same release group at the same resolution.
    case groupAndResolution = 1
    /// Same group, another resolution.
    case group = 2
    case none = 3

    public static func < (a: ChoiceMatch, b: ChoiceMatch) -> Bool { a.rawValue < b.rawValue }

    /// Shown as "Same group" in the release picker.
    public var isMatch: Bool { self != .none }

    public static func of(_ release: AddonRelease, _ choice: ShowChoice?) -> ChoiceMatch {
        guard let choice else { return .none }
        if let binge = choice.bingeGroup, let mine = release.bingeGroup, binge == mine,
           release.addonID == nil || choice.addonID == nil || release.addonID == choice.addonID {
            // A binge group that's just the info hash only matches the same pack; that's fine.
            return .bingeGroup
        }
        guard let group = choice.group, let mine = release.group,
              group.caseInsensitiveCompare(mine) == .orderedSame else { return .none }
        return release.resolution == choice.resolution ? .groupAndResolution : .group
    }
}

// MARK: - Ranking

/// Everything ranking depends on besides the releases.
public struct RankingContext: Sendable {
    public var preferredResolution: String?
    public var sort: ReleaseSort
    public var hiddenQualities: Set<QualityFilter>
    public var canStreamTorrents: Bool
    public var mobileData: MobileDataRanking?
    public var device: DeviceProfile
    /// ISO 639-1, from Settings › Playback › Audio Language.
    public var audioLanguage: String?
    /// The movie's or episode's length, for judging size per minute.
    public var runtimeMinutes: Double?
    public var showChoice: ShowChoice?
    /// Add-on IDs in your order.
    public var addonOrder: [String]

    public init(preferredResolution: String? = "1080p", sort: ReleaseSort = .seeders, hiddenQualities: Set<QualityFilter> = [],
                canStreamTorrents: Bool = true, mobileData: MobileDataRanking? = nil, device: DeviceProfile = .typical,
                audioLanguage: String? = nil, runtimeMinutes: Double? = nil, showChoice: ShowChoice? = nil,
                addonOrder: [String] = []) {
        self.preferredResolution = preferredResolution; self.sort = sort; self.hiddenQualities = hiddenQualities
        self.canStreamTorrents = canStreamTorrents; self.mobileData = mobileData; self.device = device
        self.audioLanguage = audioLanguage; self.runtimeMinutes = runtimeMinutes; self.showChoice = showChoice
        self.addonOrder = addonOrder
    }

    public init(settings: AddonSettings, canStreamTorrents: Bool, mobileData: MobileDataRanking? = nil,
                device: DeviceProfile = .typical, audioLanguage: String? = nil, runtimeMinutes: Double? = nil,
                showChoice: ShowChoice? = nil) {
        self.init(preferredResolution: settings.preferredResolution, sort: settings.sort,
                  hiddenQualities: settings.hiddenQualities, canStreamTorrents: canStreamTorrents, mobileData: mobileData,
                  device: device, audioLanguage: audioLanguage, runtimeMinutes: runtimeMinutes,
                  showChoice: settings.rememberShowChoices ? showChoice : nil, addonOrder: settings.addons.map(\.id))
    }
}

/// Orders releases best first. Each release gets a key; keys compare field by
/// field, so an earlier field always outweighs every later one:
///
/// 1. Mobile data: releases above the quality cap go last.
/// 2. Availability: links that start at once (cached debrid, direct), then
///    healthy torrents, thin or unknown swarms, uncached debrid links, dead torrents.
/// 3. The show's remembered choice (same binge group, then group and resolution).
/// 4. Resolution: the preferred one, then one step down, then up.
/// 5. Size per minute of runtime inside a sane band for the resolution
///    (Data Saver: smallest first instead).
/// 6. A codec this device decodes in hardware.
/// 7. HDR and Dolby Vision only where the screen shows them; else SDR first.
/// 8. Audio in your language.
/// 9. Seeders (when sorting by seeders), then add-on order, then the add-on's own order.
///
/// Hidden qualities, and releases the device or mobile data rules can't
/// play, are dropped.
public enum ReleaseRanker {
    /// Seeders at or above this count as a healthy swarm.
    public static let healthySeeders = 5

    public struct Key: Comparable, Sendable, CustomStringConvertible {
        public var aboveCap: Int
        public var availability: Int
        public var choice: Int
        public var resolution: Double
        public var size: Double
        public var codec: Int
        public var dynamicRange: Int
        public var language: Int
        public var seeders: Int
        public var addon: Int
        public var position: Int

        var fields: [Double] {
            [Double(aboveCap), Double(availability), Double(choice), resolution, size, Double(codec),
             Double(dynamicRange), Double(language), Double(seeders), Double(addon), Double(position)]
        }

        public static func < (a: Key, b: Key) -> Bool {
            for (x, y) in zip(a.fields, b.fields) where x != y { return x < y }
            return false
        }

        public var description: String {
            "cap \(aboveCap) avail \(availability) choice \(choice) res \(resolution) size \(size) codec \(codec) "
                + "range \(dynamicRange) lang \(language) seeders \(seeders) addon \(addon) pos \(position)"
        }
    }

    public static func rank(_ releases: [AddonRelease], context: RankingContext) -> [AddonRelease] {
        let usable = releases.filter { isAllowed($0, context: context) }
        return usable.enumerated()
            .map { (key: key(for: $0.element, position: $0.offset, context: context), release: $0.element) }
            .sorted { $0.key < $1.key }
            .map(\.release)
    }

    public static func isAllowed(_ r: AddonRelease, context: RankingContext) -> Bool {
        if !r.isDebrid, !context.canStreamTorrents || r.magnet == nil { return false }
        if let mobile = context.mobileData, !mobile.allows(r) { return false }
        if context.hiddenQualities.contains(where: { $0.matches(r.info) }) { return false }
        return true
    }

    public static func key(for r: AddonRelease, position: Int = 0, context: RankingContext) -> Key {
        let preferredLevel: Int? = {
            var preferred = context.preferredResolution.flatMap(StremioSource.resolutionLevel)
            if let cap = context.mobileData?.maxResolution.flatMap(StremioSource.resolutionLevel) {
                preferred = min(preferred ?? cap, cap)
            }
            return preferred
        }()
        let dataSaver = context.mobileData?.preferSmallest == true
        return Key(
            aboveCap: context.mobileData?.isAboveCap(r) == true ? 1 : 0,
            availability: availability(r),
            choice: ChoiceMatch.of(r, context.showChoice).rawValue,
            resolution: resolutionDistance(r, preferred: preferredLevel),
            size: dataSaver ? Double(r.sizeBytes ?? .max) / 1e12 : Double(sizeFit(r, runtimeMinutes: context.runtimeMinutes).rawValue),
            codec: codecCost(r.info, device: context.device),
            dynamicRange: dynamicRangeCost(r.info, device: context.device),
            language: languageCost(r.info, preferred: context.audioLanguage),
            seeders: context.sort == .seeders && !r.isDebrid ? -seederBucket(r.seeders) : 0,
            addon: r.addonID.flatMap { context.addonOrder.firstIndex(of: $0) } ?? context.addonOrder.count,
            position: position)
    }

    /// 0 starts at once, 1 healthy torrent, 2 thin or unknown swarm,
    /// 3 debrid link the service must fetch first, 4 nobody seeds.
    static func availability(_ r: AddonRelease) -> Int {
        if r.isDebrid { return r.cache == .uncached ? 3 : 0 }
        guard let seeders = r.seeders else { return 2 }
        if seeders == 0 { return 4 }
        return seeders >= healthySeeders ? 1 : 2
    }

    /// 0 at the preferred resolution; a step down costs 1, a step up 1.25
    /// (smaller files start sooner). Unknown resolutions sit at 2.5.
    static func resolutionDistance(_ r: AddonRelease, preferred: Int?) -> Double {
        guard let preferred else {
            // Best available: highest first.
            return Double(5 - (StremioSource.resolutionLevel(r.resolution) ?? 2))
        }
        guard let level = StremioSource.resolutionLevel(r.resolution) else { return 2.5 }
        let d = level - preferred
        return d > 0 ? Double(d) + 0.25 : Double(-d)
    }

    public enum SizeFit: Int, Sendable {
        case good = 0, unknown = 1, small = 2, large = 3
    }

    /// Megabytes per minute that stream well at each resolution: below the
    /// band the picture suffers; above it (remuxes) a swarm or connection
    /// struggles to keep up.
    public static func sizeBand(resolution: String?) -> ClosedRange<Double> {
        switch StremioSource.resolutionLevel(resolution) {
        case 1: 2...30          // 480p: about 0.3–4 Mbps
        case 2: 5...60          // 720p: 0.7–8 Mbps
        case 3: 9...140         // 1080p: 1.2–19 Mbps
        case 4: 20...420        // 4K: 2.7–56 Mbps
        default: 3...140
        }
    }

    public static func sizeFit(_ r: AddonRelease, runtimeMinutes: Double?) -> SizeFit {
        guard let bytes = r.sizeBytes, bytes > 0 else { return .unknown }
        let minutes = max(runtimeMinutes ?? 100, 1)
        let mbPerMinute = Double(bytes) / 1_048_576 / minutes
        let band = sizeBand(resolution: r.resolution)
        if mbPerMinute < band.lowerBound { return .small }
        if mbPerMinute > band.upperBound { return .large }
        return .good
    }

    /// 0: decoded in hardware (or unknown), 1: software decode or an old codec.
    static func codecCost(_ info: ReleaseInfo, device: DeviceProfile) -> Int {
        switch info.videoCodec {
        case nil, .h264: 0
        case .hevc: device.decodesHEVC ? 0 : 1
        case .av1: device.decodesAV1 ? 0 : 1
        case .vp9, .xvid, .mpeg2, .vc1: 1
        }
    }

    /// On an HDR screen, HDR is fine (Dolby Vision without an HDR10 base only
    /// where DV is decoded); elsewhere SDR first, HDR10 next, DV-only last.
    static func dynamicRangeCost(_ info: ReleaseInfo, device: DeviceProfile) -> Int {
        if device.displaysHDR {
            return info.isDolbyVisionOnly && !device.displaysDolbyVision ? 1 : 0
        }
        if !info.isHDR { return 0 }
        return info.isDolbyVisionOnly ? 2 : 1
    }

    /// 0: in your language (or no preference), 1: unknown or multi-language, 2: other languages only.
    static func languageCost(_ info: ReleaseInfo, preferred: String?) -> Int {
        guard let preferred = preferred.map(baseLanguage), !preferred.isEmpty else { return 0 }
        if info.languages.contains(preferred) { return 0 }
        let spoken = info.languages.filter { $0 != "multi" }
        if spoken.isEmpty { return 1 }
        return info.languages.contains("multi") ? 1 : 2
    }

    /// "en-US", "eng" → "en".
    static func baseLanguage(_ code: String) -> String {
        let base = code.lowercased().split(separator: "-").first.map(String.init) ?? code.lowercased()
        let threeLetter = ["eng": "en", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it",
                           "jpn": "ja", "kor": "ko", "chi": "zh", "zho": "zh", "por": "pt", "rus": "ru", "hin": "hi"]
        return threeLetter[base] ?? base
    }

    /// Seeders in rough steps (1, 2–3, 4–7, … ), so 230 and 250 tie and the
    /// next rule decides.
    static func seederBucket(_ seeders: Int?) -> Int {
        guard let s = seeders, s > 0 else { return 0 }
        return Int(log2(Double(s))) + 1
    }
}

// MARK: - Duplicates

/// Merges the same release offered by several add-ons.
public enum ReleaseDeduplicator {
    /// Lists in add-on order; the first add-on's copy is kept, with anything it
    /// lacked (file index, seeders, size, file name) taken from the others.
    /// Torrents match by info hash (and file index when both give one); links
    /// by the hash in their path; anything else by file name and size.
    /// A debrid link and a torrent of the same release both stay: they play differently.
    public static func merge(_ lists: [[AddonRelease]]) -> [AddonRelease] {
        var merged: [AddonRelease] = []
        var byHash: [String: [Int]] = [:]
        var byName: [String: Int] = [:]
        for list in lists {
            for release in list {
                if let index = match(release, merged: merged, byHash: byHash, byName: byName) {
                    merged[index] = combine(merged[index], release)
                    register(merged[index], at: index, byHash: &byHash, byName: &byName)
                } else {
                    merged.append(release)
                    register(release, at: merged.count - 1, byHash: &byHash, byName: &byName)
                }
            }
        }
        return merged
    }

    private static func match(_ r: AddonRelease, merged: [AddonRelease], byHash: [String: [Int]],
                              byName: [String: Int]) -> Int? {
        if let hash = hashKey(r) {
            // Same torrent: file indexes must agree when both are given
            // (different files of a season pack are different episodes).
            if let hit = byHash[hash]?.first(where: { i in
                let a = merged[i].fileIndex, b = r.fileIndex
                return a == nil || b == nil || a == b
            }) { return hit }
        }
        // Sizes a hair apart can land in neighbouring buckets.
        return nameKeys(r).lazy.compactMap { byName[$0] }.first
    }

    private static func register(_ r: AddonRelease, at index: Int, byHash: inout [String: [Int]], byName: inout [String: Int]) {
        if let hash = hashKey(r), !(byHash[hash]?.contains(index) ?? false) { byHash[hash, default: []].append(index) }
        if let name = nameKey(r), byName[name] == nil { byName[name] = index }
    }

    static func hashKey(_ r: AddonRelease) -> String? {
        r.contentHash.map { (r.isDebrid ? "link:" : "torrent:") + $0 }
    }

    /// File name and size within about 1% (add-ons round sizes differently).
    static func nameKey(_ r: AddonRelease) -> String? { nameKeys(r).first }

    /// The release's own name key, then its neighbours one bucket either side.
    static func nameKeys(_ r: AddonRelease) -> [String] {
        guard let size = r.sizeBytes, size > 0 else { return [] }
        let name = r.fileName.lowercased().filter { $0.isLetter || $0.isNumber }
        guard name.count >= 8 else { return [] }
        let bucket = Int((log(Double(size)) / log(1.01)).rounded())
        let prefix = (r.isDebrid ? "link:" : "torrent:") + name + ":"
        return [bucket, bucket - 1, bucket + 1].map { prefix + String($0) }
    }

    static func combine(_ kept: AddonRelease, _ other: AddonRelease) -> AddonRelease {
        var info = kept.info
        info.fill(from: other.info)
        if let s = other.seeders, s > (kept.seeders ?? -1) { info.seeders = s }
        let cache: CacheState = kept.cache == .unknown ? other.cache : kept.cache
        var trackers = kept.trackers
        for t in other.trackers where !trackers.contains(t) { trackers.append(t) }
        let fileIndex = kept.fileIndex ?? other.fileIndex
        let id = kept.infoHash.map { "\($0):\(fileIndex ?? -1)" } ?? kept.id
        var result = AddonRelease(id: id, title: kept.title, name: kept.name, infoHash: kept.infoHash,
                                  fileIndex: fileIndex, trackers: trackers, seeders: info.seeders,
                                  sizeText: kept.sizeText ?? other.sizeText, resolution: info.resolution,
                                  container: info.container, url: kept.url, addonID: kept.addonID,
                                  addonName: kept.addonName, info: info, cache: cache,
                                  bingeGroup: kept.bingeGroup ?? other.bingeGroup,
                                  filename: kept.filenameHint ?? other.filenameHint,
                                  videoSize: kept.videoSize ?? other.videoSize)
        var also = kept.alsoFrom
        if let name = other.addonName, name != kept.addonName, !also.contains(name) { also.append(name) }
        for name in other.alsoFrom where name != kept.addonName && !also.contains(name) { also.append(name) }
        result.alsoFrom = also
        return result
    }
}
