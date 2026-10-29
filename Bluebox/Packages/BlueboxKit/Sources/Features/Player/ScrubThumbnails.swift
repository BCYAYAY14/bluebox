@preconcurrency import AVFoundation
import CoreGraphics
import Domain
import Foundation
import Observation
import Playback
import TorrentStreaming
import VLCPlayback

/// Frames for the scrub bubble.
///
/// - Local files and finished downloads: AVAssetImageGenerator, or libVLC's
///   thumbnailer for containers AVFoundation can't open.
/// - Torrent streams: the partial file on disk, read directly (never through
///   the stream server, which would steer libtorrent to that spot), and only
///   where the pieces around that time have already arrived.
/// - Anything else (debrid links, servers, HLS): no frames; the bubble shows alone.
///
/// One frame is made at a time, always for the latest position asked for,
/// and kept by time bucket, so dragging never queues work or blocks the thumb.
@Observable
@MainActor
final class ScrubThumbnailer {
    /// Seconds per cached frame.
    let bucket: TimeInterval
    let duration: TimeInterval
    /// Cached frames by bucket. Observed: the scrubber redraws when one lands.
    private(set) var frames: [Int: CGImage] = [:]

    @ObservationIgnored private let source: any ScrubFrameSource
    @ObservationIgnored private var order: [Int] = []
    @ObservationIgnored private var wanted: Int?
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Buckets whose data wasn't there yet, and when they were tried.
    @ObservationIgnored private var unavailable: [Int: Date] = [:]
    static let capacity = 160
    static let pixelWidth = 320

    init(source: any ScrubFrameSource, duration: TimeInterval) {
        self.source = source
        self.duration = duration
        bucket = Self.bucketSeconds(for: duration)
    }

    /// About 240 frames over the whole video, between 2 and 15 s apart.
    nonisolated static func bucketSeconds(for duration: TimeInterval) -> TimeInterval {
        min(max(duration / 240, 2), 15)
    }

    nonisolated static func bucketIndex(_ fraction: Double, duration: TimeInterval, bucket: TimeInterval) -> Int {
        let t = min(max(fraction, 0), 1) * duration
        return Int(t / bucket)
    }

    /// The nearest cached frame to `fraction` (within two buckets), if any.
    func image(near fraction: Double) -> CGImage? {
        let b = Self.bucketIndex(fraction, duration: duration, bucket: bucket)
        for d in [0, -1, 1, -2, 2] { if let f = frames[b + d] { return f } }
        return nil
    }

    /// Asks for the frame at `fraction`. Cheap: only notes the latest wish.
    func request(_ fraction: Double) {
        let b = Self.bucketIndex(fraction, duration: duration, bucket: bucket)
        guard frames[b] == nil else { return }
        if let tried = unavailable[b], Date().timeIntervalSince(tried) < 5 { return }
        wanted = b
        if worker == nil { worker = Task { [weak self] in await self?.work() } }
    }

    private func work() async {
        while let b = wanted, !Task.isCancelled {
            wanted = nil
            guard frames[b] == nil else { continue }
            let t = min((Double(b) + 0.5) * bucket, max(duration - 1, 0))
            guard source.canMakeFrame(at: t, duration: duration) else {
                unavailable[b] = Date()
                continue
            }
            guard let image = await source.frame(at: t, width: Self.pixelWidth) else {
                unavailable[b] = Date()
                continue
            }
            store(image, at: b)
        }
        worker = nil
    }

    private func store(_ image: CGImage, at b: Int) {
        frames[b] = image
        order.append(b)
        if order.count > Self.capacity {
            let evict = order.removeFirst()
            frames[evict] = nil
        }
    }

    /// A thumbnailer for what's playing, or nil when frames can't be made without
    /// downloading more (remote links) or at all (HLS, the in-app torrent client).
    static func make(for resource: PlaybackResource, duration: TimeInterval, usesVLC: Bool) -> ScrubThumbnailer? {
        guard duration > 10 else { return nil }
        let url = resource.url
        let container = (resource.variant.container ?? url.pathExtension).lowercased()
        guard container != "m3u8" else { return nil }
        let avCan = AVPlayerEngine.supportedContainers.contains(container) || container.isEmpty
        if url.isFileURL {
            let source: (any ScrubFrameSource)? = avCan && !usesVLC
                ? AVFrameSource(url: url, gate: nil)
                : VLCFrameGrabber(fileURL: url).map { VLCFrameSource(grabber: $0, gate: nil) }
            return source.map { ScrubThumbnailer(source: $0, duration: duration) }
        }
        if let stream = StreamAvailability.stream(for: url) {
            let gate = StreamGate(stream: stream)
            let source: (any ScrubFrameSource)? = avCan && !usesVLC
                ? AVFrameSource(url: stream.fileURL, gate: gate)
                : VLCFrameGrabber(fileURL: stream.fileURL).map { VLCFrameSource(grabber: $0, gate: gate) }
            return source.map { ScrubThumbnailer(source: $0, duration: duration) }
        }
        return nil
    }
}

/// Makes one still frame.
@MainActor
protocol ScrubFrameSource: AnyObject {
    /// False when the data for `seconds` isn't on disk yet.
    func canMakeFrame(at seconds: TimeInterval, duration: TimeInterval) -> Bool
    func frame(at seconds: TimeInterval, width: Int) async -> CGImage?
}

/// For torrent streams: the file is only partly on disk.
struct StreamGate: Sendable {
    let stream: StreamAvailability.Stream

    /// The header, the index at the end, and the bytes around where `seconds`
    /// sits if the bitrate were constant (padded, since it isn't).
    func isReady(at seconds: TimeInterval, duration: TimeInterval) -> Bool {
        let length = stream.fileLength
        guard length > 0, duration > 0 else { return false }
        let edge = min(Int64(1 << 20), length)
        let centre = Int64(Double(length) * min(max(seconds / duration, 0), 1))
        let pad = max(Int64(3 << 20), length / 100)
        return Self.windows(fileLength: length, centre: centre, pad: pad, edge: edge).allSatisfy(stream.isDownloaded)
    }

    static func windows(fileLength length: Int64, centre: Int64, pad: Int64, edge: Int64) -> [Range<Int64>] {
        [0..<edge, (length - edge)..<length, max(0, centre - pad)..<min(length, centre + pad)]
    }
}

final class AVFrameSource: ScrubFrameSource {
    private let generator: AVAssetImageGenerator
    private let gate: StreamGate?

    init(url: URL, gate: StreamGate?) {
        let asset = AVURLAsset(url: url)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: ScrubThumbnailer.pixelWidth, height: ScrubThumbnailer.pixelWidth)
        // Keyframes are fine for a preview and far cheaper than exact frames.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)
        self.gate = gate
    }

    func canMakeFrame(at seconds: TimeInterval, duration: TimeInterval) -> Bool {
        gate?.isReady(at: seconds, duration: duration) ?? true
    }

    func frame(at seconds: TimeInterval, width: Int) async -> CGImage? {
        try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

final class VLCFrameSource: ScrubFrameSource {
    private let grabber: VLCFrameGrabber
    private let gate: StreamGate?

    init(grabber: VLCFrameGrabber, gate: StreamGate?) { self.grabber = grabber; self.gate = gate }

    func canMakeFrame(at seconds: TimeInterval, duration: TimeInterval) -> Bool {
        gate?.isReady(at: seconds, duration: duration) ?? true
    }

    func frame(at seconds: TimeInterval, width: Int) async -> CGImage? {
        await grabber.frame(at: seconds, width: width)
    }
}
