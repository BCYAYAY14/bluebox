import Foundation

/// Which player implementation should open a resource.
public enum PlaybackEngineKind: Equatable, Sendable {
    /// AVFoundation: keeps PiP, AirPlay and the custom-scheme stream loader.
    case avFoundation
    /// VLC: the containers AVFoundation can't open (MKV, AVI, WebM…).
    case vlc
}

/// Pure routing rules between the AVFoundation and VLC engines. The engines'
/// container lists are passed in so this stays testable without either engine.
public enum PlaybackEngineRouting {
    /// URL schemes only AVPlayer can read: they're served through
    /// `StreamResourceLoader` (AVAssetResourceLoader), which VLC can't use.
    public static let avOnlySchemes: Set<String> = ["bluebox-torrent"]

    /// AVFoundation when it can attempt the container (or the URL needs it), VLC otherwise.
    public static func choose(container: String?, url: URL?, av: Set<String>, vlc: Set<String>) -> PlaybackEngineKind {
        if let scheme = url?.scheme?.lowercased(), avOnlySchemes.contains(scheme) { return .avFoundation }
        let c = normalized(container) ?? normalized(url?.pathExtension)
        guard let c else { return .avFoundation }  // unknown: AVFoundation decides, as before
        if av.contains(c) { return .avFoundation }
        return vlc.contains(c) ? .vlc : .avFoundation
    }

    /// True when either engine can attempt the container. Unknown containers are attempted.
    public static func canAttempt(container: String?, av: Set<String>, vlc: Set<String>) -> Bool {
        guard let c = normalized(container) else { return true }
        return av.contains(c) || vlc.contains(c)
    }

    static func normalized(_ container: String?) -> String? {
        guard let c = container?.trimmingCharacters(in: .whitespaces).lowercased(), !c.isEmpty else { return nil }
        return c.hasPrefix(".") ? String(c.dropFirst()) : c
    }
}
