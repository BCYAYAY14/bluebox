import DesignSystem
import Observation
import Sync
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The Mac's highlight for the remote (the new remote, question 5; the better
/// remote, 31 Oct 2026): what the phone's touch pad moves and presses, and
/// what a tap on the phone points at.
///
/// Two kinds of thing can be highlighted. Items that mark themselves
/// `.remoteFocusable(…)` (posters, episodes, releases, Play) report their
/// frame and draw their own ring, with a picture and a name for the phone.
/// Everything else you could click (the sidebar, chips, the hero's buttons,
/// Settings rows and switches, a sheet's buttons, text fields) comes from the
/// window's own accessibility tree (`RemoteWindow`), so a new screen is
/// reachable without marking anything; its ring is drawn over the window. A
/// move picks the nearest item that way, the way tvOS's focus engine does; an
/// Apple TV app gets the same commands and uses its real focus instead.
///
/// There is always a highlight once the remote has been used (question 1):
/// after `fadeAfter` without input the ring dims to an outline rather than
/// vanishing, and a new page starts on its first item, so every swipe moves
/// and every tap presses something you can see. Using the Mac's own mouse or
/// keyboard hides it; the next touch on the phone only shows it again, where
/// it was. A screen with nothing to highlight switches the pad to a pointer.
///
/// Sheets and overlays mark themselves `.remoteModal()`: each is a layer, and
/// only the top layer's items are reachable, even when it has none of its own
/// (a trailer), so the page under it can't be pressed. Back closes the top one.
/// An open Bluebox menu comes first of all: the pad moves through its items.
/// The player and the loading screen cover everything (`setCovered`): the
/// ring and pointer aren't drawn over them, and come back when they go.
@MainActor @Observable
public final class RemoteFocus {
    struct Target {
        /// What the remote calls it: "title:<key>", "episode:<key>", "release:<id>", "play".
        var id: String
        var label: String
        var frame: CGRect
        /// A sheet over the window is its own layer: only the top layer is reachable.
        var layer: Int
        var kind: RemoteScreenItem.Kind = .button
        /// A poster's picture, for the phone.
        var image: URL? = nil
        /// The row it's in ("Continue Watching"), for the phone.
        var section: String? = nil
        var select: @MainActor () -> Void
    }

    /// A sheet or overlay over the window.
    struct Modal {
        var layer: Int
        var dismiss: @MainActor () -> Void
        /// Where it is, for an overlay in the window (the season list): only controls inside it are in reach.
        var frame: CGRect? = nil
    }

    /// A control found in the window's accessibility tree (`RemoteWindow.elements`).
    struct Element {
        var label: String
        var kind: RemoteScreenItem.Kind
        /// In the window's coordinates, top-left origin, as SwiftUI's global frames are.
        var frame: CGRect
        var isOn: Bool?
        /// The accessibility node, to press it.
        var node: AnyObject?

        func same(as other: Element) -> Bool { label == other.label && kind == other.kind && frame == other.frame }
    }

    /// One thing a move can land on: a marked item or an element.
    struct Candidate {
        enum Ref { case target(UUID), element(Element) }
        var ref: Ref
        var id: String
        var frame: CGRect
        var item: RemoteScreenItem
        var section: String?
    }

    /// The highlighted marked view (each instance, since one title can sit in several rows).
    public private(set) var focused: UUID?
    /// The highlighted element, when it isn't a marked view.
    private(set) var element: Element?
    /// The layer in reach: the topmost sheet's, or 0 for the window.
    private(set) var topLayer = 0
    /// The ring is showing.
    public private(set) var visible = false
    /// No remote input for `fadeAfter`: the ring is a faint outline.
    public private(set) var dimmed = false
    /// The pad moves a pointer instead of the highlight (`setPointer`).
    public private(set) var pointerMode = false
    /// Where the pointer is, in the window's coordinates.
    public private(set) var pointer: CGPoint?
    /// Who's driving: "Brian's iPhone".
    public private(set) var driver = ""
    /// The player or the loading screen covers the window (`setCovered`): no ring or pointer is drawn over it.
    public private(set) var covered = false
    /// Moves that hit the end of a row: the phone bumps when it goes up.
    private(set) var bumps = 0
    /// The page the Mac is on, for `RemoteScreen` (RootView keeps it up to date).
    public var screenTitle = "Home" { didSet { if screenTitle != oldValue { pageChanged(); onChange?() } } }

