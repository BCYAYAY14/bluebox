import Domain
import Foundation

/// IMDb, Rotten Tomatoes and Metacritic scores from the OMDb API
/// (omdbapi.com). Needs the user's own key; free keys allow 1,000 requests a day,
/// so results are cached for the life of the service.
public actor OMDbService: RatingsProvider {
    let apiKey: String
    let http: any HTTPClient
    private var cache: [String: ExternalRatings?] = [:]

    public init(apiKey: String, http: any HTTPClient) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = http
    }

    struct Response: Decodable {
        struct Rating: Decodable { let Source: String; let Value: String }
        let Response: String
        let Error: String?
        let imdbRating: String?
        let imdbVotes: String?
        let Metascore: String?
        let Ratings: [Rating]?
    }

    public func ratings(imdbID: String) async throws -> ExternalRatings? {
        if let hit = cache[imdbID] { return hit }
        var c = URLComponents(string: "https://www.omdbapi.com/")!
        c.queryItems = [URLQueryItem(name: "i", value: imdbID), URLQueryItem(name: "apikey", value: apiKey)]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 15
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await http.send(req) } catch { throw MetadataError.offline }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else {
            if response.statusCode == 401 { throw MetadataError.unauthorized }
            throw MetadataError.server(status: response.statusCode)
        }
        if r.Response != "True" {
            let message = r.Error ?? ""
            if response.statusCode == 401 || message.localizedCaseInsensitiveContains("api key") { throw MetadataError.unauthorized }
            if message.localizedCaseInsensitiveContains("limit") { throw MetadataError.rateLimited(retryAfter: nil) }
            cache[imdbID] = .some(nil)   // "Incorrect IMDb ID." / not found
            return nil
        }
        func clean(_ s: String?) -> String? { s.flatMap { $0 == "N/A" || $0.isEmpty ? nil : $0 } }
        let ratings = ExternalRatings(
            imdb: clean(r.imdbRating), imdbVotes: clean(r.imdbVotes),
            rottenTomatoes: clean(r.Ratings?.first { $0.Source == "Rotten Tomatoes" }?.Value),
            metacritic: clean(r.Metascore)
        )
        let value: ExternalRatings? = ratings.isEmpty ? nil : ratings
        cache[imdbID] = .some(value)
        return value
    }
}
