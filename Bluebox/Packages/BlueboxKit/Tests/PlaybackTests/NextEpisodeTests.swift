import Domain
import Foundation
@testable import Playback
import Testing

/// Counts provider calls; Sendable so the provider closure can capture it.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

@MainActor
@Suite struct NextEpisodeTests {
    let e1 = NowPlayingItem(key: .episode(seriesID: 5, season: 1, episode: 1), title: "Ep 1")
    let e2 = NowPlayingItem(key: .episode(seriesID: 5, season: 1, episode: 2), title: "Ep 2")

    @Test func upNextAsksTheProviderOnceAndAppliesDefaults() async {
        let calls = CallCounter()
        let e2 = e2
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), deviceID: "test",
                              nextProvider: { _ in calls.bump(); return (e2, resource("e2")) }, upNextCountdown: 0)
        var started: [NowPlayingItem] = []
        s.onItemStarted = { started.append($0) }
        await s.start(e1, resource: resource("e1"))
        engine.finish()
        #expect(await waitUntil { s.item == e2 })
        #expect(calls.count == 1)
        #expect(started == [e1, e2])
        await s.end()
    }

    @Test func nearTheEndAsksOnceForTheNextPick() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), deviceID: "test", nextProvider: { _ in nil })
        var noted: [MediaKey] = []
        s.onNearEnd = { noted.append($0) }
        await s.start(e1, resource: resource("e1"))
        engine.advance(to: 3600 * 0.8)
        #expect(noted.isEmpty)
        engine.advance(to: 3600 * 0.86)
        engine.advance(to: 3600 * 0.9)
        #expect(noted == [e1.key])
        // The next item gets its own.
        await s.start(e2, resource: resource("e2"))
        engine.advance(to: 3600 * 0.95)
        #expect(noted == [e1.key, e2.key])
        await s.end()
    }

    @Test func nextEpisodeThatCantBeFoundResumesTheCurrentOne() async {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), deviceID: "test", nextProvider: { _ in nil })
        await s.start(e1, resource: resource("e1"))
        engine.advance(to: 300)
        #expect(s.snapshot.status == .playing)
        await s.playNext()
        #expect(!s.isLoadingNext)
        #expect(s.item == e1)
        #expect(s.snapshot.status == .playing)
        #expect(s.snapshot.position == 300)
    }

    @Test func nextEpisodePausesWhileResolving() async {
        let e2 = e2
        let engine = MockEngine()
        let gate = CallCounter()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), deviceID: "test", nextProvider: { _ in
            gate.bump()
            try? await Task.sleep(for: .milliseconds(200))
            return (e2, resource("e2"))
        })
        await s.start(e1, resource: resource("e1"))
        let task = Task { await s.playNext() }
        #expect(await waitUntil { gate.count == 1 })
        #expect(s.isLoadingNext)
        #expect(s.snapshot.status == .paused)
        await task.value
        #expect(s.item == e2)
        #expect(!s.isLoadingNext)
    }
}
