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

    /// The grid above, every item pressing into `pressed`; no window, unless a test gives one.
    func grid(_ pressed: Box) -> RemoteFocus {
        let focus = RemoteFocus()
        focus.window = { nil }
        for item in all {
            focus.register(UUID(), .init(id: item.0, label: item.0, frame: item.1, layer: 0, select: { pressed.items.append(item.0) }))
        }
        return focus
    }
    final class Box { var items: [String] = [] }

    @Test func whileTheHighlightIsHiddenATapOnlyShowsIt() {
        let pressed = Box()
        let focus = grid(pressed)
        focus.select(driver: "iPhone")
        #expect(focus.focusedID == "play" && focus.visible)
        #expect(pressed.items.isEmpty)  // shown, not pressed: you hadn't seen it
        focus.select(driver: "iPhone")
        #expect(pressed.items == ["play"])
        // Someone used the Mac's mouse: the ring hides, and the next tap brings it back first.
        focus.hide()
        focus.select(driver: "iPhone")
        #expect(pressed.items == ["play"] && focus.visible)
        // A swipe while hidden only shows it too.
        focus.hide()
        focus.move(.down, driver: "iPhone")
        #expect(focus.focusedID == "play")
    }

    @Test func theHighlightStartsUnderTheMacsPointer() {
        let pressed = Box()
        let focus = grid(pressed)
        let c = card(row: 1, 3)
        focus.window = { (CGRect(x: 0, y: 0, width: 1000, height: 800), CGPoint(x: c.midX, y: c.midY)) }
        focus.select(driver: "iPhone")
        #expect(focus.focusedID == "r1c3")
        #expect(pressed.items.isEmpty)
    }

    @Test func itemsScrolledOffScreenAreNotWhereItStarts() {
        let focus = grid(Box())
        // Scrolled down past the Play button and the first row.
        focus.window = { (CGRect(x: 0, y: 250, width: 1000, height: 400), nil) }
        focus.move(.right, driver: "iPhone")
        #expect(focus.focusedID == "r1c0")
    }

    @Test func aSheetWithNothingToHighlightStillCoversThePage() {
        let pressed = Box()
        let focus = grid(pressed)
        focus.select(driver: "iPhone")  // "play" highlighted
        var closed = 0
        let trailer = UUID()
        focus.addModal(trailer, .init(layer: 1, dismiss: { closed += 1 }))
        #expect(focus.focusedID == nil)
        focus.select(driver: "iPhone")
        focus.move(.down, driver: "iPhone")
        #expect(pressed.items.isEmpty && focus.focusedID == nil)
        // Back closes it.
        #expect(focus.dismissTopModal())
        #expect(closed == 1)
        focus.removeModal(trailer)
        #expect(!focus.dismissTopModal())
        #expect(focus.focusedID == "play")  // the page's highlight is back where it was
    }

    @Test func aTapWithTheHighlightUnderANewSheetDoesNotPressThePage() {
        let pressed = Box()
        let focus = grid(pressed)
        focus.select(driver: "iPhone")  // "play" highlighted and showing
        focus.register(UUID(), .init(id: "release:1", label: "1080p", frame: CGRect(x: 300, y: 300, width: 400, height: 44), layer: 1,
                                     select: { pressed.items.append("1080p") }))
        focus.select(driver: "iPhone")
        #expect(pressed.items.isEmpty)  // not Play again: the sheet's row is highlighted instead
        #expect(focus.focusedID == "release:1")
        focus.select(driver: "iPhone")
        #expect(pressed.items == ["1080p"])
    }

    @Test func aNewLabelOnTheHighlightedItemReachesThePhone() {
        let focus = RemoteFocus()
        focus.window = { nil }
        var changes = 0
        focus.onChange = { changes += 1 }
        let play = UUID()
        focus.register(play, .init(id: "play", label: "Play", frame: self.play, layer: 0, select: {}))
        focus.move(.down, driver: "iPhone")
        let before = changes
        focus.register(play, .init(id: "play", label: "Resume 12:04", frame: self.play, layer: 0, select: {}))
        #expect(focus.focusedLabel == "Resume 12:04")
        #expect(changes == before + 1)
    }

    // MARK: The better remote (31 Oct 2026)

    /// Waits for something the main actor does later (a fade, a coast), however busy the machine is.
    func until(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// After a while the ring dims to an outline instead of going: the next swipe moves at once.
    @Test func theHighlightDimsInsteadOfGoing() async throws {
        let focus = grid(Box())
        focus.fadeAfter = .milliseconds(40)
        focus.move(.right, driver: "iPhone")
        #expect(focus.focusedID == "play")
        #expect(await until { focus.dimmed })
        #expect(focus.visible)
        focus.move(.down, driver: "iPhone")
        #expect(focus.focusedID == "r0c0" && !focus.dimmed)
    }

    /// The highlighted item went away (a new page): the new page's first item is highlighted by itself.
    @Test func aNewPageStartsOnItsFirstItem() async throws {
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.settleDelay = .milliseconds(20)
        let old = UUID()
        focus.register(old, .init(id: "title:a", label: "A", frame: card(row: 0, 0), layer: 0, select: {}))
        focus.move(.down, driver: "iPhone")
        #expect(focus.focusedID == "title:a")
        focus.unregister(old)
        focus.register(UUID(), .init(id: "episode:2", label: "2", frame: card(row: 1, 1), layer: 0, select: {}))
        focus.register(UUID(), .init(id: "play", label: "Play", frame: play, layer: 0, select: {}))
        #expect(await until { focus.focusedID == "play" })
    }

    @Test func aJumpTakesSeveralSteps() {
        let focus = grid(Box())
        focus.move(.down, driver: "iPhone")  // shows "play"
        focus.move(.down, driver: "iPhone")
        focus.jump(.right, count: 3, driver: "iPhone")
        #expect(focus.focusedID == "r0c3")
    }

    /// The phone's strip: the highlighted poster, the ones either side, and its row.
    @Test func thePhoneSeesTheRowAroundTheHighlight() {
        let focus = RemoteFocus()
        focus.window = { nil }
        for i in 0..<3 {
            focus.register(UUID(), .init(id: "c\(i)", label: "Card \(i)", frame: card(row: 0, i), layer: 0, kind: .poster,
                                         section: "Trending", select: {}))
        }
        focus.focus(id: "c1", driver: "iPhone")
        let s = focus.screen()
        #expect(s.focused?.label == "Card 1" && s.focused?.kind == .poster)
        #expect(s.before?.label == "Card 0" && s.after?.label == "Card 2")
        #expect(s.horizontal == true && s.section == "Trending")
    }

    /// What isn't marked comes from the window: reachable, pressed through it,
    /// and not twice when a marked item already covers it.
    @Test func unmarkedControlsAreReachable() {
        let window = FakeWindow()
        window.items = [
            .init(label: "More Info", kind: .button, frame: CGRect(x: 0, y: 0, width: 120, height: 40)),  // under "play": covered
            .init(label: "Skip intros", kind: .toggle, frame: CGRect(x: 0, y: 500, width: 300, height: 30), isOn: true),
        ]
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        focus.register(UUID(), .init(id: "play", label: "Play", frame: play, layer: 0, select: {}))
        #expect(focus.candidates().count == 2)
        focus.move(.down, driver: "iPhone")  // shows "play"
        focus.move(.down, driver: "iPhone")
        #expect(focus.focusedLabel == "Skip intros")
        #expect(focus.screen().focused?.isOn == true)
        focus.select(driver: "iPhone")
        #expect(window.log == ["press Skip intros"])
        #expect(window.ring != nil)
    }

    /// A move onto a row half below the window's edge scrolls the window so the row shows, and the ring follows it.
    @Test func theWindowFollowsTheHighlight() {
        let window = FakeWindow()
        window.items = [
            .init(label: "First", kind: .row, frame: CGRect(x: 0, y: 600, width: 300, height: 40)),
            .init(label: "Second", kind: .row, frame: CGRect(x: 0, y: 680, width: 300, height: 40)),
        ]
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        focus.move(.down, driver: "iPhone")  // shows "First", already in view
        #expect(focus.focusedLabel == "First" && window.revealed.isEmpty)
        focus.move(.down, driver: "iPhone")
        #expect(focus.focusedLabel == "Second")
        #expect(window.revealed.count == 1)
        #expect(window.ring.map { $0.maxY <= window.bounds.maxY } == true)
    }

    #if os(macOS)
    /// How far the real window scrolls: the least that shows all of it with room, and what counts as hidden.
    @Test func scrollingIntoViewMovesTheLeastItTakes() {
        #expect(RemoteWindow.nudge(100, 140, into: 0, 700, margin: 40) == 0)  // already showing
        #expect(RemoteWindow.nudge(680, 720, into: 0, 700, margin: 40) == 60)  // below: up to 40 from the edge
        #expect(RemoteWindow.nudge(-20, 20, into: 0, 700, margin: 40) == -60)  // above
        #expect(RemoteWindow.nudge(500, 1300, into: 0, 700, margin: 40) == 500)  // taller than the view: its top
        let list = CGRect(x: 0, y: 100, width: 400, height: 500)
        #expect(RemoteWindow.mostlyShowing(CGRect(x: 0, y: 580, width: 300, height: 40), in: list))  // 20 of 40 shows
        #expect(!RemoteWindow.mostlyShowing(CGRect(x: 0, y: 590, width: 300, height: 40), in: list))
        #expect(!RemoteWindow.mostlyShowing(CGRect(x: 0, y: 650, width: 300, height: 40), in: list))  // below the list, still in the window
    }
    #endif

    /// An overlay in the window (the season list): its own controls are in reach, the page's under it aren't.
    @Test func anOverlayKeepsOnlyItsOwnControls() {
        let window = FakeWindow()
        window.items = [
            .init(label: "Page button", kind: .button, frame: CGRect(x: 20, y: 20, width: 100, height: 40)),
            .init(label: "Season 2", kind: .button, frame: CGRect(x: 400, y: 300, width: 200, height: 40)),
        ]
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        let seasons = UUID()
        focus.moveModal(seasons, to: CGRect(x: 350, y: 200, width: 300, height: 300))
        focus.addModal(seasons, .init(layer: 1, dismiss: {}))
        #expect(focus.candidates().map(\.item.label) == ["Season 2"])
        focus.removeModal(seasons)
        #expect(focus.candidates().count == 2)
    }

    /// At the edge of what's showing, a move scrolls the page on and carries on to what came into view.
    @Test func aMoveAtTheEdgeScrollsOn() async throws {
        let window = FakeWindow()
        window.items = [.init(label: "Top", kind: .button, frame: CGRect(x: 0, y: 0, width: 100, height: 40))]
        window.onScrollPage = { window.items.append(.init(label: "Below", kind: .button, frame: CGRect(x: 0, y: 300, width: 100, height: 40))) }
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        focus.move(.down, driver: "iPhone")
        #expect(focus.focusedLabel == "Top")
        focus.move(.down, driver: "iPhone")
        #expect(window.log == ["page down"])
        #expect(await until { focus.focusedLabel == "Below" })
        // Nothing further: a bump the phone can feel.
        window.onScrollPage = nil
        window.canScroll = false
        let bumps = focus.screen().bumps ?? 0
        focus.move(.down, driver: "iPhone")
        #expect((focus.screen().bumps ?? 0) == bumps + 1)
    }

    /// A screen with nothing to highlight switches to the pointer; a tap clicks under it.
    @Test func nothingToHighlightMeansAPointer() {
        let window = FakeWindow()
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        focus.move(.right, driver: "iPhone")
        #expect(focus.pointerMode && focus.pointer == CGPoint(x: 500, y: 350))
        #expect(focus.screen().pointer == true)
        focus.movePointer(dx: 10, dy: 0, driver: "iPhone")
        #expect(focus.pointer == CGPoint(x: 516, y: 350))
        focus.select(driver: "iPhone")
        #expect(window.log == ["click 516,350"])
        focus.setPointer(false, driver: "iPhone")
        #expect(!focus.pointerMode && focus.pointer == nil)
    }

    /// The player or the loading screen over the window: the ring isn't left
    /// drawn over the film, and comes back on the same item afterwards.
    @Test func theRingStandsAsideUnderThePlayer() {
        let window = FakeWindow()
        window.items = [.init(label: "Card", kind: .button, frame: CGRect(x: 100, y: 100, width: 100, height: 150))]
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        focus.move(.down, driver: "iPhone")
        #expect(window.ring != nil)
        focus.setCovered(true)
        #expect(window.ring == nil)
        focus.setCovered(false)
        #expect(window.ring != nil && focus.focusedLabel == "Card")
    }

    /// A slow finger moves the pointer finely; a quick one crosses the window.
    @Test func thePointerSpeedsUpWithTheFinger() {
        #expect(RemoteFocus.pointerScale(for: 5) == RemoteFocus.pointerScale)
        #expect(RemoteFocus.pointerScale(for: 80) == RemoteFocus.pointerScale * RemoteFocus.pointerBoost)
        #expect(RemoteFocus.pointerScale(for: 30) > RemoteFocus.pointerScale(for: 15))
    }

    /// Hold: the right-click a poster's quick actions open on.
    @Test func aHoldRightClicksTheHighlight() {
        let window = FakeWindow()
        window.items = [.init(label: "Card", kind: .button, frame: CGRect(x: 100, y: 100, width: 100, height: 150))]
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        focus.move(.down, driver: "iPhone")
        focus.openMenu(driver: "iPhone")
        #expect(window.log == ["right-click 150,175"])
    }

    /// Two fingers scroll under the highlight; lifting with speed coasts on, then the highlight moves onto what's showing.
    @Test func twoFingersScrollAndCoast() async throws {
        let window = FakeWindow()
        window.items = [.init(label: "A", kind: .button, frame: CGRect(x: 0, y: 100, width: 100, height: 40))]
        let focus = RemoteFocus()
        focus.window = { nil }
        focus.platform = window
        focus.move(.down, driver: "iPhone")
        focus.scroll(RemoteScroll(dx: 0, dy: 50), driver: "iPhone")
        #expect(window.log == ["scroll 0,50"])
        // The page moved A off screen and brought B in.
        window.items = [.init(label: "B", kind: .button, frame: CGRect(x: 0, y: 300, width: 100, height: 40))]
        // A slow coast (a few frames), so a busy machine doesn't drag it out.
        focus.scroll(RemoteScroll(dx: 0, dy: 10, velocityX: 0, velocityY: 120), driver: "iPhone")
        #expect(await until(seconds: 20) { focus.focusedLabel == "B" })
        #expect(window.log.count > 3)
    }
}

