import Foundation
@testable import SkipSegments
import Testing

@Suite struct ShowSkipRulesTests {
    let show = "tmdb:tv:1396"
    let other = "tmdb:tv:60059"
    let defaults = SkipSegmentPlanner.Modes(intro: .button, recap: .button, credits: .button)

    @Test func alwaysIsPerShowAndPerPart() {
        var rules = ShowSkipRules()
        rules.setAlways(true, .intro, show: show)
        #expect(rules.alwaysSkips(.intro, show: show))
        #expect(!rules.alwaysSkips(.recap, show: show))
        #expect(!rules.alwaysSkips(.intro, show: other))
        let m = rules.modes(show: show, defaults: defaults)
        #expect(m == .init(intro: .automatic, recap: .button, credits: .button))
        #expect(rules.modes(show: other, defaults: defaults) == defaults)
    }

    @Test func showRuleBeatsAGlobalOff() {
        var rules = ShowSkipRules()
        rules.setAlways(true, .credits, show: show)
        let off = SkipSegmentPlanner.Modes(intro: .off, recap: .off, credits: .off)
        #expect(rules.modes(show: show, defaults: off).credits == .automatic)
    }

    @Test func turningTheLastPartOffForgetsTheShow() {
        var rules = ShowSkipRules()
        rules.setAlways(true, .recap, show: show)
        rules.setAlways(false, .recap, show: show)
        #expect(rules.always.isEmpty)
        rules.setAlways(true, .intro, show: show)
        rules.removeShow(show)
        #expect(!rules.alwaysSkips(.intro, show: show))
    }

    @Test func alwaysIsOfferedOncePerShowAndPart() {
        var rules = ShowSkipRules()
        #expect(rules.shouldOffer(.intro, show: show))
        rules.markOffered(.intro, show: show)
        #expect(!rules.shouldOffer(.intro, show: show))
        #expect(rules.shouldOffer(.credits, show: show))
        #expect(rules.shouldOffer(.intro, show: other))
        // Once it's on, there's nothing to offer.
        rules.setAlways(true, .credits, show: show)
        #expect(!rules.shouldOffer(.credits, show: show))
    }

    @Test func previewsCountAsCredits() {
        #expect(ShowSkipRules.Part(.preview) == .credits)
        #expect(ShowSkipRules.Part(.recap) == .recap)
    }

    @Test func roundTripsThroughJSON() throws {
        var rules = ShowSkipRules()
        rules.setAlways(true, .intro, show: show)
        rules.markOffered(.credits, show: other)
        let back = try JSONDecoder().decode(ShowSkipRules.self, from: JSONEncoder().encode(rules))
        #expect(back == rules)
    }
}

@Suite struct SkipModesPlannerTests {
    let segments = [
        SkipSegment(kind: .recap, start: 0, end: 50, source: .chapters),
        SkipSegment(kind: .intro, start: 60, end: 120, source: .chapters),
        SkipSegment(kind: .credits, start: 1300, end: nil, source: .chapters),
    ]

    @Test func recapHasItsOwnMode() {
        let modes = SkipSegmentPlanner.Modes(intro: .button, recap: .automatic, credits: .button)
        let recap = SkipSegmentPlanner.offer(at: 10, segments: segments, duration: 1400, modes: modes, hasNextEpisode: true)
        #expect(recap?.0 == .skip(.recap, to: 50) && recap?.auto == true)
        let intro = SkipSegmentPlanner.offer(at: 61, segments: segments, duration: 1400, modes: modes, hasNextEpisode: true)
        #expect(intro?.0 == .skip(.intro, to: 120) && intro?.auto == false)
    }

    @Test func automaticCreditsMoveOnOnlyWithAutoplay() {
        let modes = SkipSegmentPlanner.Modes(intro: .button, recap: .button, credits: .automatic)
        let on = SkipSegmentPlanner.offer(at: 1305, segments: segments, duration: 1400, modes: modes,
                                          hasNextEpisode: true, autoplayNext: true)
        #expect(on?.0 == .nextEpisode && on?.auto == true)
        // Autoplay off: still offers Next Episode, but waits for a press.
        let off = SkipSegmentPlanner.offer(at: 1305, segments: segments, duration: 1400, modes: modes,
                                           hasNextEpisode: true, autoplayNext: false)
        #expect(off?.0 == .nextEpisode && off?.auto == false)
    }

    @Test func oldSignatureTreatsRecapLikeIntro() {
        let auto = SkipSegmentPlanner.offer(at: 10, segments: segments, duration: 1400, introMode: .automatic,
                                            creditsMode: .button, hasNextEpisode: true)
        #expect(auto?.auto == true)
        let off = SkipSegmentPlanner.offer(at: 10, segments: segments, duration: 1400, introMode: .off,
                                           creditsMode: .button, hasNextEpisode: true)
        #expect(off == nil)
    }
}