    @ObservationIgnored private var targets: [UUID: Target] = [:]
    @ObservationIgnored private var modals: [UUID: Modal] = [:]
    @ObservationIgnored private var modalFrames: [UUID: CGRect] = [:]
    /// The window's area and the pointer, in the items' coordinates: the
    /// first item on screen, and the one under the pointer. nil in tests.
    @ObservationIgnored var window: @MainActor () -> (bounds: CGRect, pointer: CGPoint?)? = RemoteFocus.mainWindow
    /// The Mac's windows: elements, clicks, scrolling and the drawn ring.
    /// RemoteControlHost sets it in the app; nil in tests, which see marked items only.
    @ObservationIgnored var platform: (any RemoteWindowing)?
    @ObservationIgnored private var fade: Task<Void, Never>?
    @ObservationIgnored private var refocus: Task<Void, Never>?
    @ObservationIgnored private var coast: Task<Void, Never>?
    @ObservationIgnored private var follow: Task<Void, Never>?
    @ObservationIgnored private var relocate: Task<Void, Never>?
    @ObservationIgnored private var lastScrollRefresh = Date.distantPast
    /// The window's elements as last walked (`elements()`).
    @ObservationIgnored private var cachedElements: (at: Date, kind: RemoteWindowKind?, list: [Element])?
    /// Where the fingers' scroll lands, kept for the rest of the gesture.
    @ObservationIgnored private var scrollAnchor: (point: CGPoint, at: Date)?
    /// The highlight or page changed: `RemoteControl.screenChanged`.
    @ObservationIgnored var onChange: (() -> Void)?
    #if os(macOS)
    @ObservationIgnored private var localInput: Any?
    #endif

    /// How long without remote input before the ring dims; tests shorten it.
    @ObservationIgnored var fadeAfter: Duration = .seconds(8)
    /// How long a new page has to put its items in before its first one is highlighted.
    @ObservationIgnored var settleDelay: Duration = .milliseconds(350)
    /// How long a walk of the window's elements is reused: one move asks several
    /// times (the move, the phone's neighbours, a fast swipe's steps), and the
    /// walk is the slow part of a move.
    @ObservationIgnored var elementsLifetime: TimeInterval = 0.25
    /// A slow pointer move from the pad is this much bigger on the Mac; a fast one up to `pointerBoost` times more.
    nonisolated static let pointerScale: CGFloat = 1.6
    nonisolated static let pointerBoost: CGFloat = 2.5

    public init() {
        BlueboxMenuRemote.onChange = { [weak self] in self?.menuChanged() }
    }

    var focusedID: String? {
        if let current = current { return current.1.id }
        return element.map { "element:\($0.label)" }
    }
    var focusedLabel: String? { current?.1.label ?? element?.label }

    // MARK: Items

    func register(_ instance: UUID, _ target: Target) {
        let old = targets[instance]
        targets[instance] = target
        if old?.layer != target.layer { refreshTopLayer() }
        // What the phone shows changed (Play became Resume).
        if instance == focused, old?.label != target.label { onChange?() }
    }

    func unregister(_ instance: UUID) {
        guard targets.removeValue(forKey: instance) != nil else { return }
        refreshTopLayer()
        if focused == instance { focused = nil; pageChanged(); onChange?() }
    }

    func isFocused(_ instance: UUID) -> Bool { visible && !covered && focused == instance && targets[instance]?.layer == topLayer }

    /// The player or the loading screen came over the window, or went: the
    /// ring and pointer stand aside meanwhile, rather than being left drawn
    /// over the film where they were. Uncovered, the highlight comes back where
    /// it was, or on the page's first item if that went.
    func setCovered(_ on: Bool) {
        guard on != covered else { return }
        covered = on
        refocus?.cancel(); follow?.cancel(); coast?.cancel(); relocate?.cancel()
        invalidate()
        if on {
            if pointerMode { pointerMode = false; pointer = nil }
        } else {
            pageChanged()
            relocateSoon()
        }
        redraw()
        onChange?()
    }

    func addModal(_ instance: UUID, _ modal: Modal) {
        var modal = modal
        modal.frame = modal.frame ?? modalFrames[instance]
        modals[instance] = modal
        refreshTopLayer()
    }

    /// Its frame can arrive before or after it's added.
    func moveModal(_ instance: UUID, to frame: CGRect) {
        modalFrames[instance] = frame
        modals[instance]?.frame = frame
    }

    func removeModal(_ instance: UUID) {
        modalFrames[instance] = nil
        guard modals.removeValue(forKey: instance) != nil else { return }
        refreshTopLayer()
    }

    /// The remote's Back: close an open menu, else the top sheet or overlay. False when none is up.
    func dismissTopModal() -> Bool {
        if let menu = BlueboxMenuRemote.current { menu.dismiss(); return true }
        guard let top = modals.values.max(by: { $0.layer < $1.layer }) else { return false }
        top.dismiss()
        return true
    }

