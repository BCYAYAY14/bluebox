import Domain
import Foundation
import Playback
import TorrentStreaming

/// Everything the Stats card and the copied diagnostics report show, read
/// once a second from the engine, the player session and the torrent.
struct PlaybackStatsInput: Equatable {
    var diagnostics: PlaybackDiagnostics
    var snapshot: PlaybackSnapshot
    /// What kind of place the video comes from ("Torrent from an add-on", "Jellyfin").
    var source: String?
    /// "Severance · S2 E3", for the report.
    var title: String?
    /// The release's or file's name, without its folder.
    var releaseName: String?
    /// "English (1 of 3)".
    var audioTrack: String?
    /// "English · SRT · file", or "Off".
    var subtitle: String?
    var subtitleOffset: TimeInterval = 0
    /// Nil when the engine can't delay the sound (AVPlayer).
    var audioDelay: TimeInterval?
    /// "No", "Scrubbing" or "Seeking to 21:10".
    var seeking: String = "No"
    var swarm: SwarmStats?
    /// The downloaded part of the file just ahead of the playhead.
    var piecesAhead: PiecesAhead?
    var events: [PlaybackEvent] = []
    var stalls = 0
    var stalledFor: TimeInterval = 0

    struct PiecesAhead: Equatable {
        var bytes: Int64
        var seconds: TimeInterval?
    }
}

/// A row of the Stats card. Rows the engine can't fill aren't made.
struct StatsRow: Equatable, Identifiable {
    var label: String
    var value: String
    /// The value is a word Bluebox translates ("Off", "Stereo"), not a name or a number.
    var translatesValue = false
    var id: String { label }
}

/// A folding section of the Stats card, with the headline shown while it's folded.
struct StatsSection: Equatable, Identifiable {
    var title: String
    var headline: String?
    var rows: [StatsRow]
    /// The headline is a word Bluebox translates ("Off").
    var translatesHeadline = false
    var id: String { title }
}

enum PlaybackStats {
    // MARK: The card

    /// Four lines anyone can read: engine and source; video; audio; rate, buffer and drops.
    static func summary(_ i: PlaybackStatsInput) -> [String] {
        let d = i.diagnostics
        let first = [d.engine, d.container, i.source].compactMap { $0 }.joined(separator: " · ")
        let video = [d.videoCodec, size(i).map { "\(Int($0.width)) × \(Int($0.height))" }, d.frameRate.map(PlaybackDiagnostics.formatFrameRate),
                     d.dynamicRange?.rawValue].compactMap { $0 }.joined(separator: " · ")
        let audio = [d.audioCodec.map { codec in [codec, d.audioChannels.map(PlaybackDiagnostics.channelLayout)].compactMap { $0 }.joined(separator: " ") },
                     d.audioSampleRate.map(sampleRate), i.audioTrack.map(trackName)].compactMap { $0 }.joined(separator: " · ")
        let live = [d.bitrate.map(PlaybackDiagnostics.formatBitrate), ahead(i).map { "\($0) ahead" },
                    d.droppedFrames.map { "\($0) dropped" }].compactMap { $0 }.joined(separator: " · ")
        return [first, video, audio, live].filter { !$0.isEmpty }
    }

