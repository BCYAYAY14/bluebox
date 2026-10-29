@preconcurrency import AVFoundation
import AVKit
import SwiftUI

/// Hosts an `AVPlayerLayer` and owns the picture-in-picture controller for it.
@MainActor
public final class PictureInPictureModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published public private(set) var isPossible = false
    @Published public private(set) var isActive = false
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?

    public static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(_ layer: AVPlayerLayer) {
        guard controller == nil, Self.isSupported, let c = AVPictureInPictureController(playerLayer: layer) else { return }
        #if os(iOS)
        c.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        c.delegate = self
        controller = c
        possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
    }

    public func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }

    nonisolated public func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated public func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }
}

#if canImport(UIKit)
final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

public struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let pip: PictureInPictureModel
    /// When true the layer fills its frame exactly; the caller sizes it for aspect, crop and zoom.
    let stretch: Bool
    public init(player: AVPlayer, pip: PictureInPictureModel, stretch: Bool = false) {
        self.player = player; self.pip = pip; self.stretch = stretch
    }

    public func makeUIView(context: Context) -> UIView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        pip.attach(v.playerLayer)
        return v
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        guard let v = uiView as? PlayerLayerView else { return }
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        let gravity: AVLayerVideoGravity = stretch ? .resize : .resizeAspect
        if v.playerLayer.videoGravity != gravity { v.playerLayer.videoGravity = gravity }
    }
}
#else
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        // Without this the sublayer animates every size change over 0.25 s, so the
        // picture lags and swims behind the window during full-screen transitions,
        // live resizes and crop/zoom changes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

public struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let pip: PictureInPictureModel
    /// When true the layer fills its frame exactly; the caller sizes it for aspect, crop and zoom.
    let stretch: Bool
    public init(player: AVPlayer, pip: PictureInPictureModel, stretch: Bool = false) {
        self.player = player; self.pip = pip; self.stretch = stretch
    }

    public func makeNSView(context: Context) -> NSView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        pip.attach(v.playerLayer)
        return v
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? PlayerLayerView else { return }
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        let gravity: AVLayerVideoGravity = stretch ? .resize : .resizeAspect
        if v.playerLayer.videoGravity != gravity {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            v.playerLayer.videoGravity = gravity
            CATransaction.commit()
        }
    }
}
#endif

/// The system AirPlay route picker, tinted for the dark player.
#if canImport(UIKit)
public struct AirPlayButton: UIViewRepresentable {
    let player: AVPlayer?
    public init(player: AVPlayer?) { self.player = player }
    public func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = true
        return v
    }
    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
public struct AirPlayButton: NSViewRepresentable {
    let player: AVPlayer?
    public init(player: AVPlayer?) { self.player = player }
    public func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        v.setRoutePickerButtonColor(.white, for: .normal)
        v.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        v.player = player
        return v
    }
    public func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
#endif
