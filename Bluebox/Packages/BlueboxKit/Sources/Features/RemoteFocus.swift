import DesignSystem
import Observation
import Sync
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The Mac's highlight for the remote (the new remote, question 5): what the
/// phone's touch pad moves and presses, and what a tap on the phone points at.
///
/// Items mark themselves `.remoteFocusable(…)` and report their frame while
/// on a visible tab. A move picks the nearest item that way, the way tvOS's
/// focus engine does, so no screen needs a grid of its own; an Apple TV app
/// gets the same commands and uses its real focus instead. The ring shows in
/// the theme colour with the remote's name, fades after `fadeAfter` without
/// remote input, and hides at once when someone uses the Mac's own mouse or
/// keyboard. While it's hidden, the first swipe or tap only shows it: on the
/// item under the Mac's pointer, else where it was, else the first item on
/// screen. So nothing is pressed that you can't see.
///
/// Sheets and overlays mark themselves `.remoteModal()`: each is a layer, and
/// only the top layer's items are reachable, even when it has none of its own
/// (a trailer), so the page under it can't be pressed. Back closes the top one.
@MainActor @Observable
public final class RemoteFocus {
    struct Target {
        /// What the remote calls it: "title:<key>", "episode:<key>", "release:<id>", "play".
        var id: String
        var label: String
        var frame: CGRect
        /// A sheet over the window is its own layer: only the top layer is reachable.
        var layer: Int
        var select: @MainActor () -> Void
    }

    /// A sheet or overlay over the window.
    struct Modal {
        var layer: Int
        var dismiss: @MainActor () -> Void
    }

    /// The highlighted view (each instance, since one title can sit in several rows).
    public private(set) var focused: UUID?
    /// The layer in reach: the topmost sheet's, or 0 for the window.
    private(set) var topLayer = 0
    /// The ring is showing.
    public private(set) var visible = false
    /// Who's driving: "Brian's iPhone".
    public private(set) var driver = ""
    /// The page the Mac is on, for `RemoteScreen` (RootView keeps it up to date).
    public var screenTitle = "Home" { didSet { if screenTitle != oldValue { onChange?() } } }

    @ObservationIgnored private var targets: [UUID: Target] = [:]
    @ObservationIgnored private var modals: [UUID: Modal] = [:]
    /// The window's area and the pointer, in the items' coordinates: the
    /// first item on screen, and the one under the pointer. nil in tests.
    @ObservationIgnored var window: @MainActor () -> (bounds: CGRect, pointer: CGPoint?)? = RemoteFocus.mainWindow
    @ObservationIgnored private var fade: Task<Void, Never>?
    /// The highlight or page changed: `RemoteControl.screenChanged`.
    @ObservationIgnored var onChange: (() -> Void)?
    #if os(macOS)
    @ObservationIgnored private var localInput: Any?
    #endif

    static let fadeAfter: Duration = .seconds(8)

    public init() {}

