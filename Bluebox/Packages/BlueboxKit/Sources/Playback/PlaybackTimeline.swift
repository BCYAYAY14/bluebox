import Foundation

/// What the scrub bar and the time label show for a position and duration.
///
/// The length counts as unknown when it's missing, not a positive number, or
/// shorter than the position by more than `tolerance` (an engine reporting a
/// stale or partial length). Unknown means no fill, no remaining time and
/// nothing to scrub, rather than a full bar with 0:00 left.
public struct PlaybackTimeline: Equatable, Sendable {
    /// The media length in seconds, or nil when it isn't known.
    public let duration: TimeInterval?
    /// The position in seconds, never negative and never past `duration`.
    public let position: TimeInterval

    public init(position: TimeInterval, duration: TimeInterval?, tolerance: TimeInterval = 2) {
        let p = position.isFinite ? max(position, 0) : 0
        if let d = duration, d.isFinite, d > 0, p <= d + tolerance {
            self.duration = d
            self.position = min(p, d)
        } else {
            self.duration = nil
            self.position = p
        }
    }

    public var isKnown: Bool { duration != nil }

    /// How far the bar is filled, 0...1 (0 when the length is unknown).
    public var fraction: Double { fraction(at: position) }

    /// `seconds` as a fraction of the length, 0...1 (0 when the length is unknown).
    public func fraction(at seconds: TimeInterval) -> Double {
        guard let duration, seconds.isFinite else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }

    /// The time at a point on the bar, or nil when the length is unknown.
    public func time(at fraction: Double) -> TimeInterval? {
        guard let duration, fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1) * duration
    }

    /// Time left after `seconds` (the position by default), or nil when the length is unknown.
    public func remaining(at seconds: TimeInterval? = nil) -> TimeInterval? {
        guard let duration else { return nil }
        let t = seconds.flatMap { $0.isFinite ? $0 : nil } ?? position
        return max(duration - min(max(t, 0), duration), 0)
    }
}
