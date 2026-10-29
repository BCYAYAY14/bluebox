import CoreGraphics
import Foundation
import ImageIO
import SwiftVLC

/// Still frames from a file through libVLC's thumbnailer, for formats
/// AVFoundation can't open (MKV, AVI, WebM). Separate from playback: it opens
/// the file on its own, so it never disturbs the player.
public final class VLCFrameGrabber: Sendable {
    private let media: Media

    /// nil when libVLC can't open the file.
    public init?(fileURL: URL) {
        guard let media = try? Media(url: fileURL) else { return nil }
        self.media = media
    }

    /// A frame near `seconds` (keyframe-accurate: fast, and plenty for a preview), `width` pixels wide.
    public func frame(at seconds: TimeInterval, width: Int) async -> CGImage? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        guard let png = try? await media.thumbnail(at: .milliseconds(Int64(seconds * 1000)), width: width, height: 0,
                                                   seekMode: .fast, timeout: .seconds(4)),
              let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
