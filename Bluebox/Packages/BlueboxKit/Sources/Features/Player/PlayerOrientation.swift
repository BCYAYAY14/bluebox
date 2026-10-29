#if os(iOS)
import Domain
import UIKit

/// iPhone orientation policy. The library is portrait-only. The player turns
/// the phone to landscape as it opens, on the side the phone is held (and
/// then follows it between landscape left and right), and back to portrait as
/// it closes. Someone who'd rather watch upright can choose portrait in the
/// player. iPad rotates freely everywhere.
///
/// Info.plist lists portrait only for iPhone; the app delegate returns
/// `supported` from `application(_:supportedInterfaceOrientationsFor:)`, which
/// overrides it at run time.
@MainActor
public enum PlayerOrientation {
    public enum Mode: Equatable, Sendable { case landscape, portrait }

    /// True while the player is on screen.
    private static var playerUp = false
    /// What the player asked for (landscape unless portrait was chosen).
    public private(set) static var mode: Mode = .landscape

    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// What the app allows right now.
    public static var supported: UIInterfaceOrientationMask {
        guard isPhone else { return .all }
        guard playerUp else { return .portrait }
        return mode == .landscape ? .landscape : .portrait
    }

    /// The player appeared: turn to landscape, matching how the phone is held.
    static func enterPlayer() {
        guard !playerUp else { return }
        playerUp = true
        mode = .landscape
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        apply(preferredLandscape)
    }

    /// The player is closing: back to portrait.
    static func leavePlayer() {
        guard playerUp else { return }
        playerUp = false
        mode = .landscape
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        apply(.portrait)
    }

    /// The rotate button: landscape ⇄ portrait.
    static func toggle() {
        guard playerUp, isPhone else { return }
        mode = mode == .landscape ? .portrait : .landscape
        apply(mode == .landscape ? preferredLandscape : .portrait)
    }

    /// Asks again (the rotate prompt, when the first request didn't take).
    static func retry() {
        guard playerUp, isPhone else { return }
        apply(mode == .landscape ? preferredLandscape : .portrait)
    }

    /// True when the window is the way the player wants it.
    static var isSettled: Bool {
        guard isPhone, playerUp else { return true }
        guard let scene = activeScene else { return true }
        let landscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
        return mode == .landscape ? landscape : !landscape
    }

    /// Landscape on the side the phone is tilted to; both sides when it lies
    /// flat or upright (the system then picks, and follows the sensor).
    /// UIDevice and UIInterface name the sides oppositely.
    private static var preferredLandscape: UIInterfaceOrientationMask {
        switch UIDevice.current.orientation {
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: .landscape
        }
    }

    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func apply(_ mask: UIInterfaceOrientationMask) {
        guard isPhone else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var controller = window.rootViewController
                while let c = controller {
                    c.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = c.presentedViewController
                }
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                Log.playback.error("Orientation change refused: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
#endif
