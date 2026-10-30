import CoreGraphics
import Foundation
@testable import Subtitles
import Testing

@Suite struct SubtitlePlacementTests {
    /// A block 40% wide and 10% tall, centred, sitting at the default bottom margin.
    let block = CGRect(x: 0.3, y: 1 - 0.06 - 0.1, width: 0.4, height: 0.1)

    @Test func droppingNearTheDefaultSnapsBack() {
        let p = SubtitlePlacement.dropping(block: block.offsetBy(dx: 0.02, dy: 0.015), alignment: .center, horizontalMargin: 0.08)
        #expect(p.anchor == .bottom)
        #expect(p.verticalMargin == SubtitleStyle.defaultMargin && p.snappedY)
        #expect(p.horizontalOffset == 0 && p.snappedX)
    }

    @Test func droppingInTheTopHalfAnchorsToTheTop() {
        let p = SubtitlePlacement.dropping(block: block.offsetBy(dx: 0, dy: -0.6), alignment: .center, horizontalMargin: 0.08)
        #expect(p.anchor == .top)
        #expect(abs(p.verticalMargin - 0.24) < 0.0001)
        #expect(!p.snappedY)
    }

    @Test func movingSidewaysKeepsTheBlockOnThePicture() {
        let p = SubtitlePlacement.dropping(block: block.offsetBy(dx: 0.2, dy: -0.3), alignment: .center, horizontalMargin: 0.08)
        #expect(abs(p.horizontalOffset - 0.2) < 0.0001)
        // Far past the right edge: clamped so the block's right side touches the edge.
        let far = SubtitlePlacement.dropping(block: block.offsetBy(dx: 0.9, dy: 0), alignment: .center, horizontalMargin: 0.08)
        #expect(abs(far.horizontalOffset - 0.3) < 0.0001)
        // Below the picture: clamped to the bottom edge.
        let low = SubtitlePlacement.dropping(block: block.offsetBy(dx: 0, dy: 0.5), alignment: .center, horizontalMargin: 0.08)
        #expect(low.anchor == .bottom && low.verticalMargin == 0)
    }

    @Test func offsetIsRelativeToTheAlignedSpot() {
        // Left-aligned with 8% margins: a 0.4-wide block rests centred at 0.28.
        #expect(abs(SubtitlePlacement.restingMidX(blockWidth: 0.4, alignment: .leading, horizontalMargin: 0.08) - 0.28) < 0.0001)
        let p = SubtitlePlacement.dropping(block: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.1), alignment: .leading, horizontalMargin: 0.08)
        #expect(abs(p.horizontalOffset - 0.02) < 0.0001)
        #expect(abs(SubtitlePlacement.clampedOffset(0.9, blockWidth: 0.4, alignment: .leading, horizontalMargin: 0.08) - 0.52) < 0.0001)
    }

    @Test func positionPersistsAndResets() throws {
        var s = SubtitleStyle()
        #expect(s.isDefaultPosition)
        s.place(SubtitlePlacement(anchor: .top, verticalMargin: 0.2, horizontalOffset: -0.1, snappedX: false, snappedY: false))
        #expect(!s.isDefaultPosition)
        let back = try JSONDecoder().decode(SubtitleStyle.self, from: try JSONEncoder().encode(s))
        #expect(back.anchor == .top && back.verticalMargin == 0.2 && back.horizontalOffset == -0.1)
        // Presets change the look, not where the text was put.
        #expect(s.applying(.boxed).horizontalOffset == -0.1 && s.applying(.boxed).anchor == .top)
        s.resetPosition()
        #expect(s.isDefaultPosition)
        // Styles saved before the offset existed decode with no offset.
        let old = try JSONDecoder().decode(SubtitleStyle.self, from: Data(#"{"anchor":"top"}"#.utf8))
        #expect(old.horizontalOffset == 0 && old.anchor == .top)
    }

    @Test func droppingIntoTheBlackBars() {
        // A letterboxed picture with bars 0.2 of its height above and below.
        let bounds = -0.2...1.2
        let block = CGRect(x: 0.3, y: 1.05, width: 0.4, height: 0.08)
        let under = SubtitlePlacement.dropping(block: block, alignment: .center, horizontalMargin: 0.08, verticalBounds: bounds)
        #expect(under.anchor == .bottom && abs(under.verticalMargin - -0.13) < 0.0001)
        // No further than the stage's edge.
        let far = SubtitlePlacement.dropping(block: block.offsetBy(dx: 0, dy: 1), alignment: .center, horizontalMargin: 0.08, verticalBounds: bounds)
        #expect(abs(far.verticalMargin - -0.2) < 0.0001)
        let over = SubtitlePlacement.dropping(block: CGRect(x: 0.3, y: -0.15, width: 0.4, height: 0.08), alignment: .center,
                                              horizontalMargin: 0.08, verticalBounds: bounds)
        #expect(over.anchor == .top && abs(over.verticalMargin - -0.15) < 0.0001)
        // Not lifted when nothing covers it; clear of the controls when they reach past it.
        var s = SubtitleStyle(); s.place(under)
        #expect(s.restingMargin(coveredBottom: -.infinity) == s.verticalMargin)
        #expect(s.restingMargin(coveredBottom: -0.18) == s.verticalMargin)
        #expect(s.restingMargin(coveredBottom: 0.05) == 0.05)
    }
}
