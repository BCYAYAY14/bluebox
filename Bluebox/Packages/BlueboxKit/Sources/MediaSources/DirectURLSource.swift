import CryptoKit
import Domain
import Foundation

/// Media the user is authorized to stream from a direct HTTPS URL (their own
/// server, a CDN link they were given, a public-domain archive).
///
/// Bluebox only plays the URL as given; it never scrapes pages or extracts
/// streams from third-party sites.
public actor DirectURLSource: MediaSource {
    public struct Item: Hashable, Codable, Sendable {
        public var url: URL
        public var title: String
        public var mediaKey: MediaKey?
        public init(url: URL, title: String, mediaKey: MediaKey? = nil) {
            self.url = url; self.title = title; self.mediaKey = mediaKey
        }
    }

    public nonisolated let id: SourceID
    public nonisolated let kind = SourceKind.directURL
    public nonisolated let displayName: String
    public nonisolated let capabilities: SourceCapabilities = [.browse, .play, .download]

    private var items: [Item]

    public init(id: SourceID = SourceID("direct-urls"), name: String = "Direct Links", items: [Item] = []) {
        self.id = id; self.displayName = name; self.items = items
    }

    /// Validates and adds a URL. Only http(s) is accepted; plain http is
    /// allowed only for local-network hosts (ATS exception documented in SETUP.md).
    public func add(_ item: Item) throws {
        try Self.validate(item.url)
        items.removeAll { $0.url == item.url }
        items.append(item)
    }

    public func remove(_ url: URL) { items.removeAll { $0.url == url } }
    public func allItems() -> [Item] { items }

    public static func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty else {
            throw SourceError.invalidConfiguration("Enter a full URL starting with https://")
        }
        switch scheme {
        case "https": return
        case "http" where isLocalNetworkHost(host): return
        case "http": throw SourceError.invalidConfiguration("Use https:// for internet addresses.")
        default: throw SourceError.invalidConfiguration("Unsupported link type “\(scheme)”.")
        }
    }

    static func isLocalNetworkHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    public func catalog() async throws -> [MediaVariant] { items.map(variant) }

    public func variants(for key: MediaKey) async throws -> [MediaVariant] {
        items.filter { $0.mediaKey == key }.map(variant)
    }

    public func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        guard let item = items.first(where: { Self.variantID($0.url) == variant.id }) else { throw SourceError.notFound }
        return PlaybackResource(variant: variant, url: item.url)
    }

    public func testConnection() async -> SourceHealth {
        SourceHealth(ok: true, message: "\(items.count) link\(items.count == 1 ? "" : "s") saved.")
    }

    func variant(_ item: Item) -> MediaVariant {
        let ext = item.url.pathExtension.lowercased()
        return MediaVariant(
            id: Self.variantID(item.url), sourceID: id, mediaKey: item.mediaKey, displayName: item.title,
            container: ext.isEmpty ? nil : ext, location: .remote,
            // HLS playlists need AVAssetDownloadURLSession, which the download manager doesn't support yet.
            isDownloadable: ext != "m3u8"
        )
    }

    static func variantID(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
