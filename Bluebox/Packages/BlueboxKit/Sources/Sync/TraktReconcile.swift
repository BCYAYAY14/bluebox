import Domain
import Foundation

// Pure merge rules for Trakt's watched history and ratings, kept apart from
// the network so they can be tested exhaustively.
//
// Both are three-way merges against what both sides agreed on after the last
// sync (`base`: each agreed item with the time of the change both sides
// hold), so a removal on one side is carried over instead of being undone by
// the other side still having it. A local record newer than its base time
// changed here since. When both sides changed the same item, the newer
// change wins.

/// Watched history.
public enum HistoryReconcile {
    /// Plays within this window count as the same play (a scrobble and the
    /// progress record it came from are stamped a little apart).
    public static let samePlayWindow: TimeInterval = 15 * 60
    /// A record reset below this position is "unwatched", not a rewatch in progress.
    public static let unwatchedBelow: TimeInterval = 30

    public struct Plan: Equatable, Sendable {
        /// Remote plays to record here as completed, at Trakt's time.
        public var importLocal: [MediaKey: Date] = [:]
        /// Watched here, but removed on Trakt since the last sync: reset here.
        public var markLocalUnwatched: Set<MediaKey> = []
        /// Plays to send to Trakt, at the local time.
        public var addRemote: [MediaKey: Date] = [:]
        /// Unwatched here since Trakt's play: remove it on Trakt.
        public var removeRemote: Set<MediaKey> = []
        /// Watched on both sides once the plan is applied, with the play time both hold.
        public var agreed: [MediaKey: Date] = [:]
    }

    /// - Parameters:
    ///   - local: progress records for movies and episodes.
    ///   - remote: Trakt's last play of each watched movie and episode.
    ///   - base: what was agreed after the last sync, nil before the first.
    public static func plan(local: [MediaKey: WatchProgress], remote: [MediaKey: Date], base: [MediaKey: Date]?) -> Plan {
        var p = Plan()
        for key in Set(local.keys).union(remote.keys) {
            let l = local[key]
            let agreedAt = base?[key]
            // Changed here since both sides agreed (a second of slack for rounding).
            let changedHere = l.map { l in agreedAt.map { l.updatedAt > $0.addingTimeInterval(1) } ?? true } ?? false
            switch (l, remote[key]) {
            case let (l?, r?) where l.isCompleted:
                // Both watched. A clearly later play here is a rewatch Trakt should hear about.
                if l.updatedAt > r.addingTimeInterval(samePlayWindow) {
                    p.addRemote[key] = l.updatedAt
                    p.agreed[key] = l.updatedAt
                } else {
                    p.agreed[key] = max(l.updatedAt, r)
                }
            case let (l?, r?) where l.updatedAt > r:
                // Changed here after Trakt's play: an explicit reset removes it from
                // Trakt; a rewatch in progress leaves Trakt's play alone.
                if agreedAt != nil, changedHere, l.position < unwatchedBelow {
                    p.removeRemote.insert(key)
                } else {
                    p.agreed[key] = r
                }
            case let (_, r?):
                // Trakt's play is the newer news.
                p.importLocal[key] = r
                p.agreed[key] = r
            case let (l?, nil) where l.isCompleted:
                if agreedAt != nil, !changedHere {
                    p.markLocalUnwatched.insert(key)  // removed on Trakt, untouched here
                } else {
                    p.addRemote[key] = l.updatedAt  // new here, or watched again since Trakt's removal
                    p.agreed[key] = l.updatedAt
                }
            default:
                break
            }
        }
        return p
    }
}

/// A rating here: 1–10, or nil once removed (kept as a marker so the removal syncs).
public struct LocalRating: Codable, Sendable, Equatable {
    public var rating: Int?
    public var updatedAt: Date
    public init(rating: Int?, updatedAt: Date) { self.rating = rating; self.updatedAt = updatedAt }
}

public struct RemoteRating: Sendable, Equatable {
    public var rating: Int
    public var ratedAt: Date
    public init(rating: Int, ratedAt: Date) { self.rating = rating; self.ratedAt = ratedAt }
}

/// Ratings.
public enum RatingsReconcile {
    public struct Plan: Equatable, Sendable {
        public var setLocal: [MediaKey: RemoteRating] = [:]
        public var removeLocal: Set<MediaKey> = []
        public var setRemote: [MediaKey: LocalRating] = [:]
        public var removeRemote: Set<MediaKey> = []
        /// Rated on both sides once the plan is applied, with the time of that rating.
        public var agreed: [MediaKey: Date] = [:]
    }

    public static func plan(local: [MediaKey: LocalRating], remote: [MediaKey: RemoteRating], base: [MediaKey: Date]?) -> Plan {
        var p = Plan()
        for key in Set(local.keys).union(remote.keys) {
            let l = local[key], r = remote[key]
            let agreedAt = base?[key]
            let changedHere = l.map { l in agreedAt.map { l.updatedAt > $0.addingTimeInterval(1) } ?? true } ?? false
            switch (l, r) {
            case let (l?, r?):
                if let value = l.rating {
                    if value != r.rating, l.updatedAt > r.ratedAt {
                        p.setRemote[key] = l
                        p.agreed[key] = l.updatedAt
                    } else {
                        if value != r.rating { p.setLocal[key] = r }
                        p.agreed[key] = value == r.rating ? max(l.updatedAt, r.ratedAt) : r.ratedAt
                    }
                } else if l.updatedAt > r.ratedAt {
                    p.removeRemote.insert(key)  // cleared here after Trakt's rating
                } else {
                    p.setLocal[key] = r  // rated again on Trakt after the clearing here
                    p.agreed[key] = r.ratedAt
                }
            case let (nil, r?):
                p.setLocal[key] = r
                p.agreed[key] = r.ratedAt
            case let (l?, nil) where l.rating != nil:
                if agreedAt != nil, !changedHere {
                    p.removeLocal.insert(key)  // removed on Trakt, untouched here
                } else {
                    p.setRemote[key] = l
                    p.agreed[key] = l.updatedAt
                }
            default:
                break
            }
        }
        return p
    }
}
