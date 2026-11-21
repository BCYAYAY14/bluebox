import Foundation
@testable import Features
import Testing

/// The Timing page's delay dial and frame-rate convert.
@Suite struct SubtitleTimingPanelTests {
    @Test func theSliderReachesPastABigDelay() {
        #expect(SubtitleTimingPage.delayRange(0) == -10...10)
        #expect(SubtitleTimingPage.delayRange(-9.9) == -10...10)
        // +20 s (Sync to the Audio sets tens of seconds): the slider isn't pinned at +10.
        #expect(SubtitleTimingPage.delayRange(20) == -20...20)
        #expect(SubtitleTimingPage.delayRange(-34.5) == -40...40)
    }

    @Test func theConvertStartsFromTheVideosFrameRate() {
        #expect(SubtitleSyncFrameRates.startingPair(videoFPS: nil) == nil)
        #expect(SubtitleSyncFrameRates.startingPair(videoFPS: 12) == nil)
        let film = SubtitleSyncFrameRates.startingPair(videoFPS: 23.976)
        #expect(film?.video == 24000.0 / 1001 && film?.subtitles == 25)
        let pal = SubtitleSyncFrameRates.startingPair(videoFPS: 25)
        #expect(pal?.video == 25 && pal?.subtitles == 24000.0 / 1001)
        #expect(SubtitleSyncFrameRates.startingPair(videoFPS: 29.97)?.subtitles == 30)
        // 24 is 24, not the 23.976 just below it.
        #expect(SubtitleSyncFrameRates.startingPair(videoFPS: 24)?.video == 24)
    }
}
