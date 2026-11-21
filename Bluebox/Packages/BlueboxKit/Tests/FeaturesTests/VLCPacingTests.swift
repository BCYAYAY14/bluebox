import Foundation
import Playback
import Subtitles
import Testing
@testable import VLCPlayback

/// How often the VLC engine wakes: its tick slows while nothing moves, and
/// the overlay's lines wake it only when one comes or goes.
@Suite @MainActor struct VLCPacingTests {
    @Test func tickSlowsOnlyWhileNothingMoves() {
        let fast = VLCEngine.fastTick, slow = VLCEngine.slowTick
        #expect(slow > fast)
        // Playing, opening or buffering: the position, the stall check and the buffer need it.
        for status in [PlaybackStatus.playing, .loading, .buffering] {
            #expect(VLCEngine.tickInterval(status: status, settling: false, positionMoved: false) == fast)
        }
        // Paused, ended, failed: nothing to watch closely.
        for status in [PlaybackStatus.paused, .ended, .idle, .failed(.decodeFailed("x"))] {
            #expect(VLCEngine.tickInterval(status: status, settling: false, positionMoved: false) == slow)
        }
        // A seek still landing, or the clock running on under a pause: quick again.
        #expect(VLCEngine.tickInterval(status: .paused, settling: true, positionMoved: false) == fast)
        #expect(VLCEngine.tickInterval(status: .paused, settling: false, positionMoved: true) == fast)
    }

    static func seconds(_ d: Duration?) -> Double? { d.map { $0 / .seconds(1) } }

    @Test func overlayWakesAtTheNextLineChange() throws {
        let dialogue = SubtitleTimeline(cues: [SubtitleCue(start: 10, end: 12, text: "One"),
                                               SubtitleCue(start: 13, end: 15, text: "Two")])
        // Just past the next line's start, and its end once it shows.
        #expect(abs(try #require(Self.seconds(VLCEngine.overlayWake(after: 9.5, timelines: [dialogue], rate: 1))) - 0.502) < 1e-9)
        #expect(abs(try #require(Self.seconds(VLCEngine.overlayWake(after: 11, timelines: [dialogue], rate: 1))) - 1.002) < 1e-9)
        // At 2× the same stretch of film goes by in half the time.
        #expect(abs(try #require(Self.seconds(VLCEngine.overlayWake(after: 9.5, timelines: [dialogue], rate: 2))) - 0.252) < 1e-9)
        // Nothing in the next two seconds, or nothing at all: the tick looks again first.
        #expect(VLCEngine.overlayWake(after: 5, timelines: [dialogue], rate: 1) == nil)
        #expect(VLCEngine.overlayWake(after: 20, timelines: [dialogue], rate: 1) == nil)
        #expect(VLCEngine.overlayWake(after: 5, timelines: [], rate: 1) == nil)
    }

    @Test func overlayWakesForWhicheverTrackChangesFirst() throws {
        // A sign up for minutes on the second line, with dialogue coming and going under it.
        let sign = SubtitleTimeline(cues: [SubtitleCue(start: 0, end: 100, text: "Sign")])
        let dialogue = SubtitleTimeline(cues: [SubtitleCue(start: 50, end: 51, text: "Line")])
        #expect(abs(try #require(Self.seconds(VLCEngine.overlayWake(after: 49, timelines: [sign, dialogue], rate: 1))) - 1.002) < 1e-9)
        #expect(VLCEngine.overlayWake(after: 60, timelines: [sign, dialogue], rate: 1) == nil)
        // The sign going away is a change too.
        #expect(abs(try #require(Self.seconds(VLCEngine.overlayWake(after: 99, timelines: [sign, dialogue], rate: 1))) - 1.002) < 1e-9)
    }

    @Test func clipIsCutOffTheMainActor() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bluebox-keeplast-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // 70 s of a ramp, so the bytes kept show which end was kept.
        let samples = Data((0..<(70 * 32_000)).map { UInt8(truncatingIfNeeded: $0 / 32_000) })
        try (VLCAudioClip.wavHeader(dataBytes: samples.count) + samples).write(to: url)
        let kept = try await Task.detached { try VLCAudioClip.keepLast(60, of: url) }.value
        #expect(kept == 60)
        let written = try Data(contentsOf: url)
        #expect(written == VLCAudioClip.wavHeader(dataBytes: 60 * 32_000) + samples.suffix(60 * 32_000))
        #expect(written.last == 69)
    }
}

/// The overlay follows a drift fix's speed on VLC's MKV text tracks.
@Suite struct VLCOverlaySpeedTests {
    @Test func theOverlayLooksUpTheTracksTimeWithDelayAndSpeed() {
        // As SubtitleOffset.cueTime: (t − delay) × scale.
        #expect(VLCEngine.overlayTrackTime(clock: 100, delay: 0, scale: 1) == 100)
        #expect(VLCEngine.overlayTrackTime(clock: 100, delay: 2, scale: 1) == 98)
        let scale = 25 / (24000.0 / 1001)
        let offset = SubtitleOffset(seconds: -2, scale: scale)
        for t in [10.0, 600, 5400] {
            #expect(abs(VLCEngine.overlayTrackTime(clock: t, delay: offset.seconds, scale: offset.scale) - offset.cueTime(forPlayerTime: t)) < 1e-9)
        }
    }
}