    /// Going somewhere else (Home, Search, a title): close every sheet first.
    func dismissAllModals() {
        BlueboxMenuRemote.current?.dismiss()
        for modal in modals.values.sorted(by: { $0.layer > $1.layer }) { modal.dismiss() }
    }

    private func refreshTopLayer() {
        let top = max(targets.values.map(\.layer).max() ?? 0, modals.values.map(\.layer).max() ?? 0)
        if top != topLayer {
            topLayer = top
            element = nil
            invalidate()
            pageChanged()
            onChange?()
        }
    }

    /// Only the top layer's items: a sheet's, while one is up (none, if it has none).
    private var reachable: [(UUID, Target)] {
        targets.filter { $0.value.layer == topLayer }.map { ($0.key, $0.value) }
    }

    /// The highlighted marked item, if it's still in reach.
    private var current: (UUID, Target)? {
        guard let focused, let target = targets[focused], target.layer == topLayer else { return nil }
        return (focused, target)
    }

    /// Everything a move can land on: the top layer's marked items, and the
    /// window's elements that no marked item already covers (a poster is a button too).
    func candidates() -> [Candidate] {
        let active = platform?.activeKind
        var out: [Candidate] = []
        // Marked items live in the main window (layer 0) or its sheets (layer 1 and up).
        let marked: [(UUID, Target)] = switch active {
        case nil, .main: reachable
        case .sheet: reachable.filter { $0.1.layer > 0 }
        case .other: []
        }
        for (id, t) in marked {
            out.append(Candidate(ref: .target(id), id: t.id, frame: t.frame,
                                 item: RemoteScreenItem(label: t.label, kind: t.kind, image: t.image), section: t.section))
        }
        // An overlay in the main window (the season list) covers the page: only its own controls are in reach.
        let overlay: CGRect? = active == .main && topLayer > 0
            ? modals.values.filter { $0.layer == topLayer }.compactMap(\.frame).first ?? .zero : nil
        if platform != nil {
            let covered = out.map { $0.frame.insetBy(dx: -2, dy: -2) }
            for e in elements() where !covered.contains(where: { $0.contains(CGPoint(x: e.frame.midX, y: e.frame.midY)) }) {
                if let overlay, !overlay.contains(CGPoint(x: e.frame.midX, y: e.frame.midY)) { continue }
                out.append(Candidate(ref: .element(e), id: "element:\(e.label)", frame: e.frame,
                                     item: RemoteScreenItem(label: e.label, kind: e.kind, isOn: e.isOn), section: nil))
            }
        }
        return out
    }

    /// The window's elements, walked again only once `elementsLifetime` has
    /// passed or something changed the page (a press, a scroll, a sheet).
    private func elements() -> [Element] {
        guard let platform else { return [] }
        let kind = platform.activeKind
        if let c = cachedElements, c.kind == kind, Date().timeIntervalSince(c.at) < elementsLifetime { return c.list }
        let list = platform.elements()
        cachedElements = (Date(), kind, list)
        return list
    }

    /// The page changed: the next look walks the window again.
    func invalidate() { cachedElements = nil }

    /// The highlighted candidate, found again (an element may have moved, a scroll or a relayout).
    private func currentCandidate(in all: [Candidate]) -> Candidate? {
        if let (id, _) = current { return all.first { if case .target(id) = $0.ref { true } else { false } } }
        guard let element else { return nil }
        let matches = all.compactMap { c -> (Candidate, CGFloat)? in
            guard case .element(let e) = c.ref, e.label == element.label, e.kind == element.kind else { return nil }
            return (c, hypot(e.frame.midX - element.frame.midX, e.frame.midY - element.frame.midY))
        }
        guard let best = matches.min(by: { $0.1 < $1.1 }), best.1 < 400 else { return nil }
        // Keep the ring on it where it is now.
        if case .element(let e) = best.0.ref, !e.same(as: element) { self.element = e; redraw() }
        return best.0
    }

    // MARK: Commands

    /// Highlight the item with this ID (the first on screen, top to bottom), e.g. what was tapped on the phone.
    func focus(id: String, driver: String) {
        let matches = reachable.filter { $0.1.id == id }
        let area = window()?.bounds
        let onScreen = area.map { a in matches.filter { a.intersects($0.1.frame) } } ?? matches
        guard let match = (onScreen.isEmpty ? matches : onScreen).min(by: Self.readingOrder) else { return }
        setFocus(.target(match.0), driver: driver)
    }

