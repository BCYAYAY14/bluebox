import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The launch ident: the BLUEBOX wordmark on black. It settles in with a slight
/// scale, one narrow specular highlight sweeps across the letters (and only the
/// letters: the band is masked to the glyphs), then the ident hands over to the
/// app, which fades it out.
///
/// Driven by one clock so it plays the same on every device and window size.
/// The first frame is plain black. Tap to skip. With Reduce Motion the
/// wordmark simply fades in, with no scale and no sweep.
///
/// The clock counts frames the user could see, not wall time. It starts once
/// the window is on screen and the app is active, and a frame that arrives late
/// (the main thread was busy opening the library or building Home) moves it on
/// by at most one frame's worth. A launch hitch pauses the ident for a moment
/// instead of skipping the sweep.
public struct BlueboxIntro: View {
    let contentReady: Bool
    let onSweepFinished: () -> Void
    let onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var clock = FrameClock()
    @State private var sweepFinished = false
    @State private var finished = false

    /// - Parameters:
    ///   - contentReady: Whether the app behind is ready to be shown. The
    ///     wordmark holds (up to `Beat.longestHold`) until it is, then a moment
    ///     longer so the app's first frames are built before the fade.
    ///   - onSweepFinished: The animated part is over and the wordmark holds
    ///     still. A good moment for the caller to build heavy views behind it,
    ///     since a stall now can't be seen. Called once, before `onFinished`.
    ///   - onFinished: Time to fade the ident out.
    public init(contentReady: Bool = true, onSweepFinished: @escaping () -> Void = {},
                onFinished: @escaping () -> Void) {
        self.contentReady = contentReady
        self.onSweepFinished = onSweepFinished
        self.onFinished = onFinished
    }

    /// Timeline (seconds of shown frames). The caller's fade-out (about 0.45 s)
    /// follows `end`, for roughly 1.8 s in all.
    enum Beat {
        static let settle = 0.0...0.5
        static let sweep = 0.42...1.12
        static let end = 1.32
        static let reducedHold = 0.35
        static let reducedEnd = 1.0
        /// After the app is ready, the wordmark stays this long so the app's
        /// first frames are built behind it rather than during the fade.
        static let settleBehind = 0.2
        /// Never holds the app up longer than this, ready or not.
        static let longestHold = 5.0
    }

