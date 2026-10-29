import Foundation
import os

public enum Log {
    public static let subsystem = "app.bluebox"
    public static let metadata = Logger(subsystem: subsystem, category: "metadata")
    public static let sources = Logger(subsystem: subsystem, category: "sources")
    public static let playback = Logger(subsystem: subsystem, category: "playback")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let images = Logger(subsystem: subsystem, category: "images")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
}

public enum Redactor {
    private static let sensitiveQueryNames: Set<String> = [
        "api_key", "apikey", "token", "access_token", "x-plex-token", "password", "key", "signature",
    ]

    /// Returns the URL string with credential-bearing query values replaced,
    /// and user/password stripped. Safe to log.
    public static func redact(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<invalid url>" }
        if c.user != nil || c.password != nil { c.user = nil; c.password = nil }
        c.queryItems = c.queryItems?.map { item in
            sensitiveQueryNames.contains(item.name.lowercased()) ? URLQueryItem(name: item.name, value: "REDACTED") : item
        }
        return c.string ?? "<invalid url>"
    }

    public static func redact(headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { out, kv in
            let k = kv.key.lowercased()
            out[kv.key] = (k == "authorization" || k.contains("token") || k == "cookie") ? "REDACTED" : kv.value
        }
    }
}
