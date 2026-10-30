//
//  AddonSettings.swift
//  Bluebox
//
//  Written for Bluebox from public documentation. Settings for finding
//  releases: the installed add-ons (presets and any add-on added by its
//  manifest link) in the order they're asked, the debrid service, release
//  preferences, and the torrent engine's knobs. Stored as JSON under
//  `PreferenceKey.addons`; settings saved by earlier versions (a list of
//  `providers`) are read and carried over.
//

import Foundation
import TorrentStreaming

/// Add-ons Bluebox can set up in one tap, configured from your settings.
public enum AddonPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case torrentio, stremthru, comet

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .torrentio: "Torrentio"
        case .stremthru: "StremThru Torz"
        case .comet: "Comet"
        }
    }

    public var summary: String {
        switch self {
        case .torrentio: "Torrents from many public trackers. Works with or without debrid."
        case .stremthru: "Crowdsourced torrents through StremThru. Works with or without debrid."
        case .comet: "Fast debrid search. Needs a debrid service and key sharing."
        }
    }

    /// The public instance only offers debrid links.
    public var requiresDebrid: Bool { self == .comet }

    public static let defaultStremthruHost = "https://stremthru.13377001.xyz"
    static let torrentioHost = "https://torrentio.strem.fun"
    static let cometHost = "https://comet.elfhosted.com"
}

/// Earlier name of `AddonPreset`.
public typealias AddonProvider = AddonPreset

public enum DebridProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, realDebrid, premiumize, allDebrid, torBox, debridLink

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "None (peer-to-peer)"
        case .realDebrid: "Real-Debrid"
        case .premiumize: "Premiumize"
        case .allDebrid: "AllDebrid"
        case .torBox: "TorBox"
        case .debridLink: "Debrid-Link"
        }
    }

    public var keyHint: String? {
        switch self {
        case .none: nil
        case .realDebrid: "real-debrid.com/apitoken"
        case .premiumize: "premiumize.me/account"
        case .allDebrid: "alldebrid.com/apikeys"
        case .torBox: "torbox.app/settings"
        case .debridLink: "debrid-link.com/webapp/apikey"
        }
    }

    public var requiresKey: Bool { self != .none }

    /// Whether Bluebox can ask the service itself which torrents it holds
    /// (TorBox and Premiumize publish an endpoint; the others removed theirs).
    public var canCheckCache: Bool { self == .torBox || self == .premiumize }
}

/// Release qualities that can be hidden. Raw values are Torrentio's `qualityfilter` names.
public enum QualityFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case brremux, hdrall, dolbyvision, threed, unknown, scr, cam, other
    case sd = "480p", hd720 = "720p", hd1080 = "1080p", uhd = "4k"

    public var id: String { rawValue }

    /// Offered in Settings, in this order.
    public static let offered: [QualityFilter] = [.cam, .scr, .unknown, .sd, .hd720, .hd1080, .uhd, .threed]

    public var title: String {
        switch self {
        case .cam: "CAM Rips and Telesyncs"
        case .scr: "Screeners"
        case .unknown: "Unknown Quality"
        case .sd: "480p"
        case .hd720: "720p"
        case .hd1080: "1080p"
        case .uhd: "4K"
        case .brremux: "BluRay Remux"
        case .hdrall: "HDR"
        case .dolbyvision: "Dolby Vision"
        case .threed: "3D"
        case .other: "Other"
        }
    }

    /// Whether a release falls under this filter. Applied to every add-on,
    /// not only Torrentio (which also filters on its side).
    public func matches(_ info: ReleaseInfo) -> Bool {
        switch self {
        case .cam: [.cam, .telesync, .telecine].contains(info.source)
        case .scr: info.source == .screener
        case .unknown: info.resolution == nil
        case .sd: info.resolution == "480p"
        case .hd720: info.resolution == "720p"
        case .hd1080: info.resolution == "1080p"
        case .uhd: info.resolution == "2160p"
        case .brremux: info.source == .remux
        case .hdrall: info.isHDR
        case .dolbyvision: info.isDolbyVision
        case .threed: info.is3D
        case .other: false
        }
    }
}

/// How add-ons sort what they send, and how Bluebox breaks ties.
public enum ReleaseSort: String, CaseIterable, Identifiable, Codable, Sendable {
    case quality, seeders, size

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quality: "Quality"
        case .seeders: "Seeders"
        case .size: "Size"
        }
    }

    /// Torrentio's `sort` option.
    var torrentioValue: String {
        switch self {
        case .quality: "qualitysize"
        case .seeders: "seeders"
        case .size: "size"
        }
    }
}

