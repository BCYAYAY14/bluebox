import Foundation
import Playback
import Testing

/// The subtitle clock between the engine's position updates.
@Suite struct PlayheadClockTests {
    let start = ContinuousClock.now

    @Test func runsOnAtThePlaybackRate() {
        var clock = PlayheadClock()
        #expect(clock.time(position: 10, playing: true, rate: 2, now: start) == 10)
        #expect(abs(clock.time(position: 10, playing: true, rate: 2, now: start + .milliseconds(200)) - 10.4) < 0.001)
        // Never more than half a second of wall time past the last report.
        #expect(abs(clock.time(position: 10, playing: true, rate: 2, now: start + .seconds(3)) - 11) < 0.001)
    }

    @Test func holdsInsteadOfSteppingBackALittle() {
        var clock = PlayheadClock()
        _ = clock.time(position: 10, playing: true, rate: 1, now: start)
        let ahead = clock.time(position: 10, playing: true, rate: 1, now: start + .milliseconds(300))
        // The engine reports a little behind where the clock had run to: it holds.
        #expect(clock.time(position: 10.1, playing: true, rate: 1, now: start + .milliseconds(310)) == ahead)
    }

    @Test func followsASeekBackAndAPause() {
        var clock = PlayheadClock()
        _ = clock.time(position: 60, playing: true, rate: 1, now: start)
        #expect(clock.time(position: 50, playing: true, rate: 1, now: start + .milliseconds(10)) == 50)
        _ = clock.time(position: 50, playing: true, rate: 1, now: start + .milliseconds(300))
        // Paused (a frame stepped back), the reported position is the truth.
        #expect(clock.time(position: 49.96, playing: false, rate: 1, now: start + .milliseconds(320)) == 49.96)
    }
}
