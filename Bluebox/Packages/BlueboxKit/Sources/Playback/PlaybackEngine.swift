import CoreGraphics
import Domain
import Foundation
import Subtitles

public enum PlaybackStatus: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case ended
    case failed(PlaybackError)

    public var isActive: Bool { self == .playing || self == .buffering }
    public var isFailure: Bool { if case .failed = self { true } else { false } }
}

public enum PlaybackError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedFormat(String)
    case unreachable(String)
    case decodeFailed(String)
    case source(SourceError)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let f):
            "This file can't be played on this device (\(f))."
        case .unreachable(let d): "The video couldn't be loaded. \(d)"
        case .decodeFailed(let d): "Playback stopped: \(d)"
        case .source(let e): e.localizedDescription
        }
    }
}

public struct MediaTrack: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case audio, subtitle }
    public let id: String
    public let kind: Kind
    public let label: String
    public let languageCode: String?
    /// True for subtitles Bluebox renders itself (external files).
    public let isExternal: Bool
    /// Picture subtitles (PGS, VobSub, DVB): the engine draws them as they are,
    /// so the subtitle style can't change them.
    public let isBitmap: Bool
    /// The subtitle format as people know it ("SRT", "ASS", "PGS"), when known.
    /// Shown beside tracks of the same language so they can be told apart.
    public let format: String?
    /// An embedded text track the engine hands to Bluebox's overlay (VLC with
    /// SubRip, WebVTT and unstyled ASS in MKV): drawn in the user's style, and
    /// usable as the second line.
    public let drawnByBluebox: Bool
    public init(id: String, kind: Kind, label: String, languageCode: String?, isExternal: Bool = false, isBitmap: Bool = false,
                format: String? = nil, drawnByBluebox: Bool = false) {
        self.id = id; self.kind = kind; self.label = label; self.languageCode = languageCode; self.isExternal = isExternal
        self.isBitmap = isBitmap; self.format = format; self.drawnByBluebox = drawnByBluebox
    }

    /// ASS/SSA tracks in the video carry their own fonts, colours and
    /// positions, which the engine draws as the file says. (Bluebox draws
    /// subtitle files itself, in the user's style, and ASS tracks with no
    /// styled lines.)
    public var keepsOwnStyle: Bool { !isExternal && format == "ASS" && !drawnByBluebox }
}

/// Everything the UI needs to render player state, published as one value.
public struct PlaybackSnapshot: Equatable, Sendable {
    public var status: PlaybackStatus = .idle
    public var position: TimeInterval = 0
    public var duration: TimeInterval?
    public var bufferedUntil: TimeInterval = 0
    public var rate: Float = 1
    public var audioTracks: [MediaTrack] = []
    public var embeddedSubtitles: [MediaTrack] = []
    public var selectedAudioID: String?
    public var selectedEmbeddedSubtitleID: String?
    public var presentationSize: CGSize = .zero
    /// Text of the selected embedded subtitle track at the current time, when
    /// the engine hands embedded text to Bluebox to draw (so it can be styled).
    public var embeddedSubtitleText: String?
    /// Text of the embedded track chosen as the second line
    /// (`selectSecondaryEmbeddedSubtitle`) at the current time.
    public var secondaryEmbeddedSubtitleText: String?
    public var chapters: [Chapter] = []
    /// False for HLS, where AVFoundation can't apply picture adjustments.
    public var supportsVideoAdjustments = true
    /// False where Dialogue Boost and Night Mode can't run (AVPlayer with HLS).
    public var supportsAudioEffects = true
    /// Changes when the engine replaces its video output (VLC's player swap
    /// for Night Mode), so the view rebuilds its surface.
    public var outputGeneration = 0
    /// 0…1 while the engine fills its buffer (loading or stalled), when it says.
    public var bufferFill: Double?
    /// True when the engine draws embedded subtitles itself and can delay them
    /// and restyle text tracks (VLC). AVPlayer hands the text to Bluebox instead.
    public var drawsEmbeddedSubtitles = false
    /// True when `setEmbeddedSubtitleDelay` moves embedded subtitles, whoever
    /// draws them (VLC: its own tracks and the text it hands to Bluebox).
    public var delaysEmbeddedSubtitles = false
    /// AirPlay is showing the video on another screen (AVPlayer).
    public var isExternalPlaybackActive = false
    public init() {}
}