/// One add-on in your list.
public struct InstalledAddon: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: Codable, Sendable, Hashable {
        /// Built from your settings each time (so the debrid key stays in the Keychain).
        case preset(AddonPreset)
        /// Added by its manifest link. `base` is only the link's origin
        /// (`https://host`); the whole link, which holds the add-on's
        /// configuration and often a debrid key, is in the Keychain
        /// (`SecretAccount.addonLink`) and in `AddonSettings.customLinks`.
        /// Settings saved before 1.0.15 have the whole link here, which
        /// `AddonSettings.movingLinksOut()` moves.
        case custom(base: String)
    }

    public var id: String
    public var kind: Kind
    public var name: String
    public var isEnabled: Bool
    public var version: String?
    public var summary: String?
    /// "movie", "series".
    public var types: [String]

    public init(id: String, kind: Kind, name: String, isEnabled: Bool = true, version: String? = nil,
                summary: String? = nil, types: [String] = ["movie", "series"]) {
        self.id = id; self.kind = kind; self.name = name; self.isEnabled = isEnabled
        self.version = version; self.summary = summary; self.types = types
    }

    public static func preset(_ preset: AddonPreset, enabled: Bool = true) -> InstalledAddon {
        InstalledAddon(id: "preset.\(preset.rawValue)", kind: .preset(preset), name: preset.title, isEnabled: enabled,
                       summary: preset.summary)
    }

    /// An add-on added by link, described by its manifest. Only the link's
    /// origin is kept here; the caller keeps the link itself in the Keychain.
    public static func custom(base: URL, manifest: AddonManifest) -> InstalledAddon {
        InstalledAddon(id: "custom.\(UUID().uuidString.lowercased())", kind: .custom(base: AddonURL.origin(base.absoluteString)),
                       name: manifest.name, version: manifest.version, summary: manifest.description,
                       types: manifest.streamTypes)
    }

    public var preset: AddonPreset? {
        if case .preset(let p) = kind { return p }
        return nil
    }

    /// Where it lives, without any configuration in the link (which can hold keys).
    public var hostLabel: String {
        switch kind {
        case .preset(let p):
            switch p {
            case .torrentio: "torrentio.strem.fun"
            case .stremthru: "StremThru"
            case .comet: "comet.elfhosted.com"
            }
        case .custom(let base): AddonURL.displayHost(base)
        }
    }

    public func streams(_ type: String) -> Bool { types.isEmpty || types.contains(type) }
}

/// An add-on ready to ask: its base URL with your configuration.
public struct ResolvedAddon: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var base: URL
    public var types: [String]
}

/// Everything about release finding except the debrid key, which lives in the Keychain.
public struct AddonSettings: Codable, Sendable, Equatable {
    public var isEnabled = true
    /// Your add-ons in the order they're asked. Ties between equally good releases go to the earlier one.
    public var addons: [InstalledAddon] = [.preset(.torrentio), .preset(.stremthru)]
    public var debrid: DebridProvider = .none
    /// Send the debrid key to StremThru and Comet (Torrentio always gets it).
    public var shareKeyWithCommunityHosts = false
    public var stremthruHost = AddonPreset.defaultStremthruHost
    public var hiddenQualities: Set<QualityFilter> = [.cam, .scr]
    public var sort: ReleaseSort = .seeders
    /// "2160p", "1080p", "720p", or nil for the best available.
    public var preferredResolution: String? = "1080p"
    /// Prefer the release group and resolution last played for a show.
    public var rememberShowChoices = true
    /// Ask TorBox or Premiumize which releases are cached before ranking.
    public var checkDebridCache = true
    /// How long one add-on may take before it's given up on.
    public var addonTimeoutSeconds = 10
    /// The links of add-ons added by link, by add-on ID, read from the
    /// Keychain. Never saved with these settings or synced with them.
    public var customLinks: [String: String] = [:]

    // Torrent engine (TorrentStreaming).
    public var maxPeers = 80
    public var streamingPort = 8888
    public var extraTrackers: [String] = []
    public var streamCacheLimitBytes: Int64 = 5 * 1024 * 1024 * 1024
    /// Look a movie's releases up when its page opens.
    public var prefetchReleases = true
    /// Torrents tried at once on Play.
    public var raceWidth = 3
    /// Least to buffer before playing, in MB.
    public var minimumPrebufferMB = 3
    /// Most to buffer before playing, in MB.
    public var maximumPrebufferMB = 16
    /// Upload limit in KB/s; nil is unlimited, 0 uploads nothing.
    public var uploadLimitKBps: Int?

    public init() {}

