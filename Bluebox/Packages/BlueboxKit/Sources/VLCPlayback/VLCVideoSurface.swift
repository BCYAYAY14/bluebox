import AVKit
import SwiftUI
@_spi(PrivateMacOSPiP) import SwiftVLC

/// Draws a `VLCEngine`'s video (iOS and macOS), with Picture in Picture.
///
/// PiP goes through SwiftVLC's `PiPVideoView`: libVLC's Apple sample-buffer
/// video output renders decoded frames into an `AVSampleBufferDisplayLayer`,
/// and an `AVPictureInPictureController` with a sample-buffer content source
/// hosts it, with play/pause, skip ±15 s and the time range driven by the
/// player's clock. On iOS that's public AVKit. On macOS AVKit's sample-buffer
/// PiP crops the picture to a square, so SwiftVLC's private `PIP.framework`
/// backend is enabled instead (fine for this personal, non-App Store app).
///
/// With `stretch`, the picture fills the view's frame exactly, like the AV
/// surface's `.resize` gravity: the caller sizes the frame for aspect, crop
/// and zoom, and the fitted picture is scaled to it. Otherwise VLC fits the
/// picture inside the view.
public struct VLCVideoSurface: View {
    let engine: VLCEngine
    let stretch: Bool
    /// Rebuilds the native view when the engine swaps its player.
    let generation: Int
    let pip: VLCPictureInPicture?

    public init(engine: VLCEngine, stretch: Bool = false, pip: VLCPictureInPicture? = nil) {
        self.engine = engine; self.stretch = stretch; self.pip = pip
        generation = engine.snapshot.outputGeneration
        Self.enablePiPBackend()
    }

    /// Opts into SwiftVLC's macOS PiP backend once. No effect on iOS.
    @MainActor private static var enabled = false
    @MainActor static func enablePiPBackend() {
        guard !enabled else { return }
        enabled = true
        #if os(macOS)
        PiPController.allowsPrivateMacOSAPI = true
        #endif
    }

    public var body: some View {
        GeometryReader { geo in
            let fitted = Self.fittedSize(video: engine.snapshot.presentationSize, in: geo.size)
            PiPVideoView(engine.player, controller: pip.map { p in Binding(get: { p.controller }, set: { p.controller = $0 }) },
                         startsAutomaticallyFromInline: true)
                .id(generation)
                // Stretching is a SwiftUI transform of the fitted picture, never
                // libvlc_video_set_aspect_ratio: that call waits on the video
                // output's lock from the main thread, and while the output is
                // starting it holds that lock waiting on the main thread (a hang).
                .frame(width: stretch ? fitted.width : geo.size.width, height: stretch ? fitted.height : geo.size.height)
                .scaleEffect(x: stretch ? geo.size.width / fitted.width : 1, y: stretch ? geo.size.height / fitted.height : 1)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .allowsHitTesting(false)
    }

    /// The picture's own shape fitted inside `box` (VLC draws it this way);
    /// the whole box when the video's size isn't known yet.
    static func fittedSize(video: CGSize, in box: CGSize) -> CGSize {
        guard video.width >= 1, video.height >= 1, box.width >= 1, box.height >= 1 else {
            return CGSize(width: max(box.width, 1), height: max(box.height, 1))
        }
        let scale = min(box.width / video.width, box.height / video.height)
        return CGSize(width: video.width * scale, height: video.height * scale)
    }
}

/// Picture in Picture for VLC playback, for the player's PiP button.
@Observable
@MainActor
public final class VLCPictureInPicture {
    /// Set by `VLCVideoSurface` once its native view exists.
    var controller: PiPController? {
        didSet { controller?.onRestoreUserInterface = { done in done(true) } }
    }

    public init() {}

    /// The device can show PiP at all.
    public static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    /// PiP can start now (a picture is on screen).
    public var isPossible: Bool { controller?.isPossible ?? false }
    public var isActive: Bool { controller?.isActive ?? false }
    public var isAvailable: Bool { controller != nil }

    public func toggle() { controller?.toggle() }
    public func stop() { if isActive { controller?.stop() } }
}
