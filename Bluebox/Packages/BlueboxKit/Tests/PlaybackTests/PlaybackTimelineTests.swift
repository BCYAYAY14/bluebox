import Foundation
import Playback
import Testing

/// The scrub bar and the time label for a player snapshot.
@Suite struct PlaybackTimelineTests {
    @Test func knownLengthFillsAndCountsDown() {
        let t = PlaybackTimeline(position: 600, duration: 1440)
        #expect(t.isKnown)
        #expect(abs(t.fraction - 600.0 / 1440) < 1e-9)
        #expect(t.remaining() == 840)
        #expect(t.time(at: 0.5) == 720)
        #expect(t.fraction(at: 1440) == 1)
    }

    /// The reported bug: a resumed episode drawn full with 0:00 left while playing.
    @Test func positionPastTheLengthIsUnknownNotFinished() {
        let t = PlaybackTimeline(position: 900, duration: 540)
        #expect(!t.isKnown)
        #expect(t.fraction == 0)
        #expect(t.remaining() == nil)
        #expect(t.time(at: 0.9) == nil)  // nothing to scrub to
        #expect(t.position == 900)
    }

    @Test func missingZeroOrInvalidLengthIsUnknown() {
        for d: TimeInterval? in [nil, 0, -5, .nan, .infinity] {
            let t = PlaybackTimeline(position: 30, duration: d)
            #expect(!t.isKnown)
            #expect(t.fraction == 0)
            #expect(t.remaining() == nil)
            #expect(t.time(at: 0.5) == nil)
        }
    }

    @Test func theRealEndIsFull() {
        let t = PlaybackTimeline(position: 1440, duration: 1440)
        #expect(t.isKnown)
        #expect(t.fraction == 1)
        #expect(t.remaining() == 0)
        // A slight overshoot (clock vs. reported length) still counts as the end.
        #expect(PlaybackTimeline(position: 1441, duration: 1440).remaining() == 0)
        #expect(PlaybackTimeline(position: 1441, duration: 1440).position == 1440)
    }

    @Test func positionIsSanitized() {
        #expect(PlaybackTimeline(position: -3, duration: 100).position == 0)
        #expect(PlaybackTimeline(position: .nan, duration: 100).position == 0)
        #expect(PlaybackTimeline(position: .nan, duration: 100).fraction == 0)
    }

    @Test func scrubbingMapsAndClampsToTheLength() {
        let t = PlaybackTimeline(position: 0, duration: 200)
        #expect(t.time(at: 0) == 0)
        #expect(t.time(at: 1) == 200)
        #expect(t.time(at: 1.4) == 200)
        #expect(t.time(at: -1) == 0)
        #expect(t.time(at: .nan) == nil)
        // The label while dragging counts down from the drag point.
        #expect(t.remaining(at: t.time(at: 0.25)) == 150)
        #expect(t.remaining(at: 500) == 0)
        #expect(t.fraction(at: 50) == 0.25)
        #expect(t.fraction(at: .nan) == 0)
    }
}
