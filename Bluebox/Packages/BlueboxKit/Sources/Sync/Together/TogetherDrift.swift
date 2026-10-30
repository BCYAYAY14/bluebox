import Foundation

/// Keeps a player in step with the room's anchor. Small gaps are closed by
/// playing a little faster or slower, which nobody notices; big ones by
/// seeking, which everyone does.
///
///   |drift| < `tolerance`            nothing (or stop nudging, once within `settled`)
///   `tolerance` ≤ |drift| < `seekBeyond`   nudge the rate, up to ±`maxNudge`
///   |drift| ≥ `seekBeyond`           seek to where the anchor will be after the seek
///
/// Drift is local minus anchor: positive means this player is ahead.
public struct DriftCorrector: Sendable {
    public enum Correction: Equatable, Sendable {
        case none
        /// Play at this rate until told otherwise.
        case nudge(rate: Float)
        /// Back to the room's rate: close enough now.
        case restore(rate: Float)
        case seek(to: TimeInterval)
    }

    /// The task's ~0.5 s: less than this is lip-sync territory nobody watching together notices.
    public var tolerance: TimeInterval = 0.5
    /// A nudge stops once within this, so the rate doesn't flap at the edge of `tolerance`.
    public var settled: TimeInterval = 0.15
    /// Beyond this a nudge would take too long (3 s at 5 % is a minute): seek.
    public var seekBeyond: TimeInterval = 3
    /// At most 5 % faster or slower: within what scaletempo keeps natural.
    public var maxNudge: Double = 0.05
    /// Aim to close the gap over this long.
    public var catchUp: TimeInterval = 8
    /// Seeks land late by about this much (VLC re-buffers), so aim ahead of the anchor.
    public var seekLead: TimeInterval = 0.3

    public private(set) var nudging = false

    public init() {}

    /// What to do, given where this player is and where the anchor is now.
    /// `rate` is the room's rate (what both play at when in step).
    public mutating func correct(local: TimeInterval, anchor: TimeInterval, rate: Float) -> Correction {
        let drift = local - anchor
        let size = abs(drift)
        if size >= seekBeyond {
            nudging = false
            return .seek(to: max(anchor + seekLead * Double(rate), 0))
        }
        if size < tolerance && (!nudging || size < settled) {
            guard nudging else { return .none }
            nudging = false
            return .restore(rate: rate)
        }
        // Ahead: slow down; behind: speed up. Proportional, so it eases in.
        let change = min(max(-drift / catchUp, -maxNudge), maxNudge)
        nudging = true
        return .nudge(rate: Float(Double(rate) * (1 + change)))
    }

    /// Forget any nudge (after a seek, a pause or a new title).
    public mutating func reset() { nudging = false }
}