    /// The nearest item that way. While the highlight is hidden, only shows it.
    /// At the edge of what's showing, the page scrolls on and the move carries on there.
    func move(_ direction: RemoteDirection, driver: String) {
        if let menu = BlueboxMenuRemote.current {
            switch direction {
            case .up: menu.step(-1)
            case .down: menu.step(1)
            case .left, .right: break
            }
            show(driver: driver)
            return
        }
        if pointerMode {
            let step: CGFloat = 40
            let d: CGVector = switch direction {
            case .up: CGVector(dx: 0, dy: -step)
            case .down: CGVector(dx: 0, dy: step)
            case .left: CGVector(dx: -step, dy: 0)
            case .right: CGVector(dx: step, dy: 0)
            }
            movePointer(dx: d.dx, dy: d.dy, driver: driver)
            return
        }
        let all = candidates()
        guard visible, let here = currentCandidate(in: all) else { reveal(driver: driver, in: all); return }
        if let next = Self.step(from: here, toward: direction, in: all) {
            setFocus(next.ref, driver: driver)
        } else if let platform, platform.scrollPage(at: CGPoint(x: here.frame.midX, y: here.frame.midY), toward: direction) {
            // More of the page that way: once it has moved, carry on to what came into view.
            invalidate()
            show(driver: driver)
            follow?.cancel()
            follow = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard let self, !Task.isCancelled else { return }
                self.invalidate()
                let all = self.candidates()
                if let here = self.currentCandidate(in: all), let next = Self.step(from: here, toward: direction, in: all) {
                    self.setFocus(next.ref, driver: driver)
                } else {
                    self.bump(driver: driver)
                }
            }
        } else {
            bump(driver: driver)
        }
    }

    /// Several steps one way: a fast swipe.
    func jump(_ direction: RemoteDirection, count: Int, driver: String) {
        for _ in 0..<max(1, min(count, 12)) { move(direction, driver: driver) }
    }

    /// Press the highlighted item, as a click would. While the highlight is hidden, only shows it.
    func select(driver: String) {
        if let menu = BlueboxMenuRemote.current { menu.activateHighlighted(); show(driver: driver); return }
        if pointerMode { click(driver: driver); return }
        let all = candidates()
        guard visible, let here = currentCandidate(in: all) else { reveal(driver: driver, in: all); return }
        show(driver: driver)
        press(here)
        // A press usually changes the page (a title opens, a switch flips): look again.
        invalidate()
        relocateSoon()
    }

    /// Hold: the highlighted item's menu, as a right-click opens it (a poster's quick actions).
    func openMenu(driver: String) {
        guard BlueboxMenuRemote.current == nil else { return }
        let point: CGPoint?
        if pointerMode { point = pointer } else {
            let all = candidates()
            guard visible, let here = currentCandidate(in: all) else { reveal(driver: driver, in: all); return }
            point = CGPoint(x: here.frame.midX, y: here.frame.midY)
        }
        show(driver: driver)
        if let point { platform?.click(at: point, right: true) }
        invalidate()
    }

    /// An item of the open menu, picked on the phone.
    func pickMenuItem(_ index: Int, driver: String) {
        BlueboxMenuRemote.current?.pick(index)
        show(driver: driver)
    }

    /// The pad drives a pointer (or the highlight again). The pointer starts on the highlight.
    func setPointer(_ on: Bool, driver: String) {
        guard on != pointerMode else { show(driver: driver); return }
        pointerMode = on
        if on {
            let all = candidates()
            let here = currentCandidate(in: all)
            let bounds = platform?.bounds ?? window()?.bounds ?? .zero
            pointer = here.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? CGPoint(x: bounds.midX, y: bounds.midY)
        } else {
            // Back to the highlight: on what the pointer was over, if anything.
            let all = candidates()
            if let p = pointer, let hit = all.filter({ $0.frame.contains(p) }).min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                focusedRef(hit.ref)
            }
            pointer = nil
        }
        show(driver: driver)
        onChange?()
    }

    func movePointer(dx: CGFloat, dy: CGFloat, driver: String) {
        if !pointerMode { setPointer(true, driver: driver) }
        let bounds = platform?.bounds ?? window()?.bounds ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let p = pointer ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = Self.pointerScale(for: hypot(dx, dy))
        pointer = CGPoint(x: min(max(p.x + dx * scale, bounds.minX + 2), bounds.maxX - 2),
                          y: min(max(p.y + dy * scale, bounds.minY + 2), bounds.maxY - 2))
        show(driver: driver)
    }

    /// Pointer acceleration, as a trackpad's: a slow finger moves it finely,
    /// a quick one crosses the window. `distance` is one message's worth (a
    /// twentieth of a second of finger travel on the phone).
    nonisolated static func pointerScale(for distance: CGFloat) -> CGFloat {
        let quick = min(max((distance - 10) / 40, 0), 1)
        return pointerScale * (1 + (pointerBoost - 1) * quick)
    }

    /// Click under the pointer, or press the highlight.
    func click(driver: String) {
        guard pointerMode, let pointer else { select(driver: driver); return }
        show(driver: driver)
        platform?.click(at: pointer, right: false)
        invalidate()
    }

    /// Two fingers: scroll what's under the highlight (or the pointer). The
    /// last message carries the fingers' speed, and the page coasts on, as
    /// on a trackpad; then the highlight moves onto what's showing.
    func scroll(_ s: RemoteScroll, driver: String) {
        guard let platform else { return }
        // Where the gesture began scrolls for all of it: no walk of the window per message.
        let point: CGPoint
        if let anchor = scrollAnchor, Date().timeIntervalSince(anchor.at) < 0.4 {
            point = anchor.point
        } else {
            let bounds = platform.bounds
            let at = pointerMode ? pointer : currentCandidate(in: candidates()).map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
            point = at ?? CGPoint(x: bounds.midX, y: bounds.midY)
        }
        scrollAnchor = s.ends ? nil : (point, Date())
        coast?.cancel()
        _ = platform.scroll(at: point, dx: s.dx, dy: s.dy)
        invalidate()
        if !visible || dimmed { show(driver: driver) }
        guard s.ends else {
            // Now and then while the fingers move, so the ring keeps up with what it's on.
            if Date().timeIntervalSince(lastScrollRefresh) > 0.35 { lastScrollRefresh = Date(); _ = currentCandidate(in: candidates()) }
            return
        }
        var v = CGVector(dx: s.velocityX ?? 0, dy: s.velocityY ?? 0)
        coast = Task { [weak self] in
            // A trackpad's coast: the speed falls by a fixed share each frame.
            while hypot(v.dx, v.dy) > 30, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                _ = platform.scroll(at: point, dx: v.dx / 60, dy: v.dy / 60)
                v.dx *= 0.93; v.dy *= 0.93
            }
            guard let self, !Task.isCancelled else { return }
            self.invalidate()
            self.settleAfterScroll(driver: driver)
        }
    }

    /// After a scroll: if the highlight went off screen, put it on what's showing nearest to where it was.
    private func settleAfterScroll(driver: String) {
        guard !pointerMode, let bounds = platform?.bounds ?? window()?.bounds else { return }
        let all = candidates()
        if let here = currentCandidate(in: all), bounds.intersects(here.frame) { onChange?(); return }
        let was = current?.1.frame ?? element?.frame ?? CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        let onScreen = all.filter { bounds.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        if let nearest = onScreen.min(by: { hypot($0.frame.midX - was.midX, $0.frame.midY - was.midY) < hypot($1.frame.midX - was.midX, $1.frame.midY - was.midY) }) {
            setFocus(nearest.ref, driver: driver)
        }
    }

    /// Shows the highlight without moving or pressing anything: where it was
    /// if that's still on screen, else on the item under the Mac's pointer,
    /// else the first item on screen. With nothing at all to highlight, the
    /// pad becomes a pointer.
    private func reveal(driver: String, in all: [Candidate]) {
        let geometry = window()
        let bounds = platform?.bounds ?? geometry?.bounds
        let onScreen = bounds.map { b in all.filter { b.intersects($0.frame) } } ?? all
        if let here = currentCandidate(in: all), bounds.map({ $0.intersects(here.frame) }) ?? true {
            setFocus(here.ref, driver: driver)
        } else if let p = platform?.mousePointer ?? geometry?.pointer,
                  let hit = onScreen.filter({ $0.frame.contains(p) }).min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            setFocus(hit.ref, driver: driver)
        } else if let first = (onScreen.isEmpty ? all : onScreen).min(by: { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }) {
            setFocus(first.ref, driver: driver)
        } else if platform != nil {
            setPointer(true, driver: driver)
        } else {
            show(driver: driver)
        }
    }

    private static func step(from here: Candidate, toward direction: RemoteDirection, in all: [Candidate]) -> Candidate? {
        let others = all.enumerated().filter { !same($0.element.ref, here.ref) }.map { ($0.offset, $0.element.frame) }
        return nearest(from: here.frame, in: others, toward: direction).map { all[$0] }
    }

    private static func same(_ a: Candidate.Ref, _ b: Candidate.Ref) -> Bool {
        switch (a, b) {
        case (.target(let x), .target(let y)): x == y
        case (.element(let x), .element(let y)): x.same(as: y)
        default: false
        }
    }

    private func press(_ c: Candidate) {
        switch c.ref {
        case .target(let id): targets[id]?.select()
        case .element(let e): platform?.press(e)
        }
    }

    private static func readingOrder(_ a: (UUID, Target), _ b: (UUID, Target)) -> Bool {
        (a.1.frame.minY, a.1.frame.minX) < (b.1.frame.minY, b.1.frame.minX)
    }

    /// Someone used the Mac itself: hide the ring now.
    func hide() {
        fade?.cancel()
        if visible { visible = false }
        if pointerMode { pointerMode = false; pointer = nil }
        redraw()
    }

    private func bump(driver: String) {
        bumps += 1
        show(driver: driver)
        onChange?()
    }

    private func setFocus(_ ref: Candidate.Ref, driver: String) {
        focusedRef(ref)
        show(driver: driver)
        onChange?()
        relocateSoon()
    }

    /// The page may still be moving under the ring (a row scrolling the item
    /// into view, a sheet sliding in, a page opening after a press): look
    /// again once it has settled, so a ring drawn over the window stays on its
    /// element, and a page whose element went starts on its first item.
    private func relocateSoon() {
        guard !pointerMode, platform != nil else { return }
        relocate?.cancel()
        relocate = Task { [weak self] in
            for wait in [300, 600] {
                try? await Task.sleep(for: .milliseconds(wait))
                guard let self, !Task.isCancelled, self.visible, !self.covered, !self.pointerMode else { return }
                self.invalidate()
                if self.currentCandidate(in: self.candidates()) == nil { self.pageChanged(); return }
            }
        }
    }

    private func focusedRef(_ ref: Candidate.Ref) {
        switch ref {
        case .target(let id): focused = id; element = nil
        case .element(let e): element = e; focused = nil
        }
    }

    private func show(driver: String) {
        self.driver = driver
        visible = true
        dimmed = false
        startWatchingLocalInput()
        fade?.cancel()
        fade = Task { [weak self] in
            try? await Task.sleep(for: self?.fadeAfter ?? .seconds(8))
            guard let self, !Task.isCancelled else { return }
            // Never gone: an outline, so the next swipe moves from somewhere you can see.
            self.dimmed = true
            self.redraw()
        }
        redraw()
    }

    /// The page changed under the highlight (its item went away, or a sheet
    /// came or went): once the new page's items are in, highlight its first one.
    private func pageChanged() {
        guard visible, !pointerMode, !covered else { return }
        refocus?.cancel()
        refocus = Task { [weak self] in
            try? await Task.sleep(for: self?.settleDelay ?? .milliseconds(350))
            guard let self, !Task.isCancelled, self.visible, !self.pointerMode, !self.covered else { return }
            self.invalidate()
            let all = self.candidates()
            guard self.currentCandidate(in: all) == nil else { return }
            let wasDimmed = self.dimmed
            self.reveal(driver: self.driver, in: all)
            if wasDimmed { self.dimmed = true; self.redraw() }
        }
    }

    private func menuChanged() {
        if BlueboxMenuRemote.current != nil, visible { show(driver: driver) }
        onChange?()
    }

    /// The ring for an element, and the pointer, drawn over the window.
    private func redraw() {
        let shown = visible && !covered
        let ring = shown && !pointerMode && BlueboxMenuRemote.current == nil ? element?.frame : nil
        platform?.draw(ring: ring, driver: driver, dimmed: dimmed, pointer: shown && pointerMode ? pointer : nil)
    }

    // MARK: What the phone shows

    /// The highlighted item and its neighbours (left and right in a row,
    /// else above and below in a list), the open menu and the pointer.
    func screen() -> RemoteScreen {
        var s = RemoteScreen(deviceID: "", title: screenTitle, focusedID: focusedID, focusedLabel: focusedLabel,
                             pointer: pointerMode ? true : nil, bumps: bumps)
        if let menu = BlueboxMenuRemote.current {
            s.menu = RemoteMenu(title: menu.title, items: menu.items.map {
                RemoteMenu.Item(index: $0.index, title: $0.title, subtitle: $0.subtitle, systemImage: $0.systemImage,
                                checked: $0.checked, disabled: $0.disabled, destructive: $0.destructive)
            }, highlighted: menu.highlightedIndex)
        }
        guard !pointerMode else { return s }
        let all = candidates()
        guard let here = currentCandidate(in: all) else { return s }
        s.focused = here.item
        s.section = here.section
        let left = Self.step(from: here, toward: .left, in: all), right = Self.step(from: here, toward: .right, in: all)
        if left != nil || right != nil {
            s.horizontal = true; s.before = left?.item; s.after = right?.item
        } else {
            s.horizontal = false
            s.before = Self.step(from: here, toward: .up, in: all)?.item
            s.after = Self.step(from: here, toward: .down, in: all)?.item
        }
        return s
    }

    /// The main window's size and the pointer in it, top-left origin, as SwiftUI's global frames are.
    static func mainWindow() -> (bounds: CGRect, pointer: CGPoint?)? {
        #if os(macOS)
        guard let app = NSApp as NSApplication?,
              let window = app.mainWindow ?? app.windows.first(where: { $0.isVisible && !$0.isSheet && $0.canBecomeMain }),
              let view = window.contentView else { return nil }
        let bounds = CGRect(origin: .zero, size: view.bounds.size)
        let p = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let pointer = CGPoint(x: p.x, y: view.isFlipped ? p.y : bounds.height - p.y)
        return (bounds, bounds.contains(pointer) ? pointer : nil)
        #else
        return nil
        #endif
    }

    private func startWatchingLocalInput() {
        #if os(macOS)
        guard localInput == nil else { return }
        localInput = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.hide() }
            return event
        }
        #endif
    }

    // MARK: Picking the next item

    /// The item a move lands on: the nearest one past the current item's edge
    /// that way (within a small band of the nearest), then the one most in
    /// line with it. Left and right stay within the row (items overlapping it
    /// vertically); up and down go to the nearest row, at the closest column.
    nonisolated static func nearest<ID>(from current: CGRect, in candidates: [(ID, CGRect)], toward direction: RemoteDirection) -> ID? {
        let slack: CGFloat = 4, band: CGFloat = 24
        let scored: [(id: ID, primary: CGFloat, secondary: CGFloat)] = candidates.compactMap { id, r in
            let primary: CGFloat
            switch direction {
            case .right:
                guard r.midX > current.midX + slack, r.minY < current.maxY, r.maxY > current.minY else { return nil }
                primary = max(r.minX - current.maxX, 0)
            case .left:
                guard r.midX < current.midX - slack, r.minY < current.maxY, r.maxY > current.minY else { return nil }
                primary = max(current.minX - r.maxX, 0)
            case .down:
                guard r.midY > current.midY + slack, r.minY >= current.maxY - current.height / 2 else { return nil }
                primary = max(r.minY - current.maxY, 0)
            case .up:
                guard r.midY < current.midY - slack, r.maxY <= current.minY + current.height / 2 else { return nil }
                primary = max(current.minY - r.maxY, 0)
            }
            let secondary = switch direction {
            case .left, .right: abs(r.midY - current.midY)
            case .up, .down: abs(r.midX - current.midX)
            }
            return (id, primary, secondary)
        }
        guard let closest = scored.map(\.primary).min() else { return nil }
        return scored.filter { $0.primary <= closest + band }.min { ($0.secondary, $0.primary) < ($1.secondary, $1.primary) }?.id
    }
}