    var focusedID: String? { current?.1.id }
    var focusedLabel: String? { current?.1.label }

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
        if focused == instance { focused = nil; onChange?() }
    }

    func isFocused(_ instance: UUID) -> Bool { visible && focused == instance && targets[instance]?.layer == topLayer }

    func addModal(_ instance: UUID, _ modal: Modal) {
        modals[instance] = modal
        refreshTopLayer()
    }

    func removeModal(_ instance: UUID) {
        guard modals.removeValue(forKey: instance) != nil else { return }
        refreshTopLayer()
    }

    /// The remote's Back: close the top sheet or overlay. False when none is up.
    func dismissTopModal() -> Bool {
        guard let top = modals.values.max(by: { $0.layer < $1.layer }) else { return false }
        top.dismiss()
        return true
    }

    /// Going somewhere else (Home, Search, a title): close every sheet first.
    func dismissAllModals() {
        for modal in modals.values.sorted(by: { $0.layer > $1.layer }) { modal.dismiss() }
    }

    private func refreshTopLayer() {
        let top = max(targets.values.map(\.layer).max() ?? 0, modals.values.map(\.layer).max() ?? 0)
        if top != topLayer { topLayer = top; onChange?() }
    }

    /// Only the top layer's items: a sheet's, while one is up (none, if it has none).
    private var reachable: [(UUID, Target)] {
        targets.filter { $0.value.layer == topLayer }.map { ($0.key, $0.value) }
    }

    /// The highlighted item, if it's still in reach.
    private var current: (UUID, Target)? {
        guard let focused, let target = targets[focused], target.layer == topLayer else { return nil }
        return (focused, target)
    }

    // MARK: Commands

    /// Highlight the item with this ID (the first on screen, top to bottom), e.g. what was tapped on the phone.
    func focus(id: String, driver: String) {
        let matches = reachable.filter { $0.1.id == id }
        let area = window()?.bounds
        let onScreen = area.map { a in matches.filter { a.intersects($0.1.frame) } } ?? matches
        guard let match = (onScreen.isEmpty ? matches : onScreen).min(by: Self.readingOrder) else { return }
        setFocus(match.0, driver: driver)
    }

    /// The nearest item that way. While the highlight is hidden, only shows it.
    func move(_ direction: RemoteDirection, driver: String) {
        guard visible, let (id, item) = current else { reveal(driver: driver); return }
        let others = reachable.filter { $0.0 != id }.map { ($0.0, $0.1.frame) }
        if let next = Self.nearest(from: item.frame, in: others, toward: direction) {
            setFocus(next, driver: driver)
        } else {
            show(driver: driver)  // at the edge: show where it is
        }
    }

    /// Press the highlighted item, as a click would. While the highlight is hidden, only shows it.
    func select(driver: String) {
        guard visible, let (_, item) = current else { reveal(driver: driver); return }
        show(driver: driver)
        item.select()
    }

    /// Shows the highlight without moving or pressing anything: on the item
    /// under the Mac's pointer, else where it was if that's still on screen,
    /// else the first item on screen.
    private func reveal(driver: String) {
        let items = reachable
        let geometry = window()
        let onScreen = geometry.map { g in items.filter { g.bounds.intersects($0.1.frame) } } ?? items
        if let pointer = geometry?.pointer,
           let hit = onScreen.filter({ $0.1.frame.contains(pointer) }).min(by: { $0.1.frame.width * $0.1.frame.height < $1.1.frame.width * $1.1.frame.height }) {
            setFocus(hit.0, driver: driver)
        } else if let (id, item) = current, geometry.map({ $0.bounds.intersects(item.frame) }) ?? true {
            setFocus(id, driver: driver)
        } else if let first = (onScreen.isEmpty ? items : onScreen).min(by: Self.readingOrder) {
            setFocus(first.0, driver: driver)
        }
    }

    private static func readingOrder(_ a: (UUID, Target), _ b: (UUID, Target)) -> Bool {
        (a.1.frame.minY, a.1.frame.minX) < (b.1.frame.minY, b.1.frame.minX)
    }

    /// Someone used the Mac itself: hide the ring now.
    func hide() {
        fade?.cancel()
        if visible { visible = false }
    }

    private func setFocus(_ instance: UUID, driver: String) {
        focused = instance
        show(driver: driver)
        onChange?()
    }

    private func show(driver: String) {
        self.driver = driver
        visible = true
        startWatchingLocalInput()
        fade?.cancel()
        fade = Task { [weak self] in
            try? await Task.sleep(for: Self.fadeAfter)
            guard !Task.isCancelled else { return }
            self?.visible = false
        }
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

// MARK: - Marking items

extension View {
    /// Reachable with the remote's touch pad and taps (the Mac's highlight).
    /// - Parameters:
    ///   - id: what the remote calls it ("title:<key>", "episode:<key>", …).
    ///   - layer: 1 inside a sheet, so only the sheet is reachable while it's up.
    ///   - select: what a press does: the same as clicking it.
    func remoteFocusable(_ id: String, label: String, cornerRadius: CGFloat = Radius.card, layer: Int = 0,
                         select: @escaping @MainActor () -> Void) -> some View {
        modifier(RemoteFocusable(id: id, label: label, cornerRadius: cornerRadius, layer: layer, select: select))
    }

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

private struct RemoteFocusable: ViewModifier {
    let id: String
    let label: String
    let cornerRadius: CGFloat
    let layer: Int
    let select: @MainActor () -> Void

    @Environment(AppModel.self) private var app
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
        let _ = (box.select = select)  // the press does what the view does now
        content
            .scaleEffect(on && !reduceMotion ? 1.04 : 1)
            .overlay {
                if on {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Palette.brand, lineWidth: 3)
                        .shadow(color: Palette.brand.opacity(0.6), radius: 10)
                        .scaleEffect(reduceMotion ? 1 : 1.04)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if on {
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
            .onDisappear { focus.unregister(instance) }
        #else
        content
        #endif
    }

    private func register() {
        // A page pushed over this one, or another tab, hides it from the remote.
        guard isTabVisible, isTopPage, frame.width > 0 else { app.remoteFocus.unregister(instance); return }
        app.remoteFocus.register(instance, .init(id: id, label: label, frame: frame, layer: layer, select: { [box] in box.select() }))
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
