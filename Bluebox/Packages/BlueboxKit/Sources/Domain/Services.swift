import Foundation

public enum MetadataError: Error, Equatable, Sendable, LocalizedError {
    case missingCredentials
    case unauthorized
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case server(status: Int)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: "Add a TMDB read access token in Settings to browse the live catalog."
        case .unauthorized: "TMDB rejected the access token."
        case .notFound: "That title couldn't be found."
        case .rateLimited: "TMDB is busy. Trying again shortly."
        case .offline: "You're offline. Showing what's saved on this device."
        case .server(let s): "TMDB returned an error (\(s))."
        case .decoding: "TMDB returned data Bluebox couldn't read."
        case .transport(let d): "Network error: \(d)"
        }
    }
}

public enum CatalogList: String, Sendable, CaseIterable, Hashable {
    case trending, popularMovies, popularSeries, topRated
}

/// Metadata discovery. Separate from media availability by design.
public protocol MetadataProvider: Sendable {
    func list(_ list: CatalogList, page: Int) async throws -> Page<Title>
    func search(_ query: String, page: Int) async throws -> Page<Title>
    func discover(genre: Genre, kind: TitleKind, page: Int) async throws -> Page<Title>
    func genres() async throws -> [Genre]
    func detail(for key: MediaKey) async throws -> TitleDetail
    func season(_ number: Int, of seriesKey: MediaKey) async throws -> Season
    /// Converts an artwork reference into a fetchable URL for a target pixel width.
    func imageURL(for artwork: Artwork, width: Int) -> URL?
}

/// Library state the UI needs. Implementations must be safe to call from any task.
public protocol LibraryRepository: Sendable {
    func watchlist() async throws -> [Title]
    func isOnWatchlist(_ key: MediaKey) async throws -> Bool
    func setWatchlisted(_ title: Title, _ on: Bool) async throws
}

public protocol ProgressRepository: Sendable {
    func progress(for key: MediaKey) async throws -> WatchProgress?
    func progress(forSeries seriesKey: MediaKey) async throws -> [WatchProgress]
    /// Most recently updated in-progress items.
    func continueWatching(limit: Int) async throws -> [WatchProgress]
    /// Most recently updated records regardless of completion.
    func recent(limit: Int) async throws -> [WatchProgress]
    /// Stores progress, applying `ProgressMerge` against what is already saved.
    @discardableResult func save(_ progress: WatchProgress) async throws -> WatchProgress
    func delete(_ key: MediaKey) async throws
}

/// Caches titles so Continue Watching and the library can render offline.
public protocol TitleCache: Sendable {
    func store(_ titles: [Title]) async throws
    func title(for key: MediaKey) async throws -> Title?
}
