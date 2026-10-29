import CoreGraphics
import Domain
import Foundation
import ImageIO

/// Fetches, downsamples, and caches artwork.
///
/// - Memory: decoded `CGImage`s in an `NSCache` keyed by URL + pixel width.
///   `NSCache` is thread-safe, so views read it synchronously (`cachedNow`)
///   and a poster scrolled back into view draws in its first frame instead
///   of flashing the placeholder.
/// - Widths are rounded up to a few buckets, so the same poster at 277 and
///   290 px (two screens' layouts) is decoded and kept once.
/// - Disk: HTTP responses in a dedicated `URLCache` (respects server cache headers).
/// - Downloading and decoding run off the actor, in parallel; concurrent
///   requests for the same image share one download.
public actor ImagePipeline {
    public static let shared = ImagePipeline()

    private let session: URLSession
    private nonisolated let memory = MemoryCache()
    private var inFlight: [String: Task<CGImage, Error>] = [:]

    public init(diskCapacity: Int = 300 * 1024 * 1024) {
        let config = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "Artwork")
        config.urlCache = diskCapacity > 0
            ? URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: diskCapacity, directory: dir) : nil
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
        memory.totalCostLimit = 96 * 1024 * 1024
    }

    /// The decoded image if it's in memory, without waiting on the actor.
    public nonisolated func cachedNow(_ url: URL, maxPixelWidth: Int) -> CGImage? {
        memory.object(forKey: Self.key(url, Self.bucket(maxPixelWidth)))?.image
    }

    public func cached(_ url: URL, maxPixelWidth: Int) -> CGImage? {
        cachedNow(url, maxPixelWidth: maxPixelWidth)
    }

    public func image(for url: URL, maxPixelWidth: Int) async throws -> CGImage {
        let width = Self.bucket(maxPixelWidth)
        let key = Self.key(url, width)
        if let hit = memory.object(forKey: key) { return hit.image }
        if let task = inFlight[key as String] { return try await task.value }
        let session = session
        // Detached: the download and the decode don't hold the actor, so a
        // shelf's posters decode side by side instead of one after another.
        let task = Task.detached(priority: .userInitiated) { () throws -> CGImage in
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try Task.checkCancellation()
            guard let image = Self.downsample(data, maxPixelWidth: width) else { throw URLError(.cannotDecodeContentData) }
            return image
        }
        inFlight[key as String] = task
        defer { inFlight[key as String] = nil }
        let image = try await task.value
        memory.setObject(CGImageBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Starts loading images a screen is about to show (ignored when cached or loading).
    public func prefetch(_ urls: [URL], maxPixelWidth: Int) {
        for url in urls where cachedNow(url, maxPixelWidth: maxPixelWidth) == nil {
            let key = Self.key(url, Self.bucket(maxPixelWidth)) as String
            guard inFlight[key] == nil else { continue }
            Task { _ = try? await self.image(for: url, maxPixelWidth: maxPixelWidth) }
        }
    }

    public func clearMemory() { memory.removeAllObjects() }
    /// Artwork kept on disk (Settings › Storage), and clearing it.
    public var diskUsage: Int { session.configuration.urlCache?.currentDiskUsage ?? 0 }
    public func clearDisk() { session.configuration.urlCache?.removeAllCachedResponses(); memory.removeAllObjects() }

    static func key(_ url: URL, _ w: Int) -> NSString { "\(w)|\(url.absoluteString)" as NSString }

    /// Rounds a pixel width up to a step of 64 (128 past 1024), so layouts a
    /// few points apart share one decoded image. Never smaller than asked.
    public static func bucket(_ width: Int) -> Int {
        let w = max(width, 1)
        let step = w > 1024 ? 128 : 64
        return (w + step - 1) / step * step
    }

    /// Decodes at display size instead of full resolution to keep memory low.
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
            // Decoded here, off the main thread, not lazily on first draw.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxDim, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}

/// `NSCache` is thread-safe; this says so to Swift.
final class MemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, CGImageBox>()
    var totalCostLimit: Int { get { cache.totalCostLimit } set { cache.totalCostLimit = newValue } }
    func object(forKey key: NSString) -> CGImageBox? { cache.object(forKey: key) }
    func setObject(_ box: CGImageBox, forKey key: NSString, cost: Int) { cache.setObject(box, forKey: key, cost: cost) }
    func removeAllObjects() { cache.removeAllObjects() }
}

final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
