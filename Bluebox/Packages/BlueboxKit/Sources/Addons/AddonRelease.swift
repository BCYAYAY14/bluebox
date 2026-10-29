//
//  AddonRelease.swift
//  Bluebox
//
//  Written for Bluebox from public documentation: the Stremio add-on SDK's
//  stream object (docs/api/responses/stream.md). One playable release an
//  add-on offered, with the facts Bluebox read out of it.
//

import Foundation

/// Whether a debrid service already holds a release, so it starts at once.
public enum CacheState: String, Codable, Sendable, Hashable {
    /// Nobody said. For a link that isn't from a debrid service, this means a direct link.
    case unknown
    /// The add-on marked it cached ("[RD+]", "⚡") or the service confirmed it.
    case cached
    /// The service would have to download it first.
    case uncached
}

/// One release an add-on offered: a torrent (info hash) or a direct/debrid link.
public struct AddonRelease: Identifiable, Hashable, Codable, Sendable {
    /// "<info hash>:<file index or -1>" for torrents, the URL for links. Also the variant ID.
    public let id: String
    /// The add-on's description text (all lines).
    public let title: String
    /// The add-on's short label ("Torrentio\n1080p").
    public let name: String
    public let infoHash: String?
    public let fileIndex: Int?
    /// Tracker URLs from the stream's `sources`.
    public let trackers: [String]
    public var seeders: Int?
    /// The size as the add-on wrote it, or from `videoSize`.
    public var sizeText: String?
    /// "2160p", "1080p", "720p", "480p" (or "1440p").
    public let resolution: String?
    /// File extension: "mkv", "mp4"…
    public let container: String?
    /// A link to play over HTTPS (debrid or direct).
    public let url: URL?

    /// Which installed add-on found it (`InstalledAddon.id`), and its name.
    public var addonID: String?
    public var addonName: String?
    /// Other add-ons that offered the same release.
    public var alsoFrom: [String] = []
    public var info: ReleaseInfo
    public var cache: CacheState
    /// `behaviorHints.bingeGroup`: the add-on's key for "the same kind of release next episode".
    public var bingeGroup: String?
    /// `behaviorHints.filename`.
    public var filenameHint: String?
    /// `behaviorHints.videoSize`, in bytes.
    public var videoSize: Int64?

    public init(id: String, title: String, name: String, infoHash: String?, fileIndex: Int?, trackers: [String],
                seeders: Int?, sizeText: String?, resolution: String?, container: String?, url: URL?,
                addonID: String? = nil, addonName: String? = nil, info: ReleaseInfo? = nil,
                cache: CacheState = .unknown, bingeGroup: String? = nil, filename: String? = nil,
                videoSize: Int64? = nil) {
        self.id = id
        self.title = title
        self.name = name
        self.infoHash = infoHash?.lowercased()
        self.fileIndex = fileIndex
        self.trackers = trackers
        self.url = url
        self.addonID = addonID
        self.addonName = addonName
        self.bingeGroup = bingeGroup
        self.filenameHint = filename
        self.videoSize = videoSize
        self.cache = cache
        var parsed = info ?? ReleaseNameParser.parse(label: name, description: title, filename: filename)
        if let resolution { parsed.resolution = resolution }
        if let seeders { parsed.seeders = seeders }
        if let container { parsed.container = container }
        if let videoSize, videoSize > 0 { parsed.sizeBytes = videoSize }
        if let sizeText, parsed.sizeText == nil {
            parsed.sizeText = sizeText
            if parsed.sizeBytes == nil { parsed.sizeBytes = ReleaseNameParser.statistics(in: "💾 " + sizeText).sizeBytes }
        }
        if parsed.container == nil, let url { parsed.container = ReleaseNameParser.splitExtension(url.lastPathComponent).ext }
        self.info = parsed
        self.seeders = parsed.seeders
        self.resolution = parsed.resolution
        self.container = parsed.container
        self.sizeText = parsed.sizeText ?? parsed.sizeBytes.map(Self.formatted)
    }

    /// Played over HTTPS (a debrid or direct link) rather than peer to peer.
    public var isDebrid: Bool { url != nil }

    /// Starts at once: a cached debrid link, or a direct link.
    public var startsInstantly: Bool { url != nil && cache != .uncached }

    /// A magnet link for a torrent, with its trackers.
    public var magnet: String? {
        guard url == nil, let infoHash else { return nil }
        var link = "magnet:?xt=urn:btih:\(infoHash)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if let dn = (filenameHint ?? fileNameFromText)?.addingPercentEncoding(withAllowedCharacters: allowed) {
            link += "&dn=\(dn)"
        }
        for tracker in trackers.prefix(12) {
            if let tr = tracker.addingPercentEncoding(withAllowedCharacters: allowed) { link += "&tr=\(tr)" }
        }
        return link
    }

    /// The file's name: the add-on's file name hint, a file name in its text,
    /// or the first line of its text.
    public var fileName: String {
        if let filenameHint, !filenameHint.isEmpty { return filenameHint }
        if let fromText = fileNameFromText { return fromText }
        let first = title.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        if let first, !first.isEmpty { return first }
        return name.replacingOccurrences(of: "\n", with: " ")
    }

    private var fileNameFromText: String? {
        let lines = title.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let marked = lines.first(where: { $0.hasPrefix("📄") }) {
            return String(marked.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return lines.first(where: ReleaseNameParser.looksLikeFileName)
    }

    public var sizeBytes: Int64? { info.sizeBytes }

    /// The torrent's info hash, or one found in a debrid link's path (Torrentio
    /// puts it there), for deduplicating and debrid cache checks.
    public var contentHash: String? {
        if let infoHash { return infoHash }
        guard let url else { return nil }
        return url.pathComponents.first { $0.count == 40 && $0.allSatisfy(\.isHexDigit) }?.lowercased()
    }

    /// The release group, when the name carries one.
    public var group: String? { info.group }

    static func formatted(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb).replacingOccurrences(of: ".00 GB", with: " GB") }
        return "\(Int((Double(bytes) / 1_048_576).rounded())) MB"
    }
}

public enum AddonError: LocalizedError, Sendable, Equatable {
    case badStatus(Int)
    case unexpectedResponse
    case debridRejected
    case noAddons
    case timedOut
    /// The text isn't an add-on link.
    case invalidAddonURL
    /// The manifest couldn't be read.
    case invalidManifest
    /// The add-on doesn't offer streams for movies or series.
    case noStreams(String)
    /// The add-on must be configured on its website first.
    case needsConfiguration(String)
    case alreadyInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): "The add-on responded with an error (HTTP \(code)). Try again in a moment."
        case .unexpectedResponse: "The add-on returned an unexpected response. It may be busy. Try again shortly."
        case .debridRejected: "Your debrid service rejected the API key. Check it in Settings › Torrents & Debrid."
        case .noAddons: "No add-ons are turned on. Turn one on in Settings › Torrents & Debrid › Add-ons."
        case .timedOut: "The add-ons took too long to answer. Try again in a moment."
        case .invalidAddonURL: "That isn't an add-on link. Paste the add-on's manifest link (ending in manifest.json)."
        case .invalidManifest: "Bluebox couldn't read that add-on's manifest. Check the link."
        case .noStreams(let name): "\(name) doesn't offer streams for movies or series, so it can't find releases."
        case .needsConfiguration(let name): "\(name) needs setting up on its website first. Configure it there, then paste the link it gives you."
        case .alreadyInstalled(let name): "\(name) is already in your add-ons."
        }
    }
}
