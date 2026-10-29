import Foundation
@testable import Playback
import Testing

@Suite struct PlaybackWatchdogTests {
    typealias S = PlaybackWatchdog.Sample

    static func playing(_ t: Double, frame: Bool, video: Bool = true) -> S {
        S(state: .playing, position: t, newFrame: frame, watchesVideo: video, now: t)
    }

    @Test func healthyPlaybackDoesNothing() {
        var w = PlaybackWatchdog()
        for t in 0..<30 { #expect(w.observe(Self.playing(Double(t), frame: true)) == .none) }
    }

    @Test func frozenVideoIsNudgedThenReloaded() {
        var w = PlaybackWatchdog()
        #expect(w.observe(Self.playing(0, frame: true)) == .none)
        #expect(w.observe(Self.playing(1, frame: false)) == .none)
        #expect(w.observe(Self.playing(2, frame: false)) == .none)
        #expect(w.observe(Self.playing(3, frame: false)) == .nudgeVideo)
        // Still frozen: one more nudge, then a reload.
        var actions: [PlaybackWatchdog.Action] = []
        for t in 4...9 { actions.append(w.observe(Self.playing(Double(t), frame: false))) }
        #expect(actions == [.none, .none, .nudgeVideo, .none, .none, .reload])
        #expect(w.reloads == 1)
    }

    @Test func aNewFrameClearsTheFreeze() {
        var w = PlaybackWatchdog()
        _ = w.observe(Self.playing(0, frame: true))
        _ = w.observe(Self.playing(3, frame: false))
        #expect(w.observe(Self.playing(4, frame: true)) == .none)
        #expect(w.observe(Self.playing(6, frame: false)) == .none)
    }

    @Test func audioOnlyAndExternalPlaybackAreIgnored() {
        var w = PlaybackWatchdog()
        for t in 0..<20 { #expect(w.observe(Self.playing(Double(t), frame: false, video: false)) == .none) }
    }

    @Test func seekingRestartsTheFreezeClock() {
        var w = PlaybackWatchdog()
        _ = w.observe(Self.playing(0, frame: true))
        w.noteSeek()
        #expect(w.observe(Self.playing(120, frame: false)) == .none)
        #expect(w.observe(Self.playing(121, frame: true)) == .none)
    }

    @Test func longStallReloads() {
        var w = PlaybackWatchdog()
        for t in 0..<15 {
            #expect(w.observe(S(state: .waiting, position: 50, newFrame: false, watchesVideo: true, now: Double(t))) == .none)
        }
        #expect(w.observe(S(state: .waiting, position: 50, newFrame: false, watchesVideo: true, now: 15)) == .reload)
    }

    @Test func pausingIsNeverAStall() {
        var w = PlaybackWatchdog()
        for t in 0..<100 {
            #expect(w.observe(S(state: .paused, position: 50, newFrame: false, watchesVideo: true, now: Double(t))) == .none)
        }
    }

    @Test func retriesRunOutAndComeBackAfterHealthyPlayback() {
        var w = PlaybackWatchdog()
        #expect(w.recoverableFailure() == .reload)
        #expect(w.recoverableFailure() == .reload)
        #expect(w.recoverableFailure() == .reload)
        #expect(w.recoverableFailure() == .giveUp)
        for t in 0...60 { _ = w.observe(Self.playing(Double(t), frame: true)) }
        #expect(w.reloads == 0)
        #expect(w.recoverableFailure() == .reload)
    }
}
