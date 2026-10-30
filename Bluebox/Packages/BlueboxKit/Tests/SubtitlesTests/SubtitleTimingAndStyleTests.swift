import Foundation
@testable import Subtitles
import Testing

@Suite struct SubtitleTimingTests {
    @Test func frameRateConversionScalesCueTimes() {
        var o = SubtitleOffset()
        o.convertFrameRate(subtitleFPS: 25, videoFPS: 23.976)
        // A line at 1000 s in a 25 fps subtitle file belongs at ~1042.7 s of a 23.976 fps video.
        #expect(abs(o.playerTime(forCueTime: 1000) - 1042.709) < 0.01)
        #expect(o.label.contains("0.959"))
    }

    @Test func syncThisLineKeepsTheSpeed() {
        var o = SubtitleOffset(seconds: 0, scale: 1.04)
        o.align(cueStart: 520, to: 530)
        #expect(abs(o.playerTime(forCueTime: 520) - 530) < 0.002)
        #expect(o.scale == 1.04)
    }

    @Test func twoPointSyncFitsDriftAndRejectsNonsense() {
        var o = SubtitleOffset()
        // Subtitles drift: line at 100 s heard at 102 s; line at 3000 s heard at 3127 s.
        let fitted = o.align((cue: 100, heard: 102), (cue: 3000, heard: 3127))
        #expect(fitted)
        #expect(abs(o.playerTime(forCueTime: 100) - 102) < 0.01)
        #expect(abs(o.playerTime(forCueTime: 3000) - 3127) < 0.01)
        let before = o
        let tooClose = o.align((cue: 10, heard: 10), (cue: 11, heard: 12))
        let implausible = o.align((cue: 0, heard: 0), (cue: 100, heard: 1000))  // 0.1× speed
        #expect(!tooClose && !implausible)
        #expect(o == before)
    }

    @Test func oldSavedOffsetsStillDecode() throws {
        let o = try JSONDecoder().decode(SubtitleOffset.self, from: Data(#"{"seconds":1.5}"#.utf8))
        #expect(o.seconds == 1.5 && o.scale == 1)
    }

    @Test func timelineHonorsScale() {
        let t = SubtitleTimeline(cues: [SubtitleCue(start: 100, end: 102, text: "Hi")])
        let o = SubtitleOffset(seconds: 0, scale: 0.8)   // cue 100 s shows at player 125 s
        #expect(t.text(at: 126, offset: o) == "Hi")
        #expect(t.text(at: 101, offset: o) == nil)
        #expect(t.cues(near: 125, offset: o).count == 1)
        #expect(SubtitleOffset(scale: 0.5).scale == 0.8)  // out-of-range speeds are clamped
    }
}

@Suite struct SubtitleStyleTests {
    @Test func legacyPresetsMigrate() throws {
        let old = #"{"size":"large","color":"lightBlue","background":"box","position":"raised","preferredLanguage":"en"}"#
        let s = try JSONDecoder().decode(SubtitleStyle.self, from: Data(old.utf8))
        #expect(s.relativeSize == 0.055)
        #expect(s.textColor == .lightBlue)
        #expect(s.backgroundOpacity == 0.75 && !s.shadow)
        #expect(s.verticalMargin == 0.18 && s.anchor == .bottom)
        #expect(s.preferredLanguage == "en")
    }

    @Test func roundTripsAndScalesWithVideoHeight() throws {
        var s = SubtitleStyle().applying(.boldOutline)
        s.fontName = "Avenir Next"; s.secondaryLanguage = "es"
        let back = try JSONDecoder().decode(SubtitleStyle.self, from: try JSONEncoder().encode(s))
        #expect(back == s)
        #expect(SubtitleStyle().pointSize(forHeight: 1080) == 1080 * 0.045)
        #expect(SubtitleStyle().pointSize(forHeight: 100) == 9)   // never unreadably small
    }

    @Test func presetsSetTheTypeAndKeepThePosition() {
        var s = SubtitleStyle(); s.anchor = .top; s.alignment = .leading; s.hidesSoundCues = true
        let p = s.applying(.largePrint)
        #expect(p.anchor == .top && p.alignment == .leading && p.hidesSoundCues)
        #expect(p.fontName == "Atkinson Hyperlegible" && p.weight == .bold && p.relativeSize == 0.062 && p.backgroundOpacity == 0.55)
        #expect(p == p.applying(.largePrint))  // applying twice changes nothing
        #expect(p.matches(.largePrint) && !p.matches(.standard))
        #expect(p.applying(.cinema).fontName == nil && p.applying(.cinema).design == .serif)
        #expect(SubtitleStyle().matches(.standard))  // the default look is Standard
    }

    @Test func savedLooksRoundTripAndApply() throws {
        var s = SubtitleStyle().applying(.boxed)
        s.textColor = .yellow
        s.saveCurrentLook(); s.saveCurrentLook()
        #expect(s.savedLooks.map(\.name) == ["My Look 1", "My Look 2"])
        let back = try JSONDecoder().decode(SubtitleStyle.self, from: try JSONEncoder().encode(s))
        #expect(back.savedLooks == s.savedLooks)
        var other = SubtitleStyle(); other.look = back.savedLooks[0].look
        #expect(other.textColor == .yellow && other.backgroundOpacity == 0.75)
    }

    @Test func liftClearsTheControlsWithoutJumping() {
        var s = SubtitleStyle()
        // Below the bar: just above it. Already above: stays. No jump as the margin crosses the bar.
        s.verticalMargin = 0.05; #expect(s.restingMargin(coveredBottom: 0.15) == 0.15)
        s.verticalMargin = 0.149; #expect(s.restingMargin(coveredBottom: 0.15) == 0.15)
        s.verticalMargin = 0.151; #expect(s.restingMargin(coveredBottom: 0.15) == 0.151)
        s.avoidControls = false; s.verticalMargin = 0.05; #expect(s.restingMargin(coveredBottom: 0.15) == 0.05)
        s.avoidControls = true; s.anchor = .middle; #expect(s.restingMargin(coveredBottom: 0.15) == 0)
        s.anchor = .top; #expect(s.restingMargin(coveredBottom: 0.15, coveredTop: 0.08) == 0.08)
    }

    @Test func droppingInTheMiddleIsMiddle() {
        let block = CGRect(x: 0.3, y: 0.5 - 0.05 + 0.01, width: 0.4, height: 0.1)
        let p = SubtitlePlacement.dropping(block: block, alignment: .center, horizontalMargin: 0.08)
        #expect(p.anchor == .middle && p.snappedY)
        let low = SubtitlePlacement.dropping(block: CGRect(x: 0.3, y: 0.7, width: 0.4, height: 0.1), alignment: .center, horizontalMargin: 0.08)
        #expect(low.anchor == .bottom && abs(low.verticalMargin - 0.2) < 0.0001)
    }

    @Test func presetsKeepLanguages() {
        var s = SubtitleStyle(); s.preferredLanguage = "fr"; s.secondaryLanguage = "en"
        let p = s.applying(.boxed)
        #expect(p.preferredLanguage == "fr" && p.secondaryLanguage == "en" && p.backgroundOpacity == 0.75)
    }
}