/// The Mac's windows, as the remote sees them (`RemoteWindow`); a fake in tests.
@MainActor protocol RemoteWindowing: AnyObject {
    /// Which window the remote is driving: the main one, a sheet over it, or another (Settings).
    var activeKind: RemoteWindowKind? { get }
    /// The driven window's content, top-left origin.
    var bounds: CGRect { get }
    /// The Mac's own mouse, if it's over that window.
    var mousePointer: CGPoint? { get }
    /// Everything clickable on screen there and not covered by something else.
    func elements() -> [RemoteFocus.Element]
    func press(_ element: RemoteFocus.Element)
    func click(at point: CGPoint, right: Bool)
    /// Scrolls whatever scrolls under the point; false when nothing moved.
    func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat) -> Bool
    /// Scrolls most of a screen that way, for a move at the edge; false when it can't go further.
    func scrollPage(at point: CGPoint, toward direction: RemoteDirection) -> Bool
    func draw(ring: CGRect?, driver: String, dimmed: Bool, pointer: CGPoint?)
}

enum RemoteWindowKind: Equatable { case main, sheet, other }

// MARK: - Marking items

extension View {
    /// Reachable with the remote's touch pad and taps (the Mac's highlight).
    /// - Parameters:
    ///   - id: what the remote calls it ("title:<key>", "episode:<key>", …).
    ///   - layer: 1 inside a sheet, so only the sheet is reachable while it's up.
    ///   - kind, image: how the phone draws it beside the highlight (a poster's picture).
    ///   - select: what a press does: the same as clicking it.
    func remoteFocusable(_ id: String, label: String, cornerRadius: CGFloat = Radius.card, layer: Int = 0,
                         kind: RemoteScreenItem.Kind = .button, image: URL? = nil,
                         select: @escaping @MainActor () -> Void) -> some View {
        modifier(RemoteFocusable(id: id, label: label, cornerRadius: cornerRadius, layer: layer, kind: kind, image: image, select: select))
    }

