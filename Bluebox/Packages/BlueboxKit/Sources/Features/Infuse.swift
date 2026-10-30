import Domain
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Infuse (Firecore) as an external player, through its x-callback-url
/// `play` action: `infuse://x-callback-url/play?url=…&sub=…`.
@MainActor
enum Infuse {
    static let scheme = "infuse"

    /// Needs `infuse` in `LSApplicationQueriesSchemes` on iOS.
    static var isInstalled: Bool {
        guard let probe = URL(string: "\(scheme)://") else { return false }
        #if os(iOS)
        return UIApplication.shared.canOpenURL(probe)
        #else
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
        #endif
    }

    /// Whether Infuse can open `url`: web links, Bluebox's localhost torrent
    /// streams and files on disk (on iOS a file is served over localhost
    /// too, and Bluebox keeps running behind Infuse: `AppModel+Infuse`).
    /// Infuse can't send headers, so links that need them stay in Bluebox.
    static func canOpen(_ url: URL, needsHeaders: Bool = false) -> Bool {
        guard !needsHeaders else { return false }
        return url.isFileURL || url.scheme == "https" || url.scheme == "http"
    }

    static func canOpen(_ resource: PlaybackResource) -> Bool {
        canOpen(resource.url, needsHeaders: !resource.httpHeaders.isEmpty)
    }

    /// The `play` link for `url`, with one subtitle file when there is one Infuse can reach.
    static func playLink(for url: URL, subtitle: URL? = nil) -> URL? {
        var query = "url=" + encoded(url.absoluteString)
        if let subtitle { query += "&sub=" + encoded(subtitle.absoluteString) }
        return URL(string: "\(scheme)://x-callback-url/play?\(query)")
    }

    /// The video's own `?`, `&`, `=` and `+` must reach Infuse encoded.
    private static func encoded(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Opens `url` (http, or on the Mac a file) in Infuse. False when Infuse
    /// isn't installed or didn't open.
    static func open(_ url: URL, subtitles: [ExternalSubtitle]) async -> Bool {
        let subtitle = subtitles.first { !$0.url.isFileURL && canOpen($0.url) }?.url
        guard isInstalled, let link = playLink(for: url, subtitle: subtitle) else { return false }
        #if os(iOS)
        return await UIApplication.shared.open(link)
        #else
        if url.isFileURL, let app = NSWorkspace.shared.urlForApplication(toOpen: link) {
            // A file opens like "Open With", which hands Infuse access to it.
            let config = NSWorkspace.OpenConfiguration()
            return (try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)) != nil
        }
        return NSWorkspace.shared.open(link)
        #endif
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
