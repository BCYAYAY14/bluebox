#if os(macOS)
import AppKit
import DesignSystem
import ObjectiveC
import Sync
import SwiftUI

/// The Mac's windows as the remote sees them (the better remote, 31 Oct 2026):
/// what can be pressed there, pressing and clicking it, scrolling, and the
/// ring and pointer drawn over it.
///
/// What can be pressed comes from the window's own accessibility tree, which
/// AppKit and SwiftUI build for VoiceOver: every button, switch, field, link
/// and list row, with its name and frame. Bluebox asks for the tree itself
/// (`AXEnhancedUserInterface`, as an assistive app would) the first time the
/// remote looks, so it needs no permission and sees only its own windows.
/// Presses go through accessibility too (as VoiceOver's would); rows and
/// fields, and the pointer, get a click sent to the window itself. Scrolling
/// moves the scroll view under the point directly.
@MainActor final class RemoteWindow: RemoteWindowing {
    /// The window RootView is in: marked items live there.
    weak var main: NSWindow?
    private var overlay: RemoteOverlayPanel?
    private let model = RemoteOverlayModel()
    private var treeRequested = false
    private var resizeObserver: (any NSObjectProtocol)?

    init(main: NSWindow?) { self.main = main }

    /// What a press can land on. Rows only when nothing inside them can be pressed (the sidebar's).
    static let pressable: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
                                         "AXLink", "AXTextField", "AXComboBox", "AXDisclosureTriangle", "AXTab"]

    // MARK: Which window

    /// The frontmost of Bluebox's own windows (a sheet over the main one counts
    /// as the sheet), or the main window while Bluebox isn't in front.
    private var active: (window: NSWindow, kind: RemoteWindowKind)? {
        let front = NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeMain && !($0 is RemoteOverlayPanel) } ?? main
        guard let front else { return nil }
        if let main, front === main || front.sheetParent === main {
            if let sheet = main.attachedSheet { return (sheet, .sheet) }
            return (main, .main)
        }
        if let sheet = front.attachedSheet { return (sheet, .other) }
        return (front, .other)
    }

    var activeKind: RemoteWindowKind? { active?.kind }

    var bounds: CGRect {
        guard let content = active?.window.contentView else { return .zero }
        return CGRect(origin: .zero, size: content.bounds.size)
    }

    var mousePointer: CGPoint? {
        guard let (w, _) = active, let content = w.contentView else { return nil }
        let p = toTopLeft(content.convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil), in: content)
        return bounds.contains(p) ? p : nil
    }

    // MARK: Elements

    func elements() -> [RemoteFocus.Element] {
        guard let (w, _) = active, let content = w.contentView else { return [] }
        requestTree()
        let area = CGRect(origin: .zero, size: content.bounds.size)
        var out: [RemoteFocus.Element] = []
        var visited = 0
        func walk(_ node: AnyObject, depth: Int) {
            guard depth < 48, visited < 6000 else { return }
            visited += 1
            let role = AX.string(node, "accessibilityRole") ?? ""
            let frame = AX.frame(node).map { toWindow($0, in: w, content: content) }
            // A group scrolled out of sight: nothing inside it is on screen either.
            if depth > 0, let frame, frame.width > 0, frame.height > 0, !area.intersects(frame) { return }
            if Self.pressable.contains(role) || role == "AXRow" {
                guard let frame, frame.width >= 6, frame.height >= 6, area.intersects(frame) else { return }
                let el = element(node, role: role, frame: frame)
                if role == "AXRow" {
                    let before = out.count
                    for c in AX.children(node) { walk(c, depth: depth + 1) }
                    if out.count == before { out.append(el) }
                    return
                }
                out.append(el)
                return  // a control's insides aren't stops of their own
            }
            for c in AX.children(node) { walk(c, depth: depth + 1) }
        }
        walk(content, depth: 0)
        // Covered by something on top (an open menu, an overlay): out of reach.
        return out.filter { uncovered($0, in: w, content: content) }
    }

    private func element(_ node: AnyObject, role: String, frame: CGRect) -> RemoteFocus.Element {
        let kind: RemoteScreenItem.Kind = switch role {
        case "AXCheckBox": .toggle
        case "AXTextField", "AXComboBox": .field
        case "AXRow": .row
        default: .button
        }
        var label = [AX.string(node, "accessibilityLabel"), AX.string(node, "accessibilityTitle"),
                     kind == .field ? AX.string(node, "accessibilityPlaceholderValue") : nil,
                     AX.string(node, "accessibilityHelp")]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        if label == nil, kind == .row {
            // A list row's name is its text.
            label = AX.descendantText(node)
        }
        let isOn = kind == .toggle ? (AX.object(node, "accessibilityValue") as? NSNumber)?.boolValue : nil
        let fallback = switch kind {
        case .toggle: String(localized: "Switch")
        case .field: String(localized: "Text Field")
        case .row: String(localized: "Row")
        default: String(localized: "Button")
        }
        return RemoteFocus.Element(label: label ?? fallback, kind: kind, frame: frame, isOn: isOn, node: node)
    }

    /// Whether the element is what a click at its centre would reach.
    private func uncovered(_ e: RemoteFocus.Element, in w: NSWindow, content: NSView) -> Bool {
        guard let node = e.node else { return true }
        let centre = toScreen(CGPoint(x: e.frame.midX, y: e.frame.midY), in: w, content: content)
        guard let hit = AX.hitTest(content, centre) else { return true }
        // The hit is the element, or something inside it…
        var n: AnyObject? = hit
        for _ in 0..<16 {
            guard let current = n else { break }
            if current === node { return true }
            n = AX.object(current, "accessibilityParent")
        }
        // …or a container around it that doesn't itself answer hit tests.
        var up: AnyObject? = AX.object(node, "accessibilityParent")
        for _ in 0..<16 {
            guard let current = up else { break }
            if current === hit { return true }
            up = AX.object(current, "accessibilityParent")
        }
        return false
    }

    /// Asks AppKit and SwiftUI for the accessibility tree, as an assistive app would.
    private func requestTree() {
        guard !treeRequested else { return }
        treeRequested = true
        let set = Selector(("accessibilitySetValue:forAttribute:"))
        if NSApp.responds(to: set) {
            _ = NSApp.perform(set, with: NSNumber(value: true), with: "AXEnhancedUserInterface" as NSString)
        }
    }

    // MARK: Pressing, clicking

    func press(_ e: RemoteFocus.Element) {
        if let node = e.node, e.kind == .button || e.kind == .toggle, AX.press(node) { return }
        click(at: CGPoint(x: e.frame.midX, y: e.frame.midY), right: false)
    }

    /// A click sent to the window itself, as the mouse would: Bluebox only, no permission needed.
    func click(at point: CGPoint, right: Bool) {
        guard let (w, _) = active, let content = w.contentView else { return }
        if !NSApp.isActive { NSApp.activate() }
        let local = content.isFlipped ? point : CGPoint(x: point.x, y: content.bounds.height - point.y)
        let base = content.convert(local, to: nil)
        let kinds: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in kinds {
            guard let event = NSEvent.mouseEvent(with: type, location: base, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0) else { continue }
            w.sendEvent(event)
        }
    }

    // MARK: Scrolling

    func scroll(at point: CGPoint, dx: CGFloat, dy: CGFloat) -> Bool {
        let horizontal = abs(dx) > abs(dy)
        for sv in scrollViews(at: point) where canScroll(sv, horizontal: horizontal) {
            if move(sv, dx: horizontal ? dx : 0, dy: horizontal ? 0 : dy) { return true }
        }
        return false
    }

    func scrollPage(at point: CGPoint, toward direction: RemoteDirection) -> Bool {
        let horizontal = direction == .left || direction == .right
        for sv in scrollViews(at: point) where canScroll(sv, horizontal: horizontal) {
            let size = sv.contentView.bounds.size
            let amount = (horizontal ? size.width : size.height) * 0.6
            let d: CGVector = switch direction {
            case .left: CGVector(dx: -amount, dy: 0)
            case .right: CGVector(dx: amount, dy: 0)
            case .up: CGVector(dx: 0, dy: -amount)
            case .down: CGVector(dx: 0, dy: amount)
            }
            if move(sv, dx: d.dx, dy: d.dy) { return true }
        }
        return false
    }

    /// The scroll views under the point, innermost first.
    private func scrollViews(at point: CGPoint) -> [NSScrollView] {
        guard let (w, _) = active, let content = w.contentView else { return [] }
        let local = content.isFlipped ? point : CGPoint(x: point.x, y: content.bounds.height - point.y)
        var found: [(NSScrollView, Int)] = []
        func walk(_ v: NSView, depth: Int) {
            if let sv = v as? NSScrollView, sv.convert(sv.bounds, to: content).contains(local) { found.append((sv, depth)) }
            for s in v.subviews where !s.isHidden { walk(s, depth: depth + 1) }
        }
        walk(content, depth: 0)
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func canScroll(_ sv: NSScrollView, horizontal: Bool) -> Bool {
        guard let doc = sv.documentView else { return false }
        let clip = sv.contentView.bounds.size
        return horizontal ? doc.frame.width > clip.width + 1 : doc.frame.height > clip.height + 1
    }

    /// Positive `dy` shows what's further down, whichever way the document is drawn.
    private func move(_ sv: NSScrollView, dx: CGFloat, dy: CGFloat) -> Bool {
        guard let doc = sv.documentView else { return false }
        let clip = sv.contentView
        let insets = sv.contentInsets
        var o = clip.bounds.origin
        let minX = doc.frame.minX - insets.left, maxX = max(doc.frame.maxX - clip.bounds.width + insets.right, minX)
        let minY = doc.frame.minY - (doc.isFlipped ? insets.top : insets.bottom)
        let maxY = max(doc.frame.maxY - clip.bounds.height + (doc.isFlipped ? insets.bottom : insets.top), minY)
        o.x = min(max(o.x + dx, minX), maxX)
        o.y = min(max(o.y + (doc.isFlipped ? dy : -dy), minY), maxY)
        guard abs(o.x - clip.bounds.origin.x) > 0.5 || abs(o.y - clip.bounds.origin.y) > 0.5 else { return false }
        clip.scroll(to: o)
        sv.reflectScrolledClipView(clip)
        return true
    }

    // MARK: The ring and pointer

    func draw(ring: CGRect?, driver: String, dimmed: Bool, pointer: CGPoint?) {
        model.ring = ring
        model.driver = driver
        model.dimmed = dimmed
        model.pointer = pointer
        guard ring != nil || pointer != nil, let (w, _) = active, let content = w.contentView else {
            overlay?.orderOut(nil)
            return
        }
        let panel = overlay ?? makeOverlay()
        if panel.parent !== w {
            panel.parent?.removeChildWindow(panel)
            w.addChildWindow(panel, ordered: .above)
            resizeObserver.map(NotificationCenter.default.removeObserver)
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }
        place()
        _ = content
        if !panel.isVisible { panel.orderFront(nil) }
    }

    private func place() {
        guard let overlay, let w = overlay.parent, let content = w.contentView else { return }
        overlay.setFrame(w.convertToScreen(content.convert(content.bounds, to: nil)), display: true)
    }

    private func makeOverlay() -> RemoteOverlayPanel {
        let panel = RemoteOverlayPanel()
        panel.contentView = NSHostingView(rootView: RemoteOverlayView(model: model))
        overlay = panel
        return panel
    }

    // MARK: Coordinates

    private func toTopLeft(_ p: CGPoint, in content: NSView) -> CGPoint {
        content.isFlipped ? p : CGPoint(x: p.x, y: content.bounds.height - p.y)
    }

    /// A screen rectangle (accessibility frames) in the window's content, top-left origin.
    private func toWindow(_ screen: CGRect, in w: NSWindow, content: NSView) -> CGRect {
        let r = content.convert(w.convertFromScreen(screen), from: nil)
        return content.isFlipped ? r : CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    private func toScreen(_ p: CGPoint, in w: NSWindow, content: NSView) -> NSPoint {
        let local = content.isFlipped ? p : CGPoint(x: p.x, y: content.bounds.height - p.y)
        return w.convertPoint(toScreen: content.convert(local, to: nil))
    }
}

// MARK: - Accessibility, by selector

/// SwiftUI's accessibility nodes answer the NSAccessibility methods without
/// declaring the protocol to Swift, so they're called by selector.
@MainActor private enum AX {
    static func object(_ o: AnyObject, _ name: String) -> AnyObject? {
        let sel = Selector((name))
        guard let np = o as? NSObjectProtocol, np.responds(to: sel) else { return nil }
        return np.perform(sel)?.takeUnretainedValue()
    }

    static func string(_ o: AnyObject, _ name: String) -> String? {
        switch object(o, name) {
        case let s as String: s
        case let a as NSAttributedString: a.string
        default: nil
        }
    }

    static func children(_ o: AnyObject) -> [AnyObject] {
        (object(o, "accessibilityChildren") as? [Any])?.map { $0 as AnyObject } ?? []
    }

    static func frame(_ o: AnyObject) -> CGRect? {
        let sel = Selector(("accessibilityFrame"))
        guard let cls = object_getClass(o), class_respondsToSelector(cls, sel), let imp = class_getMethodImplementation(cls, sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector) -> CGRect
        return unsafeBitCast(imp, to: F.self)(o, sel)
    }

    static func press(_ o: AnyObject) -> Bool {
        let sel = Selector(("accessibilityPerformPress"))
        guard let cls = object_getClass(o), class_respondsToSelector(cls, sel), let imp = class_getMethodImplementation(cls, sel) else { return false }
        typealias F = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: F.self)(o, sel)
    }

    static func hitTest(_ o: AnyObject, _ p: NSPoint) -> AnyObject? {
        let sel = Selector(("accessibilityHitTest:"))
        guard let cls = object_getClass(o), class_respondsToSelector(cls, sel), let imp = class_getMethodImplementation(cls, sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector, NSPoint) -> AnyObject?
        return unsafeBitCast(imp, to: F.self)(o, sel, p)
    }

    /// The first text inside a node (a list row's title).
    static func descendantText(_ o: AnyObject, depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }
        for c in children(o) {
            if string(c, "accessibilityRole") == "AXStaticText",
               let t = string(c, "accessibilityValue") ?? string(c, "accessibilityLabel"), !t.isEmpty { return t }
            if let t = descendantText(c, depth: depth + 1) { return t }
        }
        return nil
    }
}

