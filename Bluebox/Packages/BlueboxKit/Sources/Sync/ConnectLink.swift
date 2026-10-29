import Foundation

/// `bluebox://connect?url=<project URL>&key=<publishable key>`: connects another
/// device to the same project without an access token. A signed-in device
/// shows it as a QR code and a link. It holds only the project URL and its
/// publishable (or legacy anon) key, which are public by design; never a
/// token, a password or a key that bypasses row level security.
public struct ConnectLink: Equatable, Sendable {
    public let config: SupabaseConfig

    public init(config: SupabaseConfig) { self.config = config }

    /// The link to show or share.
    public var url: URL {
        // Encode everything but unreserved characters, so the values survive any scanner or chat app.
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
        let project = config.url.absoluteString.hasSuffix("/") ? String(config.url.absoluteString.dropLast()) : config.url.absoluteString
        return URL(string: "bluebox://connect?url=\(encode(project))&key=\(encode(config.publishableKey))")!
    }

    /// True for any `bluebox://connect` URL, even a broken one.
    public static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "bluebox" else { return false }
        let target = (url.host() ?? url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        return target == "connect"
    }

    /// Nil when the URL isn't a connect link at all; throws `SupabaseSetupError`
    /// when it is one but can't be used (including a privileged key, which is refused).
    public static func parse(_ url: URL) throws -> ConnectLink? {
        guard matches(url) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let project = items.first { $0.name == "url" }?.value ?? ""
        let key = items.first { $0.name == "key" }?.value ?? ""
        guard !project.isEmpty, !key.isEmpty else {
            throw SupabaseSetupError.invalidURL("That link is incomplete. Copy it again from your other device.")
        }
        return ConnectLink(config: try SupabaseSetupInput.config(url: project, key: key))
    }

    /// Text pasted or typed by the user: a link, perhaps with spaces or a line around it.
    public static func parse(text: String) throws -> ConnectLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.split(whereSeparator: \.isWhitespace).first { $0.lowercased().hasPrefix("bluebox://") }
        guard let candidate, let url = URL(string: String(candidate)), let link = try parse(url) else {
            throw SupabaseSetupError.invalidURL("That isn't a Bluebox link. On your other device, open Settings › Account › Add Another Device and copy the link there.")
        }
        return link
    }
}
