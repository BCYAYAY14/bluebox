@testable import Features
import Testing

/// Jump to Time: what it reads, and why Go stays greyed out.
@MainActor
struct JumpToTimeTests {
    @Test func readsTheUsualShapes() {
        #expect(JumpToTimeSheet.check("12:30", duration: 3083) == .ok(750))
        #expect(JumpToTimeSheet.check("0:12:30", duration: 3083) == .ok(750))
        #expect(JumpToTimeSheet.check("90", duration: 3083) == .ok(90))
        #expect(JumpToTimeSheet.check(" 1:00 ", duration: 3083) == .ok(60))
    }

    /// Nothing typed asks for nothing; the footer explains the shapes instead.
    @Test func emptyIsNotAnError() {
        #expect(JumpToTimeSheet.check("", duration: 3083) == .empty)
        #expect(JumpToTimeSheet.check("   ", duration: 3083) == .empty)
    }

    @Test func saysWhyItCantGo() {
        #expect(JumpToTimeSheet.check("12:3x", duration: 3083) == .unreadable)
        #expect(JumpToTimeSheet.check("1:2:3:4", duration: 3083) == .unreadable)
        // 1:23:45 in a 51:23 episode is past the end, not quietly clamped to it.
        #expect(JumpToTimeSheet.check("1:23:45", duration: 3083) == .pastEnd)
        // With no length known, any time goes.
        #expect(JumpToTimeSheet.check("1:23:45", duration: 0) == .ok(5025))
    }
}
