import Domain
import Foundation

/// One saved (or saving) movie or episode.
public struct DownloadRecord: Codable, Sendable, Identifiable, Hashable {
    public enum State: Codable, Sendable, Hashable {
        /// Waiting for a free slot, a connection, Wi‑Fi, or the app to come back.
        case queued
        case downloading
        /// Paused by you; stays paused across launches.
        case paused
        case completed
        case failed(String)
    }

    /// `<source id>/<variant id>`: one download per variant.
    public let id: String
    public var mediaKey: MediaKey?
    /// Movie or show name.
    public var title: String
    /// "S1·E2" or "S1·E2 · Episode name" for episodes.
    public var subtitle: String?
    /// The variant it was downloaded from (release name, quality, size).
    public var origin: MediaVariant
    public var state: State
    public var receivedBytes: Int64
    public var expectedBytes: Int64?
    public var createdAt: Date
    /// File name inside the downloads folder, once complete.
    public var fileName: String?
    public var subtitleFiles: [SubtitleFile]
    // Added later; optional so older index files still decode.
    /// Poster (or still) shown in the Downloads list.
    public var artworkURL: URL?
    /// Queue position; lower goes first. Defaults to creation time.
    public var order: Double?
    public var completedAt: Date?
    /// true: "Download Now" was chosen on mobile data, so Wi‑Fi Only doesn't hold
    /// this one back. false: "Download on Wi‑Fi Later", so it waits for Wi‑Fi
    /// even when Wi‑Fi Only is off. nil: the settings decide.
    public var allowsMobileData: Bool?
    /// Started by Bluebox, not by you (Smart Downloads, new episodes, an
    /// upgrade): it waits for Settings › Downloads › Download Window.
    public var isAutomatic: Bool?
    /// The download this one upgrades: deleted once this one finishes.
    public var replaces: String?

    public init(id: String, mediaKey: MediaKey?, title: String, subtitle: String?, origin: MediaVariant, state: State,
                receivedBytes: Int64, expectedBytes: Int64?, createdAt: Date, fileName: String?, subtitleFiles: [SubtitleFile],
                artworkURL: URL? = nil, order: Double? = nil, completedAt: Date? = nil) {
        self.id = id; self.mediaKey = mediaKey; self.title = title; self.subtitle = subtitle; self.origin = origin
        self.state = state; self.receivedBytes = receivedBytes; self.expectedBytes = expectedBytes
        self.createdAt = createdAt; self.fileName = fileName; self.subtitleFiles = subtitleFiles
        self.artworkURL = artworkURL; self.order = order; self.completedAt = completedAt
    }

    public struct SubtitleFile: Codable, Sendable, Hashable {
        public var fileName: String
        public var languageCode: String?
        public var label: String
        public var format: String
    }

    public var fraction: Double? {
        if state == .completed { return 1 }
        guard let e = expectedBytes, e > 0 else { return nil }
        return min(Double(receivedBytes) / Double(e), 1)
    }

    public var sortOrder: Double { order ?? createdAt.timeIntervalSince1970 }

    /// Lowercased info hash when this is a torrent release (variant ID `<hash>:<file index>`).
    public var infoHash: String? { Self.infoHash(fromVariantID: origin.id) }
    public var isTorrent: Bool { infoHash != nil }

    /// Queued or transferring: work the queue still has to do.
    public var isActive: Bool { state == .queued || state == .downloading }
    public var isFailed: Bool { if case .failed = state { true } else { false } }
    public var failureMessage: String? { if case .failed(let m) = state { m } else { nil } }

    /// The release name when it says more than the title (torrent and debrid releases).
    public var releaseName: String? {
        let name = origin.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == title || name == "Best release" ? nil : name
    }

    public var remainingBytes: Int64? {
        guard let e = expectedBytes else { return nil }
        return max(e - receivedBytes, 0)
    }

    public static func id(for variant: MediaVariant) -> String { "\(variant.sourceID.rawValue)/\(variant.id)" }

