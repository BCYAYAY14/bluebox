import Domain
@testable import Features
import Foundation
import Playback
import Testing
import TorrentStreaming

@Suite struct PlaybackStatsTests {
    func vlcTorrent() -> PlaybackStatsInput {
        var d = PlaybackDiagnostics(engine: "VLC", container: "MKV", videoCodec: "HEVC", bitrate: 18_400_000, droppedFrames: 3)
        d.videoSize = CGSize(width: 3840, height: 2160); d.frameRate = 24000 / 1001
        d.dynamicRange = .hdr10; d.colour = "PQ · BT.2020"; d.bitDepth = 10
        d.audioCodec = "E-AC-3"; d.audioChannels = 6; d.audioSampleRate = 48000
        d.displayedFrames = 31_442; d.lateFrames = 12; d.decodedFrames = 31_460; d.readBytes = 1_860_000_000; d.readRate = 2_300_000
        var s = PlaybackSnapshot()
        s.status = .playing; s.position = 1312; s.duration = 3200; s.bufferedUntil = 1348; s.rate = 1
        var i = PlaybackStatsInput(diagnostics: d, snapshot: s)
        i.source = "Torrent from an add-on"
        i.title = "Severance · S2 E3"
        i.releaseName = "Severance.S02E03.2160p.ATVP.WEB-DL.DDP5.1.HDR.H.265-FLUX.mkv"
        i.audioTrack = "English (1 of 3)"
        i.subtitle = "English · SRT · file"
        i.subtitleOffset = 0.4
        i.audioDelay = 0
        i.swarm = SwarmStats(connectedPeers: 42, seeds: 11, downloadRate: 3_100_000, fileProgress: 0.37)
        i.piecesAhead = .init(bytes: 96_000_000, seconds: 42)
        return i
    }

    func avPlayerFile() -> PlaybackStatsInput {
        var d = PlaybackDiagnostics(engine: "AVPlayer", container: "MP4", videoCodec: "H.264", bitrate: nil, droppedFrames: nil)
        d.videoSize = CGSize(width: 1920, height: 1080); d.frameRate = 25; d.dynamicRange = .sdr; d.colour = "BT.709"; d.bitDepth = 8
        d.audioCodec = "AAC"; d.audioChannels = 2; d.audioSampleRate = 44100
        var s = PlaybackSnapshot()
        s.status = .paused; s.position = 494; s.duration = 2520
        var i = PlaybackStatsInput(diagnostics: d, snapshot: s)
        i.source = "Jellyfin"
        i.subtitle = "Off"
        return i
    }

