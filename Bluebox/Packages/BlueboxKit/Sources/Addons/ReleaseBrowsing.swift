//
//  ReleaseBrowsing.swift
//  Bluebox
//
//  What the release picker needs to make 80 rows choosable: filters (its
//  chips), quality groups, near-duplicates folded into one row, and plain
//  tags ("Cached", "Fast", "Small"). Pure functions over `AddonRelease`, so
//  the picker only draws.
//

import Foundation

/// The picker's quality groups, best first.
public enum QualityTier: Int, CaseIterable, Comparable, Hashable, Sendable {
    case uhd, fullHD, hd, other

    /// 1440p counts as 1080p (the ranker puts them on one level too).
    public init(resolution: String?) {
        switch StremioSource.resolutionLevel(resolution) {
        case 4: self = .uhd
        case 3: self = .fullHD
        case 2: self = .hd
        default: self = .other
        }
    }

    public var title: String {
        switch self {
        case .uhd: "4K"
        case .fullHD: "1080p"
        case .hd: "720p"
        case .other: "Other"
        }
    }

    public static func < (a: QualityTier, b: QualityTier) -> Bool { a.rawValue < b.rawValue }
}

/// The "≤ 5 GB" chip's choices.
public enum ReleaseSizeCap: Int64, CaseIterable, Hashable, Sendable {
    case twoGB = 2, fiveGB = 5, tenGB = 10

    public var bytes: Int64 { rawValue * 1_073_741_824 }
    public var title: String { "≤ \(rawValue) GB" }
}

/// The release picker's chips. Empty means everything; chips of one kind
/// widen (4K or 1080p), chips of different kinds narrow (1080p and Cached).
public struct ReleaseFilter: Hashable, Sendable {
    public var tiers: Set<QualityTier> = []
    /// HDR10, HDR10+, HLG or Dolby Vision.
    public var hdrOnly = false
    /// Starts at once: a cached debrid link or a plain link.
    public var instantOnly = false
    public var sizeCap: ReleaseSizeCap?
    /// ISO 639-1 audio language, or nil for any.
    public var language: String?

    public init(tiers: Set<QualityTier> = [], hdrOnly: Bool = false, instantOnly: Bool = false,
                sizeCap: ReleaseSizeCap? = nil, language: String? = nil) {
        self.tiers = tiers; self.hdrOnly = hdrOnly; self.instantOnly = instantOnly
        self.sizeCap = sizeCap; self.language = language
    }

    public var isActive: Bool { self != ReleaseFilter() }

    public func matches(_ r: AddonRelease) -> Bool {
        if !tiers.isEmpty, !tiers.contains(QualityTier(resolution: r.resolution)) { return false }
        if hdrOnly, !r.info.isHDR { return false }
        if instantOnly, !r.startsInstantly { return false }
        // An unknown size can't be shown to fit.
        if let sizeCap, (r.sizeBytes ?? .max) > sizeCap.bytes { return false }
        if let language, !Self.speaks(r.info, language) { return false }
        return true
    }

    public func apply(_ releases: [AddonRelease]) -> [AddonRelease] { releases.filter(matches) }

    /// In the language, or multi-language. Scene releases only name their
    /// audio when it isn't English, so an unmarked release counts as English.
    static func speaks(_ info: ReleaseInfo, _ language: String) -> Bool {
        let wanted = ReleaseRanker.baseLanguage(language)
        if info.languages.contains(wanted) || info.languages.contains("multi") { return true }
        return wanted == "en" && info.languages.isEmpty
    }
}

/// One row in the picker: a release, plus the near-copies folded under it
/// ("+3 similar").
public struct ReleaseCluster: Identifiable, Hashable, Sendable {
    public let lead: AddonRelease
    public internal(set) var similar: [AddonRelease]
    public var id: String { lead.id }
    public var all: [AddonRelease] { [lead] + similar }
}

/// A quality group's header and rows.
public struct ReleaseSection: Identifiable, Hashable, Sendable {
    public let tier: QualityTier
    public let clusters: [ReleaseCluster]
    public var id: QualityTier { tier }
    /// Releases, counting the folded ones.
    public var count: Int { clusters.reduce(0) { $0 + 1 + $1.similar.count } }
}

/// Folds near-duplicates and groups by quality.
public enum ReleaseCollapser {
    /// Sizes within 3% read as the same encode re-shared (a different
    /// container, a sample removed, an extra subtitle).
    public static let sizeTolerance = 0.03

