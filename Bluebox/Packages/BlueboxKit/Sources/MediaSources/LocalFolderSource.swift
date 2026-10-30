import CryptoKit
import Domain
import Foundation

/// Resolves a parsed filename to a catalog key (usually via TMDB search).
public typealias MediaMatcher = @Sendable (ParsedMediaName) async -> MediaKey?

/// Why a folder source can't be read, in words for the user.
public enum LocalFolderError: Error, Hashable, Sendable, LocalizedError {
    /// The folder isn't there (moved, renamed, or its drive isn't connected).
    case missing(String)
    /// Bluebox may no longer read it (the saved permission didn't resolve or was refused).
    case notPermitted(String)
    /// The path isn't a folder.
    case notAFolder(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name):
            "“\(name)” can't be found. It may have been moved or renamed, or its drive isn't connected."
        case .notPermitted(let name):
            "Bluebox isn't allowed to read “\(name)” any more. Remove it in Settings › Sources and add it again."
        case .notAFolder(let name): "“\(name)” isn't a folder."
        }
    }
}

/// Video files in a user-chosen folder.
///
/// Access is through a security-scoped bookmark so the folder stays readable
/// across launches in the sandbox. Matching filenames to catalog titles is
/// delegated to a `MediaMatcher` and cached for the life of the source.
public actor LocalFolderSource: MediaSource {
    /// What a folder scan picks up, and what can be opened or dropped on Bluebox.
    public static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts", "m2ts", "mts",
                                                      "wmv", "flv", "mpg", "mpeg", "ogv", "3gp", "divx", "vob"]

    public nonisolated let id: SourceID
    public nonisolated let kind = SourceKind.localFolder
    public nonisolated let displayName: String
    public nonisolated let capabilities: SourceCapabilities = [.browse, .play]

    private let folderURL: URL
    private let usesSecurityScope: Bool
    private let matcher: MediaMatcher?
    private let overrides: MatchOverrides?
    /// Set when the saved bookmark couldn't be resolved: every read fails with it.
    private let accessProblem: LocalFolderError?
    /// New bookmark data for a stale bookmark, for the app to save in place of the old.
    public nonisolated let refreshedBookmark: Data?
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
    /// - Parameter overrides: Fix Match choices, read before the matcher.
    public init(id: SourceID, name: String, folderURL: URL, usesSecurityScope: Bool, matcher: MediaMatcher? = nil,
                overrides: MatchOverrides? = nil) {
        self.init(id: id, name: name, folderURL: folderURL, usesSecurityScope: usesSecurityScope, matcher: matcher,
                  overrides: overrides, accessProblem: nil, refreshedBookmark: nil)
    }

    private init(id: SourceID, name: String, folderURL: URL, usesSecurityScope: Bool, matcher: MediaMatcher?,
                 overrides: MatchOverrides?, accessProblem: LocalFolderError?, refreshedBookmark: Data?) {
        self.id = id; self.displayName = name; self.folderURL = folderURL
        self.usesSecurityScope = usesSecurityScope; self.matcher = matcher; self.overrides = overrides
        self.accessProblem = accessProblem; self.refreshedBookmark = refreshedBookmark
    }

    /// Tests: replaces the clock.
    func setClock(_ now: @escaping @Sendable () -> Date) { self.now = now }

    /// Recreates a source from a stored configuration (`settings["bookmark"]` is base64
    /// bookmark data, `settings["path"]` the folder's path when it was added).
    ///
    /// A bookmark that no longer resolves still gives a source, one whose reads
    /// fail with a `LocalFolderError` saying what to do, so the folder stays in
    /// Settings and My Sources instead of quietly disappearing. A stale one that
    /// still resolves is renewed (`refreshedBookmark`).
    public static func fromConfiguration(_ config: SourceConfiguration, matcher: MediaMatcher?,
                                         overrides: MatchOverrides? = nil) throws -> LocalFolderSource {
        guard let b64 = config.settings["bookmark"], let data = Data(base64Encoded: b64) else {
            throw SourceError.invalidConfiguration("Missing folder bookmark")
        }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            let path = config.settings["path"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            let problem: LocalFolderError = [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains((error as NSError).code)
                ? .missing(config.name) : .notPermitted(config.name)
            return LocalFolderSource(id: config.id, name: config.name, folderURL: path ?? URL(fileURLWithPath: "/"),
                                     usesSecurityScope: false, matcher: matcher, overrides: overrides,
                                     accessProblem: problem, refreshedBookmark: nil)
        }
        var renewed: Data?
        if stale {
            let started = url.startAccessingSecurityScopedResource()
            renewed = try? makeBookmark(for: url)
            if started { url.stopAccessingSecurityScopedResource() }
        }
        return LocalFolderSource(id: config.id, name: config.name, folderURL: url, usesSecurityScope: true, matcher: matcher,
                                 overrides: overrides, accessProblem: nil, refreshedBookmark: renewed)
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
            if allMatched || now().timeIntervalSince(scannedAt) < Self.unmatchedRetryInterval { return applyingOverrides(scanned) }
        }
        let files = try withAccess { try Self.videoFiles(in: folderURL, name: displayName) }
        var out: [MediaVariant] = []
        var byVariant: [String: URL] = [:]
        // One lookup per film or show in this scan: a season of 20 episodes is one search, not 20.
        var lookups: [String: MediaKey?] = [:]
        for file in files {
            try Task.checkCancellation()
            let parsed = MediaNameParser.parse(filename: file.lastPathComponent)
            let vid = Self.variantID(for: file, root: folderURL)
            var key = matches[file]
            // Matched even when Fix Match overrides it, so Reset Match has the automatic match at hand.
            if key == nil, let matcher {
                key = await Self.lookUp(parsed, in: &lookups, matcher: matcher)
                if let key { matches[file] = key }
            }
            byVariant[vid] = file
            let size = withAccessNoThrow { (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) }
            out.append(MediaVariant(
                id: vid, sourceID: id, mediaKey: key, displayName: file.deletingPathExtension().lastPathComponent,
                container: file.pathExtension.lowercased(), resolution: parsed.resolution, sizeBytes: size,
                location: .localFile, isDownloadable: false
            ))
        }
        fileByVariant = byVariant
        scanned = out
        scannedAt = now()
        return applyingOverrides(out)
    }

    /// The automatic match for a film or show, shared by every file of it in one scan.
    static func lookUp(_ parsed: ParsedMediaName, in lookups: inout [String: MediaKey?], matcher: MediaMatcher) async -> MediaKey? {
        let title = MediaNameParser.normalized(parsed.title)
        guard !title.isEmpty else { return nil }
        switch parsed.kind {
        case .movie:
            let k = "m:\(title):\(parsed.year ?? 0)"
            if let cached = lookups[k] { return cached }
            let found = await matcher(parsed)
            lookups[k] = .some(found)
            return found
        case .episode(let s, let e):
            let k = "s:\(title):\(parsed.year ?? 0)"
            let show: MediaKey?
            if let cached = lookups[k] {
                show = cached
            } else {
                show = await matcher(parsed).map { $0.seriesKey ?? $0 }
                lookups[k] = .some(show)
            }
            return show?.episode(season: s, episode: e)
        }
    }

    /// Fix Match choices win over what the file names matched.
    private func applyingOverrides(_ variants: [MediaVariant]) -> [MediaVariant] {
        guard let overrides else { return variants }
        return variants.map { v in
            guard let o = overrides.override(source: id, variant: v.id) else { return v }
            return v.withMediaKey(o.key)
        }
    }

    /// The parsed name of a scanned file, for Fix Match's search field.
    public func parsedName(of variantID: String) -> ParsedMediaName? {
        fileByVariant[variantID].map { MediaNameParser.parse(filename: $0.lastPathComponent) }
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
            let count = try withAccess { try Self.videoFiles(in: folderURL, name: displayName).count }
            return SourceHealth(ok: true, message: count == 0
                                ? "No videos found. Bluebox looks for \(Self.extensionList) files in the folder and the folders inside it."
                                : "\(count) video file\(count == 1 ? "" : "s") found.")
        } catch {
            return SourceHealth(ok: false, message: (error as? LocalizedError)?.errorDescription
                                ?? "Folder can't be read. Remove it and add it again in Settings › Sources.")
        }
    }

    /// "MKV, MP4, MOV…" for messages.
    public static var extensionList: String {
        ["mkv", "mp4", "mov", "avi", "m4v", "webm"].map { $0.uppercased() }.joined(separator: ", ") + " and similar"
    }

    /// The folder URL, for starting security-scoped access during playback.
    public nonisolated var rootURL: URL { folderURL }

    // MARK: Helpers

    private func withAccess<T>(_ body: () throws -> T) throws -> T {
        if let accessProblem { throw accessProblem }
        let started = usesSecurityScope && folderURL.startAccessingSecurityScopedResource()
        defer { if started { folderURL.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private func withAccessNoThrow<T>(_ body: () -> T) -> T {
        let started = usesSecurityScope && folderURL.startAccessingSecurityScopedResource()
        defer { if started { folderURL.stopAccessingSecurityScopedResource() } }
        return body()
    }

    /// Every video in `folder` and the folders inside it (following folder
    /// aliases and symlinks one level), without samples. Throws a
    /// `LocalFolderError` when the folder itself can't be read, rather than
    /// returning nothing.
    public static func videoFiles(in folder: URL, name: String? = nil) throws -> [URL] {
        let fm = FileManager.default
        let name = name ?? folder.lastPathComponent
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir) else {
            // The sandbox answers "no such file" for a folder it won't let us see.
            throw fm.isReadableFile(atPath: folder.deletingLastPathComponent().path) ? LocalFolderError.missing(name)
                : LocalFolderError.notPermitted(name)
        }
        guard isDir.boolValue else { throw LocalFolderError.notAFolder(name) }
        // Read the top level first: the enumerator below skips what it can't
        // read without saying so, which made an unreadable folder look empty.
        do { _ = try fm.contentsOfDirectory(atPath: folder.path) } catch {
            throw (error as NSError).code == NSFileReadNoSuchFileError ? LocalFolderError.missing(name) : LocalFolderError.notPermitted(name)
        }
        var files: [URL] = []
        var visited: Set<String> = []
        var roots = [folder]
        while let root = roots.popLast() {
            guard visited.insert(root.resolvingSymlinksInPath().path).inserted,
                  let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isDirectory == true, isSampleFolder(url) {
                    e.skipDescendants()
                    continue
                }
                if values?.isSymbolicLink == true, root == folder {
                    var linkIsDir: ObjCBool = false
                    // The enumerator doesn't follow a link it starts on, so it's given the target.
                    if fm.fileExists(atPath: url.path, isDirectory: &linkIsDir), linkIsDir.boolValue {
                        roots.append(url.resolvingSymlinksInPath())
                    }
                }
                guard videoExtensions.contains(url.pathExtension.lowercased()), !isSample(url) else { continue }
                files.append(url)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Samples shipped next to releases: "sample.mkv", "Movie.2010-sample.mkv",
    /// "Movie.Sample.mkv". Not titles that merely contain the word ("The Sampler").
    static func isSample(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return stem.range(of: #"(^|[\s._\-\[(])sample([\s._\-\])]|$)"#, options: .regularExpression) != nil
    }

    static func isSampleFolder(_ url: URL) -> Bool {
        ["sample", "samples"].contains(url.lastPathComponent.lowercased())
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
