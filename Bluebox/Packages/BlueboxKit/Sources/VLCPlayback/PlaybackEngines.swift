import Domain
import Foundation
import Playback

/// Picks AVFoundation or VLC for a resource. AVFoundation wins whenever it can
/// attempt the container (keeps PiP and AirPlay); VLC takes the rest.
@MainActor
public enum PlaybackEngines {
    /// Engine for a resolved resource. Uses the resolved variant's container
    /// (sources may only learn the real release in `resolve`), falling back to
    /// the URL's extension when the container is unknown.
    public static func kind(for resource: PlaybackResource) -> PlaybackEngineKind {
        PlaybackEngineRouting.choose(container: resource.variant.container, url: resource.url,
                                     av: AVPlayerEngine.supportedContainers, vlc: VLCEngine.supportedContainers)
    }

    public static func make(for resource: PlaybackResource, streams: (any StreamDataProvider)?) -> any PlaybackEngine {
        switch kind(for: resource) {
        case .avFoundation: AVPlayerEngine(streams: streams)
        case .vlc: VLCEngine()
        }
    }

    /// A new engine when `resource` needs a different one than `current`
    /// (e.g. an MKV episode after an MP4 one); nil keeps `current`.
    public static func replacement(for resource: PlaybackResource, current: any PlaybackEngine,
                                   streams: (any StreamDataProvider)?) -> (any PlaybackEngine)? {
        let currentKind: PlaybackEngineKind = current is VLCEngine ? .vlc : .avFoundation
        return kind(for: resource) == currentKind ? nil : make(for: resource, streams: streams)
    }

    /// True when either engine can attempt the container.
    public static func canAttempt(container: String?) -> Bool {
        PlaybackEngineRouting.canAttempt(container: container, av: AVPlayerEngine.supportedContainers,
                                         vlc: VLCEngine.supportedContainers)
    }

    /// Starts VLC's one-time setup in the background.
    public static func prewarm() { VLCEngine.prewarm() }
}
