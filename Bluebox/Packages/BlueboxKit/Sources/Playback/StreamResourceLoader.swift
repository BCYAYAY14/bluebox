@preconcurrency import AVFoundation
import Domain
import Foundation
import UniformTypeIdentifiers

/// Feeds AVPlayer from a `StreamDataProvider` for custom-scheme URLs, so a
/// torrent can play while it downloads. Requests are answered in chunks as
/// bytes become available; seeking just issues new requests.
final class StreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let provider: any StreamDataProvider
    let queue = DispatchQueue(label: "bluebox.stream-loader")
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    static let chunk = 512 * 1024

    init(provider: any StreamDataProvider) { self.provider = provider }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url, provider.canProvide(url) else { return false }
        let key = ObjectIdentifier(request)
        let provider = provider
        let box = RequestBox(request)
        let task = Task { [weak self] in
            do {
                let length = try await provider.contentLength(of: url)
                if let info = box.request.contentInformationRequest {
                    info.contentLength = length
                    info.isByteRangeAccessSupported = true
                    info.contentType = Self.contentType(for: url)
                }
                if let data = box.request.dataRequest {
                    var offset = data.requestedOffset
                    let end = data.requestsAllDataToEndOfResource ? length : min(length, offset + Int64(data.requestedLength))
                    while offset < end {
                        try Task.checkCancellation()
                        let n = Int(min(Int64(Self.chunk), end - offset))
                        let bytes = try await provider.read(url, offset: offset, length: n)
                        guard !bytes.isEmpty else { break }
                        try Task.checkCancellation()
                        data.respond(with: bytes)
                        offset += Int64(bytes.count)
                    }
                }
                if !Task.isCancelled { box.request.finishLoading() }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { box.request.finishLoading(with: error) }
            }
            self?.finished(key)
        }
        lock.withLock { tasks[key] = task }
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        let t = lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(request)) }
        t?.cancel()
    }

    func cancelAll() {
        let all = lock.withLock { defer { tasks = [:] }; return tasks.values }
        all.forEach { $0.cancel() }
    }

    private func finished(_ key: ObjectIdentifier) { lock.withLock { _ = tasks.removeValue(forKey: key) } }

    static func contentType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v": return UTType.mpeg4Movie.identifier
        case "mov": return UTType.quickTimeMovie.identifier
        case "m4a": return UTType.mpeg4Audio.identifier
        case "mp3": return UTType.mp3.identifier
        case "ts": return "public.mpeg-2-transport-stream"
        default: return UTType(filenameExtension: ext)?.identifier ?? UTType.movie.identifier
        }
    }
}

/// AVAssetResourceLoadingRequest isn't Sendable; it's safe to use from one task at a time.
private final class RequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
    init(_ r: AVAssetResourceLoadingRequest) { request = r }
}