    public static func infoHash(fromVariantID id: String) -> String? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 40, parts[0].allSatisfy(\.isHexDigit),
              Int(parts[1]) != nil else { return nil }
        return parts[0].lowercased()
    }
}

/// Transfer speed and swarm size; not saved.
public struct DownloadLiveStats: Sendable, Equatable {
    public var bytesPerSecond: Double
    /// Connected peers, for torrents.
    public var peers: Int?
    /// True while a torrent is still looking for peers / its file list.
    public var isConnecting: Bool

    public init(bytesPerSecond: Double = 0, peers: Int? = nil, isConnecting: Bool = false) {
        self.bytesPerSecond = bytesPerSecond; self.peers = peers; self.isConnecting = isConnecting
    }

    /// Seconds left at the current speed.
    public func eta(remaining: Int64?) -> TimeInterval? {
        guard let remaining, remaining > 0, bytesPerSecond > 1_000 else { return nil }
        return Double(remaining) / bytesPerSecond
    }
}

/// Why a queued download isn't transferring.
public enum DownloadWait: Sendable, Equatable {
    /// Waiting for a free slot; 1 is next.
    case queued(position: Int)
    case offline
    case wifi
    /// Torrents only run while Bluebox is open.
    case appInBackground
    /// Held for a reason given by the app (e.g. the same release is streaming).
    case held(String)
    /// An automatic download outside Settings › Downloads › Download Window.
    case window(DownloadWindow)

    public var message: String {
        switch self {
        case .queued(let p): p == 1 ? "Up next" : "Queued (\(p) in line)"
        case .offline: "Waiting for a connection"
        case .wifi: "Waiting for Wi‑Fi"
        case .appInBackground: "Continues when Bluebox is open"
        case .held(let reason): reason
        case .window(.whileCharging): "Waiting to charge"
        case .window: "Waiting for overnight (1–6 am)"
        }
    }
}

/// A transfer that runs but gets nothing: the amber bar and its reason in the queue.
public enum DownloadStall {
    /// No new bytes for this long counts as stalled.
    public static let after: TimeInterval = 60

    /// Why a running download is stuck, or nil while it moves.
    /// - Parameter idle: seconds since its last new bytes (`DownloadManager.idleSeconds`).
    public static func reason(_ r: DownloadRecord, stats: DownloadLiveStats?, idle: TimeInterval?) -> String? {
        guard r.state == .downloading, let idle, idle >= after else { return nil }
        let span = minutes(idle)
        if r.isTorrent {
            if stats?.isConnecting == true || (stats?.peers ?? 0) == 0 { return "No peers for \(span)" }
            return "Peers aren't sending for \(span)"
        }
        return "No data for \(span)"
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m <= 1 ? "1 min" : m < 60 ? "\(m) min" : "\(m / 60) h"
    }
}

public enum DownloadError: Error, Equatable, Sendable, LocalizedError {
    case notDownloadable
    case alreadyDownloaded
    case alreadyInQueue
    case insufficientSpace(needed: Int64?, free: Int64?)

    public var errorDescription: String? {
        switch self {
        case .notDownloadable: "This version can't be downloaded. Streams (HLS) and some servers don't allow it."
        case .alreadyDownloaded: "This is already downloaded."
        case .alreadyInQueue: "This is already in Downloads."
        case .insufficientSpace(let needed, let free):
            if let needed, let free {
                "Not enough free space: this needs \(Self.bytes(needed)) and \(Self.bytes(max(free, 0))) is free. Delete some downloads and try again."
            } else {
                "There isn't enough free space for this download. Delete some downloads and try again."
            }
        }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    public static func == (a: DownloadError, b: DownloadError) -> Bool {
        switch (a, b) {
        case (.notDownloadable, .notDownloadable), (.alreadyDownloaded, .alreadyDownloaded),
             (.alreadyInQueue, .alreadyInQueue), (.insufficientSpace, .insufficientSpace): true
        default: false
        }
    }
}
