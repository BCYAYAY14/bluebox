import Foundation
import Metadata

/// Finds skip segments for what's playing, in order: the file's chapters,
/// Jellyfin's media segments, then TheIntroDB and IntroDB. Crowd answers are
/// cached on disk, so an episode is looked up once a week at most.
public actor SkipSegmentResolver {
    public struct Result: Equatable, Sendable {
        public var segments: [SkipSegment]
        /// Sources that answered with something, best first.
        public var sources: [SkipSegment.Source]
        public var usesCrowdSources: Bool { sources.contains { $0.isCrowdSourced } }
        public init(segments: [SkipSegment], sources: [SkipSegment.Source]) { self.segments = segments; self.sources = sources }
    }

    let jellyfin: (any SkipSegmentFetching)?
    let crowd: [any SkipSegmentFetching]
    let cache: SkipSegmentCache

    public init(jellyfin: (any SkipSegmentFetching)?, crowd: [any SkipSegmentFetching], cache: SkipSegmentCache) {
        self.jellyfin = jellyfin; self.crowd = crowd; self.cache = cache
    }

    /// The live setup: real clients over `http`, cache in Caches/SkipSegments.json.
    public static func live(http: any HTTPClient) -> SkipSegmentResolver {
        SkipSegmentResolver(jellyfin: JellyfinSegmentsClient(http: http),
                            crowd: [TheIntroDBClient(http: http), IntroDBClient(http: http)],
                            cache: SkipSegmentCache(file: SkipSegmentCache.defaultFile))
    }

    public func resolve(_ query: SkipSegmentQuery) async -> Result {
        var results: [[SkipSegment]] = []
        let chapters = ChapterSegments.segments(from: query.chapters, duration: query.duration)
        results.append(chapters)
        if query.jellyfin != nil, let jellyfin {
            results.append((try? await jellyfin.segments(for: query)) ?? [])
        }
        let isEpisode = query.season != nil && query.episode != nil
        if query.allowsCrowdSources {
            for client in crowd {
                let local = SkipSegmentPlanner.merge(results, duration: query.duration)
                guard SkipSegmentPlanner.needsCrowdSources(local, isEpisode: isEpisode) else { break }
                results.append(await crowdSegments(client, query))
            }
        }
        let merged = SkipSegmentPlanner.merge(results, duration: query.duration)
        var sources: [SkipSegment.Source] = []
        for s in merged.map(\.source).sorted() where !sources.contains(s) { sources.append(s) }
        return Result(segments: merged, sources: sources)
    }

    private func crowdSegments(_ client: any SkipSegmentFetching, _ query: SkipSegmentQuery) async -> [SkipSegment] {
        guard let key = SkipSegmentCache.key(for: query, source: client.source) else { return [] }
        if let hit = await cache.value(for: key) { return hit }
        do {
            let found = try await client.segments(for: query)
            await cache.store(found, for: key)
            return found
        } catch {
            return []  // network trouble or rate limit: try again next time
        }
    }
}

/// Crowd answers on disk. Found segments keep for a week; "nobody has timed
/// this yet" for 12 hours, so a new episode is picked up once someone does.
public actor SkipSegmentCache {
    struct Entry: Codable { var segments: [SkipSegment]; var fetchedAt: Date }

    public static var defaultFile: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appending(path: "SkipSegments.json")
    }

    let file: URL?
    let now: @Sendable () -> Date
    private var entries: [String: Entry]?
    static let hitLifetime: TimeInterval = 7 * 24 * 3600
    static let missLifetime: TimeInterval = 12 * 3600
    static let capacity = 600

    /// `file: nil` keeps the cache in memory only (tests).
    public init(file: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file; self.now = now
    }

    /// Per title, episode, source and (for release matching) the length to the minute.
    static func key(for q: SkipSegmentQuery, source: SkipSegment.Source) -> String? {
        guard let base = q.crowdCacheKey else { return nil }
        let minutes = q.duration.map { Int(($0 / 60).rounded()) } ?? 0
        return "\(source.rawValue).\(base).\(minutes)m"
    }

    func value(for key: String) -> [SkipSegment]? {
        load()
        guard let e = entries?[key] else { return nil }
        let life = e.segments.isEmpty ? Self.missLifetime : Self.hitLifetime
        return now().timeIntervalSince(e.fetchedAt) < life ? e.segments : nil
    }

    func store(_ segments: [SkipSegment], for key: String) {
        load()
        entries?[key] = Entry(segments: segments, fetchedAt: now())
        if let e = entries, e.count > Self.capacity {
            entries = Dictionary(uniqueKeysWithValues: e.sorted { $0.value.fetchedAt > $1.value.fetchedAt }
                .prefix(Self.capacity * 3 / 4).map { ($0.key, $0.value) })
        }
        save()
    }

    private func load() {
        guard entries == nil else { return }
        guard let file, let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { entries = [:]; return }
        entries = decoded
    }

    private func save() {
        guard let file, let entries, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