/// The Mac's windows, in memory.
@MainActor final class FakeWindow: RemoteWindowing {
    struct Item { var label: String; var kind: RemoteScreenItem.Kind; var frame: CGRect; var isOn: Bool? = nil }
    var items: [Item] = []
    var log: [String] = []
    var ring: CGRect?
    var canScroll = true
    var onScrollPage: (() -> Void)?

    var activeKind: RemoteWindowKind? { .main }
    var bounds: CGRect { CGRect(x: 0, y: 0, width: 1000, height: 700) }
    var mousePointer: CGPoint? { nil }
    func elements() -> [RemoteFocus.Element] { items.map { .init(label: $0.label, kind: $0.kind, frame: $0.frame, isOn: $0.isOn) } }
    func press(_ element: RemoteFocus.Element) { log.append("press \(element.label)") }
    func click(at point: CGPoint, right: Bool) { log.append("\(right ? "right-click" : "click") \(Int(point.x)),\(Int(point.y))") }
    func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat) -> Bool { log.append("scroll \(Int(dx)),\(Int(dy))"); return true }
    func scrollPage(at point: CGPoint, toward direction: RemoteDirection) -> Bool {
        guard canScroll else { return false }
        log.append("page \(direction.rawValue)")
        onScrollPage?()
        return true
    }
    func scrollIntoView(_ frame: CGRect) -> Bool {
        // Below the window: scroll the page up by the overhang, as RemoteWindow would.
        let over = frame.maxY + 40 - bounds.maxY
        guard canScroll, over > 0 else { return false }
        revealed.append(frame)
        for i in items.indices { items[i].frame.origin.y -= over }
        return true
    }
    var revealed: [CGRect] = []
    func draw(ring: CGRect?, driver: String, dimmed: Bool, pointer: CGPoint?) { self.ring = ring }
}