    static func sections(_ i: PlaybackStatsInput) -> [StatsSection] {
        let d = i.diagnostics, s = i.snapshot
        var out: [StatsSection] = []
        func add(_ title: String, _ headline: String?, _ rows: [StatsRow?]) {
            let rows = rows.compactMap { $0 }
            if !rows.isEmpty { out.append(StatsSection(title: title, headline: headline, rows: rows, translatesHeadline: headline == "Off")) }
        }
        func row(_ label: String, _ value: String?, word: Bool = false) -> StatsRow? {
            value.flatMap { $0.isEmpty ? nil : StatsRow(label: label, value: $0, translatesValue: word) }
        }
        let resolution = size(i).map { "\(Int($0.width)) × \(Int($0.height))" }
        let sizeWord: String? = size(i).flatMap { sizeName($0) }
        add("Video", [d.videoCodec, sizeWord, d.dynamicRange?.rawValue].compactMap { $0 }.joined(separator: " "), [
            row("Codec", d.videoCodec),
            row("Resolution", resolution),
            row("Frame rate", d.frameRate.map(PlaybackDiagnostics.formatFrameRate)),
            row("Dynamic range", [d.dynamicRange?.rawValue, d.colour].compactMap { $0 }.joined(separator: " · ")),
            row("Bit depth", d.bitDepth.map { "\($0)-bit" }),
        ])
        let channels = d.audioChannels.map(PlaybackDiagnostics.channelLayout)
        add("Audio", [d.audioCodec, channels].compactMap { $0 }.joined(separator: " "), [
            row("Codec", d.audioCodec),
            row("Channels", channels, word: d.audioChannels.map { $0 <= 2 } ?? false),
            row("Sample rate", d.audioSampleRate.map(sampleRate)),
            row("Track", i.audioTrack),
        ])
        add("Subtitles", i.subtitle, [
            row("Track", i.subtitle, word: i.subtitle == "Off"),
            row("Offset", offset(i.subtitleOffset)),
        ])
        add("Stream", d.bitrate.map(PlaybackDiagnostics.formatBitrate), [
            row("Engine", d.engine),
            row("Source", i.source, word: true),
            row("Container", d.container),
            row("Bitrate", d.bitrate.map(PlaybackDiagnostics.formatBitrate)),
            row("Read", d.readRate.map { bytes(Int64($0)) + "/s" }),
            row("Read so far", d.readBytes.map(bytes)),
        ])
        add("Frames", d.droppedFrames.map { "\($0) dropped" }, [
            row("Displayed", d.displayedFrames.map(count)),
            row("Dropped", d.droppedFrames.map(count)),
            row("Late", d.lateFrames.map(count)),
            row("Decoded", d.decodedFrames.map(count)),
        ])
        let stalls = d.stalls ?? i.stalls
        add("Buffer", ahead(i).map { "\($0) ahead" }, [
            row("Ahead", ahead(i)),
            row("Filling", s.bufferFill.map { "\(Int(($0 * 100).rounded())) %" }),
            row("Stalls", i.stalledFor >= 0.1 && d.stalls == nil ? "\(stalls) (\(PlaybackEventLog.duration(i.stalledFor)))" : "\(stalls)"),
        ])
        if let w = i.swarm {
            add("Torrent", "\(w.connectedPeers) peers", [
                row("Peers", "\(w.connectedPeers) (\(w.seeds) seeds)"),
                row("Download", bytes(Int64(w.downloadRate)) + "/s"),
                row("Pieces ahead", i.piecesAhead.map { p in
                    [bytes(p.bytes), p.seconds.map { "about \(PlaybackEventLog.clock($0))" }].compactMap { $0 }.joined(separator: " · ")
                }),
                row("File", "\(Int((w.fileProgress * 100).rounded())) % downloaded"),
            ])
        }
        add("Sync", position(i), [
            row("Position", position(i)),
            row("Speed", PlayerSession.rateLabel(s.rate)),
            row("Audio delay", i.audioDelay.map { "\(Int(($0 * 1000).rounded())) ms" }),
            row("Subtitle offset", offset(i.subtitleOffset)),
            row("Seeking", i.seeking, word: i.seeking == "No" || i.seeking == "Scrubbing"),
        ])
        return out
    }

    // MARK: The report

    /// The plain-text report Copy Diagnostics puts on the clipboard: English,
    /// for bug reports, with no links, server names, keys, paths or names of
    /// people or devices (`redact`).
    static func report(_ i: PlaybackStatsInput, app: String, system: String, device: String, at date: Date) -> String {
        var lines = ["Bluebox diagnostics", "\(app) · \(system) · \(device) · \(stamp(date))"]
        let title = i.title.map { "Title: \($0)" }
        let release = i.releaseName.map { "Release: \($0)" }
        let named = [title, release].compactMap { $0 }.joined(separator: " · ")
        if !named.isEmpty { lines.append(named) }
        lines.append("Status: " + redactHosts(status(i.snapshot.status)))
        lines.append("")
        for section in sections(i) {
            lines.append(section.title)
            for row in section.rows { lines.append("  " + (row.label + ":").padding(toLength: 17, withPad: " ", startingAt: 0) + row.value) }
        }
        lines.append("")
        lines.append("Timeline (playback time · what happened)")
        if i.events.isEmpty { lines.append("  (nothing yet)") }
        for e in i.events.reversed() {
            let mark = e.kind == .error ? "! " : e.kind == .warning ? "* " : "  "
            let detail = e.detail.map { ": " + redactHosts($0) } ?? ""
            lines.append("  " + PlaybackEventLog.clock(e.position).leftPadded(to: 8) + "  " + mark + e.title + detail)
        }
        let errors = i.events.filter { $0.kind == .error }
        lines.append("")
        lines.append(errors.isEmpty ? "Errors: none" : "Errors: \(errors.count)")
        return redact(lines.joined(separator: "\n"))
    }

