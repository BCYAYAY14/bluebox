import Domain
import Foundation
import Observation
@testable import Playback
import Testing

/// Set from an observation's change handler.
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func set() { lock.withLock { fired = true } }
    var value: Bool { lock.withLock { fired } }
}

/// The player's views follow the session's state in parts, so the playhead
/// moving several times a second doesn't redraw what doesn't show the time.
@MainActor
@Suite struct SessionObservationTests {
    let movie = NowPlayingItem(key: .movie(tmdbID: 1), title: "One")

    private func flag(_ read: @escaping () -> Void) -> ChangeFlag {
        let f = ChangeFlag()
        withObservationTracking { read() } onChange: { f.set() }
        return f
    }

    @Test func aPlayheadTickLeavesTheSlowStateAlone() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress())
        await s.start(movie, resource: resource())
        let before = s.slowSnapshot
        let slow = flag { _ = s.slowSnapshot }
        let events = flag { _ = s.events }
        let position = flag { _ = s.position }

        engine.advance(to: 42)
        engine.snapshot.bufferedUntil = 80
        engine.snapshot.embeddedSubtitleText = "Hello"

        #expect(!slow.value)
        #expect(!events.value)
        #expect(position.value)
        #expect(s.slowSnapshot == before)
        // Everything still reads as one value, as it did.
        #expect(s.snapshot.position == 42 && s.position == 42 && s.displayPosition == 42)
        #expect(s.snapshot.bufferedUntil == 80 && s.bufferedUntil == 80)
        #expect(s.snapshot.embeddedSubtitleText == "Hello")
        #expect(s.snapshot.status == .playing && s.snapshot.duration == 3600)
        // The slow part leaves the moving fields out rather than holding a stale copy.
        #expect(s.slowSnapshot.position == 0 && s.slowSnapshot.embeddedSubtitleText == nil)
    }

    @Test func theSameReportAgainChangesNothing() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress())
        await s.start(movie, resource: resource())
        engine.advance(to: 42)
        let slow = flag { _ = s.slowSnapshot }
        let position = flag { _ = s.position }
        engine.advance(to: 42)  // paused, or the engine reporting again
        #expect(!slow.value && !position.value)
    }

    @Test func aRealChangeReachesTheSlowState() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress())
        await s.start(movie, resource: resource())
        let slow = flag { _ = s.slowSnapshot }
        engine.pause()
        #expect(slow.value)
        #expect(s.slowSnapshot.status == .paused && s.snapshot.status == .paused)
        #expect(!s.appearsPlaying)
    }
}
