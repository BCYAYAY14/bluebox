import Foundation

/// The playhead between the engine's position updates, for timing subtitle
/// lines: the last reported position plus the time since, at the playback
/// rate, while playing (never more than half a second of wall time on).
///
/// It never steps back a little: the engines' reported positions jitter, and
/// running ahead and then falling back put the next line on screen and took
/// it off again. A step back bigger than `seekThreshold` is a seek and is
/// followed; so is anything while paused or after `reset()`.
///
/// It starts again from the reported position when play starts or stops (a
/// resume used to run on from the last report before the pause, half a
/// second early, and the hold kept it there) and when no new position has
/// come for `stallAfter` while playing (a stall the engine still calls
/// playing: the lines wait with the picture instead of running ahead).
public struct PlayheadClock: Sendable {
    /// Further back than this (in media seconds, at 1×) is a seek, not jitter.
    public static let seekThreshold: TimeInterval = 0.4
    static let maxExtrapolation: TimeInterval = 0.5
    /// No new position for this long (wall time) while playing is a stall. The
    /// engines report at least every half second (AVPlayer a quarter second of
    /// video, so half a second at 0.5×; VLC's tick four times a second).
    static let stallAfter: TimeInterval = 1

    private var mark: (position: TimeInterval, at: ContinuousClock.Instant)?
    private var shown: TimeInterval?
    private var wasPlaying: Bool?

    public init() {}

    public mutating func reset() { mark = nil; shown = nil; wasPlaying = nil }

    public mutating func time(position: TimeInterval, playing: Bool, rate: Float,
                              now: ContinuousClock.Instant = .now) -> TimeInterval {
        let rate = Double(max(rate, 0.01))
        // Play or pause: run on from here and now, not from a report made before.
        if wasPlaying != playing { mark = nil; shown = nil; wasPlaying = playing }
        if mark?.position != position { mark = (position, now) }
        var t = position
        if playing, let mark {
            let seconds = Self.seconds(now - mark.at)
            if seconds >= Self.stallAfter {
                // Stalled: the reported position, and nothing held ahead of it.
                shown = nil
            } else {
                t = mark.position + min(max(seconds, 0), Self.maxExtrapolation) * rate
            }
        }
        // Paused, the reported position is the truth (a frame step back must show).
        if playing, let shown, t < shown, shown - t < Self.seekThreshold * max(rate, 1) { t = shown }
        shown = t
        return t
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
