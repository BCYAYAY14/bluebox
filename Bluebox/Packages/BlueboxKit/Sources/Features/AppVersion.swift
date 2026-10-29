import Foundation

/// The running app's version, read from its Info.plist at run time (the
/// install step stamps the installed copy, so it's never compiled in).
/// Settings › About and the Mac's About window show it.
public enum AppVersion {
    /// CFBundleShortVersionString, e.g. "1.0.3"; "dev" when missing.
    public static var marketing: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// CFBundleVersion, e.g. "1".
    public static var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// "1.0.3 (1)".
    public static var display: String {
        build.map { "\(marketing) (\($0))" } ?? marketing
    }
}
