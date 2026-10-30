import Domain
import Foundation

/// The same title in the other catalog. Bluebox keys titles by TMDB ID
/// (`tmdb:…`) with a TMDB token and by IMDb ID (`imdb:…`) on Cinemeta, so
/// progress, downloads and My List saved under one stay keyed that way
/// after the catalog changes (a token added or removed, or a device using
/// the other one). `CachedMetadataProvider` asks for those keys' details in
/// the catalog in use and hands them back under the saved key.
///
/// Both directions go through Cinemeta, which needs no key: its pages carry
/// the TMDB ID (`moviedb_id`). From TMDB to IMDb there's no lookup by ID, so
/// the saved title's name is searched and a match must carry that TMDB ID.
public final class CatalogKeyBridge: @unchecked Sendable {
    /// The saved title for a key (name and year), for the TMDB → IMDb search.
    public var savedTitle: @Sendable (MediaKey) async -> Title? = { _ in nil }

    private let cinemeta: CinemetaMetadataProvider
    private let lock = NSLock()
    /// Series or movie raw key → the other catalog's key, both ways; nil = no match.
    private var known: [String: MediaKey?] = [:]

    public init(http: any HTTPClient = URLSessionHTTPClient(), base: URL = CinemetaMetadataProvider.defaultBase) {
        cinemeta = CinemetaMetadataProvider(http: http, base: base)
    }

    /// `key` in the TMDB catalog (`toTMDB`) or the Cinemeta one. Nil when it's
    /// already there, or no match was found. Episode keys keep their episode.
    public func key(for key: MediaKey, toTMDB: Bool) async -> MediaKey? {
        let whole = key.seriesKey ?? key
        let isTMDB = whole.tmdbID != nil
        guard whole.imdbID != nil || isTMDB, isTMDB != toTMDB else { return nil }
        let other: MediaKey?
        if let hit = lock.withLock({ known[whole.rawValue] }) {
            other = hit
        } else {
            let lookup = toTMDB ? await tmdbKey(for: whole) : await imdbKey(for: whole)
            other = lookup.key
            // Answers are remembered (no match too); a request that failed is asked again next time.
            if !lookup.failed {
                lock.withLock {
                    known[whole.rawValue] = .some(other)
                    if let other { known[other.rawValue] = .some(whole) }
                }
            }
        }
        guard let other else { return nil }
        if let ep = key.episodeNumbers { return other.episode(season: ep.season, episode: ep.episode) }
        return other
    }

    private typealias Lookup = (key: MediaKey?, failed: Bool)

    private func tmdbKey(for key: MediaKey) async -> Lookup {
        do {
            let meta = try await cinemeta.meta(for: key)
            guard let id = meta.moviedbID else { return (nil, false) }
            return (key.isMovie ? .movie(tmdbID: id) : .series(tmdbID: id), false)
        } catch {
            return (nil, (error as? MetadataError) != .notFound)
        }
    }

    private func imdbKey(for key: MediaKey) async -> Lookup {
        guard let id = key.tmdbID, let saved = await savedTitle(key) else { return (nil, true) }
        let type = key.isMovie ? "movie" : "series"
        let found: [Title]
        do {
            found = try await cinemeta.catalog(type, "top", extra: ["search": saved.name], page: 1).items
        } catch {
            return (nil, true)
        }
        // The same year first, then the rest, a few at most.
        var candidates: [Title] = []
        for t in found.filter({ saved.year == nil || $0.year == saved.year }) + found
        where !candidates.contains(where: { $0.key == t.key }) { candidates.append(t) }
        for candidate in candidates.prefix(5) {
            guard let meta = try? await cinemeta.meta(for: candidate.key), meta.moviedbID == id else { continue }
            return (candidate.key, false)
        }
        return (nil, false)
    }
}
