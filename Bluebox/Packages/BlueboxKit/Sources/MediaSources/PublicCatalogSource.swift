import Domain
import Foundation

/// Openly licensed films hosted by the Blender Foundation. Every entry was
/// checked for a direct, AVFoundation-playable rendition (H.264 in MOV/MP4).
///
/// TMDB IDs let these entries line up with catalog detail pages, so "Play"
/// works end-to-end without any user configuration.
public struct PublicCatalogSource: MediaSource {
    public struct Entry: Sendable, Hashable {
        public let slug: String
        public let mediaKey: MediaKey?
        public let title: String
        public let year: Int
        public let url: URL
        public let container: String
        public let resolution: String
        public let duration: TimeInterval
        public let sizeBytes: Int64
        public let license: String
        public let attribution: String
        public let subtitles: [ExternalSubtitle]
    }

    public let id = SourceID("public-catalog")
    public let kind = SourceKind.publicCatalog
    public let displayName = "Open Movies"
    public let capabilities: SourceCapabilities = [.browse, .play, .download, .externalSubtitles]
    public let entries: [Entry]

    public init(entries: [Entry] = PublicCatalogSource.defaultEntries) { self.entries = entries }

    public func catalog() async throws -> [MediaVariant] { entries.map(variant) }

    public func variants(for key: MediaKey) async throws -> [MediaVariant] {
        entries.filter { $0.mediaKey == key }.map(variant)
    }

    public func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        guard let e = entries.first(where: { $0.slug == variant.id }) else { throw SourceError.notFound }
        return PlaybackResource(variant: variant, url: e.url, externalSubtitles: e.subtitles)
    }

    public func testConnection() async -> SourceHealth {
        SourceHealth(ok: true, message: "\(entries.count) open-licensed films available.")
    }

    public func entry(for variant: MediaVariant) -> Entry? { entries.first { $0.slug == variant.id } }

    func variant(_ e: Entry) -> MediaVariant {
        MediaVariant(
            id: e.slug, sourceID: id, mediaKey: e.mediaKey, displayName: e.title, container: e.container,
            videoCodec: "h264", resolution: e.resolution, sizeBytes: e.sizeBytes, duration: e.duration,
            location: .remote, isDownloadable: true
        )
    }

    private static func sub(_ slug: String, _ file: String, _ lang: String, _ label: String) -> ExternalSubtitle {
        ExternalSubtitle(id: "\(slug)-\(lang)", url: URL(string: "https://download.blender.org/demo/movies/ToS/subtitles/\(file)")!,
                         languageCode: lang, label: label, format: "srt")
    }

    public static let defaultEntries: [Entry] = [
        Entry(
            slug: "tears-of-steel", mediaKey: .movie(tmdbID: 133701), title: "Tears of Steel", year: 2012,
            url: URL(string: "https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov")!,
            container: "mov", resolution: "720p", duration: 734.17, sizeBytes: 372_178_639,
            license: "CC BY 3.0", attribution: "(CC) Blender Foundation | mango.blender.org",
            subtitles: [
                sub("tos", "TOS-en.srt", "en", "English"), sub("tos", "TOS-es.srt", "es", "Español"),
                sub("tos", "TOS-fr-orig.srt", "fr", "Français"), sub("tos", "TOS-de.srt", "de", "Deutsch"),
                sub("tos", "TOS-it.srt", "it", "Italiano"), sub("tos", "TOS-JP.srt", "ja", "日本語"),
            ]
        ),
        Entry(
            slug: "elephants-dream", mediaKey: .movie(tmdbID: 9761), title: "Elephants Dream", year: 2006,
            url: URL(string: "https://download.blender.org/ED/elephantsdream-720-h264-st-aac.mov")!,
            container: "mov", resolution: "720p", duration: 658.32, sizeBytes: 152_496_338,
            license: "CC BY 2.5", attribution: "(c) copyright 2006, Blender Foundation / Netherlands Media Art Institute / www.elephantsdream.org",
            subtitles: []
        ),
        Entry(
            slug: "sintel-trailer", mediaKey: .movie(tmdbID: 45745), title: "Sintel (Trailer)", year: 2010,
            url: URL(string: "https://download.blender.org/durian/trailer/sintel_trailer-720p.mp4")!,
            container: "mp4", resolution: "720p", duration: 52.21, sizeBytes: 7_608_204,
            license: "CC BY 3.0", attribution: "(c) copyright Blender Foundation | durian.blender.org",
            subtitles: []
        ),
    ]
}
