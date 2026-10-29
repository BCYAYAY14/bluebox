import CoreGraphics
@testable import Features
import Foundation
import Playback
import Testing
import TorrentStreaming

@Suite struct PlaybackSpeedTests {
    @Test func stepsInFiveHundredths() {
        #expect(PlaybackSpeed.stepped(1, by: 1) == 1.05)
        #expect(PlaybackSpeed.stepped(1, by: -1) == 0.95)
        #expect(PlaybackSpeed.stepped(1.1, by: 1) == 1.15)
        #expect(PlaybackSpeed.stepped(1.15, by: -3) == 1)
        #expect(PlaybackSpeed.stepped(1.25, by: 2) == 1.35)
    }

    @Test func offGridRatesSnapToTheNextStepInThatDirection() {
        #expect(PlaybackSpeed.stepped(1.12, by: 1) == 1.15)
        #expect(PlaybackSpeed.stepped(1.12, by: -1) == 1.1)
        // Float noise must not skip a step: 1.15 stored as 1.1499999.
        #expect(PlaybackSpeed.stepped(Float(1.15), by: 1) == 1.2)
        #expect(PlaybackSpeed.stepped(Float(1.15), by: -1) == 1.1)
    }

    @Test func clampsToWhatTheEnginesPlay() {
        #expect(PlaybackSpeed.stepped(0.25, by: -1) == 0.25)
        #expect(PlaybackSpeed.stepped(4, by: 1) == 4)
        #expect(PlaybackSpeed.stepped(3.98, by: 1) == 4)
        #expect(PlaybackSpeed.clamp(.nan) == 1)
    }

    @Test func labels() {
        #expect(PlaybackSpeed.label(1) == "1×")
        #expect(PlaybackSpeed.label(1.15) == "1.15×")
        #expect(PlaybackSpeed.label(0.5) == "0.5×")
        #expect(PlaybackSpeed.label(PlaybackSpeed.stepped(1, by: 3)) == "1.15×")
        #expect(PlaybackSpeed.isNormal(1))
        #expect(!PlaybackSpeed.isNormal(1.05))
    }

    @Test func presetsRunFromHalfToDouble() {
        #expect(PlaybackSpeed.presets.first == 0.5)
        #expect(PlaybackSpeed.presets.last == PlaybackSpeed.hold)
        #expect(PlaybackSpeed.presets.contains(1))
    }
}

@Suite struct PlayerBarLayoutTests {
    @Test func macGroupsMatchTheDesign() {
        let l = PlayerBarLayout.make(platform: .mac, width: 1200)
        #expect(l.leading == [.playPause, .skipBack, .skipForward, .volume])
        #expect(l.showsTitle)
        #expect(l.trailing == [[.previous, .next], [.episodes, .tracks, .speed, .tools], [.pip, .fullScreen]])
    }

    @Test func phoneKeepsPlaybackInTheMiddleAndPiPOnTop() {
        let l = PlayerBarLayout.make(platform: .phone, width: 850)
        #expect(l.leading == [.lock])
        #expect(!l.showsTitle)
        #expect(l.trailing == [[.previous, .next], [.episodes, .tracks, .speed, .tools]])
        #expect(!l.all.contains(.pip) && !l.all.contains(.playPause) && !l.all.contains(.volume))
    }

    @Test func narrowWindowsDropOnlyTheTitle() {
        let wide = PlayerBarLayout.make(platform: .mac, width: 1000)
        let narrow = PlayerBarLayout.make(platform: .mac, width: 520)
        #expect(!narrow.showsTitle)
        #expect(narrow.all == wide.all)
    }

    /// Nothing is added or removed when a video has chapters or episodes:
    /// the layout depends only on platform and width, and controls dim instead.
    @Test func sameControlsForEveryVideo() {
        let film = PlayerBarLayout.Context()
        let series = PlayerBarLayout.Context(isSeries: true, hasPreviousEpisode: true, hasNextEpisode: true, chapterCount: 5, pipAvailable: true)
        let layout = PlayerBarLayout.make(platform: .mac, width: 1000)
        #expect(layout.all.count == PlayerBarItem.allCases.count - 1)  // every item but the touch-only lock
        #expect(!PlayerBarLayout.isEnabled(.episodes, in: film))
        #expect(PlayerBarLayout.isEnabled(.episodes, in: series))
        #expect(!PlayerBarLayout.isEnabled(.pip, in: film))
        #expect(PlayerBarLayout.isEnabled(.tracks, in: film) && PlayerBarLayout.isEnabled(.speed, in: film))
    }

