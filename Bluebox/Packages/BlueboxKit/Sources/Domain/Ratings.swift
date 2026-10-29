import Foundation

/// Critic and audience scores from outside TMDB, as display strings.
public struct ExternalRatings: Hashable, Codable, Sendable {
    /// e.g. "8.7" (out of 10).
    public var imdb: String?
    /// e.g. "1,234,567".
    public var imdbVotes: String?
    /// Tomatometer, e.g. "83%".
    public var rottenTomatoes: String?
    /// Metascore, e.g. "73" (out of 100).
    public var metacritic: String?

    public init(imdb: String? = nil, imdbVotes: String? = nil, rottenTomatoes: String? = nil, metacritic: String? = nil) {
        self.imdb = imdb; self.imdbVotes = imdbVotes; self.rottenTomatoes = rottenTomatoes; self.metacritic = metacritic
    }

    public var isEmpty: Bool { imdb == nil && rottenTomatoes == nil && metacritic == nil }
}

public protocol RatingsProvider: Sendable {
    /// Ratings for an IMDb ID, or nil when the service has none.
    func ratings(imdbID: String) async throws -> ExternalRatings?
}