    /// Rows in the order given; each release joins the first earlier row it
    /// matches, so the better-ranked copy leads.
    public static func collapse(_ releases: [AddonRelease]) -> [ReleaseCluster] {
        var clusters: [ReleaseCluster] = []
        for r in releases {
            if let i = clusters.firstIndex(where: { isSimilar($0.lead, r) }) {
                clusters[i].similar.append(r)
            } else {
                clusters.append(ReleaseCluster(lead: r, similar: []))
            }
        }
        return clusters
    }

    /// The same torrent, or the same resolution, source, codec and HDR at
    /// nearly the same size. Compared with the row's lead only, so a chain of
    /// 3% steps can't drift into a different release.
    public static func isSimilar(_ a: AddonRelease, _ b: AddonRelease) -> Bool {
        if let ha = a.contentHash, let hb = b.contentHash, ha == hb { return true }
        guard a.resolution == b.resolution, a.info.source == b.info.source, a.info.videoCodec == b.info.videoCodec,
              a.info.hdr == b.info.hdr,
              let sa = a.sizeBytes, let sb = b.sizeBytes, sa > 0, sb > 0 else { return false }
        return Double(abs(sa - sb)) / Double(max(sa, sb)) <= sizeTolerance
    }

    /// Quality groups, best first, each keeping the order its rows came in.
    public static func sections(_ clusters: [ReleaseCluster]) -> [ReleaseSection] {
        let byTier = Dictionary(grouping: clusters) { QualityTier(resolution: $0.lead.resolution) }
        return QualityTier.allCases.compactMap { tier in
            byTier[tier].map { ReleaseSection(tier: tier, clusters: $0) }
        }
    }

    /// Filters, folds and groups in one go.
    public static func sections(_ releases: [AddonRelease], filter: ReleaseFilter) -> [ReleaseSection] {
        sections(collapse(filter.apply(releases)))
    }
}

/// Plain-language facts shown on a release's row, in this order.
public enum ReleaseTag: String, CaseIterable, Hashable, Sendable {
    case cached, fast, small, hdr, dolbyVision, atmos, remux

    public var title: String {
        switch self {
        case .cached: "Cached"
        case .fast: "Fast"
        case .small: "Small"
        case .hdr: "HDR"
        case .dolbyVision: "DV"
        case .atmos: "Atmos"
        case .remux: "Remux"
        }
    }

    /// A swarm this big fills the buffer quickly.
    public static let fastSeeders = 50
    /// "Small" is under this share of the typical size at its quality.
    public static let smallShare = 0.6

    /// - Parameter smallBelow: sizes under this are "Small" (see `smallThresholds`).
    public static func tags(for r: AddonRelease, smallBelow: Int64?) -> [ReleaseTag] {
        var out: [ReleaseTag] = []
        if r.isDebrid && r.cache == .cached { out.append(.cached) }
        if !r.isDebrid, (r.seeders ?? 0) >= fastSeeders { out.append(.fast) }
        if let smallBelow, let size = r.sizeBytes, size > 0, size < smallBelow { out.append(.small) }
        // DV says it alone; HDR is for the other formats (a DV release with an HDR10 base gets both).
        if r.info.hdr.contains(where: { $0 != .dolbyVision }) { out.append(.hdr) }
        if r.info.isDolbyVision { out.append(.dolbyVision) }
        if r.info.audio.contains(.atmos) { out.append(.atmos) }
        if r.info.source == .remux { out.append(.remux) }
        return out
    }

    /// Per quality, the size below which a release counts as small: a share
    /// of the median. Needs three sized releases at that quality to judge.
    public static func smallThresholds(_ releases: [AddonRelease]) -> [QualityTier: Int64] {
        var sizes: [QualityTier: [Int64]] = [:]
        for r in releases {
            guard let s = r.sizeBytes, s > 0 else { continue }
            sizes[QualityTier(resolution: r.resolution), default: []].append(s)
        }
        return sizes.compactMapValues { list in
            guard list.count >= 3 else { return nil }
            let sorted = list.sorted()
            let median = sorted.count % 2 == 1
                ? Double(sorted[sorted.count / 2])
                : Double(sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            return Int64(median * smallShare)
        }
    }
}

/// What add-on searches this session found for a title, for Search's chips.
public struct ReleaseOffer: Hashable, Sendable {
    /// Some release starts at once (cached debrid or a plain link).
    public var instant = false
    /// Some release is 4K.
    public var uhd = false
    public init(instant: Bool = false, uhd: Bool = false) { self.instant = instant; self.uhd = uhd }
}
