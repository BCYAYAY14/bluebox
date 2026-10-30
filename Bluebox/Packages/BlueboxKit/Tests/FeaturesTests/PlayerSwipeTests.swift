import CoreGraphics
@testable import Features
import Testing

@Suite struct PlayerSwipeTests {
    let size = CGSize(width: 800, height: 400)

    @Test func theFirstMovementDecidesTheKind() {
        #expect(PlayerSwipe.kind(startLocation: CGPoint(x: 100, y: 200), translation: CGSize(width: 30, height: 10), in: size) == .seek)
        #expect(PlayerSwipe.kind(startLocation: CGPoint(x: 100, y: 200), translation: CGSize(width: 5, height: -30), in: size) == .brightness)
        #expect(PlayerSwipe.kind(startLocation: CGPoint(x: 700, y: 200), translation: CGSize(width: 5, height: 30), in: size) == .volume)
    }

    @Test func theSystemsEdgesAreLeftAlone() {
        #expect(PlayerSwipe.kind(startLocation: CGPoint(x: 400, y: 10), translation: CGSize(width: 0, height: 40), in: size) == nil)
        #expect(PlayerSwipe.kind(startLocation: CGPoint(x: 400, y: 390), translation: CGSize(width: 0, height: -40), in: size) == nil)
    }

    @Test func aFullWidthSeeksTwoMinutesWithinTheVideo() {
        #expect(PlayerSwipe.seekTarget(from: 600, dx: 800, width: 800, duration: 3600) == 720)
        #expect(PlayerSwipe.seekTarget(from: 600, dx: -400, width: 800, duration: 3600) == 540)
        #expect(PlayerSwipe.seekTarget(from: 30, dx: -800, width: 800, duration: 3600) == 0)
        #expect(PlayerSwipe.seekTarget(from: 3550, dx: 800, width: 800, duration: 3600) == 3600)
        #expect(PlayerSwipe.seekTarget(from: 10, dx: 800, width: 800, duration: nil) == 130)
    }

    @Test func upRaisesTheLevelAndItStaysInRange() {
        #expect(PlayerSwipe.level(from: 0.5, dy: -200, height: 400) == 1)
        #expect(PlayerSwipe.level(from: 0.5, dy: 100, height: 400) == 0.25)
        #expect(PlayerSwipe.level(from: 0.1, dy: 400, height: 400) == 0)
    }
}
