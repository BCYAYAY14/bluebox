import Foundation

// When a debrid account has lapsed, hit a limit or doesn't hold a release
// yet, debrid add-ons answer the play link with a short clip that says so
// instead of the film. Played or downloaded as it is, that clip looks like a
// release that works (and a 10-second file like a finished download). These
// recognise the clips by where they live, from each add-on's source:
//
// - Torrentio redirects to `/videos/<name>_v<n>.mp4` (`addon/static/videos`,
//   named in `addon/crates/addon/src/providers/static_videos.rs`).
// - MediaFusion redirects to `/static/exceptions/<name>.mp4` (`resources/exceptions`).
// - Comet sends `comet/assets/status_videos/<NAME>.mp4` as the play link's own
//   body, with no redirect, so it is caught by its size (`problem(totalBytes:expectedBytes:)`).

/// What a debrid add-on's notice clip says went wrong.
public enum DebridProblem: String, Sendable, Hashable, Codable, CaseIterable {
    /// The subscription has run out, or the account is blocked.
    case planExpired
    /// The service didn't accept the API key.
    case keyRejected
    /// The service doesn't hold the release yet and is fetching it.
    case notCachedYet
    /// A daily, monthly or active-download limit was reached.
    case limitReached
    /// The release is packed in a RAR the service won't stream.
    case archiveUnsupported
    /// Anything else the add-on couldn't do with this release.
    case failed

    /// Whether another release may play: the account itself is fine.
    public var isPerRelease: Bool {
        switch self {
        case .notCachedYet, .archiveUnsupported, .failed: true
        case .planExpired, .keyRejected, .limitReached: false
        }
    }
}

public enum DebridPlaceholder {
    /// A finished download under this share of the size the add-on gave is a clip, not the release.
    public static let minimumFraction = 0.05
    /// With no size to compare against, a "video" this small from a debrid link is a clip.
    public static let clipBytes: Int64 = 5_000_000

    /// The problem a link names when it is one of the add-ons' notice clips; nil for anything else.
    public static func problem(for url: URL) -> DebridProblem? {
        let parts = url.path.lowercased().split(separator: "/").map(String.init)
        guard let file = parts.last, file.hasSuffix(".mp4"), parts.count >= 2 else { return nil }
        let name = String(file.dropLast(4))
        let folder = parts[parts.count - 2]
        if folder == "videos", let stem = torrentioStem(name) { return torrentio(stem) }
        if folder == "exceptions", parts.count >= 3, parts[parts.count - 3] == "static" { return mediaFusion(name) }
        if folder == "status_videos" { return comet(name) ?? .failed }
        return nil
    }

    /// A body far smaller than the release should be: a clip. `expectedBytes`
    /// is the add-on's size for the release, when it gave one.
    public static func problem(totalBytes: Int64?, expectedBytes: Int64?) -> DebridProblem? {
        guard let totalBytes, totalBytes >= 0 else { return nil }
        if let expectedBytes, expectedBytes > 0 {
            return Double(totalBytes) < Double(expectedBytes) * minimumFraction ? .failed : nil
        }
        return totalBytes < clipBytes ? .failed : nil
    }

    /// "failed_access_v3" → "failed_access"; nil without the version suffix Torrentio always adds.
    static func torrentioStem(_ name: String) -> String? {
        guard let range = name.range(of: #"_v\d+$"#, options: .regularExpression) else { return nil }
        let stem = String(name[..<range.lowerBound])
        let known = ["downloading", "download_failed", "limits_exceeded", "blocked_access"]
        return known.contains(stem) || stem.hasPrefix("failed_") ? stem : nil
    }

    static func torrentio(_ stem: String) -> DebridProblem {
        switch stem {
        case "downloading": .notCachedYet
        case "failed_access", "blocked_access": .planExpired
        case "limits_exceeded": .limitReached
        case "failed_rar": .archiveUnsupported
        default: .failed  // download_failed, failed_too_big, failed_opening, failed_unexpected, failed_infringement, failed_unavailable
        }
    }

    static func mediaFusion(_ name: String) -> DebridProblem {
        switch name {
        case "torrent_downloading", "torrent_not_downloaded": .notCachedYet
        case "need_premium": .planExpired
        case "invalid_token", "invalid_credentials", "configure_debrid", "invalid_debrider_token": .keyRejected
        case "daily_download_limit", "torrent_limit", "too_many_requests", "exceed_remote_traffic_limit", "queue_full":
            .limitReached
        default: .failed
        }
    }

    /// Comet's names, lowercased; nil for a name that isn't one of them.
    static func comet(_ name: String) -> DebridProblem? {
        switch name {
        case "media_not_cached_yet": .notCachedYet
        case "must_be_premium", "magnet_must_be_premium", "payment_required", "account_invalid", "auth_blocked",
             "auth_user_banned", "plan_restricted_feature":
            .planExpired
        case "auth_bad_apikey", "auth_missing_apikey", "bad_token", "badtoken", "expired_token", "no_auth",
             "unauthorized", "unauthenticated", "invalid_account_or_password":
            .keyRejected
        case "active_limit", "monthly_limit", "cooldown_limit", "free_trial_limit_reached", "store_limit_exceeded",
             "too_many_requests", "proxy_limit_reached":
            .limitReached
        case "link_offline", "download_server_error", "store_server_down", "store_magnet_invalid", "unknown":
            .failed
        default: nil
        }
    }
}

/// A debrid link that leads to a notice clip rather than the release.
public struct DebridLinkError: LocalizedError, Hashable, Sendable {
    public let problem: DebridProblem
    /// The service's name ("Real-Debrid"), when known.
    public let service: String?

    public init(_ problem: DebridProblem, service: String? = nil) {
        self.problem = problem; self.service = service
    }

    public var errorDescription: String? {
        let name = service ?? "Your debrid service"
        let own = service.map { "Your \($0)" } ?? "Your debrid"
        return switch problem {
        case .planExpired: "\(own) plan has expired, or the account can't be used right now. Renew it on \(service.map { "\($0)'s" } ?? "the service's") site, then try again."
        case .keyRejected: "\(name) didn't accept your API key. Check it in Settings › Torrents & Debrid."
        case .notCachedYet: "\(name) doesn't have this release ready yet and is downloading it now. Try again in a few minutes, or pick another release."
        case .limitReached: "You've reached \(service.map { "\($0)'s" } ?? "your debrid service's") download limit. Wait for it to reset, or check your account."
        case .archiveUnsupported: "This release is packed in an archive \(service ?? "the service") can't stream. Pick another release."
        case .failed: "\(name) sent a short notice clip instead of this release. Pick another release."
        }
    }
}
