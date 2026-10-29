import Domain
import Foundation
import Torrent

/// Torrents the user added themselves (a magnet link or a .torrent file for
/// something they have the right to watch). Each video file is a variant,
/// matched to the catalog by its filename.
///
/// Bluebox never searches indexers or looks up torrents for catalog titles.
public actor TorrentSource: MediaSource {
    /// Per-torrent catalog matches, persisted by the app.
    public struct Item: Hashable, Codable, Sendable {
        public var infoHash: InfoHash
        public var title: String
        /// File index → matched key. Files without a match play from the source list only.
        public var matches: [Int: MediaKey]
        public init(infoHash: InfoHash, title: String, matches: [Int: MediaKey] = [:]) {
            self.infoHash = infoHash; self.title = title; self.matches = matches
        }
    }

    public nonisolated let id = SourceID("torrents")
    public nonisolated let kind = SourceKind.torrent
    public nonisolated let displayName = "Torrents"
    public nonisolated let capabilities: SourceCapabilities = [.browse, .play, .download, .reportsProgress]

    public nonisolated let client: TorrentClient
    private var items: [InfoHash: Item]
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts"]

    public init(client: TorrentClient, items: [Item]) {
        self.client = client
        self.items = Dictionary(items.map { ($0.infoHash, $0) }) { a, _ in a }
    }

    public func allItems() -> [Item] { Array(items.values).sorted { $0.title.localizedCompare($1.title) == .orderedAscending } }

    /// Adds a magnet link or .torrent, waits for its file list, and matches
    /// each video file to the catalog.
    public func add(_ descriptor: TorrentDescriptor, matcher: MediaMatcher?, timeout: TimeInterval = 90) async throws -> Item {
        let hash = try await client.add(descriptor)
        let info: TorrentInfo
        do { info = try await client.info(for: hash, timeout: timeout) }
        catch { await client.remove(hash); throw error }
        var matches: [Int: MediaKey] = [:]
        if let matcher {
            for (i, f) in info.files.enumerated() where Self.isVideo(f.name) {
                if let key = await matcher(MediaNameParser.parse(filename: f.name)) { matches[i] = key }
            }
            // A single-video torrent named after the film: try the torrent's name too.
            let videos = info.files.indices.filter { Self.isVideo(info.files[$0].name) }
            if videos.count == 1, matches[videos[0]] == nil,
               let key = await matcher(MediaNameParser.parse(filename: info.name)) { matches[videos[0]] = key }
        }
        let item = Item(infoHash: hash, title: info.name, matches: matches)
        items[hash] = item
        return item
    }

    public func remove(_ hash: InfoHash) async {
        items[hash] = nil
        await client.remove(hash)
    }

    public func catalog() async throws -> [MediaVariant] {
        var out: [MediaVariant] = []
        for item in allItems() {
            guard let info = await client.knownInfo(for: item.infoHash) else { continue }
            let complete = await client.status(item.infoHash)?.phase == .complete
            for (i, f) in info.files.enumerated() where Self.isVideo(f.name) {
                out.append(variant(item, info: info, file: i, complete: complete))
            }
        }
        return out
    }

    public func variants(for key: MediaKey) async throws -> [MediaVariant] {
        var out: [MediaVariant] = []
        for item in allItems() {
            let files = item.matches.filter { $0.value == key }.map(\.key).sorted()
            guard !files.isEmpty, let info = await client.knownInfo(for: item.infoHash) else { continue }
            let complete = await client.status(item.infoHash)?.phase == .complete
            out += files.filter { info.files.indices.contains($0) }.map { variant(item, info: info, file: $0, complete: complete) }
        }
        return out
    }

    public func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        guard let (hash, index) = Self.parseVariantID(variant.id), items[hash] != nil,
              let info = await client.knownInfo(for: hash), info.files.indices.contains(index) else { throw SourceError.notFound }
        // Finished files play straight from disk; others stream as they download.
        if let local = await client.completedFileURL(hash, file: index) {
            return PlaybackResource(variant: variant, url: local)
        }
        await client.resume(hash)
        let ext = (info.files[index].name as NSString).pathExtension.lowercased()
        return PlaybackResource(variant: variant, url: TorrentClient.streamURL(hash, file: index, ext: ext))
    }

    public func testConnection() async -> SourceHealth {
        SourceHealth(ok: true, message: "\(items.count) torrent\(items.count == 1 ? "" : "s") added.")
    }

    func variant(_ item: Item, info: TorrentInfo, file i: Int, complete: Bool) -> MediaVariant {
        let f = info.files[i]
        let parsed = MediaNameParser.parse(filename: f.name)
        let ext = (f.name as NSString).pathExtension.lowercased()
        return MediaVariant(
            id: Self.variantID(item.infoHash, i), sourceID: id, mediaKey: item.matches[i],
            displayName: info.files.count == 1 ? item.title : "\(item.title) › \(f.name)",
            container: ext.isEmpty ? nil : ext, resolution: parsed.resolution, sizeBytes: f.length,
            location: complete ? .downloaded : .remote)
    }

    static func isVideo(_ name: String) -> Bool { videoExtensions.contains((name as NSString).pathExtension.lowercased()) }
    static func variantID(_ hash: InfoHash, _ index: Int) -> String { "\(hash.hex):\(index)" }
    static func parseVariantID(_ id: String) -> (InfoHash, Int)? {
        let parts = id.split(separator: ":")
        guard parts.count == 2, let h = InfoHash(hex: String(parts[0])), let i = Int(parts[1]) else { return nil }
        return (h, i)
    }
}
