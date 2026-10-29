import Domain
import Foundation
import Metadata

/// Your debrid cloud library as a source: the videos you've added to
/// Real-Debrid, Premiumize or TorBox, matched to catalog titles by name, and
/// played with a fresh link each time.
///
/// Registered before the add-ons, so a title you already have in your cloud
/// plays from there rather than starting a new search. Uses the debrid key
/// already saved for add-ons (Keychain, `SecretAccount.debrid`).
public actor DebridLibrarySource: MediaSource {
    /// One file and what it matched.
    public struct Entry: Hashable, Sendable, Identifiable {
        public let file: DebridFile
        public let parsed: ParsedMediaName
        public let key: MediaKey?
        public var id: String { file.id }
        public var displayName: String {
            switch parsed.kind {
            case .movie: parsed.year.map { "\(parsed.title) (\($0))" } ?? parsed.title
            case .episode(let s, let e): "\(parsed.title) S\(s)·E\(e)"
            }
        }
    }

    public nonisolated let id = SourceID("debrid-library")
    /// No dedicated kind yet (the Sources menu's icons switch over kinds), so it
    /// shows with the add-ons' "Torrents & Debrid" icon.
    public nonisolated let kind = SourceKind.addons
    public nonisolated let displayName = "Debrid Library"
    public nonisolated let capabilities: SourceCapabilities = [.browse, .play, .download, .requiresAuthentication]

    private var api: (any DebridLibraryAPI)?
    private var matcher: MediaMatcher?
    private var entries: [Entry] = []
    private var loadedAt: Date?
    private var loading: Task<[Entry], Error>?
    /// Parsed name → match, so a refresh doesn't search the catalog again.
    private var matches: [String: MediaKey?] = [:]
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date

    public init(api: (any DebridLibraryAPI)?, matcher: MediaMatcher?, lifetime: TimeInterval = 600,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.api = api; self.matcher = matcher; self.lifetime = lifetime; self.now = now
    }

    /// The service and key changed (Settings › Sources). Forgets the old library.
    public func update(api: (any DebridLibraryAPI)?, matcher: MediaMatcher? = nil) {
        loading?.cancel(); loading = nil
        self.api = api
        if let matcher { self.matcher = matcher; matches = [:] }
        entries = []; loadedAt = nil
    }

    public var service: DebridService? { api?.service }
    public var isConfigured: Bool { api != nil }

    // MARK: Library

    /// Every video file, matched where possible. Cached for `lifetime`; `refresh` forces a reload.
    public func library(refresh: Bool = false) async throws -> [Entry] {
        guard let api else { throw SourceError.notConfigured }
        if !refresh, let loadedAt, now().timeIntervalSince(loadedAt) < lifetime { return entries }
        if let loading { return try await loading.value }
        let task = Task { try await self.load(api) }
        loading = task
        defer { loading = nil }
        let result = try await task.value
        entries = result
        loadedAt = now()
        return result
    }

    private func load(_ api: any DebridLibraryAPI) async throws -> [Entry] {
        let files = try await api.files()
        var out: [Entry] = []
        for file in files.sorted(by: { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }) {
            try Task.checkCancellation()
            let parsed = Self.parse(file)
            out.append(Entry(file: file, parsed: parsed, key: await match(parsed)))
        }
        return out
    }

    /// Uses the file name, borrowing the title (and year) from the torrent or
    /// folder when the file is only "S01E02.mkv" or similar.
    static func parse(_ file: DebridFile) -> ParsedMediaName {
        let own = MediaNameParser.parse(filename: file.filename)
        guard let parent = file.parentName else { return own }
        // "Show.Name.S01.1080p" → "Show Name": a season pack's folder names the show.
        let parsedParent = MediaNameParser.parse(filename: parent + ".mkv")
        let showTitle = parsedParent.title
            .replacingOccurrences(of: #"(?i)\s+(s\d{1,2}|season\s*\d+)(\s.*)?$"#, with: "", options: .regularExpression)
        let fromParent = ParsedMediaName(title: showTitle, year: parsedParent.year, kind: parsedParent.kind,
                                         resolution: parsedParent.resolution, container: parsedParent.container)
        let bare = MediaNameParser.normalized(own.title).count < 2
        switch own.kind {
        case .episode where bare:
            return ParsedMediaName(title: fromParent.title, year: fromParent.year, kind: own.kind,
                                   resolution: own.resolution ?? fromParent.resolution, container: own.container)
        // "bbb.1080p.mp4" inside "Big Buck Bunny (2008)": the folder has the year, so it's the better name.
        case .movie where bare || (own.year == nil && fromParent.year != nil):
            return ParsedMediaName(title: fromParent.title, year: fromParent.year ?? own.year, kind: fromParent.kind,
                                   resolution: own.resolution ?? fromParent.resolution, container: own.container)
        default:
            return own
        }
    }

    private func match(_ parsed: ParsedMediaName) async -> MediaKey? {
        guard let matcher, !parsed.title.isEmpty else { return nil }
        // Episodes of one show share one lookup.
        let showKey: String
        switch parsed.kind {
        case .movie: showKey = "m:\(MediaNameParser.normalized(parsed.title)):\(parsed.year ?? 0)"
        case .episode: showKey = "s:\(MediaNameParser.normalized(parsed.title))"
        }
        let seriesKey: MediaKey?
        if let cached = matches[showKey] {
            seriesKey = cached
        } else {
            let probe = ParsedMediaName(title: parsed.title, year: parsed.year,
                                        kind: { if case .episode = parsed.kind { .episode(season: 1, episode: 1) } else { .movie } }(),
                                        resolution: nil, container: nil)
            let found = await matcher(probe)
            seriesKey = found.map { $0.seriesKey ?? $0 }
            matches[showKey] = .some(seriesKey)
        }
        guard let seriesKey else { return nil }
        switch parsed.kind {
        case .movie: return seriesKey
        case .episode(let s, let e): return seriesKey.episode(season: s, episode: e)
        }
    }

    // MARK: MediaSource

    public func catalog() async throws -> [MediaVariant] {
        try await library().map(makeVariant)
    }

    public func variants(for key: MediaKey) async throws -> [MediaVariant] {
        guard api != nil else { return [] }
        // Don't hold up a title page on a cold library; it fills in on the next look.
        let current = loadedAt == nil ? ((try? await library()) ?? []) : entries
        if let loadedAt, now().timeIntervalSince(loadedAt) >= lifetime, loading == nil {
            Task { _ = try? await self.library(refresh: true) }
        }
        return current.filter { $0.key == key }.map(makeVariant)
    }

    public func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        guard let api else { throw SourceError.notConfigured }
        var entry = entries.first { $0.id == variant.id }
        if entry == nil { entry = try await library(refresh: true).first { $0.id == variant.id } }
        guard let entry else { throw SourceError.notFound }
        let url = try await api.link(for: entry.file)
        return PlaybackResource(variant: variant, url: url)
    }

    public func testConnection() async -> SourceHealth {
        guard let api else { return SourceHealth(ok: false, message: "Add a debrid service and key in Settings › Sources.") }
        do {
            let name = try await api.accountName()
            return SourceHealth(ok: true, message: "Connected to \(api.service.title) as \(name).")
        } catch {
            return SourceHealth(ok: false, message: (error as? LocalizedError)?.errorDescription ?? "Couldn't reach \(api.service.title).")
        }
    }

    public func variant(for entry: Entry) -> MediaVariant { makeVariant(entry) }

    func makeVariant(_ e: Entry) -> MediaVariant {
        MediaVariant(id: e.file.id, sourceID: id, mediaKey: e.key, displayName: e.file.filename,
                     container: e.parsed.container, resolution: e.parsed.resolution, sizeBytes: e.file.sizeBytes,
                     location: .remote, isDownloadable: true)
    }
}
