#if os(macOS)
import AppKit
import Domain
@testable import Features
import Foundation
import Persistence
import Playback
import SwiftUI
import Testing
import TorrentStreaming

/// Draws the player's Stats card offscreen over a dark backdrop and saves a
/// PNG of each case, for design review without a real stream. Runs only when
/// /tmp/bluebox-stats-shots exists.
@MainActor
@Suite struct PlayerStatsSnapshotTests {
    nonisolated static let folder = "/tmp/bluebox-stats-shots"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: PlayerStatsSnapshotTests.folder)))
    func snapshotStatsCard() async throws {
        let app = AppModel.demo()
        await app.bootstrap()
        let torrent = PlaybackResource(
            variant: MediaVariant(id: "r", sourceID: app.addons.id, mediaKey: nil,
                                  displayName: "Severance.S02E03.2160p.ATVP.WEB-DL.DDP5.1.HDR.H.265-FLUX.mkv", container: "mkv", location: .remote),
            url: URL(string: "http://127.0.0.1:8090/stream/abc")!)
        let jellyfin = PlaybackResource(
            variant: MediaVariant(id: "j", sourceID: SourceID("opened-files"), mediaKey: nil, displayName: "The Bear S03E01.mp4",
                                  container: "mp4", location: .remote),
            url: URL(fileURLWithPath: "/tmp/The Bear S03E01.mp4"))
        let swarm = SwarmStats(connectedPeers: 42, seeds: 11, knownPeers: 120, downloadRate: 3_100_000, downloadedBytes: 1_700_000_000,
                               fileProgress: 0.37)
        let ranges = TorrentFileRanges(length: 4_600_000_000, ranges: [0..<1_980_000_000])
        let cases: [(String, StatsTestEngine, PlaybackResource, SwarmStats?, String)] = [
            ("vlc-torrent", .vlc, torrent, swarm, "Video,Buffer,Torrent"),
            ("vlc-all-open", .vlc, torrent, swarm, "Video,Audio,Subtitles,Stream,Frames,Buffer,Torrent,Sync"),
            ("avplayer-file", .avPlayer, jellyfin, nil, "Video,Frames,Sync"),
            ("vlc-folded", .vlc, torrent, swarm, ""),
        ]
        for (name, engine, resource, swarm, open) in cases {
            UserDefaults.standard.set(open, forKey: "playerStatsOpenSections")
            let player = PlayerSession(engine: engine, progress: try LibraryStore.make(inMemory: true))
            await player.start(NowPlayingItem(key: .movie(tmdbID: 1), title: "Severance", subtitle: "S2 E3"), resource: resource)
            await player.seek(to: 1290)
            engine.snapshot.status = .buffering
            try await Task.sleep(for: .milliseconds(30))
            engine.snapshot.status = .playing
            engine.snapshot.position = 1312
            engine.snapshot.bufferedUntil = 1348
            let height: CGFloat = name == "vlc-all-open" ? 760 : 470
            let view = ZStack(alignment: .topLeading) {
                Color(white: 0.12)
                PlayerStatsCard(session: player, swarm: swarm, fileRanges: swarm == nil ? nil : ranges, maxHeight: height - 32,
                                onCopied: {}, onClose: {})
                    .padding(16)
            }
            .frame(width: 302, height: height)
            .environment(app)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 302, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(3500))  // a few graph samples
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(Self.folder)/\(name).png"))
            window.orderOut(nil)
            await player.end()
        }
        UserDefaults.standard.removeObject(forKey: "playerStatsOpenSections")
    }
}

/// Reports what VLC or AVPlayer would for a 4K HDR torrent or an MP4 file,
/// with a bitrate that moves so the graph has something to draw.
@MainActor
final class StatsTestEngine: PlaybackEngine {
    static let supportedContainers: Set<String> = ["mp4", "mkv"]
    static var vlc: StatsTestEngine { StatsTestEngine(isVLC: true) }
    static var avPlayer: StatsTestEngine { StatsTestEngine(isVLC: false) }
    let isVLC: Bool
    var snapshot = PlaybackSnapshot() { didSet { onChange?(snapshot) } }
    var onChange: ((PlaybackSnapshot) -> Void)?
    private var reads = 0
    init(isVLC: Bool) { self.isVLC = isVLC }

    func load(_ resource: PlaybackResource, startAt: TimeInterval?) async throws {
        var s = PlaybackSnapshot()
        s.status = .paused; s.duration = isVLC ? 3200 : 2520; s.position = 0
        s.audioTracks = [MediaTrack(id: "a1", kind: .audio, label: "English", languageCode: "en"),
                         MediaTrack(id: "a2", kind: .audio, label: "French", languageCode: "fr"),
                         MediaTrack(id: "a3", kind: .audio, label: "Commentary", languageCode: "en")]
        s.selectedAudioID = "a1"
        snapshot = s
    }
    func play() { snapshot.status = .playing }
    func pause() { snapshot.status = .paused }
    func seek(to seconds: TimeInterval) async { snapshot.position = seconds }
    func setRate(_ rate: Float) { snapshot.rate = rate }
    func selectAudio(_ trackID: String?) { snapshot.selectedAudioID = trackID }
    func selectEmbeddedSubtitle(_ trackID: String?) {}
    func stop() { snapshot.status = .idle }
    var supportsAudioDelay: Bool { isVLC }
    func diagnostics() -> PlaybackDiagnostics {
        reads += 1
        let wobble = Double([0, 3, -2, 5, 1, -3, 4][reads % 7]) * 1_000_000
        var d = PlaybackDiagnostics(engine: isVLC ? "VLC" : "AVPlayer", container: isVLC ? "MKV" : "MP4",
                                    videoCodec: isVLC ? "HEVC" : "H.264", bitrate: (isVLC ? 18_400_000 : 6_200_000) + wobble,
                                    droppedFrames: isVLC ? 3 : 0, source: nil)
        d.videoSize = isVLC ? CGSize(width: 3840, height: 2160) : CGSize(width: 1920, height: 1080)
        d.frameRate = isVLC ? 24000 / 1001 : 25
        d.dynamicRange = isVLC ? .hdr10 : .sdr
        d.colour = isVLC ? "PQ · BT.2020" : "BT.709"
        d.bitDepth = isVLC ? 10 : 8
        d.audioCodec = isVLC ? "E-AC-3" : "AAC"
        d.audioChannels = isVLC ? 6 : 2
        d.audioSampleRate = 48000
        if isVLC {
            d.displayedFrames = 31_442; d.lateFrames = 12; d.decodedFrames = 31_460
            d.readRate = 2_300_000; d.readBytes = 1_860_000_000
        } else {
            d.readBytes = 412_000_000; d.stalls = 0
        }
        return d
    }
}
#endif