    public var body: some View {
        TimelineView(.animation) { context in
            let t = Self.frozenTime ?? clock.advance(to: context.date, visible: isOnScreen, contentReady: contentReady)
            let end = min(max(reduceMotion ? Beat.reducedEnd : Beat.end, (clock.readyAt ?? .infinity) + Beat.settleBehind),
                          Beat.longestHold)
            GeometryReader { geo in
                ZStack {
                    Color.black
                    wordmark(t: t, in: geo.size)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .onChange(of: t >= (reduceMotion ? Beat.reducedHold : Beat.sweep.upperBound)) { _, done in
                if done { finishSweep() }
            }
            .onChange(of: t >= end) { _, done in if done { finish() } }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement()
        .accessibilityLabel("Bluebox")
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: "Skip") { finish() }
    }

    /// Debug builds: `-intro-freeze 0.8` holds the ident at that moment, for
    /// checking single frames (the sweep's clipping, say).
    static let frozenTime: Double? = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-intro-freeze"), i + 1 < args.count { return Double(args[i + 1]) }
        #endif
        return nil
    }()

    /// Whether frames drawn now reach the screen: the scene is active and, on
    /// the Mac, one of the app's windows is actually visible.
    private var isOnScreen: Bool {
        guard scenePhase == .active else { return false }
        #if os(macOS)
        return NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        #else
        return true
        #endif
    }

    /// Seconds of the ident shown so far. A reference type, so the timeline
    /// can move it on while drawing without invalidating the view.
    @MainActor final class FrameClock {
        private var last: Date?
        private let created = Date()
        private(set) var elapsed = 0.0
        /// `elapsed` when the content behind became ready.
        private(set) var readyAt: Double?
        /// The most one frame may add: a late frame carries on from where the
        /// last one left off rather than jumping ahead.
        static let maxStep = 1.0 / 30
        /// Runs anyway after this long, in case visibility is never reported
        /// (a window opened behind another app, say), so the app isn't held up.
        static let visibilityTimeout = 2.5

        func advance(to date: Date, visible: Bool, contentReady: Bool) -> Double {
            if contentReady && readyAt == nil { readyAt = elapsed }
            guard visible || date.timeIntervalSince(created) > Self.visibilityTimeout else {
                last = nil
                return elapsed
            }
            if let last { elapsed += min(max(date.timeIntervalSince(last), 0), Self.maxStep) }
            last = date
            return elapsed
        }
    }

    private func finishSweep() {
        guard !sweepFinished else { return }
        sweepFinished = true
        onSweepFinished()
    }

    private func finish() {
        finishSweep()
        guard !finished else { return }
        finished = true
        onFinished()
    }

    /// Sized from the window so it reads the same on a phone, an iPad and a
    /// full-screen or narrow Mac window: about 56% of the width, capped by height.
    /// (A type size, as `BlueboxWordmark` takes: the letters are 0.705 of it
    /// tall and `widthPerSize` of it wide.)
    static func fontSize(for size: CGSize) -> CGFloat {
        max(28, min(size.width * 0.56 / widthPerSize, size.height * 0.16))
    }

    /// The letters' width for each point of type size.
    static let widthPerSize = 0.705 / BlueboxLetters.capHeightRatio * BlueboxLetters.aspectRatio

    @ViewBuilder private func wordmark(t: Double, in size: CGSize) -> some View {
        let fontSize = Self.fontSize(for: size)
        let settle = easeOut(progress(t, in: Beat.settle))
        let sweep = progress(t, in: Beat.sweep)
        let glyphs = BlueboxLetters.sized(fontSize)

        if reduceMotion {
            glyphs.foregroundStyle(Palette.brand)
                .opacity(progress(t, in: 0...0.35))
        } else {
            glyphs.foregroundStyle(Palette.brand)
                .overlay {
                    // The highlight is a gradient the size of the wordmark,
                    // clipped by the glyphs themselves, so nothing shows
                    // outside the letters.
                    Highlight(position: easeInOut(sweep))
                        .mask { glyphs }
                        .opacity(sweep > 0 && sweep < 1 ? 1 : 0)
                }
                .scaleEffect(0.94 + 0.06 * settle)
                .opacity(settle)
        }
    }

    /// A soft-edged white band at a slight angle. `position` runs 0 → 1 as the
    /// band crosses from just off the left edge to just off the right.
    private struct Highlight: View {
        let position: Double

        var body: some View {
            // Starts and ends just past the edges (half the band plus the tilt).
            let centre = -0.14 + position * 1.28
            let half = 0.075  // of the wordmark's width: about one letter wide in all
            // Many stops along a smooth falloff, so the band has no visible
            // steps even on a large, dark wordmark.
            let stops = stride(from: -1.0, through: 1.0, by: 0.125).map { u -> Gradient.Stop in
                let falloff = pow(cos(u * .pi / 2), 2)  // 1 at the centre, 0 at the edges
                // The gradient's axis runs from -0.5 to 1.5 of the width, so
                // every stop stays inside 0…1 even while the band is off the edge.
                return .init(color: .white.opacity(0.8 * falloff), location: (centre + u * half + 0.5) / 2)
            }
            LinearGradient(stops: stops,
                           // The wordmark's frame is about 2.4:1, so this axis
                           // tilts the band roughly 20° from vertical.
                           startPoint: UnitPoint(x: -0.5, y: -0.58), endPoint: UnitPoint(x: 1.5, y: 1.58))
        }
    }

    // MARK: Curves

    /// 0 before the range, 1 after, linear inside.
    private func progress(_ t: Double, in r: ClosedRange<Double>) -> Double {
        min(max((t - r.lowerBound) / (r.upperBound - r.lowerBound), 0), 1)
    }

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    /// A gentle sine ease, so the band crosses at an even pace with soft ends.
    private func easeInOut(_ x: Double) -> Double { (1 - cos(x * .pi)) / 2 }
}