    /// Names the row the remote's items here sit in ("Continue Watching"), for the phone.
    func remoteSection(_ title: String) -> some View { environment(\.remoteSection, title) }

    /// A sheet or overlay over the window, for the remote: what's under it is
    /// out of reach while it's up, and the remote's Back closes it. Inside a
    /// sheet, `dismiss` can be left out: the sheet's own is used.
    /// - Parameter layer: 1 for a sheet over the window, 2 for one over that.
    func remoteModal(layer: Int = 1, dismiss: (@MainActor () -> Void)? = nil) -> some View {
        modifier(RemoteModal(layer: layer, dismiss: dismiss))
    }
}

private struct RemoteModal: ViewModifier {
    let layer: Int
    let dismiss: (@MainActor () -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismissSheet
    @State private var instance = UUID()

    func body(content: Content) -> some View {
        #if os(macOS)
        let close = dismiss ?? { [dismissSheet] in dismissSheet() }
        content
            .onAppear { app.remoteFocus.addModal(instance, .init(layer: layer, dismiss: close)) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.remoteFocus.moveModal(instance, to: $0) }
            .onDisappear { app.remoteFocus.removeModal(instance) }
        #else
        content
        #endif
    }
}

/// The press action as it is now: a target keeps the box, not a closure
/// captured when its frame last changed.
@MainActor private final class SelectBox {
    var select: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// The row a marked item sits in (`remoteSection`).
    @Entry var remoteSection: String? = nil
}

private struct RemoteFocusable: ViewModifier {
    let id: String
    let label: String
    let cornerRadius: CGFloat
    let layer: Int
    let kind: RemoteScreenItem.Kind
    let image: URL?
    let select: @MainActor () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.remoteSection) private var section
    @Environment(\.isTabVisible) private var isTabVisible
    @Environment(\.isTopPage) private var isTopPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var instance = UUID()
    @State private var frame: CGRect = .zero
    @State private var box = SelectBox()

