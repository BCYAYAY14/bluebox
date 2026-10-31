import Domain
import Foundation
@testable import Playback
import Testing

@Suite struct PlaybackEventLogTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func bufferingGetsItsLengthAndCountsAsAStallOnlyAfterPlaying() {
        var log = PlaybackEventLog()
        log.statusChanged(from: .idle, to: .loading, position: 0, at: t0)
        log.statusChanged(from: .loading, to: .buffering, position: 0, at: t0)
        log.statusChanged(from: .buffering, to: .playing, position: 0, at: t0.addingTimeInterval(4))
        #expect(log.stalls == 0)  // filling up before the first frame isn't a stall
        log.statusChanged(from: .playing, to: .buffering, position: 600, at: t0.addingTimeInterval(10))
        log.statusChanged(from: .buffering, to: .playing, position: 600, at: t0.addingTimeInterval(12.1))
        #expect(log.stalls == 1)
        #expect(abs(log.stalledFor - 2.1) < 0.001)
        #expect(log.events.map(\.title) == ["Loading", "Buffering", "Playing", "Buffering", "Playing"])
        #expect(log.events[1].detail == "4.0 s")
        #expect(log.events[3].detail == "2.1 s")
        #expect(log.events[3].kind == .warning)
        #expect(log.events[3].position == 600)
    }

    @Test func repeatsAndIdleAreSkippedAndErrorsKeepTheirMessage() {
        var log = PlaybackEventLog()
        log.statusChanged(from: .playing, to: .playing, position: 1, at: t0)
        log.statusChanged(from: .playing, to: .idle, position: 1, at: t0)
        #expect(log.events.isEmpty)
        log.statusChanged(from: .playing, to: .failed(.decodeFailed("the decoder gave up")), position: 5, at: t0)
        #expect(log.events.last?.kind == .error)
        #expect(log.events.last?.detail == "Playback stopped: the decoder gave up")
    }

    @Test func keepsTheLatestFifty() {
        var log = PlaybackEventLog()
        for n in 0..<120 { log.record("Seeked", detail: "\(n)", position: Double(n), at: t0) }
        #expect(log.events.count == PlaybackEventLog.capacity)
        #expect(log.events.first?.detail == "70")
        #expect(log.events.last?.detail == "119")
        #expect(Set(log.events.map(\.id)).count == PlaybackEventLog.capacity)
    }

    @Test func clockAndDurationWords() {
        #expect(PlaybackEventLog.clock(0) == "0:00")
        #expect(PlaybackEventLog.clock(1312.7) == "21:52")
        #expect(PlaybackEventLog.clock(3729) == "1:02:09")
        #expect(PlaybackEventLog.clock(.nan) == "0:00")
        #expect(PlaybackEventLog.duration(2.06) == "2.1 s")
        #expect(PlaybackEventLog.duration(64) == "1 min 4 s")
    }

    @Test @MainActor func theSessionRecordsWhatHappens() async throws {
        let engine = MockEngine()
        let s = PlayerSession(engine: engine, progress: MemoryProgress(), deviceID: "test")
        await s.start(NowPlayingItem(key: .movie(tmdbID: 1), title: "One"), resource: resource())
        await s.seek(to: 600)
        s.setRate(1.25)
        s.selectSubtitle(.embedded("s0"))
        s.selectSubtitle(.off)
        let titles = s.events.events.map(\.title)
        #expect(titles.prefix(2) == ["Opened", "Engine"])
        #expect(s.events.events.first?.detail == "MP4")
        #expect(titles.contains("Playing"))
        let seek = try #require(s.events.events.first { $0.title == "Seeked" })
        #expect(seek.detail == "0:00 → 10:00")
        #expect(s.events.events.first { $0.title == "Speed" }?.detail == "1.25×")
        #expect(s.events.events.filter { $0.title == "Subtitles" }.map(\.detail) == ["English", "Off"])

        // A new item starts a new timeline.
        await s.start(NowPlayingItem(key: .movie(tmdbID: 2), title: "Two"), resource: resource("w"))
        #expect(s.events.events.first?.title == "Opened")
        #expect(!s.events.events.contains { $0.title == "Seeked" })
    }

    @Test func codecAndChannelWords() {
        #expect(PlaybackDiagnostics.codecName("hevc") == "HEVC")
        #expect(PlaybackDiagnostics.codecName("a52 ") == "AC-3")
        #expect(PlaybackDiagnostics.codecName("ec-3") == "E-AC-3")
        #expect(PlaybackDiagnostics.codecName("mp4a") == "AAC")
        #expect(PlaybackDiagnostics.codecName("xyzw") == "XYZW")
        #expect(PlaybackDiagnostics.channelLayout(6) == "5.1")
        #expect(PlaybackDiagnostics.channelLayout(2) == "Stereo")
        #expect(PlaybackDiagnostics.channelLayout(4) == "4 channels")
        #expect(PlaybackDiagnostics.formatFrameRate(24000 / 1001) == "23.976 fps")
        #expect(PlaybackDiagnostics.formatFrameRate(25) == "25 fps")
        #expect(PlaybackDiagnostics.describeColour(transfer: "BT.709", primaries: "BT.709") == "BT.709")
        #expect(PlaybackDiagnostics.describeColour(transfer: "PQ", primaries: "BT.2020") == "PQ · BT.2020")
        #expect(PlaybackDiagnostics.describeColour(transfer: nil, primaries: nil) == nil)
        #expect(AVPlayerEngine.colourRange(transfer: "PQ", dolbyVision: false) == .hdr10)
        #expect(AVPlayerEngine.colourRange(transfer: "HLG", dolbyVision: false) == .hlg)
        #expect(AVPlayerEngine.colourRange(transfer: "BT.709", dolbyVision: true) == .dolbyVision)
        #expect(AVPlayerEngine.colourRange(transfer: nil, dolbyVision: false) == nil)
    }
}