// MARK: - The overlay

/// A clear window over the driven one, for the ring around an element and the pointer. Never takes clicks.
final class RemoteOverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable final class RemoteOverlayModel {
    var ring: CGRect?
    var driver = ""
    var dimmed = false
    var pointer: CGPoint?
}

/// The ring in the theme colour with the remote's name (as marked items draw
/// their own), dimmed to an outline after a while, and the pointer.
private struct RemoteOverlayView: View {
    let model: RemoteOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let r = model.ring {
                let bold = !model.dimmed
                RoundedRectangle(cornerRadius: min(Radius.control, r.height / 2), style: .continuous)
                    .strokeBorder(Palette.brand.opacity(bold ? 1 : 0.5), lineWidth: bold ? 3 : 1.5)
                    .shadow(color: Palette.brand.opacity(bold ? 0.6 : 0), radius: 10)
                    .frame(width: r.width + 8, height: r.height + 8)
                    .offset(x: r.minX - 4, y: r.minY - 4)
                if bold {
                    Label(model.driver, systemImage: "iphone")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.brand, in: Capsule())
                        .fixedSize()
                        .offset(x: r.minX + 2, y: r.minY - 13)
                }
            }
            if let p = model.pointer {
                Circle()
                    .fill(Palette.brand.opacity(0.75))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    .frame(width: 18, height: 18)
                    .offset(x: p.x - 9, y: p.y - 9)
            }
        }
        .animation(Motion.snappy(reduceMotion), value: model.ring)
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.12), value: model.pointer)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

#endif
