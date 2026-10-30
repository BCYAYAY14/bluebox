import SwiftUI

// The rest of the motion vocabulary, next to the springs in Theme.swift
// (`Motion.standard`, `.snappy`, `.spatial`, `.hover`, `.press`,
// `.cardZoom`). Curves for things that come and go, and the transitions
// that go with them, so a toast, a banner and a badge all arrive the same
// way. Anything that moves takes `reduceMotion` and becomes a plain fade.

extension Motion {
    /// Something arriving on its own (a loaded image, a toast, controls
    /// coming back): eases out, so it lands softly.
    public static let appear = Animation.easeOut(duration: 0.2)
    /// Something leaving on its own (controls hiding, a flash fading):
    /// eases in, a touch longer, so it doesn't vanish.
    public static let disappear = Animation.easeIn(duration: 0.25)
    /// Progress filling: linear, so a bar never springs past its value.
    public static let progress = Animation.linear(duration: 0.25)

    /// A menu, popover or small card opening over the page: quick, so it
    /// never makes anyone wait, with the snappy spring's slight settle.
    public static func popover(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22)
    }

    /// Fades in with a slight scale: badges, small buttons and cards that
    /// appear in place. A fade alone under Reduce Motion.
    public static func pop(_ reduceMotion: Bool, scale: CGFloat = 0.92, anchor: UnitPoint = .center) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: scale, anchor: anchor).combined(with: .opacity)
    }

    /// Fades in while sliding a few points in from `edge`. For views laid
    /// out in a full-size frame (banners, toasts pinned to the top of a
    /// stage), where `.move(edge:)` would travel the frame's whole height.
    public static func nudge(from edge: Edge, _ reduceMotion: Bool, distance: CGFloat = 12) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let offset: CGSize = switch edge {
        case .top: CGSize(width: 0, height: -distance)
        case .bottom: CGSize(width: 0, height: distance)
        case .leading: CGSize(width: -distance, height: 0)
        case .trailing: CGSize(width: distance, height: 0)
        }
        return .offset(offset).combined(with: .opacity)
    }

    /// Slides in from `edge` by the view's own size and fades: a bar or
    /// capsule sized to its content, coming up from the bottom of the
    /// window. A fade alone under Reduce Motion.
    public static func slide(from edge: Edge, _ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}
