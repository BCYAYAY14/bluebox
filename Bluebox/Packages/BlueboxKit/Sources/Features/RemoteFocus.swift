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
/// keyboard (the focus stays, so the next swipe carries on from it).
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

    /// The highlighted view (each instance, since one title can sit in several rows).
    public private(set) var focused: UUID?
    /// The ring is showing.
    public private(set) var visible = false
    /// Who's driving: "Brian's iPhone".
    public private(set) var driver = ""
    /// The page the Mac is on, for `RemoteScreen` (RootView keeps it up to date).
    public var screenTitle = "Home" { didSet { if screenTitle != oldValue { onChange?() } } }

    @ObservationIgnored private var targets: [UUID: Target] = [:]
    @ObservationIgnored private var fade: Task<Void, Never>?
    /// The highlight or page changed: `RemoteControl.screenChanged`.
    @ObservationIgnored var onChange: (() -> Void)?
    #if os(macOS)
    @ObservationIgnored private var localInput: Any?
    #endif

    static let fadeAfter: Duration = .seconds(8)

    public init() {}

    var focusedID: String? { focused.flatMap { targets[$0]?.id } }
    var focusedLabel: String? { focused.flatMap { targets[$0]?.label } }

    // MARK: Items

    func register(_ instance: UUID, _ target: Target) { targets[instance] = target }

    func unregister(_ instance: UUID) {
        targets[instance] = nil
        if focused == instance { focused = nil; onChange?() }
    }

    func isFocused(_ instance: UUID) -> Bool { visible && focused == instance }

    /// Only the top layer's items: a sheet's, while one is up.
    private var reachable: [(UUID, Target)] {
        let top = targets.values.map(\.layer).max() ?? 0
        return targets.filter { $0.value.layer == top }.map { ($0.key, $0.value) }
    }

    // MARK: Commands

    /// Highlight the item with this ID (the first on screen, top to bottom), e.g. what was tapped on the phone.
    func focus(id: String, driver: String) {
        guard let match = reachable.filter({ $0.1.id == id })
            .min(by: { ($0.1.frame.minY, $0.1.frame.minX) < ($1.1.frame.minY, $1.1.frame.minX) }) else { return }
        setFocus(match.0, driver: driver)
    }

    /// The nearest item that way; with nothing highlighted yet, the first one on screen.
    func move(_ direction: RemoteDirection, driver: String) {
        let items = reachable
        if let focused, visible || targets[focused] != nil, let current = targets[focused], current.layer == (items.first?.1.layer ?? 0) {
            let others = items.filter { $0.0 != focused }.map { ($0.0, $0.1.frame) }
            if let next = Self.nearest(from: current.frame, in: others, toward: direction) {
                setFocus(next, driver: driver)
            } else {
                show(driver: driver)  // at the edge: show where it is
            }
        } else if let first = items.min(by: { ($0.1.frame.minY, $0.1.frame.minX) < ($1.1.frame.minY, $1.1.frame.minX) }) {
            setFocus(first.0, driver: driver)
        }
    }

    /// Press the highlighted item, as a click would.
    func select(driver: String) {
        guard let focused, let target = targets[focused] else { move(.down, driver: driver); return }
        show(driver: driver)
        target.select()
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
}

private struct RemoteFocusable: ViewModifier {
    let id: String
    let label: String
    let cornerRadius: CGFloat
    let layer: Int
    let select: @MainActor () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.isTabVisible) private var isTabVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var instance = UUID()
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        #if os(macOS)
        let focus = app.remoteFocus
        let on = focus.isFocused(instance)
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
            .onChange(of: id) { register() }
            .onDisappear { focus.unregister(instance) }
        #else
        content
        #endif
    }

    private func register() {
        guard isTabVisible, frame.width > 0 else { app.remoteFocus.unregister(instance); return }
        app.remoteFocus.register(instance, .init(id: id, label: label, frame: frame, layer: layer, select: select))
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
