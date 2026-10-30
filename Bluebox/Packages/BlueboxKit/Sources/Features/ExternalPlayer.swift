import Domain
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Another app that plays Bluebox's videos (Open In…, Settings › Playback ›
/// Open Videos In). Each is handed the video's link: web links, Bluebox's
/// localhost torrent streams, and files (on iOS a file is served over
/// localhost too, and Bluebox keeps running behind the app:
/// `AppModel+ExternalPlayer`). None of them tells Bluebox how far you got.
///
/// Links, from each app's source or docs: Infuse (support.firecore.com,
/// "x-callback-url"), VLC for iOS (vlc-ios `URLHandler.swift`), IINA
/// (`AppDelegate.parsePendingURL`), VidHub (as Stremio opens it,
/// stremio-core `deep_links`), nPlayer (its `nplayer-` prefix, as Stremio
/// and others use it). VLC and mpv on the Mac register http and https, so
/// they're handed the link itself. Outplayer and SenPlayer publish no
/// scheme, and the ones in use disagree, so they aren't offered.
public enum ExternalPlayer: String, CaseIterable, Codable, Sendable, Identifiable {
    case infuse, vlc, iina, mpv, nplayer, vidhub
    /// iPhone and iPad: the system share sheet, for any other app.
    case shareSheet

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .infuse: "Infuse"
        case .vlc: "VLC"
        case .iina: "IINA"
        case .mpv: "mpv"
        case .nplayer: "nPlayer"
        case .vidhub: "VidHub"
        case .shareSheet: "Other App…"
        }
    }

    /// The players offered on this platform, in menu order.
    public static var forThisPlatform: [ExternalPlayer] {
        #if os(iOS)
        [.infuse, .vlc, .nplayer, .vidhub, .shareSheet]
        #else
        [.iina, .vlc, .mpv, .infuse]
        #endif
    }

    /// iOS: the scheme `canOpenURL` asks about. Each is in the app's
    /// `LSApplicationQueriesSchemes` (project.yml).
    var queryScheme: String? {
        switch self {
        case .infuse: "infuse"
        case .vlc: "vlc-x-callback"
        case .nplayer: "nplayer-http"
        case .vidhub: "open-vidhub"
        case .iina, .mpv, .shareSheet: nil
        }
    }

    /// Mac: the app's bundle ID, to find it and open videos with it.
    var macBundleID: String? {
        switch self {
        case .infuse: "com.firecore.infuse"
        case .vlc: "org.videolan.vlc"
        case .iina: "com.colliderli.iina"
        case .mpv: "io.mpv"
        default: nil
        }
    }

    /// The link that opens `url` in this app, with one subtitle file where the
    /// app takes one. Nil where the Mac opens the video with the app itself
    /// (VLC, mpv) or the share sheet does. Infuse and VLC take a subtitle link.
    func playLink(for url: URL, subtitle: URL? = nil, mac: Bool) -> URL? {
        let video = Self.encoded(url.absoluteString)
        let sub = subtitle.map { Self.encoded($0.absoluteString) }
        let link: String
        switch self {
        case .infuse:
            link = "infuse://x-callback-url/play?url=\(video)" + (sub.map { "&sub=\($0)" } ?? "")
        case .vlc:
            guard !mac else { return nil }
            link = "vlc-x-callback://x-callback-url/stream?url=\(video)" + (sub.map { "&sub=\($0)" } ?? "")
        case .iina:
            link = "iina://weblink?url=\(video)"
        case .nplayer:
            // nplayer-http://…, nplayer-https://…: the link itself, prefixed.
            link = "nplayer-\(url.absoluteString)"
        case .vidhub:
            link = "open-vidhub://x-callback-url/open?url=\(video)"
        case .mpv, .shareSheet:
            return nil
        }
        return URL(string: link)
    }

    /// Whether Bluebox can hand `url` over: web links, localhost streams and
    /// files. None of these apps can send headers, so links that need them
    /// stay in Bluebox.
    static func canOpen(_ url: URL, needsHeaders: Bool = false) -> Bool {
        guard !needsHeaders else { return false }
        return url.isFileURL || url.scheme == "https" || url.scheme == "http"
    }

    static func canOpen(_ resource: PlaybackResource) -> Bool {
        canOpen(resource.url, needsHeaders: !resource.httpHeaders.isEmpty)
    }

    /// The video's own `?`, `&`, `=` and `+` must reach the app encoded.
    static func encoded(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

// MARK: - On this device

@MainActor
extension ExternalPlayer {
    /// Installed on this device (the share sheet always is, on iOS).
    var isInstalled: Bool {
        #if os(iOS)
        if self == .shareSheet { return true }
        guard let scheme = queryScheme, let probe = URL(string: "\(scheme)://") else { return false }
        return UIApplication.shared.canOpenURL(probe)
        #else
        return appURL != nil
        #endif
    }

    /// This platform's players that are installed, in menu order.
    static var installed: [ExternalPlayer] { forThisPlatform.filter(\.isInstalled) }

    #if os(macOS)
    /// By bundle ID, else whichever app opens the player's own links.
    private var appURL: URL? {
        if let app = macBundleID.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:)) { return app }
        guard let probe = playLink(for: URL(string: "https://example.com/v.mp4")!, mac: true) else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }
    #endif

    /// Opens `url` (http, or on the Mac a file) in this app. False when it
    /// isn't installed or didn't open.
    func open(_ url: URL, subtitles: [ExternalSubtitle]) async -> Bool {
        guard isInstalled else { return false }
        let subtitle = subtitles.first { !$0.url.isFileURL && Self.canOpen($0.url) }?.url
        #if os(iOS)
        if self == .shareSheet {
            ShareSheet.present(url)
            return true
        }
        guard let link = playLink(for: url, subtitle: subtitle, mac: false) else { return false }
        return await UIApplication.shared.open(link)
        #else
        guard let app = appURL else { return false }
        if url.isFileURL || playLink(for: url, mac: true) == nil {
            // Like "Open With": a file this way also hands the app access to it.
            let config = NSWorkspace.OpenConfiguration()
            return (try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)) != nil
        }
        guard let link = playLink(for: url, subtitle: subtitle, mac: true) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        return (try? await NSWorkspace.shared.open([link], withApplicationAt: app, configuration: config)) != nil
        #endif
    }
}