    /// An add-on added by link whose link isn't on this device (it came from
    /// another device without Sync API Keys): it's skipped until pasted again.
    public func needsLink(_ addon: InstalledAddon) -> Bool {
        if case .custom = addon.kind { return customLinks[addon.id] == nil }
        return false
    }

    /// Settings from before links moved to the Keychain hold the whole link in
    /// `custom(base:)`. Returns the settings with only origins left, and the
    /// links taken out, by add-on ID.
    public func movingLinksOut() -> (settings: AddonSettings, links: [String: String]) {
        var copy = self, links: [String: String] = [:]
        for i in copy.addons.indices {
            guard case .custom(let base) = copy.addons[i].kind else { continue }
            let origin = AddonURL.origin(base)
            guard origin != base else { continue }
            links[copy.addons[i].id] = base
            copy.addons[i].kind = .custom(base: origin)
        }
        return (copy, links)
    }

    /// The presets turned on, in order (the shape earlier versions stored).
    public var providers: [AddonPreset] {
        addons.filter(\.isEnabled).compactMap(\.preset)
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case isEnabled, addons, providers, debrid, shareKeyWithCommunityHosts, stremthruHost, hiddenQualities, sort
        case preferredResolution, rememberShowChoices, checkDebridCache, addonTimeoutSeconds
        case maxPeers, streamingPort, extraTrackers, streamCacheLimitBytes
        case prefetchReleases, raceWidth, minimumPrebufferMB, maximumPrebufferMB, uploadLimitKBps
    }

    /// Missing or unreadable values fall back to the defaults, so a setting
    /// added later never resets the others. Settings from before add-ons
    /// could be added by link have `providers` instead of `addons`: those
    /// presets come back in the same order, turned on.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AddonSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        isEnabled = value(.isEnabled, d.isEnabled)
        if let saved = try? c.decodeIfPresent([InstalledAddon].self, forKey: .addons) {
            addons = saved
        } else if let names = try? c.decodeIfPresent([String].self, forKey: .providers) {
            var seen = Set<AddonPreset>()
            addons = names.compactMap(AddonPreset.init(rawValue:)).filter { seen.insert($0).inserted }.map { .preset($0) }
        } else {
            addons = d.addons
        }
        debrid = value(.debrid, d.debrid)
        shareKeyWithCommunityHosts = value(.shareKeyWithCommunityHosts, d.shareKeyWithCommunityHosts)
        stremthruHost = value(.stremthruHost, d.stremthruHost)
        // Unknown filter names (from a newer version) are skipped, not fatal.
        if let names = try? c.decodeIfPresent([String].self, forKey: .hiddenQualities) {
            hiddenQualities = Set(names.compactMap(QualityFilter.init(rawValue:)))
        }
        sort = value(.sort, d.sort)
        if c.contains(.preferredResolution) {
            preferredResolution = (try? c.decodeIfPresent(String.self, forKey: .preferredResolution)) ?? nil
        }
        rememberShowChoices = value(.rememberShowChoices, d.rememberShowChoices)
        checkDebridCache = value(.checkDebridCache, d.checkDebridCache)
        addonTimeoutSeconds = value(.addonTimeoutSeconds, d.addonTimeoutSeconds)
        maxPeers = value(.maxPeers, d.maxPeers)
        streamingPort = value(.streamingPort, d.streamingPort)
        extraTrackers = value(.extraTrackers, d.extraTrackers)
        streamCacheLimitBytes = value(.streamCacheLimitBytes, d.streamCacheLimitBytes)
        prefetchReleases = value(.prefetchReleases, d.prefetchReleases)
        raceWidth = value(.raceWidth, d.raceWidth)
        minimumPrebufferMB = value(.minimumPrebufferMB, d.minimumPrebufferMB)
        maximumPrebufferMB = value(.maximumPrebufferMB, d.maximumPrebufferMB)
        uploadLimitKBps = (try? c.decodeIfPresent(Int.self, forKey: .uploadLimitKBps)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(addons, forKey: .addons)
        // Kept for older builds reading these settings.
        try c.encode(providers.map(\.rawValue), forKey: .providers)
        try c.encode(debrid, forKey: .debrid)
        try c.encode(shareKeyWithCommunityHosts, forKey: .shareKeyWithCommunityHosts)
        try c.encode(stremthruHost, forKey: .stremthruHost)
        try c.encode(hiddenQualities.map(\.rawValue).sorted(), forKey: .hiddenQualities)
        try c.encode(sort, forKey: .sort)
        try c.encode(preferredResolution, forKey: .preferredResolution)
        try c.encode(rememberShowChoices, forKey: .rememberShowChoices)
        try c.encode(checkDebridCache, forKey: .checkDebridCache)
        try c.encode(addonTimeoutSeconds, forKey: .addonTimeoutSeconds)
        try c.encode(maxPeers, forKey: .maxPeers)
        try c.encode(streamingPort, forKey: .streamingPort)
        try c.encode(extraTrackers, forKey: .extraTrackers)
        try c.encode(streamCacheLimitBytes, forKey: .streamCacheLimitBytes)
        try c.encode(prefetchReleases, forKey: .prefetchReleases)
        try c.encode(raceWidth, forKey: .raceWidth)
        try c.encode(minimumPrebufferMB, forKey: .minimumPrebufferMB)
        try c.encode(maximumPrebufferMB, forKey: .maximumPrebufferMB)
        try c.encodeIfPresent(uploadLimitKBps, forKey: .uploadLimitKBps)
    }

