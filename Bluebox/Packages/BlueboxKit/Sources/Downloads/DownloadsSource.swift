import Domain
import Foundation

/// Finished downloads as a source, listed first so they're preferred and play offline.
public struct DownloadsSource: MediaSource {
    public let id = SourceID("downloads")
    public let kind = SourceKind.downloads
    public let displayName = "Downloads"
    public let capabilities: SourceCapabilities = [.browse, .play]
    let manager: DownloadManager

    public init(manager: DownloadManager) { self.manager = manager }

    public func catalog() async throws -> [MediaVariant] {
        manager.all().filter { $0.state == .completed }.map(variant)
    }

    public func variants(for key: MediaKey) async throws -> [MediaVariant] {
        manager.records(for: key).filter { $0.state == .completed }.map(variant)
    }

    public func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        guard let r = manager.record(id: variant.id), let url = manager.fileURL(r),
              FileManager.default.fileExists(atPath: url.path) else { throw SourceError.notFound }
        let subs = r.subtitleFiles.map {
            ExternalSubtitle(id: "dl-\($0.fileName)", url: manager.subtitleURL($0), languageCode: $0.languageCode,
                             label: $0.label, format: $0.format)
        }
        return PlaybackResource(variant: variant, url: url, externalSubtitles: subs)
    }

    public func testConnection() async -> SourceHealth {
        let n = manager.all().filter { $0.state == .completed }.count
        return SourceHealth(ok: true, message: "\(n) download\(n == 1 ? "" : "s") saved.")
    }

    /// The playable variant for a finished download.
    public func variant(_ r: DownloadRecord) -> MediaVariant {
        // The saved file's extension is the truth (a torrent's add-on listing may guess the container).
        let ext = r.fileName.map { ($0 as NSString).pathExtension.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
        return MediaVariant(id: r.id, sourceID: id, mediaKey: r.mediaKey, displayName: r.title, container: ext ?? r.origin.container,
                     videoCodec: r.origin.videoCodec, resolution: r.origin.resolution, sizeBytes: r.expectedBytes,
                     duration: r.origin.duration, location: .downloaded)
    }
}
