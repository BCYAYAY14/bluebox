import CoreGraphics
@testable import Features
import Foundation
import Sync
import Testing

/// The Mac's highlight for the remote's touch pad: which item a swipe lands
/// on, the way tvOS's focus engine picks, and sheets taking the focus.
@MainActor
@Suite struct RemoteFocusTests {
    /// Two rows of posters (100×150, 10 apart), the second shifted right by 30, and a Play button above.
    let play = CGRect(x: 0, y: 0, width: 120, height: 40)
    func card(row: Int, _ i: Int) -> CGRect {
        CGRect(x: CGFloat(i) * 110 + (row == 1 ? 30 : 0), y: 80 + CGFloat(row) * 200, width: 100, height: 150)
    }
    var all: [(String, CGRect)] {
        [("play", play)] + (0..<2).flatMap { r in (0..<5).map { ("r\(r)c\($0)", card(row: r, $0)) } }
    }
    func next(from id: String, _ d: RemoteDirection) -> String? {
        let current = all.first { $0.0 == id }!.1
        return RemoteFocus.nearest(from: current, in: all.filter { $0.0 != id }, toward: d)
    }

    @Test func rightAndLeftStayInTheRow() {
        #expect(next(from: "r0c1", .right) == "r0c2")
        #expect(next(from: "r0c1", .left) == "r0c0")
        // The row's end: nothing further that way, rather than jumping rows.
        #expect(next(from: "r0c4", .right) == nil)
        #expect(next(from: "r1c0", .left) == nil)
    }

    @Test func downGoesToTheNearestRowAtTheClosestColumn() {
        // r0c2 is centred at x 270; row 1's nearest are centred at 190 and 300.
        #expect(next(from: "r0c2", .down) == "r1c2")
        #expect(next(from: "play", .down) == "r0c0")
        #expect(next(from: "r1c3", .down) == nil)
    }

    @Test func upClimbsOneRowAtATime() {
        #expect(next(from: "r1c2", .up) == "r0c2")
        #expect(next(from: "r0c3", .up) == "play")
        #expect(next(from: "play", .up) == nil)
    }

    @Test func movingStartsFromTheFirstItemOnScreen() {
        let focus = RemoteFocus()
        let ids = all.map { _ in UUID() }
        for (i, item) in all.enumerated() {
            focus.register(ids[i], .init(id: item.0, label: item.0, frame: item.1, layer: 0, select: {}))
        }
        focus.move(.right, driver: "iPhone")
        #expect(focus.focusedID == "play")  // nothing highlighted yet: the top-left item
        focus.move(.down, driver: "iPhone")
        focus.move(.right, driver: "iPhone")
        #expect(focus.focusedID == "r0c1")
        #expect(focus.visible && focus.driver == "iPhone")
    }

    @Test func aSheetTakesTheFocusAndSelectPressesIt() {
        let focus = RemoteFocus()
        var pressed: [String] = []
        focus.register(UUID(), .init(id: "title:a", label: "A", frame: card(row: 0, 0), layer: 0, select: { pressed.append("A") }))
        let release = UUID()
        focus.register(release, .init(id: "release:1", label: "1080p", frame: CGRect(x: 300, y: 300, width: 400, height: 44), layer: 1,
                                      select: { pressed.append("1080p") }))
        focus.move(.down, driver: "iPhone")
        #expect(focus.focusedID == "release:1")  // the window behind the sheet is out of reach
        focus.select(driver: "iPhone")
        #expect(pressed == ["1080p"])
        // The sheet closes: the window's items are reachable again.
        focus.unregister(release)
        #expect(focus.focusedID == nil)
        focus.move(.down, driver: "iPhone")
        #expect(focus.focusedID == "title:a")
    }

    @Test func aTapOnThePhoneHighlightsTheFirstMatch() {
        let focus = RemoteFocus()
        // The same title in two rows: the upper one.
        focus.register(UUID(), .init(id: "title:x", label: "X", frame: card(row: 1, 2), layer: 0, select: {}))
        focus.register(UUID(), .init(id: "title:x", label: "X", frame: card(row: 0, 4), layer: 0, select: {}))
        focus.focus(id: "title:x", driver: "iPhone")
        #expect(focus.focusedLabel == "X")
        focus.move(.down, driver: "iPhone")
        #expect(focus.focusedID == "title:x")  // moved to the lower copy
        focus.hide()
        #expect(!focus.visible)
    }
}