    // MARK: Engine

    public var streamSettings: TorrentStreamSettings {
        let minimum = max(1, minimumPrebufferMB)
        let maximum = max(minimum, maximumPrebufferMB)
        return TorrentStreamSettings(maxPeers: maxPeers, port: UInt16(clamping: streamingPort),
                                     extraTrackers: extraTrackers.compactMap(URL.init(string:)),
                                     cacheLimitBytes: streamCacheLimitBytes,
                                     minimumPrebufferBytes: Int64(minimum) * 1024 * 1024,
                                     maximumPrebufferBytes: Int64(maximum) * 1024 * 1024,
                                     raceWidth: min(max(raceWidth, 1), 5),
                                     uploadRateLimit: uploadLimitKBps.map { Int64(max($0, 0)) * 1024 },
                                     // Settings › Mobile Data decides at run time (`TorrentStreamer.setUploadOnMobileData`).
                                     uploadOnExpensiveNetwork: true)
    }

    // MARK: Add-ons

    /// The presets not in your list yet, for one-tap adding.
    public var availablePresets: [AddonPreset] {
        AddonPreset.allCases.filter { p in !addons.contains { $0.preset == p } }
    }

    public mutating func addPreset(_ preset: AddonPreset) {
        if let i = addons.firstIndex(where: { $0.preset == preset }) {
            addons[i].isEnabled = true
        } else {
            addons.append(.preset(preset))
        }
    }

    /// Whether the debrid key is set and may be used.
    func hasDebrid(_ key: String) -> Bool {
        debrid.requiresKey && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The add-ons to ask, turned on and in order, with their configured
    /// URLs. A preset that can't work with these settings (Comet without a
    /// shared debrid key) is left out; so are duplicates of the same link.
    public func resolvedAddons(debridKey: String) -> [ResolvedAddon] {
        var seen = Set<URL>()
        return addons.filter(\.isEnabled).compactMap { addon -> ResolvedAddon? in
            let base: URL?
            switch addon.kind {
            case .preset(let preset): base = AddonPresetURL.base(for: preset, settings: self, debridKey: debridKey)
            case .custom: base = customLinks[addon.id].flatMap(URL.init(string:))
            }
            guard let base, seen.insert(base).inserted else { return nil }
            return ResolvedAddon(id: addon.id, name: addon.name, base: base, types: addon.types)
        }
    }
}

/// Builds the presets' configured base URLs, following each add-on's
/// documented URL configuration.
enum AddonPresetURL {
    static func base(for preset: AddonPreset, settings: AddonSettings, debridKey: String) -> URL? {
        let key = debridKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDebrid = settings.hasDebrid(key)
        let share = hasDebrid && settings.shareKeyWithCommunityHosts
        switch preset {
        case .torrentio:
            return torrentio(settings: settings, debridKey: hasDebrid ? key : nil)
        case .stremthru:
            return stremthru(host: settings.stremthruHost, debrid: share ? settings.debrid : .none, key: share ? key : "")
        case .comet:
            guard share else { return nil }
            return comet(debrid: settings.debrid, key: key)
        }
    }

    /// `https://torrentio.strem.fun/<option=value|option=value>`: options are
    /// `sort`, `qualityfilter` (comma-separated) and the debrid service's key
    /// (`realdebrid=…`, `premiumize=…`, `alldebrid=…`, `torbox=…`, `debridlink=…`).
    static func torrentio(settings: AddonSettings, debridKey: String?) -> URL? {
        var options = ["sort=\(settings.sort.torrentioValue)"]
        let hidden = settings.hiddenQualities.map(\.rawValue).sorted()
        if !hidden.isEmpty { options.append("qualityfilter=\(hidden.joined(separator: ","))") }
        if let debridKey, let service = torrentioService(settings.debrid) {
            options.append("\(service)=\(debridKey)")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~=,"))
        let config = options.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "%7C")
        return URL(string: AddonPreset.torrentioHost + "/" + config)
    }