/// A player implementation. All calls happen on the main actor, matching
/// AVFoundation's and SwiftUI's expectations.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var snapshot: PlaybackSnapshot { get }
    /// Called on every snapshot change.
    var onChange: ((PlaybackSnapshot) -> Void)? { get set }

    /// Container formats this engine can attempt. Used to reject files up front.
    static var supportedContainers: Set<String> { get }

    func load(_ resource: PlaybackResource, startAt: TimeInterval?) async throws
    func play()
    func pause()
    func seek(to seconds: TimeInterval) async
    func setRate(_ rate: Float)
    func selectAudio(_ trackID: String?)
    func selectEmbeddedSubtitle(_ trackID: String?)
    /// An embedded track to show as the second line (one with `drawnByBluebox`), nil for none.
    func selectSecondaryEmbeddedSubtitle(_ trackID: String?)
    func stop()
    /// Applies brightness/contrast/etc. A no-op where unsupported.
    func setVideoAdjustments(_ adjustments: VideoAdjustments)
    /// Steps one frame forward or back while paused.
    func stepFrame(by count: Int)
    /// The frame on screen now, for snapshots.
    func captureFrame() async -> CGImage?
    /// A fast, approximate seek while the user drags the timeline. Engines may
    /// drop intermediate targets; a final `seek(to:)` lands exactly.
    func scrub(to seconds: TimeInterval)
    /// What the engine is doing, for the player's info panel.
    func diagnostics() -> PlaybackDiagnostics
    /// Dialogue boost and night mode. Kept across items the engine loads.
    func setAudioEffects(_ effects: AudioEffects)
    /// Delays embedded subtitles the engine draws itself (positive = later).
    func setEmbeddedSubtitleDelay(_ seconds: TimeInterval)
    /// The look for embedded text subtitles the engine draws itself. Applied
    /// live; never reopens the stream.
    func setEmbeddedSubtitleStyle(_ style: SubtitleStyle)
    /// Output volume, 0…1, and mute. Audio only: never touches the video output.
    func setVolume(_ volume: Float, muted: Bool)
    /// Shifts the sound against the picture (positive plays it later).
    func setAudioDelay(_ seconds: TimeInterval)
    /// True when `setAudioDelay` does something (VLC).
    var supportsAudioDelay: Bool { get }
    /// Lines to draw into the picture itself (Picture in Picture, AirPlay),
    /// nil for none. Called whenever the line or the style changes.
    func setSubtitleBurnIn(_ burnIn: SubtitleBurnIn?)
    /// The lines of the selected embedded text track the engine knows so far,
    /// on the file's clock (VLC: read from the file around the playhead;
    /// AVPlayer: the ones shown so far). For the Lines page and ⇧← ⇧→.
    func embeddedSubtitleCues() -> [SubtitleCue]
}

public extension PlaybackEngine {
    func selectSecondaryEmbeddedSubtitle(_ trackID: String?) {}
    func setEmbeddedSubtitleDelay(_ seconds: TimeInterval) {}
    func setEmbeddedSubtitleStyle(_ style: SubtitleStyle) {}
    func setVolume(_ volume: Float, muted: Bool) {}
    func setAudioDelay(_ seconds: TimeInterval) {}
    var supportsAudioDelay: Bool { false }
    func setSubtitleBurnIn(_ burnIn: SubtitleBurnIn?) {}
    func embeddedSubtitleCues() -> [SubtitleCue] { [] }
}

/// Engine details for the info panel. Every field is optional because each
/// engine knows different things.
public struct PlaybackDiagnostics: Equatable, Sendable {
    public var engine: String
    /// Container or stream kind ("MKV", "HLS", "MP4").
    public var container: String?
    /// Video codec, when known ("HEVC", "H.264").
    public var videoCodec: String?
    /// Bits per second the stream is being read at (observed or indicated).
    public var bitrate: Double?
    /// Frames dropped so far.
    public var droppedFrames: Int?
    /// Where the bytes come from ("Local file", "Torrent", "Network").
    public var source: String?
    public init(engine: String, container: String? = nil, videoCodec: String? = nil, bitrate: Double? = nil,
                droppedFrames: Int? = nil, source: String? = nil) {
        self.engine = engine; self.container = container; self.videoCodec = videoCodec
        self.bitrate = bitrate; self.droppedFrames = droppedFrames; self.source = source
    }

    /// "Local file", "Torrent" or "Network", from a playback URL.
    public static func sourceKind(of url: URL?) -> String? {
        guard let url else { return nil }
        if url.isFileURL { return "Local file" }
        if url.scheme == "bluebox-torrent" { return "Torrent" }
        if url.scheme == "http", url.host == "127.0.0.1" || url.host == "localhost" { return "Torrent" }
        return "Network"
    }

    /// "8.4 Mbps", "640 kbps".
    public static func formatBitrate(_ bps: Double) -> String {
        bps >= 1_000_000 ? String(format: "%.1f Mbps", bps / 1_000_000) : String(format: "%.0f kbps", bps / 1000)
    }
}

public extension PlaybackEngine {
    func setVideoAdjustments(_ adjustments: VideoAdjustments) {}
    func stepFrame(by count: Int) {}
    func captureFrame() async -> CGImage? { nil }
    func scrub(to seconds: TimeInterval) { Task { await seek(to: seconds) } }
    func diagnostics() -> PlaybackDiagnostics { PlaybackDiagnostics(engine: "Player") }
    func setAudioEffects(_ effects: AudioEffects) {}
}

public extension PlaybackEngine {
    static func canAttempt(container: String?) -> Bool {
        guard let c = container?.lowercased(), !c.isEmpty else { return true }  // unknown: let the engine decide
        return supportedContainers.contains(c)
    }
}