    @Test func summaryReadsLikeTheMockup() {
        #expect(PlaybackStats.summary(vlcTorrent()) == [
            "VLC · MKV · Torrent from an add-on",
            "HEVC · 3840 × 2160 · 23.976 fps · HDR10",
            "E-AC-3 5.1 · 48 kHz · English",
            "18.4 Mbps · 36 s ahead · 3 dropped",
        ])
        #expect(PlaybackStats.summary(avPlayerFile()) == [
            "AVPlayer · MP4 · Jellyfin", "H.264 · 1920 × 1080 · 25 fps · SDR", "AAC Stereo · 44.1 kHz",
        ])
    }

    @Test func sectionsHaveHeadlinesAndEveryRow() {
        let sections = PlaybackStats.sections(vlcTorrent())
        #expect(sections.map(\.title) == ["Video", "Audio", "Subtitles", "Stream", "Frames", "Buffer", "Torrent", "Sync"])
        #expect(sections.map(\.headline) == ["HEVC 4K HDR10", "E-AC-3 5.1", "English · SRT · file", "18.4 Mbps", "3 dropped", "36 s ahead",
                                             "42 peers", "21:52 / 53:20"])
        let rows = Dictionary(sections.flatMap(\.rows).map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(rows["Dynamic range"] == "HDR10 · PQ · BT.2020")
        #expect(rows["Bit depth"] == "10-bit")
        #expect(rows["Displayed"] == "31,442")
        #expect(rows["Read"] == "2.3 MB/s")
        #expect(rows["Read so far"] == "1.86 GB")
        #expect(rows["Pieces ahead"] == "96.0 MB · about 0:42")
        #expect(rows["File"] == "37 % downloaded")
        #expect(rows["Offset"] == "+0.4 s")
        #expect(rows["Audio delay"] == "0 ms")
        #expect(rows["Seeking"] == "No")
    }

    @Test func rowsTheEngineCantFillAreLeftOut() {
        let sections = PlaybackStats.sections(avPlayerFile())
        let labels = sections.flatMap(\.rows).map(\.label)
        #expect(!sections.map(\.title).contains("Frames"))  // no access log for a file: nothing to show
        #expect(!sections.map(\.title).contains("Torrent"))
        for missing in ["Displayed", "Late", "Decoded", "Audio delay", "Bitrate", "Read"] { #expect(!labels.contains(missing)) }
        #expect(sections.first { $0.title == "Audio" }?.rows.map(\.label) == ["Codec", "Channels", "Sample rate"])  // no track list
        #expect(!sections.flatMap(\.rows).contains { $0.value.isEmpty || $0.value == "–" })
        // Words are translated, names and numbers aren't.
        let channels = sections.flatMap(\.rows).first { $0.label == "Channels" }
        #expect(channels?.value == "Stereo" && channels?.translatesValue == true)
        #expect(sections.first { $0.title == "Subtitles" }?.translatesHeadline == true)
    }

    @Test func sourcesAreNamedByKindNeverByAddress() {
        let addons = SourceID("addons")
        func res(_ source: String, _ url: String) -> PlaybackResource {
            PlaybackResource(variant: MediaVariant(id: "x", sourceID: SourceID(source), mediaKey: nil, displayName: "x", container: "mkv",
                                                   location: .remote), url: URL(string: url)!)
        }
        #expect(PlaybackStats.sourceKind(of: res("addons", "http://127.0.0.1:8090/stream/1"), kind: nil, addonsID: addons) == "Torrent from an add-on")
        #expect(PlaybackStats.sourceKind(of: res("addons", "https://cdn.real-debrid.com/d/ABC/x.mkv"), kind: nil, addonsID: addons)
            == "Debrid link from an add-on")
        #expect(PlaybackStats.sourceKind(of: res("debrid-library", "https://x.invalid/a"), kind: nil, addonsID: addons) == "Debrid library")
        #expect(PlaybackStats.sourceKind(of: res("jellyfin-1a2b", "https://media.example.net/Videos/1"), kind: .jellyfin, addonsID: addons) == "Jellyfin")
        #expect(PlaybackStats.sourceKind(of: res("webdav-9", "https://nas.local/x.mkv"), kind: .webdav, addonsID: addons) == "WebDAV")
        #expect(PlaybackStats.sourceKind(of: res("downloads", "file:///Users/sam/x.mkv"), kind: nil, addonsID: addons) == "Download")
        #expect(PlaybackStats.sourceKind(of: res("mystery", "file:///Users/sam/x.mkv"), kind: nil, addonsID: addons) == "Local file")
        #expect(PlaybackStats.sourceKind(of: nil, kind: nil, addonsID: addons) == nil)
    }

    @Test func piecesAheadRunToTheEndOfTheRangeAtThePlayhead() {
        let ranges = TorrentFileRanges(length: 1_000, ranges: [0..<300, 500..<800])
        let ahead = PlaybackStats.piecesAhead(ranges: ranges, position: 60, duration: 100)
        #expect(ahead == .init(bytes: 200, seconds: 20))
        #expect(PlaybackStats.piecesAhead(ranges: ranges, position: 40, duration: 100) == .init(bytes: 0, seconds: 0))
        #expect(PlaybackStats.piecesAhead(ranges: ranges, position: 40, duration: nil) == nil)
        #expect(PlaybackStats.piecesAhead(ranges: nil, position: 40, duration: 100) == nil)
    }

    @Test func historyKeepsAMinuteAndScales() {
        var h = StatsHistory()
        for n in 0..<75 { h.add(bitrate: Double(n), buffer: nil, download: 5) }
        #expect(h.bitrate.count == 60 && h.bitrate.first == 15 && h.bitrate.last == 74)
        #expect(h.buffer.allSatisfy { $0 == 0 })
        #expect(StatsHistory.normalized(h.buffer).isEmpty)
        #expect(StatsHistory.normalized([2, 4]) == [0.5, 1])
        #expect(StatsHistory.normalized([15, 15], floor: 30) == [0.5, 0.5])
    }

    // MARK: The copied report

    @Test func reportHasTheTitleReleaseAndEverySection() {
        var i = vlcTorrent()
        i.events = [PlaybackEvent(id: 0, position: 0, date: Date(), title: "Opened", detail: "MKV", kind: .info),
                    PlaybackEvent(id: 1, position: 1291, date: Date(), title: "Buffering", detail: "2.1 s", kind: .warning)]
        let text = PlaybackStats.report(i, app: "Bluebox 1.2.4 (1)", system: "macOS 27.0", device: "Mac15,3",
                                        at: Date(timeIntervalSince1970: 1_793_000_000))
        #expect(text.hasPrefix("Bluebox diagnostics\nBluebox 1.2.4 (1) · macOS 27.0 · Mac15,3 · "))
        #expect(text.contains("Title: Severance · S2 E3 · Release: Severance.S02E03.2160p.ATVP.WEB-DL.DDP5.1.HDR.H.265-FLUX.mkv"))
        #expect(text.contains("Status: Playing"))
        for section in ["Video", "Audio", "Subtitles", "Stream", "Frames", "Buffer", "Torrent", "Sync"] { #expect(text.contains("\n\(section)\n")) }
        #expect(text.contains("  Dynamic range:   HDR10 · PQ · BT.2020"))
        #expect(text.contains("     21:31  * Buffering: 2.1 s"))  // newest first, warnings marked
        #expect(text.contains("      0:00    Opened: MKV"))
        #expect(text.hasSuffix("Errors: none"))
    }

    @Test func reportLeavesOutLinksKeysAddressesPathsAndServers() {
        var i = vlcTorrent()
        let key = "ABCDEF1234567890ABCDEF1234567890ABCD"
        i.releaseName = "Severance.S02E03.mkv"
        i.subtitle = "English · SRT · file"
        i.snapshot.status = .failed(.unreachable("Couldn't open https://api.real-debrid.com/rest/1.0/unrestrict?auth_token=\(key)"))
        i.events = [
            PlaybackEvent(id: 0, position: 3729, date: Date(), title: "Error",
                          detail: "Could not connect to media.example.net (192.168.1.20:8096) for sam@example.com", kind: .error),
            PlaybackEvent(id: 1, position: 10, date: Date(), title: "Subtitles failed",
                          detail: "No file at /Users/sam/Movies/Private Stuff/sub.srt or magnet:?xt=urn:btih:\(String(repeating: "c0ffee", count: 6))",
                          kind: .error),
            PlaybackEvent(id: 2, position: 20, date: Date(), title: "Error", detail: "Server [fe80::1c2b:3cff:fe4d:5e6f] refused token=\(key)",
                          kind: .error),
        ]
        let text = PlaybackStats.report(i, app: "Bluebox 1.2.4", system: "macOS 27.0", device: "Mac15,3", at: Date())
        for leak in ["http", "real-debrid.com", "auth_token", key, "media.example.net", "192.168.1.20", "8096", "sam@example.com",
                     "/Users", "sam/", "Private Stuff", "magnet", "c0ffee", "fe80", "token="] {
            #expect(!text.contains(leak), "\(leak) is in the report")
        }
        #expect(text.contains("Release: Severance.S02E03.mkv"))
        #expect(text.contains("1:02:09"))  // playback times survive
        #expect(text.contains("sub.srt"))
        #expect(text.contains("Errors: 3"))
    }

    @Test func redactKeepsReleaseNamesAndTimes() {
        let home = "/Users/brianc"
        #expect(PlaybackStats.redact("Life.of.Brian.1979.1080p.BluRay.x264-GROUP.mkv at 1:02:09", home: home)
            == "Life.of.Brian.1979.1080p.BluRay.x264-GROUP.mkv at 1:02:09")
        #expect(PlaybackStats.redact("\(home)/Movies/Film.mkv", home: home) == "Film.mkv")
        #expect(PlaybackStats.redact("see bluebox-torrent://abc/1?x=y", home: home) == "see (link)")
        #expect(PlaybackStats.redact("key 9f8e7d6c5b4a39281706f5e4d3c2b1a0", home: home) == "key (key)")
        #expect(PlaybackStats.redact("HEVC Main 10 · 23.976 fps · 18.4 Mbps · 5.1", home: home) == "HEVC Main 10 · 23.976 fps · 18.4 Mbps · 5.1")
        #expect(PlaybackStats.redactHosts("Could not connect to plex.direct.home or nas.local") == "Could not connect to (server) or (server)")
    }
}
