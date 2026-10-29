import Foundation

/// Client-safe Supabase settings: the project URL and its publishable (or
/// legacy anon) key. Never the service-role key.
public struct SupabaseConfig: Sendable, Equatable {
    public let url: URL
    public let publishableKey: String

    public init?(url: String?, publishableKey: String?) {
        guard let url = url?.trimmingCharacters(in: .whitespaces), let key = publishableKey?.trimmingCharacters(in: .whitespaces),
              !key.isEmpty, !key.hasPrefix("YOUR_"), !url.contains("YOUR-PROJECT"),
              let parsed = URL(string: url), parsed.scheme == "https" || parsed.host == "localhost" || parsed.host == "127.0.0.1",
              parsed.host != nil,
              // Never hold a key that bypasses row level security, wherever it came from.
              !SupabaseKeyKind(key).isPrivileged
        else { return nil }
        self.url = parsed
        self.publishableKey = key
    }

    /// Reads `SupabaseURL` / `SupabasePublishableKey` from an Info.plist, which
    /// the app targets fill from `Config/Secrets.xcconfig`. Nil when unset.
    public init?(bundle: Bundle) {
        self.init(url: bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
                  publishableKey: bundle.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String)
    }

    func endpoint(_ path: String) -> URL { url.appending(path: path) }
}
