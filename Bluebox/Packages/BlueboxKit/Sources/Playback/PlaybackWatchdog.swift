import Foundation

/// Decides when a playing stream needs help. Fed one sample a second by the
/// engine; kept free of AVFoundation so the rules can be tested directly.
///
/// - Frozen video: the clock keeps moving (audio plays) but no new video frame
///   has arrived for `freezeThreshold` seconds of media time. A seek to the
///   current position flushes the decoder, which fixes this in practice.
///   If that doesn't help twice in a row, the item is rebuilt.
/// - Stall: the player has been waiting for data for `stallThreshold` seconds.
///   The item is rebuilt at the current position, which reopens the connection.
/// - Network failure: the item is rebuilt, up to `maxReloads` times. Healthy
///   playback for `healthyResetAfter` seconds earns the retries back.
public struct PlaybackWatchdog: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Seek to the current position to restart video decoding.
        case nudgeVideo
        /// Rebuild the player item at the current position.
        case reload
        /// Retries are spent; let the failure stand.
        case giveUp
    }

    public struct Sample: Sendable {
        public enum State: Sendable { case playing, waiting, paused }
        public var state: State
        public var position: TimeInterval
        /// The video output produced at least one new frame since the last sample.
        public var newFrame: Bool
        /// False for audio-only items and while video plays on an external screen.
        public var watchesVideo: Bool
        public var now: TimeInterval

        public init(state: State, position: TimeInterval, newFrame: Bool, watchesVideo: Bool, now: TimeInterval) {
            self.state = state; self.position = position; self.newFrame = newFrame
            self.watchesVideo = watchesVideo; self.now = now
        }
    }

    public var freezeThreshold: TimeInterval = 3
    public var stallThreshold: TimeInterval = 15
    public var maxReloads = 3
    public var healthyResetAfter: TimeInterval = 60

    public private(set) var reloads = 0
    private var lastFramePosition: TimeInterval?
    private var nudgesSinceFrame = 0
    private var waitingSince: TimeInterval?
    private var healthySince: TimeInterval?

    public init() {}

    public mutating func observe(_ s: Sample) -> Action {
        switch s.state {
        case .paused:
            waitingSince = nil; healthySince = nil
            lastFramePosition = nil
            return .none

        case .waiting:
            healthySince = nil
            lastFramePosition = nil
            let since = waitingSince ?? s.now
            waitingSince = since
            guard s.now - since >= stallThreshold else { return .none }
            waitingSince = nil
            return reloadIfAllowed()

        case .playing:
            waitingSince = nil
            if healthySince == nil { healthySince = s.now }
            if let h = healthySince, s.now - h >= healthyResetAfter { reloads = 0 }
            guard s.watchesVideo else { lastFramePosition = nil; return .none }
            if s.newFrame || lastFramePosition == nil {
                if s.newFrame { nudgesSinceFrame = 0 }
                lastFramePosition = s.position
                return .none
            }
            guard let last = lastFramePosition, s.position - last >= freezeThreshold else { return .none }
            healthySince = nil
            lastFramePosition = s.position  // give the fix time to work before acting again
            nudgesSinceFrame += 1
            if nudgesSinceFrame <= 2 { return .nudgeVideo }
            nudgesSinceFrame = 0
            return reloadIfAllowed()
        }
    }

    /// The item failed with an error that a fresh connection might fix.
    public mutating func recoverableFailure() -> Action {
        healthySince = nil
        return reloadIfAllowed()
    }

    /// The position jumped; measure freezes from the new position.
    public mutating func noteSeek() { lastFramePosition = nil }

    /// A new item was loaded by the user (not a recovery): start over.
    public mutating func reset() {
        reloads = 0; lastFramePosition = nil; nudgesSinceFrame = 0
        waitingSince = nil; healthySince = nil
    }

    private mutating func reloadIfAllowed() -> Action {
        guard reloads < maxReloads else { return .giveUp }
        reloads += 1
        lastFramePosition = nil
        return .reload
    }
}
