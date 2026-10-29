import Foundation

/// A `bluebox://auth-callback` URL opened from a Supabase sign-in email.
///
/// Supabase can deliver the result three ways, depending on the email template
/// and auth flow:
/// - implicit flow: `#access_token=…&refresh_token=…&expires_in=…` after
///   Supabase's `/verify` redirect (the default `{{ .ConfirmationURL }}` link);
/// - a token hash: `?token_hash=…&type=email` when the template links straight
///   to the app (`{{ .TokenHash }}`), which the app verifies itself;
/// - PKCE: `?code=…`, which Bluebox doesn't request, so it's reported as unsupported.
/// Failures come back as `error`, `error_code` and `error_description`, in the
/// query or the fragment.
public enum AuthCallback: Equatable, Sendable {
    public struct Tokens: Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresIn: Double?
        public var expiresAt: Double?
        /// `magiclink`, `signup`, … as Supabase reports it.
        public var type: String?
    }

    case session(Tokens)
    case tokenHash(String, type: String)
    case pkceCode(String)
    case failure(code: String?, description: String)

    /// Where sign-in emails send the user back to. Must be in the project's
    /// Authentication › URL Configuration › Redirect URLs.
    public static let redirectURL = URL(string: "bluebox://auth-callback")!

    /// True for any URL meant for sign-in, even a malformed one.
    public static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == redirectURL.scheme else { return false }
        let target = (url.host() ?? url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        return target == "auth-callback" || target.hasPrefix("auth-callback/")
    }

    /// Nil when the URL isn't a sign-in callback at all.
    public init?(url: URL) {
        guard Self.matches(url) else { return nil }
        var params = Self.formDecode(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        for (k, v) in Self.formDecode(url.fragment(percentEncoded: true)) { params[k] = v }

        if params["error"] != nil || params["error_code"] != nil || params["error_description"] != nil {
            self = .failure(code: params["error_code"] ?? params["error"],
                            description: params["error_description"] ?? "Supabase couldn't complete sign-in.")
        } else if let access = params["access_token"], !access.isEmpty, let refresh = params["refresh_token"], !refresh.isEmpty {
            self = .session(Tokens(accessToken: access, refreshToken: refresh,
                                   expiresIn: params["expires_in"].flatMap(Double.init),
                                   expiresAt: params["expires_at"].flatMap(Double.init),
                                   type: params["type"]))
        } else if let hash = params["token_hash"], !hash.isEmpty {
            self = .tokenHash(hash, type: params["type"].flatMap { $0.isEmpty ? nil : $0 } ?? "email")
        } else if let code = params["code"], !code.isEmpty {
            self = .pkceCode(code)
        } else {
            self = .failure(code: nil, description: "The sign-in link was incomplete. Request a new code and try again.")
        }
    }

    /// `a=1&b=two+words` → ["a": "1", "b": "two words"]. GoTrue form-encodes
    /// spaces as `+`, which `URLComponents` leaves alone.
    static func formDecode(_ s: String?) -> [String: String] {
        guard let s, !s.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ x: Substring) -> String {
                let spaced = x.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            guard let k = kv.first, !k.isEmpty else { continue }
            out[decode(k)] = kv.count > 1 ? decode(kv[1]) : ""
        }
        return out
    }
}