    static func torrentioService(_ debrid: DebridProvider) -> String? {
        switch debrid {
        case .none: nil
        case .realDebrid: "realdebrid"
        case .premiumize: "premiumize"
        case .allDebrid: "alldebrid"
        case .torBox: "torbox"
        case .debridLink: "debridlink"
        }
    }

    /// StremThru's Torz add-on: `<host>/stremio/torz/<base64 JSON>`, where the
    /// JSON lists stores as `{"stores":[{"c":"<code>","t":"<token>"}]}`
    /// ("p2p" with no token for peer-to-peer).
    static func stremthru(host: String, debrid: DebridProvider, key: String) -> URL? {
        let code: String = switch debrid {
        case .none: "p2p"
        case .realDebrid: "rd"
        case .premiumize: "pm"
        case .allDebrid: "ad"
        case .torBox: "tb"
        case .debridLink: "dl"
        }
        let store: [(String, String)] = [("c", code), ("t", debrid == .none ? "" : key)]
        let json = { (pad: String) in #"{"stores":["# + pad + object(store) + "]}" }
        var trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmedHost.hasSuffix("/") { trimmedHost.removeLast() }
        guard let config = PathSafeBase64.encode(json) else { return nil }
        return URL(string: trimmedHost + "/stremio/torz/" + config)
    }

    /// Comet: `<host>/<base64 JSON>` with `debridService` ("realdebrid",
    /// "premiumize", "alldebrid", "torbox", "debridlink") and `debridApiKey`.
    static func comet(debrid: DebridProvider, key: String) -> URL? {
        let service: String? = switch debrid {
        case .none: nil
        case .realDebrid: "realdebrid"
        case .premiumize: "premiumize"
        case .allDebrid: "alldebrid"
        case .torBox: "torbox"
        case .debridLink: "debridlink"
        }
        guard let service else { return nil }
        let fields: [(String, String)] = [("debridService", service), ("debridApiKey", key)]
        guard let config = PathSafeBase64.encode({ pad in "{" + pad + members(fields) + "}" }) else { return nil }
        return URL(string: AddonPreset.cometHost + "/" + config)
    }

    static func object(_ fields: [(String, String)]) -> String { "{" + members(fields) + "}" }

    static func members(_ fields: [(String, String)]) -> String {
        fields.map { "\(jsonString($0.0)):\(jsonString($0.1))" }.joined(separator: ",")
    }

    static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

/// Standard base64 for a JSON config that goes in a URL path. A "/" in the
/// output would split the path, and not every add-on accepts it escaped, so
/// whitespace (insignificant in JSON) is added until the encoding has none.
enum PathSafeBase64 {
    static func encode(_ json: (String) -> String) -> String? {
        for spaces in 0..<96 {
            let encoded = Data(json(String(repeating: " ", count: spaces)).utf8).base64EncodedString()
            if !encoded.contains("/") { return encoded }
        }
        // Practically unreachable; StremThru accepts an escaped slash.
        return Data(json("").utf8).base64EncodedString().replacingOccurrences(of: "/", with: "%2F")
    }
}

/// How to rank releases while on mobile data (Settings › Mobile Data). Not
/// stored here: the app passes one to `StremioSource.setMobileData` while the
/// device is on mobile data, and nil on Wi‑Fi.
public struct MobileDataRanking: Sendable, Equatable {
    /// "720p", "1080p", or nil for no cap. Releases above it go after every release within it.
    public var maxResolution: String?
    /// Data Saver: among equally healthy releases, the smallest file first.
    public var preferSmallest: Bool
    /// Peer-to-peer torrents may play.
    public var allowsTorrents: Bool
    /// Debrid links may play.
    public var allowsDebrid: Bool

    public init(maxResolution: String?, preferSmallest: Bool, allowsTorrents: Bool, allowsDebrid: Bool) {
        self.maxResolution = maxResolution; self.preferSmallest = preferSmallest
        self.allowsTorrents = allowsTorrents; self.allowsDebrid = allowsDebrid
    }

    /// True when the release's resolution is above the cap. The release picker marks these.
    public func isAboveCap(_ release: AddonRelease) -> Bool {
        guard let cap = maxResolution.flatMap(StremioSource.resolutionLevel),
              let level = StremioSource.resolutionLevel(release.resolution) else { return false }
        return level > cap
    }

    /// Whether this release may play on mobile data at all.
    public func allows(_ release: AddonRelease) -> Bool {
        release.isDebrid ? allowsDebrid : allowsTorrents
    }
}