    @Test func previousAndNextStepEpisodesThenChapters() {
        var c = PlayerBarLayout.Context(isSeries: true, hasPreviousEpisode: false, hasNextEpisode: true, chapterCount: 6)
        #expect(PlayerBarLayout.stepTarget(c) == .episode)
        #expect(!PlayerBarLayout.isEnabled(.previous, in: c))  // the first episode
        #expect(PlayerBarLayout.isEnabled(.next, in: c))
        c.isSwitching = true
        #expect(!PlayerBarLayout.isEnabled(.next, in: c))

        let film = PlayerBarLayout.Context(chapterCount: 6)
        #expect(PlayerBarLayout.stepTarget(film) == .chapter)
        #expect(PlayerBarLayout.isEnabled(.previous, in: film) && PlayerBarLayout.isEnabled(.next, in: film))

        let plain = PlayerBarLayout.Context(chapterCount: 1)
        #expect(PlayerBarLayout.stepTarget(plain) == .none)
        #expect(!PlayerBarLayout.isEnabled(.next, in: plain))
    }
}

@Suite struct PanelPlacementTests {
    let stage = CGSize(width: 1000, height: 600)

    @Test func centresOverItsButtonAboveTheBar() {
        let f = PanelPlacement.frame(anchor: CGRect(x: 600, y: 540, width: 32, height: 32), width: 300, stage: stage,
                                     barTop: 480, topInset: 44)
        #expect(f.x == CGFloat(466))
        #expect(f.bottom == CGFloat(128))  // 600 − 480 + 8
        #expect(f.maxHeight == CGFloat(428))
    }

    @Test func staysInsideTheStage() {
        let right = PanelPlacement.frame(anchor: CGRect(x: 960, y: 540, width: 32, height: 32), width: 300, stage: stage,
                                         barTop: nil, topInset: 8)
        #expect(right.x == CGFloat(688))
        #expect(right.bottom == CGFloat(68))  // phones: just above the button, over the timeline
        let left = PanelPlacement.frame(anchor: CGRect(x: 4, y: 540, width: 32, height: 32), width: 300, stage: stage,
                                        barTop: nil, topInset: 8)
        #expect(left.x == CGFloat(12))
        let tooWide = PanelPlacement.frame(anchor: nil, width: 1400, stage: stage, barTop: nil, topInset: 8)
        #expect(tooWide.x == CGFloat(12))
    }
}

@Suite struct BufferProgressTests {
    @Test func usesTheEnginesFillWhileWaiting() {
        #expect(BufferProgress.fraction(status: .buffering, bufferFill: 0.64, position: 10, bufferedUntil: 10) == 0.64)
        #expect(BufferProgress.fraction(status: .playing, bufferFill: 0.64, position: 10, bufferedUntil: 20) == nil)
    }

    @Test func otherwiseCountsSecondsAheadTowardsResuming() {
        #expect(BufferProgress.fraction(status: .buffering, bufferFill: nil, position: 10, bufferedUntil: 12.5) == 0.5)
        #expect(BufferProgress.fraction(status: .buffering, bufferFill: nil, position: 10, bufferedUntil: 40) == 0.99)
        // Nothing to measure: the ring spins.
        #expect(BufferProgress.fraction(status: .loading, bufferFill: nil, position: 0, bufferedUntil: 0) == nil)
    }

    @Test func captionsSaySpeedOrPeers() {
        let fast = SwarmStats(connectedPeers: 42, downloadRate: 3_100_000)
        #expect(BufferProgress.caption(status: .buffering, torrent: fast, elapsed: 3)?.hasPrefix("Buffering · ") == true)
        #expect(BufferProgress.caption(status: .buffering, torrent: fast, elapsed: 3)?.hasSuffix("/s") == true)
        #expect(BufferProgress.caption(status: .loading, torrent: SwarmStats(connectedPeers: 3), elapsed: 3) == "Opening · 3 peers")
        #expect(BufferProgress.caption(status: .loading, torrent: SwarmStats(knownPeers: 12), elapsed: 3) == "Connecting · 12 peers found")
        #expect(BufferProgress.caption(status: .buffering, torrent: nil, elapsed: 3) == "Buffering")
        #expect(BufferProgress.caption(status: .playing, torrent: fast, elapsed: 3) == nil)
    }
}
