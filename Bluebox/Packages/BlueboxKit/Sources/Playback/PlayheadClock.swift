import Foundation

/// The playhead between the engine's position updates, for timing subtitle
/// lines: the last reported position plus the time since, at the playback
/// rate, while playing (never more than half a second of wall time on).
///
/// It never steps back a little: the engines' reported positions jitter, and
/// running ahead and then falling back put the next line on screen and took
/// it off again. A step back bigger than `seekThreshold` is a seek and is
/// followed; so is anything while paused or after `reset()`.
public struct PlayheadClock: Sendable {
    /// Further back than this (in media seconds, at 1×) is a seek, not jitter.
    public static let seekThreshold: TimeInterval = 0.4
    static let maxExtrapolation: TimeInterval = 0.5

    private var mark: (position: TimeInterval, at: ContinuousClock.Instant)?
    private var shown: TimeInterval?

    public init() {}

    public mutating func reset() { mark = nil; shown = nil }

    public mutating func time(position: TimeInterval, playing: Bool, rate: Float,
                              now: ContinuousClock.Instant = .now) -> TimeInterval {
        let rate = Double(max(rate, 0.01))
        if mark?.position != position { mark = (position, now) }
        var t = position
        if playing, let mark {
            let elapsed = now - mark.at
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            t = mark.position + min(max(seconds, 0), Self.maxExtrapolation) * rate
        }
        // Paused, the reported position is the truth (a frame step back must show).
        if playing, let shown, t < shown, shown - t < Self.seekThreshold * max(rate, 1) { t = shown }
        shown = t
        return t
    }
}
