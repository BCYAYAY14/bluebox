import CryptoKit
import Domain
import Foundation

/// Resolves a parsed filename to a catalog key (usually via TMDB search).
public typealias MediaMatcher = @Sendable (ParsedMediaName) async -> MediaKey?

/// Video files in a user-chosen folder.
///
/// Access is through a security-scoped bookmark so the folder stays readable
/// across launches in the sandbox. Matching filenames to catalog titles is
/// delegated to a `MediaMatcher` and cached for the life of the source.
public actor LocalFolderSource: MediaSource {
    public static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts", "m2ts"]

    public nonisolated let id: SourceID
    public nonisolated let kind = SourceKind.localFolder
    public nonisolated let displayName: String
    public nonisolated let capabilities: SourceCapabilities = [.browse, .play]

    private let folderURL: URL
    private let usesSecurityScope: Bool
    private let matcher: MediaMatcher?
    private var scanned: [MediaVariant]?
    private var scannedAt: Date?
    private var fileByVariant: [String: URL] = [:]
    /// Catalog matches found so far, kept across rescans so only new or
    /// unmatched files are looked up again.
    private var matches: [URL: MediaKey] = [:]
    /// How long a scan with unmatched files is trusted before matching is tried
    /// again (a scan made offline matches nothing).
    static let unmatchedRetryInterval: TimeInterval = 300
    private var now: @Sendable () -> Date = { Date() }

    /// - Parameter usesSecurityScope: true when `folderURL` came from a bookmark.
    public init(id: SourceID, name: String, folderURL: URL, usesSecurityScope: Bool, matcher: MediaMatcher? = nil) {
        self.id = id; self.displayName = name; self.folderURL = folderURL
        self.usesSecurityScope = usesSecurityScope; self.matcher = matcher
    }

    /// Tests: replaces the clock.
    func setClock(_ now: @escaping @Sendable () -> Date) { self.now = now }

    /// Recreates a source from a stored configuration (`settings["bookmark"]` is base64 bookmark data).
    public static func fromConfiguration(_ config: SourceConfiguration, matcher: MediaMatcher?) throws -> LocalFolderSource {
        guard let b64 = config.settings["bookmark"], let data = Data(base64Encoded: b64) else {
            throw SourceError.invalidConfiguration("Missing folder bookmark")
        }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw SourceError.notFound
        }
        return LocalFolderSource(id: config.id, name: config.name, folderURL: url, usesSecurityScope: true, matcher: matcher)
    }

    /// Creates bookmark data for a folder the user just picked.
    public static func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    public func rescan() async throws -> [MediaVariant] {
        scanned = nil
        matches = [:]  // match everything again (e.g. after adding a TMDB token)
        return try await catalog()
    }

    public func catalog() async throws -> [MediaVariant] {
        if let scanned, let scannedAt {
            let allMatched = matcher == nil || !scanned.contains { $0.mediaKey == nil }
            if allMatched || now().timeIntervalSince(scannedAt) < Self.unmatchedRetryInterval { return scanned }
        }
        let files = try withAccess { try Self.videoFiles(in: folderURL) }
        var out: [MediaVariant] = []
        var byVariant: [String: URL] = [:]
        for file in files {
            try Task.checkCancellation()
            let parsed = MediaNameParser.parse(filename: file.lastPathComponent)
            var key = matches[file]
            if key == nil, let matcher {
                key = await matcher(parsed)
                if let key { matches[file] = key }
            }
            let vid = Self.variantID(for: file, root: folderURL)
            byVariant[vid] = file
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            out.append(MediaVariant(
                id: vid, sourceID: id, mediaKey: key, displayName: file.deletingPathExtension().lastPathComponent,
                container: file.pathExtension.lowercased(), resolution: parsed.resolution, sizeBytes: size,
                location: .localFile, isDownloadable: false
            ))
        }
        fileByVariant = byVariant
        scanned = out
        scannedAt = now()
        return out
    }

    public func variants(for key: MediaKey) async throws -> [MediaVariant] {
        try await catalog().filter { $0.mediaKey == key }
    }

    public func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        if scanned == nil { _ = try await catalog() }
        guard let file = fileByVariant[variant.id] else { throw SourceError.notFound }
        let exists = withAccessNoThrow { FileManager.default.isReadableFile(atPath: file.path) }
        guard exists else { throw SourceError.notFound }
        let subs = withAccessNoThrow { Self.sidecarSubtitles(for: file) }
        return PlaybackResource(variant: variant, url: file, externalSubtitles: subs, securityScopedRoot: usesSecurityScope ? folderURL : nil)
    }

    public func testConnection() async -> SourceHealth {
        do {
            let count = try withAccess { try Self.videoFiles(in: folderURL).count }
            return SourceHealth(ok: true, message: "\(count) video file\(count == 1 ? "" : "s") found.")
        } catch {
            return SourceHealth(ok: false, message: "Folder can't be read. Choose it again in Settings.")
        }
    }

    /// The folder URL, for starting security-scoped access during playback.
    public nonisolated var rootURL: URL { folderURL }

    // MARK: Helpers

    private func withAccess<T>(_ body: () throws -> T) throws -> T {
        let started = usesSecurityScope && folderURL.startAccessingSecurityScopedResource()
        defer { if started { folderURL.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private func withAccessNoThrow<T>(_ body: () -> T) -> T {
        let started = usesSecurityScope && folderURL.startAccessingSecurityScopedResource()
        defer { if started { folderURL.stopAccessingSecurityScopedResource() } }
        return body()
    }

    static func videoFiles(in folder: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { throw SourceError.notFound }
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw SourceError.notFound
        }
        var files: [URL] = []
        for case let url as URL in e where videoExtensions.contains(url.pathExtension.lowercased()) {
            // Skip samples/trailers shipped next to releases.
            if url.lastPathComponent.lowercased().contains("sample") { continue }
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// `Movie.mkv` + `Movie.en.srt` / `Movie.srt` / `Movie.vtt` / `Movie.ass` in the same folder.
    static func sidecarSubtitles(for file: URL) -> [ExternalSubtitle] {
        let dir = file.deletingLastPathComponent()
        let stem = file.deletingPathExtension().lastPathComponent
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return contents.compactMap { url -> ExternalSubtitle? in
            let ext = url.pathExtension.lowercased()
            guard ["srt", "vtt", "ass", "ssa"].contains(ext) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard name == stem || name.hasPrefix(stem + ".") else { return nil }
            let lang = name == stem ? nil : String(name.dropFirst(stem.count + 1)).split(separator: ".").first.map(String.init)
            let label = lang.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? url.lastPathComponent
            return ExternalSubtitle(id: url.lastPathComponent, url: url, languageCode: lang, label: label, format: ext)
        }.sorted { $0.label < $1.label }
    }

    static func variantID(for file: URL, root: URL) -> String {
        let relative = file.path.replacingOccurrences(of: root.path, with: "")
        let digest = SHA256.hash(data: Data(relative.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
