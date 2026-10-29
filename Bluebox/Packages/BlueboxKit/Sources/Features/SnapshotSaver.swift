import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import Photos
import UIKit
#endif

/// Saves a captured video frame: to Photos on iPhone and iPad, to
/// Pictures/Bluebox on the Mac.
enum SnapshotSaver {
    enum Failure: LocalizedError {
        case denied, encode
        var errorDescription: String? {
            switch self {
            case .denied: "Bluebox isn't allowed to add photos. Allow it in Settings › Privacy › Photos."
            case .encode: "Couldn't save the frame."
            }
        }
    }

    static func save(_ image: CGImage, title: String, at seconds: TimeInterval) async throws -> String {
        #if os(iOS)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: UIImage(cgImage: image))
        }
        return "Photos"
        #else
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appending(path: "Bluebox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = title.map { $0.isLetter || $0.isNumber || $0 == " " ? String($0) : "-" }.joined().prefix(60)
        // Int(_:) traps on NaN/infinity (an unknown position, e.g. a live stream).
        let s = seconds.isFinite ? Int(max(0, min(seconds, 1e7))) : 0
        let stem = String(format: "%@ %02d-%02d-%02d", String(safe), s / 3600, s / 60 % 60, s % 60)
        // Two captures in the same second get " 2", " 3"… instead of replacing the first.
        var url = dir.appending(path: stem + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appending(path: "\(stem) \(n).png"); n += 1 }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Failure.encode }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encode }
        return "Pictures › Bluebox"
        #endif
    }
}