    func body(content: Content) -> some View {
        #if os(macOS)
        let focus = app.remoteFocus
        let on = focus.isFocused(instance)
        // After a while without input the ring dims to an outline (question 1): still there, quieter.
        let bold = on && !focus.dimmed
        let _ = (box.select = select)  // the press does what the view does now
        content
            .scaleEffect(bold && !reduceMotion ? 1.04 : 1)
            .overlay {
                if on {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Palette.brand.opacity(bold ? 1 : 0.5), lineWidth: bold ? 3 : 1.5)
                        .shadow(color: Palette.brand.opacity(bold ? 0.6 : 0), radius: 10)
                        .scaleEffect(bold && !reduceMotion ? 1.04 : 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if bold {
                    Label(focus.driver, systemImage: "iphone")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.brand, in: Capsule())
                        .offset(x: 6, y: -9)
                        .fixedSize()
                        .allowsHitTesting(false)
                }
            }
            .zIndex(on ? 1 : 0)
            .animation(Motion.snappy(reduceMotion), value: on)
            .animation(Motion.standard(reduceMotion), value: bold)
            .background(ScrollIntoView(active: on))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { new in
                frame = new
                register()
            }
            .onChange(of: isTabVisible) { register() }
            .onChange(of: isTopPage) { register() }
            .onChange(of: id) { register() }
            .onChange(of: label) { register() }
            .onChange(of: layer) { register() }
            .onChange(of: section) { register() }
            .onDisappear { focus.unregister(instance) }
        #else
        content
        #endif
    }

    private func register() {
        // A page pushed over this one, or another tab, hides it from the remote.
        guard isTabVisible, isTopPage, frame.width > 0 else { app.remoteFocus.unregister(instance); return }
        app.remoteFocus.register(instance, .init(id: id, label: label, frame: frame, layer: layer, kind: kind, image: image,
                                                 section: section, select: { [box] in box.select() }))
    }
}

#if os(macOS)
/// Scrolls the highlighted item into view, through every scroll view around it (a row inside the page).
private struct ScrollIntoView: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard active, !context.coordinator.wasActive else { context.coordinator.wasActive = active; return }
        context.coordinator.wasActive = true
        DispatchQueue.main.async { _ = view.scrollToVisible(view.bounds.insetBy(dx: -40, dy: -40)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var wasActive = false }
}
#endif
