import Foundation

/// The `bluebox://` links widgets, Spotlight and Siri open, read back by
/// `AppModel.handleOpenURL`. Keys are `MediaKey` raw values, kept as strings
/// so the widget extension needs no other module.
///
///     bluebox://title?key=tmdb:tv:1399                     the title page
///     bluebox://title?key=tmdb:tv:1399&episode=tmdb:tv:1399:s1e2
///     bluebox://play?key=tmdb:tv:1399:s1e2                 resumes (only what's in the library)
///     bluebox://my-list
///     bluebox://search?q=heist
public enum SystemLink: Equatable, Sendable {
    case title(key: String, episode: String?)
    case play(key: String)
    case myList
    case search(String)

    public static let scheme = "bluebox"

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .title(let key, let episode):
            c.host = "title"
            c.queryItems = [URLQueryItem(name: "key", value: key)] + (episode.map { [URLQueryItem(name: "episode", value: $0)] } ?? [])
        case .play(let key):
            c.host = "play"
            c.queryItems = [URLQueryItem(name: "key", value: key)]
        case .myList:
            c.host = "my-list"
        case .search(let query):
            c.host = "search"
            c.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        return c.url!
    }

    /// Nil for any other link (connect links, sign-in callbacks, magnets).
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            c.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch c.host?.lowercased() {
        case "title":
            guard let key = value("key"), Self.isKey(key) else { return nil }
            let episode = value("episode").flatMap { Self.isKey($0) ? $0 : nil }
            self = .title(key: key, episode: episode)
        case "play":
            guard let key = value("key"), Self.isKey(key) else { return nil }
            self = .play(key: key)
        case "my-list":
            self = .myList
        case "search":
            self = .search(String((value("q") ?? "").prefix(200)))
        default:
            return nil
        }
    }

    /// A catalogue key (`tmdb:…`, `imdb:…`) of sensible length; local and URL keys
    /// aren't linked to, since they mean nothing on another device or profile.
    static func isKey(_ s: String) -> Bool {
        s.count <= 120 && (s.hasPrefix("tmdb:") || s.hasPrefix("imdb:"))
    }
}