    /// Takes out anything that could reach a server or name someone: links
    /// (with their tokens), email addresses, IP addresses, the folders of file
    /// paths (with the home folder and so the user's name) and long keys.
    /// Release names, codecs and playback times stay.
    static func redact(_ text: String, home: String = NSHomeDirectory()) -> String {
        var t = text
        if !home.isEmpty, home != "/" { t = t.replacingOccurrences(of: home, with: "~") }
        let rules: [(String, String)] = [
            // Any URL, whatever the scheme (http, magnet, bluebox-torrent, smb, file…).
            (#"\b[A-Za-z][A-Za-z0-9+.\-]{1,20}:(//|\?)[^\s"'<>]*"#, "(link)"),
            (#"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#, "(email)"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"#, "(address)"),
            // IPv6: eight groups, or fewer around "::" (never a playback time like 1:02:09).
            (#"\[?\b(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}\b\]?"#, "(address)"),
            (#"\[?(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{0,4}::(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{0,4}\]?(?:%\w+)?"#, "(address)"),
            // Folders: "/Users/…/file.mkv", "~/Movies/…", "C:\…" keep only the last part.
            // Folder names can have spaces: everything up to the last slash goes.
            (#"(?:~|/(?:Users|home|private|var|Volumes|tmp|Library|mnt|media|storage)|[A-Z]:\\)(?:[^\n"'/\\]*[/\\])+"#, ""),
            // Query strings and fragments left from a link cut short.
            (#"[?&#][A-Za-z0-9_\-]+=[^\s&]*"#, ""),
            (#"\b(?:access_token|auth_token|api_?key|apikey|token|auth|key|password|secret)\s*[=:]\s*[^\s&,;)]+"#, "(key)"),
            // Keys and tokens: long runs of letters and digits with no spaces.
            (#"\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{24,}\b"#, "(key)"),
        ]
        for (pattern, replacement) in rules {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return t
    }

    /// Server names in error messages ("Could not connect to media.example.net").
    /// Only for messages: release names have dots too, and stay.
    static func redactHosts(_ text: String) -> String {
        text.replacingOccurrences(of: #"\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#, with: "(email)", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(
            of: #"\b(?:[a-z0-9](?:[a-z0-9\-]*[a-z0-9])?\.)+(?:com|net|org|io|me|tv|app|dev|co|uk|de|fr|nl|eu|ca|au|us|info|biz|xyz|cloud|local|lan|home|arpa|internal)\b"#,
            with: "(server)", options: [.regularExpression, .caseInsensitive])
    }

    // MARK: Sources

    /// What kind of place a resource comes from, in words: never its address.
    static func sourceKind(of resource: PlaybackResource?, kind: SourceKind?, addonsID: SourceID) -> String? {
        guard let resource else { return nil }
        let id = resource.variant.sourceID
        let local = resource.url.host == "127.0.0.1" || resource.url.host == "localhost" || resource.url.scheme == "bluebox-torrent"
        if id == addonsID { return local ? "Torrent from an add-on" : "Debrid link from an add-on" }
        switch id.rawValue {
        case "debrid-library": return "Debrid library"
        case "downloads": return "Download"
        case "opened-files": return "Opened file"
        case "direct-urls": return "Direct link"
        case "public-catalog": return "Open Movies"
        default: break
        }
        switch kind {
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        case .webdav: return "WebDAV"
        case .localFolder: return "Local folder"
        case .torrent: return "Torrent"
        case .downloads: return "Download"
        case .directURL: return "Direct link"
        case .publicCatalog: return "Open Movies"
        case .addons: return local ? "Torrent from an add-on" : "Debrid link from an add-on"
        case nil: return resource.url.isFileURL ? "Local file" : local ? "Torrent" : "Network"
        }
    }

    /// The downloaded bytes from the playhead to the end of the range it's in.
    static func piecesAhead(ranges: TorrentFileRanges?, position: TimeInterval, duration: TimeInterval?) -> PlaybackStatsInput.PiecesAhead? {
        guard let ranges, ranges.length > 0, let duration, duration > 0 else { return nil }
        let at = Int64(Double(ranges.length) * min(max(position / duration, 0), 1))
        guard let range = ranges.ranges.first(where: { $0.contains(at) }) else { return PlaybackStatsInput.PiecesAhead(bytes: 0, seconds: 0) }
        let bytes = range.upperBound - at
        return PlaybackStatsInput.PiecesAhead(bytes: bytes, seconds: Double(bytes) / Double(ranges.length) * duration)
    }

    // MARK: Words for numbers

    static func size(_ i: PlaybackStatsInput) -> CGSize? {
        if let s = i.diagnostics.videoSize { return s }
        return i.snapshot.presentationSize == .zero ? nil : i.snapshot.presentationSize
    }

    /// "4K", "1080p", "720p", or nil for other sizes.
    static func sizeName(_ s: CGSize) -> String? {
        switch max(s.width, s.height) {
        case 3800...: "4K"
        case 1900..<3800: "1080p"
        case 1260..<1900: "720p"
        default: nil
        }
    }

    static func ahead(_ i: PlaybackStatsInput) -> String? {
        let s = i.snapshot
        guard s.bufferedUntil > s.position else { return nil }
        return "\(Int((s.bufferedUntil - s.position).rounded())) s"
    }

    static func position(_ i: PlaybackStatsInput) -> String {
        let p = PlaybackEventLog.clock(i.snapshot.position)
        return i.snapshot.duration.map { "\(p) / \(PlaybackEventLog.clock($0))" } ?? p
    }

    static func sampleRate(_ hz: Int) -> String {
        hz % 1000 == 0 ? "\(hz / 1000) kHz" : String(format: "%.1f kHz", Double(hz) / 1000)
    }

    static func offset(_ seconds: TimeInterval) -> String {
        seconds == 0 ? "0 s" : String(format: "%+.1f s", seconds)
    }

    static func count(_ n: Int) -> String { n.formatted(.number.locale(Locale(identifier: "en_US"))) }

    static func bytes(_ n: Int64) -> String {
        let n = max(0, Double(n))
        switch n {
        case 1_000_000_000...: return String(format: "%.2f GB", n / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1f MB", n / 1_000_000)
        case 1000...: return String(format: "%.0f KB", n / 1000)
        default: return "\(Int(n)) B"
        }
    }

    /// "English" from "English (1 of 3)", for the summary.
    private static func trackName(_ track: String) -> String {
        track.range(of: " (", options: .backwards).map { String(track[..<$0.lowerBound]) } ?? track
    }

    private static func status(_ s: PlaybackStatus) -> String {
        switch s {
        case .idle: "Idle"
        case .loading: "Loading"
        case .playing: "Playing"
        case .paused: "Paused"
        case .buffering: "Buffering"
        case .ended: "Ended"
        case .failed(let e): "Failed: \(e.localizedDescription)"
        }
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

/// The last minute of bitrate, buffer and download speed, one sample a second, for the Stats graph.
struct StatsHistory: Equatable {
    static let length = 60
    private(set) var bitrate: [Double] = []
    private(set) var buffer: [Double] = []
    private(set) var download: [Double] = []

    mutating func add(bitrate: Double?, buffer: Double?, download: Double?) {
        func push(_ list: inout [Double], _ value: Double?) {
            list.append(max(0, value ?? 0))
            if list.count > Self.length { list.removeFirst(list.count - Self.length) }
        }
        push(&self.bitrate, bitrate); push(&self.buffer, buffer); push(&self.download, download)
    }

    mutating func reset() { self = StatsHistory() }

    /// Each value over the series' largest (or `floor`, if larger), 0…1;
    /// empty when the series never rose above zero.
    static func normalized(_ values: [Double], floor: Double = 0) -> [Double] {
        guard let top = values.max().map({ max($0, floor) }), top > 0 else { return [] }
        return values.map { $0 / top }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}
