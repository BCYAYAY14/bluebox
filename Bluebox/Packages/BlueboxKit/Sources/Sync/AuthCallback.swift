import Foundation

/// `bluebox://auth-callback`, where Supabase's sign-in emails used to send
/// people back. Bluebox signs in with a username and password and never asks
/// for those emails, so a callback is never accepted: one carrying tokens or a
/// token hash could only have been started by someone else (security review
/// BB-01), and would otherwise swap this device into their account. The URL
/// stays recognised so it can be refused with a message, and stays the
/// project's redirect URL (automatic setup sets it) so Supabase never sends a
/// link anywhere else.
public enum AuthCallback {
    /// The project's Site URL and only redirect URL.
    public static let redirectURL = URL(string: "bluebox://auth-callback")!

    /// True for any URL meant for sign-in, even a malformed one.
    public static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == redirectURL.scheme else { return false }
        let target = (url.host() ?? url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        return target == "auth-callback" || target.hasPrefix("auth-callback/")
    }

    /// What the banner says when one is opened.
    public static let refusal = "Bluebox doesn't sign in from links. If you didn't open this link yourself, ignore it. To sign in, open Settings › Account & Sync and use your username and password."
}
