import CoreGraphics
import Foundation

/// Where a dragged subtitle block lands, with snapping. Pure geometry in unit
/// coordinates of the visible video (0…1 on both axes, origin top-left), so it
/// works the same in a window, full screen or PiP.
public struct SubtitlePlacement: Equatable, Sendable {
    public var anchor: SubtitleStyle.Anchor
    /// Distance of the block's anchored edge from that edge of the video.
    public var verticalMargin: Double
    /// Sideways shift from the aligned position.
    public var horizontalOffset: Double
    /// The block snapped to the vertical centre line.
    public var snappedX: Bool
    /// The block snapped to the default distance from the top or bottom.
    public var snappedY: Bool

    /// How close (in video fractions) counts as "on" a snap line.
    public static let snapDistance = 0.03

    /// - Parameters:
    ///   - block: the block's frame after the drag, in unit coordinates.
    ///   - alignment/horizontalMargin: the style's, which define the block's resting x.
    public static func dropping(block: CGRect, alignment: SubtitleStyle.Alignment, horizontalMargin: Double) -> SubtitlePlacement {
        let w = min(max(Double(block.width), 0), 1), h = min(max(Double(block.height), 0), 1)
        // Keep the whole block on the picture.
        let midX = min(max(Double(block.midX), w / 2), 1 - w / 2)
        let minY = min(max(Double(block.minY), 0), 1 - h)
        let maxY = minY + h

        let midY = (minY + maxY) / 2
        var anchor: SubtitleStyle.Anchor = midY >= 0.5 ? .bottom : .top
        var margin = anchor == .bottom ? 1 - maxY : minY
        var snappedY = false
        if abs(midY - 0.5) < snapDistance {
            // Centred on the picture: Middle, which stays centred whatever the line count.
            anchor = .middle; margin = SubtitleStyle.defaultMargin; snappedY = true
        } else if abs(margin - SubtitleStyle.defaultMargin) < snapDistance {
            margin = SubtitleStyle.defaultMargin; snappedY = true
        }
        margin = min(max(margin, 0), 0.85)

        var x = midX
        var snappedX = false
        if abs(x - 0.5) < snapDistance { x = 0.5; snappedX = true }
        let restingMidX = restingMidX(blockWidth: w, alignment: alignment, horizontalMargin: horizontalMargin)
        var offset = x - restingMidX
        if abs(offset) < 0.0005 { offset = 0 }
        return SubtitlePlacement(anchor: anchor, verticalMargin: margin, horizontalOffset: min(max(offset, -1), 1),
                                 snappedX: snappedX, snappedY: snappedY)
    }

    /// Centre x of a block of `blockWidth` at its aligned spot, before any offset.
    public static func restingMidX(blockWidth w: Double, alignment: SubtitleStyle.Alignment, horizontalMargin m: Double) -> Double {
        switch alignment {
        case .center: 0.5
        case .leading: m + w / 2
        case .trailing: 1 - m - w / 2
        }
    }

    /// The sideways shift that keeps a block of `blockWidth` fully on the
    /// picture (used while the window is resized after a drag).
    public static func clampedOffset(_ offset: Double, blockWidth w: Double, alignment: SubtitleStyle.Alignment,
                                     horizontalMargin m: Double) -> Double {
        let rest = restingMidX(blockWidth: w, alignment: alignment, horizontalMargin: m)
        let mid = min(max(rest + offset, w / 2), 1 - w / 2)
        return mid - rest
    }
}
