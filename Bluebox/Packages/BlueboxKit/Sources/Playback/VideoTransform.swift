import CoreGraphics
import Foundation

/// How the picture is framed: VLC-style aspect ratio, crop, zoom and rotation.
/// Reset when a new video starts.
public struct VideoFraming: Hashable, Sendable {
    public enum Ratio: String, CaseIterable, Sendable, Identifiable {
        case auto, r16x9, r4x3, r1_85, r2_35, r2_39, r21x9, r1x1, r5x4, r3x2
        public var id: String { rawValue }
        /// Width ÷ height, or nil for "use the video's own".
        public var value: Double? {
            switch self {
            case .auto: nil
            case .r16x9: 16.0 / 9
            case .r4x3: 4.0 / 3
            case .r1_85: 1.85
            case .r2_35: 2.35
            case .r2_39: 2.39
            case .r21x9: 21.0 / 9
            case .r1x1: 1
            case .r5x4: 5.0 / 4
            case .r3x2: 3.0 / 2
            }
        }
        public var label: String {
            switch self {
            case .auto: "Default"
            case .r16x9: "16:9"
            case .r4x3: "4:3"
            case .r1_85: "1.85:1"
            case .r2_35: "2.35:1"
            case .r2_39: "2.39:1"
            case .r21x9: "21:9"
            case .r1x1: "1:1"
            case .r5x4: "5:4"
            case .r3x2: "3:2"
            }
        }
    }

    public enum Scaling: String, CaseIterable, Sendable { case fit, fill, stretch }

    /// Stretches the source to this shape (for anamorphic or wrongly flagged files).
    public var aspect: Ratio = .auto
    /// Crops the source to this shape (e.g. remove letterbox bars baked into the picture).
    public var crop: Ratio = .auto
    /// Extra manual crop, as fractions of each edge (0…0.45).
    public var cropTop = 0.0, cropBottom = 0.0, cropLeft = 0.0, cropRight = 0.0
    public var scaling: Scaling = .fit
    /// 1 = no zoom; up to 4×.
    public var zoom = 1.0
    /// Pan while zoomed, −1…1 across the overflow in each direction.
    public var panX = 0.0, panY = 0.0
    /// Clockwise quarter turns, 0…3.
    public var quarterTurns = 0
    public var flipHorizontal = false
    public var flipVertical = false

    public init() {}

    public var isDefault: Bool { self == VideoFraming() }
    public var rotationDegrees: Double { Double(((quarterTurns % 4) + 4) % 4) * 90 }

    public mutating func rotate() { quarterTurns = (quarterTurns + 1) % 4 }

    public mutating func setZoom(_ z: Double) {
        zoom = min(max(z.isFinite ? z : 1, 1), 4)
        if zoom == 1 { panX = 0; panY = 0 }
    }

    public mutating func setPan(x: Double, y: Double) {
        panX = min(max(x, -1), 1); panY = min(max(y, -1), 1)
    }

    /// The visible part of the source, in unit coordinates (origin top-left).
    public func cropRect(sourceAspect: Double) -> CGRect {
        var r = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let target = crop.value, sourceAspect > 0 {
            if sourceAspect > target {
                let w = target / sourceAspect
                r = CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
            } else {
                let h = sourceAspect / target
                r = CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
            }
        }
        func c(_ v: Double) -> Double { min(max(v, 0), 0.45) }
        let l = c(cropLeft), rt = c(cropRight), t = c(cropTop), b = c(cropBottom)
        r = CGRect(x: r.minX + r.width * l, y: r.minY + r.height * t,
                   width: r.width * (1 - l - rt), height: r.height * (1 - t - b))
        return r
    }
}

/// Where to put the video layer for a framing, computed once per layout pass.
public struct VideoLayout: Equatable, Sendable {
    /// Size of the (possibly rotated) box the video is laid out in. It is
    /// centered in the container and rotated by `rotationDegrees`.
    public let box: CGSize
    /// Frame of the full, uncropped video layer inside `box` (stretched to the
    /// chosen aspect); the box clips it to the crop.
    public let videoFrame: CGRect
    /// The visible picture in container coordinates, for placing subtitles.
    public let visibleRect: CGRect
    public let rotationDegrees: Double

