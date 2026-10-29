import Domain
import Downloads
import DownloadsActivity
@testable import Features
import Foundation
import Sync
import Testing

/// The Downloads Live Activity's content and its update budget, and the
/// remote's "has playback changed" test.
@Suite struct DownloadsActivityTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func record(_ id: String, _ state: DownloadRecord.State, received: Int64 = 0, expected: Int64? = 1_000_000_000,
                order: Double, title: String = "Film") -> DownloadRecord {
        let variant = MediaVariant(id: id, sourceID: SourceID("test"), mediaKey: .movie(tmdbID: 1), displayName: id,
                                   container: "mkv", resolution: "1080p", sizeBytes: expected, location: .remote)
        return DownloadRecord(id: id, mediaKey: .movie(tmdbID: 1), title: title, subtitle: nil, origin: variant, state: state,
                              receivedBytes: received, expectedBytes: expected, createdAt: t0, fileName: nil, subtitleFiles: [],
                              order: order)
    }

    // MARK: Throttle

    @Test func throttleSendsFirstThenWaits() {
        var t = ActivityUpdateThrottle<Int>(minimumInterval: 5)
        #expect(t.decide(1, now: t0) == .sendNow)
        t.didSend(1, at: t0)
        #expect(t.decide(1, now: t0.addingTimeInterval(1)) == .unchanged)
        #expect(t.decide(2, now: t0.addingTimeInterval(1)) == .waitUntil(t0.addingTimeInterval(5)))
        #expect(t.decide(3, now: t0.addingTimeInterval(4.9)) == .waitUntil(t0.addingTimeInterval(5)))
        #expect(t.decide(3, now: t0.addingTimeInterval(5)) == .sendNow)
        t.didSend(3, at: t0.addingTimeInterval(5))
        // Equal to what was sent is never sent again, however long it's been.
        #expect(t.decide(3, now: t0.addingTimeInterval(60)) == .unchanged)
        t.reset()
        #expect(t.decide(3, now: t0.addingTimeInterval(61)) == .sendNow)
    }

    @Test func atMostOneUpdatePerIntervalOverAMinuteOfTicks() {
        var t = ActivityUpdateThrottle<Int>(minimumInterval: 5)
        var sent = 0, pendingUntil: Date?
        for second in 0..<60 {
            let now = t0.addingTimeInterval(Double(second))
            if let due = pendingUntil, now >= due { pendingUntil = nil }
            switch t.decide(second, now: now) {  // a new state every second
            case .sendNow: t.didSend(second, at: now); sent += 1
            case .waitUntil(let due): pendingUntil = pendingUntil ?? due
            case .unchanged: break
            }
        }
        #expect(sent == 12)
    }

    // MARK: Summary

    @Test func summaryCoversTheQueue() throws {
        let records = [
            record("b", .queued, order: 2, title: "Second"),
            record("a", .downloading, received: 500_000_000, order: 1, title: "Dune"),
            record("c", .downloading, received: 250_000_000, order: 3, title: "Third"),
            record("done", .completed, received: 1_000_000_000, order: 0),
            record("p", .paused, received: 10, order: 4),
        ]
        let speeds = ["a": 6_000_000.0, "c": 2_420_000.0]
        let s = try #require(DownloadsActivityState.summary(records) { id in speeds[id].map { DownloadLiveStats(bytesPerSecond: $0) } })
        #expect(s.title == "Dune")
        #expect(s.activeCount == 3)
        #expect(s.fraction == 0.25)  // 750 MB of 3 GB
        #expect(s.bytesPerSecond == 8_400_000)  // rounded to 100 kB/s
        // 2.25 GB at 8.42 MB/s ≈ 267 s, shown in whole minutes.
        #expect(s.secondsLeft == 300)
        #expect(s.detailLine == "3 downloading · 8.4 MB/s · 5 min left")
        #expect(s.percentText == "25%")
    }

    @Test func summaryLeavesOutWhatIsntKnown() throws {
        let records = [record("a", .downloading, received: 0, expected: nil, order: 1)]
        let s = try #require(DownloadsActivityState.summary(records) { _ in DownloadLiveStats(bytesPerSecond: 3_000_000) })
        #expect(s.secondsLeft == nil && s.fraction == 0)
        #expect(s.detailLine == "1 downloading · 3 MB/s")
        #expect(DownloadsActivityState.summary([record("p", .paused, order: 1)]) { _ in nil } == nil)
    }

    @Test func smallChangesDontMakeANewState() {
        let a = DownloadsActivityState.summary([record("a", .downloading, received: 500_000_000, order: 1)]) { _ in
            DownloadLiveStats(bytesPerSecond: 5_010_000)
        }
        let b = DownloadsActivityState.summary([record("a", .downloading, received: 501_000_000, order: 1)]) { _ in
            DownloadLiveStats(bytesPerSecond: 4_990_000)
        }
        #expect(a == b)
    }

    @Test func timeLeftWording() {
        #expect(DownloadsActivityState.timeLeft(30) == "< 1 min left")
        #expect(DownloadsActivityState.timeLeft(720) == "12 min left")
        #expect(DownloadsActivityState.timeLeft(3_900) == "1 h 5 min left")
    }

    // MARK: Remote publishing

    @Test func remotePublishesAtOnceOnlyForRealChanges() {
        let a = RemoteNowPlaying(deviceID: "m", deviceName: "Mac", title: "T", position: 10, duration: 100, paused: false, seq: 1)
        var b = a
        b.position = 12; b.seq = 2
        #expect(RemoteControl.samePlayback(a, b))
        b.paused = true
        #expect(!RemoteControl.samePlayback(a, b))
    }
}
