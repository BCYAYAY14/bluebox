import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#endif

/// One swipe across the picture (iPhone and iPad, Settings › Playback ›
/// Swipe Gestures): sideways seeks, up and down sets the brightness on the
/// left half and the volume on the right, like most phone video players.
/// The kind is fixed by the first movement, so a seek doesn't drift into volume.
struct PlayerSwipe: Equatable {
    enum Kind: Equatable { case seek, brightness, volume }

    let kind: Kind
    /// Where it started: seconds for a seek, 0...1 for brightness and volume.
    let start: Double

    /// A swipe the width of the picture moves this many seconds.
    static let secondsPerWidth: Double = 120
    /// Starts this close to the top or bottom belong to the system (Notification
    /// Centre, the Home indicator), not to the player.
    static let edgeInset: CGFloat = 44

    /// Which kind a swipe is, from where it began and its first movement; nil
    /// for a start in the system's edges.
    static func kind(startLocation: CGPoint, translation: CGSize, in size: CGSize) -> Kind? {
        guard size.width > 0, size.height > 0,
              startLocation.y > edgeInset, startLocation.y < size.height - edgeInset else { return nil }
        if abs(translation.width) >= abs(translation.height) { return .seek }
        return startLocation.x < size.width / 2 ? .brightness : .volume
    }

    /// The seek target for a sideways movement of `dx` points, within the video.
    static func seekTarget(from start: Double, dx: CGFloat, width: CGFloat, duration: Double?) -> Double {
        let moved = start + Double(dx / max(width, 1)) * secondsPerWidth
        return min(max(moved, 0), max(duration ?? .infinity, 0))
    }

    /// The level after moving `dy` points (up is negative): the picture's
    /// height takes it from 0 to 1.
    static func level(from start: Double, dy: CGFloat, height: CGFloat) -> Double {
        min(max(start - Double(dy / max(height, 1)), 0), 1)
    }
}

#if os(iOS)
/// The screen's brightness, for the swipe on the left. What it was before the
/// player changed it comes back when the player closes, as in Photos and most
/// players: the brightness was meant for this video.
@MainActor
enum ScreenBrightness {
    private static var before: Double?

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    static var level: Double { Double(screen?.brightness ?? 0.5) }

    static func set(_ value: Double) {
        guard let screen else { return }
        if before == nil { before = Double(screen.brightness) }
        screen.brightness = CGFloat(min(max(value, 0), 1))
    }

    static func restore() {
        guard let before, let screen else { return }
        screen.brightness = CGFloat(before)
        Self.before = nil
    }
}
#endif