    public init(container: CGSize, natural: CGSize, framing f: VideoFraming) {
        rotationDegrees = f.rotationDegrees
        let turned = f.quarterTurns % 2 != 0
        let box = turned ? CGSize(width: container.height, height: container.width) : container
        self.box = box
        guard natural.width > 0, natural.height > 0, box.width > 0, box.height > 0 else {
            videoFrame = CGRect(origin: .zero, size: box)
            visibleRect = CGRect(origin: .zero, size: container)
            return
        }
        let aspect = f.aspect.value ?? Double(natural.width / natural.height)
        let crop = f.cropRect(sourceAspect: aspect)
        let visibleAspect = aspect * crop.width / crop.height

        // Size of the visible picture inside the box.
        var vis: CGSize
        let boxAspect = box.width / box.height
        switch f.scaling {
        case .stretch: vis = box
        case .fit:
            vis = visibleAspect > boxAspect ? CGSize(width: box.width, height: box.width / visibleAspect)
                                            : CGSize(width: box.height * visibleAspect, height: box.height)
        case .fill:
            vis = visibleAspect > boxAspect ? CGSize(width: box.height * visibleAspect, height: box.height)
                                            : CGSize(width: box.width, height: box.width / visibleAspect)
        }
        vis = CGSize(width: vis.width * f.zoom, height: vis.height * f.zoom)

        // Pan across whatever overflows the box.
        let overflowX = max(0, vis.width - box.width) / 2, overflowY = max(0, vis.height - box.height) / 2
        let visOrigin = CGPoint(x: (box.width - vis.width) / 2 - f.panX * overflowX,
                                y: (box.height - vis.height) / 2 - f.panY * overflowY)

        // The full layer is larger than the visible crop by the crop fraction.
        let full = CGSize(width: vis.width / crop.width, height: vis.height / crop.height)
        videoFrame = CGRect(x: visOrigin.x - crop.minX * full.width, y: visOrigin.y - crop.minY * full.height,
                            width: full.width, height: full.height)

        // Visible rect (clipped to the box), mapped back to the container.
        var shown = CGRect(origin: visOrigin, size: vis).intersection(CGRect(origin: .zero, size: box))
        // Flips happen inside the box, before it's rotated.
        if f.flipHorizontal { shown.origin.x = box.width - shown.maxX }
        if f.flipVertical { shown.origin.y = box.height - shown.maxY }
        // Rotate the rect's center about the shared center (SwiftUI angles turn clockwise).
        let c = CGPoint(x: container.width / 2, y: container.height / 2)
        let dx = shown.midX - box.width / 2, dy = shown.midY - box.height / 2
        let center: CGPoint
        switch ((f.quarterTurns % 4) + 4) % 4 {
        case 1: center = CGPoint(x: c.x - dy, y: c.y + dx)
        case 2: center = CGPoint(x: c.x - dx, y: c.y - dy)
        case 3: center = CGPoint(x: c.x + dy, y: c.y - dx)
        default: center = CGPoint(x: c.x + dx, y: c.y + dy)
        }
        let size = turned ? CGSize(width: shown.height, height: shown.width) : shown.size
        visibleRect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

/// Picture adjustments applied with Core Image (files and progressive
/// streams; AVFoundation doesn't allow video compositions on HLS).
public struct VideoAdjustments: Hashable, Sendable {
    /// −1…1, 0 = unchanged.
    public var brightness = 0.0
    /// 0…2, 1 = unchanged.
    public var contrast = 1.0
    /// 0…2, 1 = unchanged (0 = black and white).
    public var saturation = 1.0
    /// −180…180 degrees.
    public var hue = 0.0
    /// 0.5…2, 1 = unchanged.
    public var gamma = 1.0
    /// 0…2, 0 = unchanged.
    public var sharpness = 0.0
    public var invert = false

    public init() {}
    public var isDefault: Bool { self == VideoAdjustments() }

    public mutating func clamp() {
        brightness = min(max(brightness, -1), 1); contrast = min(max(contrast, 0), 2)
        saturation = min(max(saturation, 0), 2); hue = min(max(hue, -180), 180)
        gamma = min(max(gamma, 0.5), 2); sharpness = min(max(sharpness, 0), 2)
    }
}

/// A bookmark inside the video (from the file's chapter metadata).
public struct Chapter: Hashable, Sendable, Identifiable {
    public let title: String
    public let start: TimeInterval
    public var id: TimeInterval { start }
    public init(title: String, start: TimeInterval) { self.title = title; self.start = start }
}
