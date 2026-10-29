import CoreGraphics
import DesignSystem
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Poster loading: many large JPEGs fetched and downsampled at once, as when
/// a shelf of posters scrolls in. Prints wall-clock time so a change to the
/// pipeline can be compared run to run.
@Suite("Image pipeline")
struct ImagePipelineBenchmark {
    /// Writes `count` 1500×2250 JPEGs (TMDB "original" poster size) to a temp folder.
    static func posters(count: Int) throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bluebox-posters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = 1500, h = 2250
        var urls: [URL] = []
        for i in 0..<count {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            // Stripes and blocks so the JPEG isn't trivially small.
            for y in stride(from: 0, to: h, by: 30) {
                for x in stride(from: 0, to: w, by: 30) {
                    let v = CGFloat((x * 7 + y * 13 + i * 31) % 255) / 255
                    ctx.setFillColor(red: v, green: 1 - v, blue: CGFloat(i % 7) / 7, alpha: 1)
                    ctx.fill(CGRect(x: x, y: y, width: 30, height: 30))
                }
            }
            let url = dir.appending(path: "poster-\(i).jpg")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(dest)
            urls.append(url)
        }
        return urls
    }

    @Test("Decodes a shelf of posters concurrently, at display size")
    func shelfOfPosters() async throws {
        let urls = try Self.posters(count: 24)
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        for url in urls { _ = try Data(contentsOf: url) }  // same warm file cache for both runs
        let clock = ContinuousClock()
        // Before: the pre-change pipeline (decodes one at a time on its actor).
        // Alternate the two, fresh instances each round, and keep the best of three.
        var before: [Duration] = [], after: [Duration] = []
        var pipeline = ImagePipeline(diskCapacity: 0)
        for _ in 0..<3 {
            let legacy = LegacyImagePipeline()
            before.append(try await clock.measure {
                try await withThrowingTaskGroup(of: CGImage.self) { group in
                    for url in urls { group.addTask { try await legacy.image(for: url, maxPixelWidth: 300) } }
                    for try await _ in group {}
                }
            })
            pipeline = ImagePipeline(diskCapacity: 0)
            let fresh = pipeline
            after.append(try await clock.measure {
                try await withThrowingTaskGroup(of: CGImage.self) { group in
                    for url in urls { group.addTask { try await fresh.image(for: url, maxPixelWidth: 300) } }
                    for try await image in group { #expect(image.width <= 322) }  // 320 px bucket, ±rounding
                }
            })
        }
        let elapsed = after.min()!
        print("[bench] legacy pipeline: \(before.min()!.formatted(.units(allowed: [.milliseconds]))) (runs: \(before.map { $0.formatted(.units(allowed: [.milliseconds])) }))")
        print("[bench] new pipeline runs: \(after.map { $0.formatted(.units(allowed: [.milliseconds])) })")
        // A second pass is all memory hits, and answers without waiting.
        let hits = urls.filter { pipeline.cachedNow($0, maxPixelWidth: 300) != nil }.count
        print("[bench] 24 posters 1500×2250 → 300 px: \(elapsed.formatted(.units(allowed: [.milliseconds]))), memory hits after: \(hits)")
        #expect(hits == urls.count)
    }

    @Test("Nearby widths share one cached image")
    func widthBuckets() {
        #expect(ImagePipeline.bucket(277) == ImagePipeline.bucket(290))
        #expect(ImagePipeline.bucket(300) >= 300)
        #expect(ImagePipeline.bucket(1) >= 1)
        #expect(ImagePipeline.bucket(1300) >= 1300)
    }
}

/// The pipeline as it was before decoding moved off its actor, kept only to
/// compare against.
private actor LegacyImagePipeline {
    private let session: URLSession
    private let memory = NSCache<NSString, Box>()
    private var inFlight: [String: Task<CGImage, Error>] = [:]
    final class Box: @unchecked Sendable { let image: CGImage; init(_ i: CGImage) { image = i } }

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    func image(for url: URL, maxPixelWidth: Int) async throws -> CGImage {
        let key = "\(maxPixelWidth)|\(url.absoluteString)" as NSString
        if let hit = memory.object(forKey: key) { return hit.image }
        if let task = inFlight[key as String] { return try await task.value }
        let session = session
        let task = Task<CGImage, Error> {
            let (data, _) = try await session.data(from: url)
            guard let image = Self.downsample(data, maxPixelWidth: maxPixelWidth) else { throw URLError(.cannotDecodeContentData) }
            return image
        }
        inFlight[key as String] = task
        defer { inFlight[key as String] = nil }
        let image = try await task.value
        memory.setObject(Box(image), forKey: key)
        return image
    }

    static func downsample(_ data: Data, maxPixelWidth: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? maxPixelWidth
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? maxPixelWidth
        let scale = Double(maxPixelWidth) / Double(max(w, 1))
        let maxDim = Int((Double(max(w, h)) * min(scale, 1)).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxDim, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
