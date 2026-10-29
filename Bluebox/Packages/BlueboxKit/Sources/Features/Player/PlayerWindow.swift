#if os(macOS)
import AppKit
import SwiftUI

/// The player's window on the Mac: full-screen state, Esc, and the pointer.
///
/// Esc follows every Mac video app: in full screen it only leaves full screen;
/// in a window it closes the player. It's handled with a local key monitor
/// scoped to the player's own window, because SwiftUI's `onKeyPress` only sees
/// keys while the video has focus and AppKit's own Esc handling in full screen
/// would otherwise run as well (closing the player *and* leaving full screen).
@MainActor
@Observable
final class PlayerWindowModel {
    private(set) var isFullScreen = false
    /// True during the full-screen animation; toggling again then would bounce.
    private(set) var isTransitioning = false {
        didSet { if isTransitioning { transitionStarted = .now } }
    }
    /// A transition that never reports its end (it failed) stops blocking after 3 s.
    @ObservationIgnored private var transitionStarted = Date.distantPast
    private var isAnimating: Bool {
        if isTransitioning, Date.now.timeIntervalSince(transitionStarted) > 3 {
            isTransitioning = false
            isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
        }
        return isTransitioning
    }
    @ObservationIgnored private weak var window: NSWindow?
    /// The player put the window in full screen, so leaving the player restores it.
    @ObservationIgnored private var enteredByPlayer = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var keyMonitor: Any?
    /// Esc in a window (not full screen), or ⌘W: close the player.
    @ObservationIgnored var onEscapeInWindow: () -> Void = {}

    func attach(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        detachObservers()
        self.window = window
        isFullScreen = window.styleMask.contains(.fullScreen)
        let center = NotificationCenter.default
        let events: [(Notification.Name, @MainActor (PlayerWindowModel) -> Void)] = [
            // However it was entered (button, F, double-click, ⌃⌘F, the green button),
            // full screen that started during playback ends with it.
            (NSWindow.willEnterFullScreenNotification, { $0.isTransitioning = true; $0.enteredByPlayer = true }),
            (NSWindow.didEnterFullScreenNotification, { $0.isTransitioning = false; $0.isFullScreen = true }),
            (NSWindow.willExitFullScreenNotification, { $0.isTransitioning = true }),
            (NSWindow.didExitFullScreenNotification, { $0.isTransitioning = false; $0.isFullScreen = false; $0.enteredByPlayer = false }),
        ]
        for (name, apply) in events {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { apply(self) } }
            })
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = KeyInfo(event)
            let handled = MainActor.assumeIsolated { self?.handle(key) ?? false }
            return handled ? nil : event
        }
    }

    /// The parts of a key event the player needs (NSEvent isn't Sendable).
    private struct KeyInfo: Sendable {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let character: String?
        let isRepeat: Bool
        let windowNumber: Int
        init(_ e: NSEvent) {
            keyCode = e.keyCode
            modifiers = e.modifierFlags.intersection([.command, .option, .control, .shift])
            character = e.charactersIgnoringModifiers?.lowercased()
            isRepeat = e.isARepeat
            windowNumber = e.windowNumber
        }
    }

    private func handle(_ key: KeyInfo) -> Bool {
        guard let window, key.windowNumber == window.windowNumber, window.attachedSheet == nil,
              !(window.firstResponder is NSText) else { return false }  // let a text field cancel itself first
        if key.modifiers == .command, key.character == "w" {
            onEscapeInWindow()  // ⌘W closes the player, not the app's only window
            return true
        }
        guard key.modifiers.isEmpty, !key.isRepeat else { return false }
        if key.keyCode == 53 { escape(); return true }  // Esc
        if key.character == "f" { toggleFullScreen(); return true }
        return false
    }

    /// Leaves full screen if the player entered it, and stops listening.
    func detach() {
        if enteredByPlayer, let window {
            if isTransitioning, !isFullScreen {
                // Still animating into full screen: leave once it gets there.
                let box = ObserverBox()
                box.token = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window,
                                                                   queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let token = box.token { NotificationCenter.default.removeObserver(token) }
                        box.token = nil
                        window?.toggleFullScreen(nil)
                    }
                }
            } else if isFullScreen, !isTransitioning {
                window.toggleFullScreen(nil)
            }
        }
        enteredByPlayer = false
        detachObservers()
        NSCursor.setHiddenUntilMouseMoves(false)
        window = nil
    }

    func toggleFullScreen() {
        guard let window, !isAnimating else { return }
        window.toggleFullScreen(nil)
    }

    func escape() {
        if isAnimating { return }  // a second Esc mid-animation would bounce back
        if isFullScreen { toggleFullScreen() } else { onEscapeInWindow() }
    }

    /// Hides the pointer over the video until it moves (when controls hide).
    func hidePointer() {
        guard let window, window.isKeyWindow, window.frame.contains(NSEvent.mouseLocation) else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func detachObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// Holds a one-shot notification token for its own handler.
private final class ObserverBox: @unchecked Sendable {
    var token: NSObjectProtocol?
}

/// Reports the NSWindow a view lives in.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: ReaderView, context: Context) { nsView.onWindow = onWindow }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
#endif
