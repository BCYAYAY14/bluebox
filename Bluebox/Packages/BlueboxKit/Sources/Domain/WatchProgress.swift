import Foundation

/// Playback progress for a single movie or episode.
public struct WatchProgress: Hashable, Codable, Sendable, Identifiable {
    /// Movie key or episode key.
    public let key: MediaKey
    public var position: TimeInterval
    public var duration: TimeInterval?
    public var isCompleted: Bool
    public var updatedAt: Date
    /// Diagnostic only; never used for ownership.
    public var deviceID: String?

    public var id: MediaKey { key }

    public init(
        key: MediaKey, position: TimeInterval, duration: TimeInterval?, isCompleted: Bool = false,
        updatedAt: Date, deviceID: String? = nil
    ) {
        self.key = key; self.position = position; self.duration = duration
        self.isCompleted = isCompleted; self.updatedAt = updatedAt; self.deviceID = deviceID
    }

    /// 0...1, or nil when the duration is unknown.
    public var fraction: Double? {
        guard let duration, duration > 0 else { return nil }
        if isCompleted { return 1 }
        return min(max(position / duration, 0), 1)
    }

    public var remaining: TimeInterval? {
        guard let duration, duration > 0 else { return nil }
        return max(duration - position, 0)
    }
}

/// Rules that turn raw player positions into stored progress.
public struct ProgressPolicy: Sendable, Hashable {
    /// Positions below this are not worth resuming (trailers, accidental taps).
    public var minimumResumePosition: TimeInterval = 30
    /// Fraction of the duration after which an item counts as watched.
    public var completionFraction: Double = 0.92
    /// Absolute time from the end after which an item counts as watched
    /// (covers long credits on short items).
    public var completionRemaining: TimeInterval = 120

    public init() {}

    public static let standard = ProgressPolicy()

    /// Clamps an invalid position (negative, NaN, past the end) to something storable.
    public func sanitize(position: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        guard position.isFinite, position > 0 else { return 0 }
        if let duration, duration.isFinite, duration > 0 { return min(position, duration) }
        return position
    }

    public func isComplete(position: TimeInterval, duration: TimeInterval?) -> Bool {
        guard let duration, duration.isFinite, duration > 0 else { return false }
        let p = sanitize(position: position, duration: duration)
        if p / duration >= completionFraction { return true }
        // Only apply the absolute rule when it is not most of the item.
        return duration > completionRemaining * 4 && duration - p <= completionRemaining
    }

    /// Builds the progress record to store for a player observation.
    public func record(
        key: MediaKey, position: TimeInterval, duration: TimeInterval?, at date: Date, deviceID: String? = nil
    ) -> WatchProgress {
        let validDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let p = sanitize(position: position, duration: validDuration)
        let done = isComplete(position: p, duration: validDuration)
        return WatchProgress(
            key: key, position: done ? (validDuration ?? p) : p, duration: validDuration,
            isCompleted: done, updatedAt: date, deviceID: deviceID
        )
    }

    /// Where playback should start for stored progress, or nil to start from the beginning.
    public func resumePosition(for progress: WatchProgress?) -> TimeInterval? {
        guard let progress, !progress.isCompleted else { return nil }
        guard progress.position >= minimumResumePosition else { return nil }
        if let d = progress.duration, d > 0, isComplete(position: progress.position, duration: d) { return nil }
        return progress.position
    }

    /// Where to start a file whose real length is `duration`, given a resume
    /// point. Nil (start from the beginning) when the point is in the closing
    /// stretch or past the end, which the stored progress can't always tell
    /// (its duration may be missing or differ from this copy's).
    public func startPosition(resumingAt position: TimeInterval?, duration: TimeInterval?) -> TimeInterval? {
        guard let position, position.isFinite, position > 0 else { return nil }
        guard let duration, duration.isFinite, duration > 0 else { return position }
        if position >= duration || isComplete(position: position, duration: duration) { return nil }
        return position
    }

    /// Whether an item belongs in Continue Watching.
    public func isInProgress(_ progress: WatchProgress) -> Bool {
        resumePosition(for: progress) != nil
    }
}

/// Deterministic merge for progress records that arrive from different devices.
///
/// Rules, in order:
/// 1. The newer `updatedAt` wins.
/// 2. On an exact timestamp tie, a completed record wins.
/// 3. Then the larger position wins.
/// 4. Then the lexicographically larger device ID wins (pure tiebreak so the
///    result is the same on every device regardless of argument order).
public enum ProgressMerge {
    public static func merge(_ a: WatchProgress, _ b: WatchProgress) -> WatchProgress {
        precondition(a.key == b.key, "Merging progress for different items")
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt ? a : b }
        if a.isCompleted != b.isCompleted { return a.isCompleted ? a : b }
        if a.position != b.position { return a.position > b.position ? a : b }
        return (a.deviceID ?? "") >= (b.deviceID ?? "") ? a : b
    }

    /// Merges an incoming record into an optional existing one. Returns the
    /// winner and whether the local value changed.
    public static func apply(incoming: WatchProgress, to existing: WatchProgress?) -> (WatchProgress, changed: Bool) {
        guard let existing else { return (incoming, true) }
        let winner = merge(existing, incoming)
        return (winner, winner != existing)
    }
}
