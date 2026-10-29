import Foundation

public struct SourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// What a source can do. Capabilities are independent: a source may browse
/// without downloading, or play without subtitle search.
public struct SourceCapabilities: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let browse = SourceCapabilities(rawValue: 1 << 0)
    public static let search = SourceCapabilities(rawValue: 1 << 1)
    public static let play = SourceCapabilities(rawValue: 1 << 2)
    public static let download = SourceCapabilities(rawValue: 1 << 3)
    public static let externalSubtitles = SourceCapabilities(rawValue: 1 << 4)
    public static let reportsProgress = SourceCapabilities(rawValue: 1 << 5)
    public static let requiresAuthentication = SourceCapabilities(rawValue: 1 << 6)
}

public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case localFolder, directURL, jellyfin, publicCatalog, torrent, downloads, addons
}

/// Where the bytes of a variant live.
public enum StorageLocation: String, Codable, Sendable {
    case localFile      // file the user owns on this device
    case downloaded     // copy made by Bluebox's download manager
    case remote         // server-only
}

/// One playable rendition of a media item offered by a source.
public struct MediaVariant: Hashable, Codable, Sendable, Identifiable {
    public let id: String                 // unique within the source
    public let sourceID: SourceID
    public let mediaKey: MediaKey?        // matched catalog key, if any
    public let displayName: String
    public let container: String?         // "mp4", "mkv", "m3u8"...
    public let videoCodec: String?
    public let resolution: String?        // "1080p", "4K"
    public let sizeBytes: Int64?
    public let duration: TimeInterval?
    public let location: StorageLocation
    public let isDownloadable: Bool

    public init(
        id: String, sourceID: SourceID, mediaKey: MediaKey?, displayName: String, container: String? = nil,
        videoCodec: String? = nil, resolution: String? = nil, sizeBytes: Int64? = nil,
        duration: TimeInterval? = nil, location: StorageLocation, isDownloadable: Bool = false
    ) {
        self.id = id; self.sourceID = sourceID; self.mediaKey = mediaKey; self.displayName = displayName
        self.container = container; self.videoCodec = videoCodec; self.resolution = resolution
        self.sizeBytes = sizeBytes; self.duration = duration; self.location = location; self.isDownloadable = isDownloadable
    }
}

public struct ExternalSubtitle: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let url: URL
    public let languageCode: String?
    public let label: String
    public let format: String   // "srt", "vtt", "ass"
    public init(id: String, url: URL, languageCode: String?, label: String, format: String) {
        self.id = id; self.url = url; self.languageCode = languageCode; self.label = label; self.format = format
    }
}

/// Everything a player needs to start playback. URLs may expire; callers must
/// re-resolve rather than caching a `PlaybackResource` across sessions.
public struct PlaybackResource: Sendable, Hashable {
    public let variant: MediaVariant
    public let url: URL
    public let httpHeaders: [String: String]
    public let externalSubtitles: [ExternalSubtitle]
    public let expiresAt: Date?
    /// Security-scoped URL (e.g. a bookmarked folder) the player must hold
    /// access to while reading `url`. Nil for network and in-container files.
    public let securityScopedRoot: URL?

    public init(
        variant: MediaVariant, url: URL, httpHeaders: [String: String] = [:],
        externalSubtitles: [ExternalSubtitle] = [], expiresAt: Date? = nil, securityScopedRoot: URL? = nil
    ) {
        self.variant = variant; self.url = url; self.httpHeaders = httpHeaders
        self.externalSubtitles = externalSubtitles; self.expiresAt = expiresAt; self.securityScopedRoot = securityScopedRoot
    }
}

public enum SourceError: Error, Hashable, Sendable, LocalizedError {
    case notConfigured
    case unauthorized
    case unreachable(String)
    case timedOut
    case notFound
    case unsupportedFormat(String)
    case expired
    case capabilityUnavailable(String)
    case invalidConfiguration(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "This source hasn't been set up yet."
        case .unauthorized: "Sign-in failed or expired. Check the source's credentials."
        case .unreachable(let d): "The source couldn't be reached. \(d)"
        case .timedOut: "The source took too long to respond."
        case .notFound: "This item is no longer available from the source."
        case .unsupportedFormat(let f): "Bluebox can't play this format (\(f)) yet."
        case .expired: "The playback link expired. Try again."
        case .capabilityUnavailable(let c): "This source doesn't support \(c)."
        case .invalidConfiguration(let d): "Invalid configuration: \(d)"
        case .cancelled: "Cancelled."
        }
    }

    /// Whether retrying the same request may succeed.
    public var isTransient: Bool {
        switch self {
        case .unreachable, .timedOut, .expired: true
        default: false
        }
    }
}

/// Serializable configuration for a source instance. Secrets (tokens,
/// passwords) are *not* stored here; they live in the Keychain keyed by `id`.
public struct SourceConfiguration: Hashable, Codable, Sendable, Identifiable {
    public let id: SourceID
    public var kind: SourceKind
    public var name: String
    public var isEnabled: Bool
    public var settings: [String: String]
    public init(id: SourceID, kind: SourceKind, name: String, isEnabled: Bool = true, settings: [String: String] = [:]) {
        self.id = id; self.kind = kind; self.name = name; self.isEnabled = isEnabled; self.settings = settings
    }
}

public struct SourceHealth: Sendable, Hashable {
    public let ok: Bool
    public let message: String
    public init(ok: Bool, message: String) { self.ok = ok; self.message = message }
}

/// A provider of playable media. Implementations normalize their results into
/// shared domain types and map their own failures to `SourceError`.
public protocol MediaSource: Sendable {
    var id: SourceID { get }
    var kind: SourceKind { get }
    var displayName: String { get }
    var capabilities: SourceCapabilities { get }

    /// All variants this source can offer right now (for library browsing).
    func catalog() async throws -> [MediaVariant]
    /// Variants that match a catalog key (movie or episode).
    func variants(for key: MediaKey) async throws -> [MediaVariant]
    /// Turns a variant into a fresh, playable resource.
    func resolve(_ variant: MediaVariant) async throws -> PlaybackResource
    /// Verifies the source is configured and reachable.
    func testConnection() async -> SourceHealth
}

public extension MediaSource {
    func supports(_ capability: SourceCapabilities) -> Bool { capabilities.contains(capability) }
}

/// Supplies bytes for playback URLs that aren't plain files or HTTP, such as
/// a torrent that is still downloading. The player reads through this.
public protocol StreamDataProvider: Sendable {
    func canProvide(_ url: URL) -> Bool
    func contentLength(of url: URL) async throws -> Int64
    func read(_ url: URL, offset: Int64, length: Int) async throws -> Data
}
