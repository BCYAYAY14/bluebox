import CoreGraphics
import Domain
import Foundation
import ImageIO
import Playback
import Subtitles
import SwiftVLC
import VLCVariables
#if os(iOS)
import AVFoundation
#endif

/// libVLC-backed engine (via SwiftVLC) for the containers AVFoundation can't
/// open: MKV, AVI, WebM and friends, which is most torrent releases.
///
/// Differences from `AVPlayerEngine`:
/// - Embedded subtitles are split. In MKV and WebM, SubRip, WebVTT and ASS
///   with no styled lines are read from the file near the playhead
///   (`EmbeddedTextFeed`), VLC's own track is turned off, and the text goes
///   out as `embeddedSubtitleText` for Bluebox's overlay, timed here with
///   the playhead, the subtitle delay and the rate. Everything else (styled
///   ASS, PGS, VobSub, DVB, and text tracks in other containers) VLC draws
///   inside the picture; text tracks among those take the user's subtitle
///   style through VLC's text renderer variables, set on the player (see
///   `VLCTextLook`): size, colour, box, outline and position change live,
///   the font and shadow from the next video. Nothing reopens the stream.
/// - No AirPlay (PiP goes through `VLCPictureInPicture`), no buffered-range reporting, no automatic stream rebuild
///   (VLC reconnects HTTP itself via `:http-reconnect`).
/// - Sharpness and invert adjustments aren't available through VLC's adjust filter.
@MainActor
public final class VLCEngine: PlaybackEngine {
    public static let supportedContainers: Set<String> = [
        "mkv", "mk3d", "mka", "mp4", "m4v", "mov", "qt", "avi", "divx", "webm", "ts", "m2ts", "mts", "m2t",
        "wmv", "asf", "flv", "f4v", "ogv", "ogg", "ogm", "mpg", "mpeg", "mpe", "m1v", "m2v", "vob", "3gp", "3g2",
        "rm", "rmvb", "dv", "mxf", "nut", "y4m", "m3u8", "mp3", "m4a", "aac", "flac", "wav", "opus",
    ]

    /// Starts libVLC's one-time plugin setup off the main thread (expensive on iOS).
    public static func prewarm() { _ = VLCInstance.prewarmShared() }

    /// The SwiftVLC player; `VLCVideoSurface` draws it. The first load makes
    /// a fresh one (the player from `init` is never given a video output); the
    /// snapshot's `outputGeneration` changes with it.
    public private(set) var player: Player
    private var audioEffects = AudioEffects()
    /// The first load has made the player that plays (see `player`).
    private var playerReady = false
    /// The native player the compressor settings were set on (Night Mode).
    private var compressorSetOn: UnsafeMutableRawPointer?
    /// The subtitle look wanted (from `setEmbeddedSubtitleStyle`).
    private var textLook = VLCTextLook(SubtitleStyle())
    /// What was last set on the native player (`appliedTo` is its handle; SwiftVLC can swap it).
    private var appliedLook: VLCTextLook?
    private var appliedTo: UnsafeMutableRawPointer?
    /// Subtitle size, VLC's `sub-text-scale` / 100. Set on the player live.
    private var subtitleTextScale: Float = 0.9
    private var subtitleDelay: TimeInterval = 0
    private var audioDelay: TimeInterval = 0
    private var volume: Float = 1
    private var muted = false
    public private(set) var snapshot = PlaybackSnapshot() {
        didSet { if snapshot != oldValue { onChange?(snapshot) } }
    }
    public var onChange: ((PlaybackSnapshot) -> Void)?

    private var resource: PlaybackResource?
    private var scopedRoot: URL?
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var adjustments = Playback.VideoAdjustments()
    private var chaptersLoaded = false

    /// The user wants playback paused. VLC drops a pause issued while it is
    /// opening or buffering and starts playing anyway, so whenever VLC reports
    /// `.playing` while this is set, the pause is issued again.
    private var intendedPaused = true
    private var lastPauseReassert: ContinuousClock.Instant?
    /// Embedded subtitle the session asked for (nil = off). Re-applied when
    /// tracks change, because VLC auto-selects "default" tracks on its own.
    private var desiredSubtitleID: String?
    private var desiredAudioID: String?
    /// Embedded track shown as the second line (one the overlay draws), nil for none.
    private var desiredSecondaryID: String?
    /// Text tracks read from the file for Bluebox's overlay (MKV and WebM).
    private var textFeed: EmbeddedTextFeed?
    private var textFeedURL: URL?
    /// The file's track behind each VLC subtitle track id (see `feedTrack`).
    private var fileTracks: [String: MatroskaTrack] = [:]
    /// The track whose every line has been asked for (`embeddedSubtitleCues`).
    private var wholeTrackRead: Int?
    /// The lines drawn into the picture (libVLC's logo overlay) for Picture in Picture.
    private var burnIn: SubtitleBurnIn?
    private var burnInFile = 0
    private var subtitleTask: Task<Void, Never>?
    /// Runs the subtitle clock between VLC's updates, never stepping back on their jitter.
    private var clock = PlayheadClock()
    /// A seek requested before the media became seekable, or the start point
    /// of media that was just opened (see `mediaOptions`).
    private var pendingSeek: TimeInterval?
    /// `pendingSeek` is the resume point passed to `load`: checked against the
    /// file's real length before use, so a point at the end starts over.
    private var pendingSeekIsResume = false
    /// How long a resume point waits for VLC to learn the length before it's used unchecked.
    private var resumeLengthDeadline: ContinuousClock.Instant?
    /// VLC was opened paused (`:start-paused`) so it can seek to the start
    /// point first. Playback continues once that seek is issued, if wanted.
    private var heldForStartSeek = false
    private var ended = false
    /// Position published right after a seek, until VLC's clock catches up.
    private var heldPosition: (time: TimeInterval, until: ContinuousClock.Instant)?
    private var lastScrub: ContinuousClock.Instant?
    private var scrubPending: TimeInterval?
    private var scrubFlush: Task<Void, Never>?
    // Stall detection: VLC can report `.playing` while the clock is frozen waiting for data.
    private var lastClock: TimeInterval = -1
    private var frozenSince: ContinuousClock.Instant?
    /// The clock while a pause is asked for (`enforcePause`).
    private var pausedClock: (time: TimeInterval, at: ContinuousClock.Instant)?
    /// Frozen picture: the clock and the sound run on but VLC shows no new
    /// frames (seen resuming mid-episode, after the start seek). Sampled once
    /// a second from VLC's displayed-picture count; a seek to the current
    /// point restarts the video, and twice in vain the media is reopened there.
    private var videoWatchdog = PlaybackWatchdog()
    private var lastVideoSample: ContinuousClock.Instant?
    private var lastDisplayedPictures: UInt64?

    /// The libVLC instance players are made on: the app's shared one, or one
    /// with its own arguments (tests capture the sound with `--aout=afile`).
    private let instance: VLCInstance

    public init(instance: VLCInstance = .shared) {
        self.instance = instance
        player = Player()
    }

    // MARK: Loading

    public func load(_ resource: PlaybackResource, startAt: TimeInterval?) async throws {
        try await loadMedia(resource, startAt: startAt)
    }

    /// Opens `resource`.
    private func loadMedia(_ resource: PlaybackResource, startAt: TimeInterval?) async throws {
        teardown()
        let container = resource.variant.container ?? resource.url.pathExtension
        guard Self.canAttempt(container: container) else {
            fail(.unsupportedFormat(container))
            throw PlaybackError.unsupportedFormat(resource.variant.container ?? "unknown")
        }
        let generation = snapshot.outputGeneration
        snapshot = PlaybackSnapshot()
        snapshot.outputGeneration = generation
        snapshot.drawsEmbeddedSubtitles = true
        snapshot.delaysEmbeddedSubtitles = true
        snapshot.status = .loading
        self.resource = resource
        intendedPaused = true  // the session calls play() after load when it wants autoplay
        // A new video starts on VLC's tracks.
        desiredSubtitleID = nil; desiredAudioID = nil; desiredSecondaryID = nil
        prepareTextFeed(for: resource)
        pendingSeek = nil; ended = false; chaptersLoaded = false
        videoWatchdog.reset(); lastVideoSample = nil; lastDisplayedPictures = nil
        pendingSeekIsResume = startAt != nil
        resumeLengthDeadline = .now + .seconds(2)
        if let startAt, startAt > 0 { snapshot.position = startAt }

        if let root = resource.securityScopedRoot, root.startAccessingSecurityScopedResource() {
            scopedRoot = root
        }
        await Self.activateAudioSession()
        guard self.resource == resource else { throw CancellationError() }
        if !playerReady {
            // The old player's decoder and video output must be gone before
            // the new one takes the surface: releasing it while they ran
            // crashed in VLC's picture pool (AV1 especially).
            await player.shutdown()
            guard self.resource == resource else { throw CancellationError() }
            player = Player(instance: instance)
            playerReady = true
            appliedTo = nil; compressorSetOn = nil
            snapshot.outputGeneration &+= 1
        }

        startObserving()
        do {
            try open(resource, startAt: startAt)
        } catch let e as PlaybackError {
            fail(e); throw e
        }
        try await waitUntilOpened(resource)
    }

    /// Creates the media with its options and starts it. VLC has no "prepared"
    /// state, so it opens by playing; `intendedPaused` holds it if needed.
    /// With a start point it opens paused and seeks there once seekable.
    private func open(_ resource: PlaybackResource, startAt: TimeInterval?) throws {
        let media: Media
        let url = Self.mediaURL(for: resource)
        do { media = try Media(url: url) } catch {
            // VLC's error names the URL, which may carry a login or token; it gets logged and shown.
            throw PlaybackError.unreachable(error.localizedDescription.replacingOccurrences(of: url.absoluteString, with: Redactor.redact(url)))
        }
        let start = startAt.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        pendingSeek = start
        heldForStartSeek = start != nil
        for option in Self.mediaOptions(for: resource, startAt: start) { media.addOption(option) }
        applyAdjustments()
        applyEqualizer()
        applyAudioFilters()
        // Before the video output and the subtitle decoder start, which read it.
        applyTextLook()
        do { try player.play(media) } catch {
            throw PlaybackError.decodeFailed(error.localizedDescription)
        }
        applyTextLook()  // play() can swap SwiftVLC's native player
        if snapshot.rate != 1 { try? player.setPlaybackRate(PlaybackRate(snapshot.rate)) }
        player.setSubtitleScale(SubtitleScale(subtitleTextScale))
        if subtitleDelay != 0 { try? player.setSubtitleDelay(.milliseconds(Int((subtitleDelay * 1000).rounded()))) }
        if audioDelay != 0 { try? player.setAudioDelay(.milliseconds(Int((audioDelay * 1000).rounded()))) }
        applyVolume()
    }

    static func mediaOptions(for resource: PlaybackResource, startAt: TimeInterval?) -> [String] {
        var options: [String] = []
        // Not `:start-time`: with it libVLC 4 reports the length minus the
        // start time and takes seeks relative to it, while the clock stays
        // absolute. A resumed episode then showed a full scrub bar with 0:00
        // left, scrubbing landed in the wrong place, and its progress was
        // saved as watched. Open paused at the beginning and seek instead.
        if let startAt, startAt > 0 { options.append(":start-paused") }
        let url = resource.url
        guard !url.isFileURL else { return options }
        let isLocalStream = url.host == "127.0.0.1" || url.host == "localhost"
        // VLC holds back this much media before the first frame. Local torrent
        // streams are already prebuffered and libtorrent reads ahead of the
        // playhead, so a shorter cache starts sooner without more stalls.
        options.append(":network-caching=\(isLocalStream ? 2500 : 3000)")
        if !isLocalStream, url.scheme?.hasPrefix("http") == true { options.append(":http-reconnect") }
        // libVLC only takes a user agent and a referrer; other headers can't be passed.
        for (name, value) in resource.httpHeaders {
            switch name.lowercased() {
            case "user-agent": options.append(":http-user-agent=\(value)")
            case "referer", "referrer": options.append(":http-referrer=\(value)")
            case "authorization" where basicLogin(value) != nil: break  // in the URL instead (`mediaURL`)
            default: Log.playback.notice("VLC ignores HTTP header \(name, privacy: .public)")
            }
        }
        return options
    }

    /// The URL VLC opens. A Basic `Authorization` header (a WebDAV login) goes
    /// in as the URL's user and password, which VLC answers the server's login
    /// challenge with; VLC can't send the header itself.
    static func mediaURL(for resource: PlaybackResource) -> URL {
        guard !resource.url.isFileURL,
              let header = resource.httpHeaders.first(where: { $0.key.lowercased() == "authorization" })?.value,
              let (user, password) = basicLogin(header),
              var c = URLComponents(url: resource.url, resolvingAgainstBaseURL: false) else { return resource.url }
        c.user = user
        c.password = password
        return c.url ?? resource.url
    }

    static func basicLogin(_ header: String) -> (String, String)? {
        guard header.lowercased().hasPrefix("basic "),
              let data = Data(base64Encoded: String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)),
              let pair = String(data: data, encoding: .utf8), let colon = pair.firstIndex(of: ":") else { return nil }
        return (String(pair[..<colon]), String(pair[pair.index(after: colon)...]))
    }

    /// Waits until VLC is playing (tracks known) or fails, like AVFoundation's asset load.
    private func waitUntilOpened(_ resource: PlaybackResource) async throws {
        let isLocal = resource.url.isFileURL
        let limit: Duration = isLocal ? .seconds(20) : .seconds(90)
        let start = ContinuousClock.now
        var openedAt: ContinuousClock.Instant?
        while true {
            try? await Task.sleep(for: .milliseconds(100))
            guard self.resource == resource else { throw CancellationError() }
            if case .failed(let e) = snapshot.status { throw e }
            switch player.state {
            case .playing, .paused:
                refresh()
                // Opened paused to seek to the start point: give the seek a
                // moment to go out, so playing starts there and not at 0:00.
                let opened = openedAt ?? .now
                openedAt = opened
                if pendingSeek == nil || ContinuousClock.now - opened > .seconds(3) { return }
            case .error:
                let e = failureError()
                fail(e); throw e
            default:
                break
            }
            if ContinuousClock.now - start > limit {
                let e = PlaybackError.unreachable("The stream didn't start in time.")
                fail(e); throw e
            }
        }
    }

    // MARK: Transport

    public func play() {
        guard let resource else { return }
        intendedPaused = false
        if ended || player.state == .stopped {
            restart(resource, at: 0)
            return
        }
        switch player.state {
        case .paused: player.resume()
        case .idle: try? player.play()
        default: player.resume()  // cancels a deferred pause while opening/buffering
        }
        refresh()
    }

    public func pause() {
        intendedPaused = true
        lastPauseReassert = .now
        player.pause()
        if snapshot.status == .playing || snapshot.status == .buffering { snapshot.status = .paused }
    }

    public func seek(to seconds: TimeInterval) async {
        guard let resource else { return }
        var target = max(0, seconds)
        if let d = snapshot.duration { target = min(target, max(d - 0.5, 0)) }
        snapshot.position = target
        clock.reset()
        pendingSeekIsResume = false  // the user chose this point
        if ended || player.state == .stopped {
            restart(resource, at: target)
            return
        }
        holdPosition(at: target)
        guard player.isSeekable else { pendingSeek = target; return }
        scrubPending = nil; scrubFlush?.cancel(); scrubFlush = nil
        pendingSeek = target
        applyPendingSeek()
    }

    /// Keyframe ("fast") seeks, at most every 120 ms, always to the latest target.
    public func scrub(to seconds: TimeInterval) {
        guard resource != nil, !ended, player.state != .stopped, player.isSeekable else { return }
        var target = max(0, seconds)
        if let d = snapshot.duration { target = min(target, max(d - 0.5, 0)) }
        holdPosition(at: target)
        let now = ContinuousClock.now
        if let last = lastScrub, now - last < .milliseconds(120) {
            scrubPending = target
            if scrubFlush == nil {
                scrubFlush = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard let self, !Task.isCancelled else { return }
                    self.scrubFlush = nil
                    if let pending = self.scrubPending { self.scrubPending = nil; self.scrub(to: pending) }
                }
            }
            return
        }
        lastScrub = now
        try? player.seek(to: .milliseconds(Int64(target * 1000)), fast: true)
        frozenSince = nil
    }

    /// VLC reports the old time for a moment after a seek; publishing it would
    /// make the timeline jump back and forth. Hold the target briefly instead.
    private func holdPosition(at target: TimeInterval) {
        snapshot.position = target
        heldPosition = (target, ContinuousClock.now + .milliseconds(1500))
    }

    public func diagnostics() -> PlaybackDiagnostics {
        var d = PlaybackDiagnostics(engine: "VLC")
        let ext = (resource?.variant.container ?? resource?.url.pathExtension ?? "").lowercased()
        d.container = ext.isEmpty ? nil : (ext == "m3u8" ? "HLS" : ext.uppercased())
        d.source = PlaybackDiagnostics.sourceKind(of: resource?.url)
        if let stats = player.statistics {
            let raw = Double(stats.demuxBitrate > 0 ? stats.demuxBitrate : stats.inputBitrate)
            // libVLC's bitrates are in kB per ms (VLC's own GUI multiplies by 8000 for kb/s).
            if raw > 0 { d.bitrate = raw * 8_000_000 }
            if stats.inputBitrate > 0 { d.readRate = Double(stats.inputBitrate) * 1_000_000 }
            d.droppedFrames = Int(stats.lostPictures)
            d.lateFrames = Int(stats.latePictures)
            d.displayedFrames = Int(stats.displayedPictures)
            d.decodedFrames = Int(stats.decodedVideo)
            if stats.readBytes > 0 { d.readBytes = Int64(clamping: stats.readBytes) }
        }
        if let video = player.videoTracks.first(where: \.isSelected) ?? player.videoTracks.first {
            d.videoCodec = video.codecString.map(PlaybackDiagnostics.codecName)
            if let w = video.width, let h = video.height, w > 0, h > 0 { d.videoSize = CGSize(width: w, height: h) }
            if let fps = video.frameRate, fps.isFinite, fps > 0 { d.frameRate = fps }
            if let native = nativePlayer, let w = video.width, let h = video.height {
                var format = bluebox_vlc_video_format()
                if bluebox_vlc_video_format_of(native, UInt32(truncatingIfNeeded: video.codec), UInt32(w), UInt32(h), &format) {
                    let colour = Self.colour(of: format)
                    d.dynamicRange = colour.range
                    d.colour = colour.description
                    d.bitDepth = Self.bitDepth(chroma: format.chroma)
                }
            }
        }
        if let audio = player.selectedAudioTrack ?? player.audioTracks.first(where: \.isSelected) {
            d.audioCodec = audio.codecString.map(PlaybackDiagnostics.codecName)
            d.audioChannels = audio.channels.flatMap { $0 > 0 ? $0 : nil }
            d.audioSampleRate = audio.sampleRate.flatMap { $0 > 0 ? $0 : nil }
        }
        return d
    }

    /// libVLC's colour enums (`video_transfer_func_t`, `video_color_primaries_t`)
    /// as words, and the dynamic range they mean. Undefined parts are left out.
    static func colour(of format: bluebox_vlc_video_format) -> (range: PlaybackDiagnostics.DynamicRange?, description: String?) {
        let transfer: String? = switch format.transfer {
        case 1: "Linear"
        case 2: "sRGB"
        case 3, 4: "BT.470"
        case 5: "BT.709"
        case 6: "PQ"
        case 7: "SMPTE 240"
        case 8: "HLG"
        default: nil
        }
        let primaries: String? = switch format.primaries {
        case 1: "BT.601 (525)"
        case 2: "BT.601 (625)"
        case 3: "BT.709"
        case 4: "BT.2020"
        case 5: "DCI-P3"
        case 6: "P3"
        default: nil
        }
        let range: PlaybackDiagnostics.DynamicRange? = switch transfer {
        case "PQ": .hdr10
        case "HLG": .hlg
        case nil: nil
        default: .sdr
        }
        return (range, PlaybackDiagnostics.describeColour(transfer: transfer, primaries: primaries))
    }

    /// Bits per component of a libVLC chroma (its FourCC, low byte first);
    /// nil for chromas that don't say (the demuxer often leaves it unset).
    static func bitDepth(chroma: UInt32) -> Int? {
        let code = String(bytes: [0, 8, 16, 24].map { UInt8((chroma >> $0) & 0xff) }, encoding: .ascii) ?? ""
        switch code {
        case "I420", "YV12", "NV12", "NV21", "I422", "I444", "J420", "J422", "J444", "CVPN", "CVPI", "CVPY", "UYVY", "YUY2": return 8
        case "I0AL", "I0AB", "I2AL", "I2AB", "I4AL", "I4AB", "P010", "CVPP", "XV30": return 10
        case "I0CL", "I0CB", "I2CL", "I2CB", "I4CL", "I4CB", "P016": return 12
        default: return nil
        }
    }

    public func setRate(_ rate: Float) {
        let r = min(max(rate, 0.25), 4)
        snapshot.rate = r
        try? player.setPlaybackRate(PlaybackRate(r))
    }

    public func selectAudio(_ trackID: String?) {
        desiredAudioID = trackID
        // Tracks not listed yet (just opened): kept, and chosen when they are (see `applyTrackSelection`).
        guard !player.audioTracks.isEmpty else { snapshot.selectedAudioID = trackID; return }
        let track = trackID.flatMap { id in player.audioTracks.first { $0.id == id } } ?? player.audioTracks.first
        if let track, !track.isSelected { player.selectedAudioTrack = track }
        snapshot.selectedAudioID = track?.id
    }

    public func selectEmbeddedSubtitle(_ trackID: String?) {
        desiredSubtitleID = trackID.flatMap { id in player.subtitleTracks.contains { $0.id == id } ? id : nil }
        applyTrackSelection()
        snapshot.selectedEmbeddedSubtitleID = desiredSubtitleID
        snapshot.embeddedSubtitleText = nil
        updateOverlayText()
    }

    public func selectSecondaryEmbeddedSubtitle(_ trackID: String?) {
        desiredSecondaryID = trackID
        snapshot.secondaryEmbeddedSubtitleText = nil
        updateOverlayText()
    }

    // MARK: Volume and audio delay

    /// Volume, mute and audio delay are audio-output values: safe to set from
    /// the main thread (unlike anything that touches the video output).
    public func setVolume(_ volume: Float, muted: Bool) {
        self.volume = min(max(volume, 0), 1)
        self.muted = muted
        applyVolume()
    }

    private func applyVolume() {
        try? player.setAudioVolume(Volume(volume))
        player.isMuted = muted
    }

    public var supportsAudioDelay: Bool { true }

    public func setAudioDelay(_ seconds: TimeInterval) {
        let s = seconds.isFinite ? min(max(seconds, -10), 10) : 0
        guard s != audioDelay else { return }
        audioDelay = s
        guard resource != nil else { return }
        try? player.setAudioDelay(.milliseconds(Int((s * 1000).rounded())))
    }

    // MARK: Subtitles

    /// spu-delay is a player value VLC applies live (no video-output lock).
    public func setEmbeddedSubtitleDelay(_ seconds: TimeInterval) {
        let s = seconds.isFinite ? min(max(seconds, -600), 600) : 0
        guard s != subtitleDelay else { return }
        subtitleDelay = s
        guard resource != nil else { return }
        try? player.setSubtitleDelay(.milliseconds(Int((s * 1000).rounded())))
    }

    /// Size, colour, box, outline and position reach the picture at once (VLC's
    /// text renderer reads them as it draws); the font, weight and shadow from
    /// the next video. Never reopens the stream.
    public func setEmbeddedSubtitleStyle(_ style: SubtitleStyle) {
        let scale = Self.textScale(for: style)
        if scale != subtitleTextScale {
            subtitleTextScale = scale
            if resource != nil { player.setSubtitleScale(SubtitleScale(scale)) }
        }
        textLook = VLCTextLook(style)
        if resource != nil { applyTextLook() }
    }

    /// The `libvlc_media_player_t` under SwiftVLC's player (it keeps it internal).
    private var nativePlayer: UnsafeMutableRawPointer? {
        Mirror(reflecting: player).children.first { $0.label == "pointer" }
            .flatMap { $0.value as? OpaquePointer }.map(UnsafeMutableRawPointer.init)
    }

    /// Sets what changed of the look on the native player (all of it on a new handle).
    private func applyTextLook() {
        guard let native = nativePlayer else { return }
        let old = appliedTo == native ? appliedLook : nil
        let look = textLook
        guard look != old else { return }
        guard look.apply(to: native, changedFrom: old) else {
            Log.playback.error("VLC subtitle look: the player's variables couldn't be set")
            return
        }
        appliedLook = look; appliedTo = native
        // Alignment is read when the subtitle decoder starts: restart it on the same track.
        if let old, old.align != look.align, let id = desiredSubtitleID, !overlayDraws(id),
           let track = player.subtitleTracks.first(where: { $0.id == id }) {
            player.selectedSubtitleTrack = nil
            player.selectedSubtitleTrack = track
        }
    }

    /// VLC's text size: its default text is about 1/20 of the video height,
    /// scaled by `sub-text-scale`; Bluebox's size is relative to the picture too.
    static func textScale(for style: SubtitleStyle) -> Float {
        Float(SubtitleStyle.clampSize(style.relativeSize) / 0.05)
    }

    /// Stops for good.
    public func stop() {
        teardown()
        textFeed = nil; textFeedURL = nil; fileTracks = [:]; wholeTrackRead = nil
    }

    /// Stops what's playing (also the first step of every load).
    private func teardown() {
        eventTask?.cancel(); eventTask = nil
        tickTask?.cancel(); tickTask = nil
        subtitleTask?.cancel(); subtitleTask = nil
        clock.reset()
        if resource != nil || player.state != .idle { player.stop() }
        resource = nil
        intendedPaused = true
        pendingSeek = nil; pendingSeekIsResume = false; heldForStartSeek = false
        heldPosition = nil; scrubPending = nil; scrubFlush?.cancel(); scrubFlush = nil; lastScrub = nil
        if let scopedRoot { scopedRoot.stopAccessingSecurityScopedResource() }
        scopedRoot = nil
        if snapshot.status != .idle { snapshot.status = .idle }
    }

    /// Re-opens the media at `at` (after the end, VLC has stopped and can't seek).
    private func restart(_ resource: PlaybackResource, at seconds: TimeInterval) {
        ended = false
        chaptersLoaded = false
        pendingSeekIsResume = false
        snapshot.position = seconds
        snapshot.status = intendedPaused ? .paused : .buffering
        lastDisplayedPictures = nil  // a new media's counts start over
        do { try open(resource, startAt: seconds) } catch let e as PlaybackError { fail(e) } catch {}
    }

    // MARK: Picture

    public func setVideoAdjustments(_ a: Playback.VideoAdjustments) {
        var a = a; a.clamp()
        adjustments = a
        applyAdjustments()
    }

    private func applyAdjustments() {
        let a = adjustments
        let active = a.brightness != 0 || a.contrast != 1 || a.saturation != 1 || a.hue != 0 || a.gamma != 1
        player.withAdjustments { adj in
            // VLC's adjust filter: brightness/contrast 0…2, saturation 0…3, hue in degrees, gamma 0.01…10.
            adj.brightness = Float(1 + a.brightness)
            adj.contrast = Float(a.contrast)
            adj.saturation = Float(a.saturation)
            adj.hue = Float(a.hue)
            adj.gamma = Float(a.gamma)
            adj.isEnabled = active
        }
    }

    // MARK: Sound

    /// Dialogue Boost and the equaliser are VLC's equalizer, and Night Mode is
    /// its compressor, all applied live: none of them reopens the video.
    ///
    /// Measured with this libVLC 4 build (an `amem` capture of a −40 dBFS
    /// tone, Oct 2026): `set_equalizer` replaces the audio output's
    /// `audio-filter` with "equalizer" (dropping anything else there), and an
    /// instance's `--audio-filter=compressor` never reaches the output at all
    /// (the tone came out unchanged, not 8 dB up). Setting `audio-filter` on
    /// the player's audio output itself runs the filters, live, on any
    /// instance. So after each `set_equalizer` the chain is set again on the
    /// output (`applyAudioFilters`): "equalizer:compressor", "compressor",
    /// "equalizer" or nothing.
    public func setAudioEffects(_ e: AudioEffects) {
        let nightChanged = e.nightMode != audioEffects.nightMode
        audioEffects = e
        applyEqualizer()
        if nightChanged { applyAudioFilters() }
    }

    /// libVLC 4's equaliser bands: octaves, 31 Hz to 16 kHz (not the 60 Hz…16 kHz
    /// set of VLC 2 and 3 the presets are drawn on, so the curve is resampled).
    /// From `Equalizer.bandFrequency` when libVLC answers.
    @MainActor static let bandFrequencies: [Double] = {
        let asked = (0..<Equalizer.bandCount).compactMap { Equalizer.bandFrequency(at: $0).map(Double.init) }
        return asked.count == Equalizer.bandCount && !asked.isEmpty ? asked : [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    }()

    /// What libVLC's equalizer is given for these effects: Dialogue Boost and
    /// the equaliser added up (`EqualizerCurve.combined`, ±20 dB), the bands
    /// read off at libVLC's own frequencies. The preamp is offset by +12 dB:
    /// libVLC's equalizer passes a flat signal at −12 dB with a 0 dB preamp
    /// (its band-pass sum runs at a quarter of the input; its own Flat preset
    /// has a +12 dB preamp), measured as a 1 kHz tone exactly level at +12.
    /// Nil when neither changes the sound.
    @MainActor static func vlcEqualizer(for e: AudioEffects) -> (preamp: Float, bands: [Float])? {
        guard let curve = EqualizerCurve.combined(e) else { return nil }
        let range = EqualizerCurve.engineRange
        return (Float(min(max(curve.preamp + vlcUnityPreamp, range.lowerBound), range.upperBound)),
                curve.resampled(at: bandFrequencies).map(Float.init))
    }

    /// The preamp at which libVLC's flat equalizer leaves the level alone.
    static let vlcUnityPreamp = 12.0

    /// Night Mode's compressor: feed-forward, −24 dB threshold, 4:1, +8 dB
    /// make-up, 10 ms attack, 250 ms release. Set on the player as variables,
    /// which the compressor in its audio output inherits when it starts.
    static let compressorSettings: [(String, Float)] = [
        ("compressor-rms-peak", 0.2), ("compressor-attack", 10), ("compressor-release", 250),
        ("compressor-threshold", -24), ("compressor-ratio", 4), ("compressor-knee", 6), ("compressor-makeup-gain", 8),
    ]

    /// The audio output's filter chain for these effects (the equalizer first,
    /// so the compressor evens out what it boosts).
    static func audioFilters(equalizer: Bool, nightMode: Bool) -> String {
        [equalizer ? "equalizer" : nil, nightMode ? "compressor" : nil].compactMap { $0 }.joined(separator: ":")
    }

    /// Puts the filter chain on the player's audio output (and on the player,
    /// for an output made later). Rebuilding the chain costs a few
    /// milliseconds of audio, so it's done only when it changes: on Night Mode
    /// changing and after a `set_equalizer` (which resets the output's chain).
    private func applyAudioFilters() {
        guard let native = nativePlayer else { return }
        if audioEffects.nightMode, compressorSetOn != native {
            for (name, value) in Self.compressorSettings where !bluebox_vlc_set_float(native, name, value) {
                Log.playback.error("VLC Night Mode: \(name, privacy: .public) couldn't be set")
            }
            compressorSetOn = native
        }
        let filters = Self.audioFilters(equalizer: player.equalizer != nil, nightMode: audioEffects.nightMode)
        _ = bluebox_vlc_set_string(native, "audio-filter", filters)
        if bluebox_vlc_set_aout_string(native, "audio-filter", filters) == 0, audioEffects.nightMode {
            Log.playback.error("VLC Night Mode: the audio output didn't take the compressor")
        }
    }

    /// Gives the player the equalizer the effects need, or takes it away.
    /// Unchanged values cost nothing; a change is one `set_equalizer`.
    private func applyEqualizer() {
        guard let wanted = Self.vlcEqualizer(for: audioEffects) else {
            if player.equalizer != nil { player.equalizer = nil; applyAudioFilters() }
            return
        }
        if let current = player.equalizer, current.preamp == wanted.preamp, current.bands == wanted.bands { return }
        // A new equalizer, filled in before it's handed over: one set_equalizer,
        // not one per band (each change to an attached one applies at once).
        let eq = Equalizer()
        eq.preampGain = EqualizerGain(wanted.preamp)
        try? eq.setBands(wanted.bands)
        player.equalizer = eq
        // set_equalizer left the output's chain as "equalizer": the compressor goes back on.
        if audioEffects.nightMode { applyAudioFilters() }
    }

    public func stepFrame(by count: Int) {
        guard resource != nil, count != 0 else { return }
        pause()
        // An exact seek a frame away, both ways. Not libVLC's next-frame: called
        // while the pause is still settling, it left the input paused under a
        // player that said it was playing, so Play never resumed it (the clock
        // stood still and showed as buffering, even with the whole file in).
        let fps = player.videoTracks.first(where: \.isSelected)?.frameRate ?? player.videoTracks.first?.frameRate ?? 24
        let target = max(0, snapshot.position + Double(count) / max(fps, 1))
        Task { await seek(to: target) }
    }

    public func captureFrame() async -> CGImage? {
        guard resource != nil, player.hasVideoOutput else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "bluebox-vlc-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        do { try player.takeSnapshot(to: url.path) } catch { return nil }
        // libVLC writes the PNG from its video output thread; wait for it briefly.
        for _ in 0..<40 {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               CGImageSourceGetStatus(source) == .statusComplete,
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return image
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    // MARK: Observation

    private func startObserving() {
        eventTask?.cancel()
        let events = player.events(policy: .unbounded) { event in
            switch event {
            case .timeChanged, .positionChanged, .bufferingProgress, .volumeChanged: false
            default: true
            }
        }
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                // Let SwiftVLC's own consumer publish the matching state first.
                await Task.yield()
                self.handle(event)
            }
        }
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
        subtitleTask?.cancel()
        subtitleTask = Task { [weak self] in
            // Often enough that a line comes and goes within a frame or two of its time.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                self.updateOverlayText()
            }
        }
    }

    private func handle(_ event: PlayerEvent) {
        guard resource != nil else { return }
        switch event {
        case .endReached:
            markEnded()
        case .encounteredError:
            fail(failureError())
        case .stateChanged(let state):
            if state == .error { fail(failureError()); return }
            if state == .stopped, player.didReachEnd { markEnded(); return }
            refresh(reportedState: state)
        case .tracksChanged:
            applyTrackSelection()
            refresh()
        default:
            refresh()
        }
    }

    private func markEnded() {
        guard !ended else { return }
        ended = true
        if let d = snapshot.duration { snapshot.position = d }
        snapshot.status = .ended
    }

    /// Copies the player's state into the snapshot.
    private func refresh(reportedState: PlayerState? = nil) {
        guard resource != nil else { return }
        if case .failed = snapshot.status { return }
        let state = reportedState ?? player.state

        if !ended, player.didReachEnd { markEnded() }
        if let d = player.duration, d > .zero { snapshot.duration = Self.seconds(d) }
        applyPendingSeek()
        if !ended {
            let t = Self.seconds(player.currentTime)
            // Until a pending seek goes out VLC sits elsewhere (0:00 when just opened); show the target.
            if let pendingSeek {
                snapshot.position = pendingSeek
            } else if let held = heldPosition {
                if ContinuousClock.now < held.until, abs(t - held.time) > 1.5 {
                    snapshot.position = held.time
                } else {
                    heldPosition = nil
                    if t > 0 || state == .playing || state == .paused { snapshot.position = t }
                }
            } else if t > 0 || state == .playing || state == .paused {
                snapshot.position = t
            }
            snapshot.bufferedUntil = snapshot.position
        }
        if let size = player.videoSize, size != snapshot.presentationSize { snapshot.presentationSize = size }

        publishTracks()
        if !chaptersLoaded, state == .playing || state == .paused {
            let chapters = player.chapters()
            snapshot.chapters = chapters.map {
                Playback.Chapter(title: $0.name?.isEmpty == false ? $0.name! : "Chapter \($0.index + 1)",
                                 start: Self.seconds($0.timeOffset))
            }
            chaptersLoaded = true
        }

        guard !ended else { return }
        switch state {
        case .playing:
            if intendedPaused {
                reassertPause()
                snapshot.status = .paused
            } else {
                snapshot.status = isClockFrozen() ? .buffering : .playing
            }
        case .paused:
            snapshot.status = .paused
        case .opening, .buffering:
            if snapshot.status != .loading { snapshot.status = intendedPaused ? .paused : .buffering }
            let fill = Double(player.bufferFill)
            snapshot.bufferFill = fill > 0 && fill < 1 ? fill : nil
        case .error:
            fail(failureError())
        case .idle, .stopped, .stopping:
            break
        }
        if state != .playing { lastClock = -1; frozenSince = nil }
        watchVideo(state)
        if state == .playing || state == .paused, snapshot.bufferFill != nil { snapshot.bufferFill = nil }
        enforcePause(state)
    }

    /// Asked to pause, yet the clock runs on: SwiftVLC can take a pause for
    /// done (one it held back while the stream buffered) while libVLC plays
    /// on, and then its own pause() does nothing, so the film carried on under
    /// a Play button. Half a second of steady running pauses libVLC itself.
    private func enforcePause(_ state: PlayerState) {
        guard intendedPaused, !ended, state == .playing || state == .paused else { pausedClock = nil; return }
        let t = Self.seconds(player.currentTime), now = ContinuousClock.now
        guard let was = pausedClock else { pausedClock = (t, now); return }
        let gap = (now - was.at).components
        let elapsed = Double(gap.seconds) + Double(gap.attoseconds) / 1e18
        guard elapsed >= 0.5 else { return }
        pausedClock = (t, now)
        // A seek moves the clock too, by a jump rather than at the pace of time.
        let ran = t - was.time
        guard ran > 0.3, ran < elapsed + 0.5, let native = nativePlayer else { return }
        if bluebox_vlc_pause(native) { Log.playback.notice("VLC played on while paused; paused it underneath") }
    }

    /// Issues `pendingSeek` once VLC can seek. A resume point is checked
    /// against the real length first (one in the closing stretch starts over).
    private func applyPendingSeek() {
        guard let requested = pendingSeek, player.isSeekable else { return }
        let length = player.duration.map(Self.seconds).flatMap { $0 > 0 ? $0 : nil }
        // VLC can be seekable a moment before it knows the length.
        if pendingSeekIsResume, length == nil, let deadline = resumeLengthDeadline, ContinuousClock.now < deadline { return }
        var target = requested
        if pendingSeekIsResume { target = ProgressPolicy.standard.startPosition(resumingAt: target, duration: length) ?? 0 }
        if let length { target = min(target, max(length - 0.5, 0)) }
        pendingSeek = nil
        pendingSeekIsResume = false
        videoWatchdog.noteSeek()
        do {
            try player.seek(to: .milliseconds(Int64(target * 1000)))
            snapshot.position = target
        } catch {
            Log.playback.notice("VLC refused a seek to \(target, privacy: .public)s: \(String(describing: error), privacy: .public)")
            snapshot.position = Self.seconds(player.currentTime)
        }
        frozenSince = nil
        if heldForStartSeek {
            heldForStartSeek = false
            if !intendedPaused { player.resume() }
        }
    }

    /// Feeds the frozen-picture watchdog (see `videoWatchdog`), once a second.
    private func watchVideo(_ state: PlayerState) {
        let now = ContinuousClock.now
        if let last = lastVideoSample, now - last < .seconds(1) { return }
        lastVideoSample = now
        guard let resource else { return }
        let stats = player.statistics
        let displayed = stats?.displayedPictures
        let newFrame = displayed.map { d in lastDisplayedPictures.map { d > $0 } ?? true } ?? true
        lastDisplayedPictures = displayed
        // Only once VLC's counts are known to move: a build without them would look frozen.
        let counts = stats.map { $0.displayedPictures > 0 || $0.decodedVideo > 0 } ?? false
        let running = state == .playing && !intendedPaused && snapshot.status == .playing
            && pendingSeek == nil && scrubPending == nil
        let position = Self.seconds(player.currentTime)
        let action = videoWatchdog.observe(.init(
            state: running ? .playing : .paused, position: position, newFrame: newFrame,
            watchesVideo: counts && player.videoSize != nil, now: ProcessInfo.processInfo.systemUptime))
        switch action {
        case .nudgeVideo:
            Log.playback.notice("VLC picture froze at \(position, privacy: .public)s: seeking to restart it")
            videoWatchdog.noteSeek()
            try? player.seek(to: .milliseconds(Int64(position * 1000)))
        case .reload:
            Log.playback.notice("VLC picture still frozen at \(position, privacy: .public)s: reopening there")
            restart(resource, at: position)
        case .none, .giveUp:
            break
        }
    }

    private func reassertPause() {
        let now = ContinuousClock.now
        if let last = lastPauseReassert, now - last < .milliseconds(300) { return }
        lastPauseReassert = now
        player.pause()
    }

    /// True once the clock has stood still for 1.5 s while VLC says it's playing.
    private func isClockFrozen() -> Bool {
        let t = Self.seconds(player.currentTime)
        let now = ContinuousClock.now
        if t != lastClock { lastClock = t; frozenSince = now; return false }
        guard let since = frozenSince else { frozenSince = now; return false }
        return now - since > .milliseconds(1500)
    }

    private func publishTracks() {
        let audio = player.audioTracks.enumerated().map { i, t in
            MediaTrack(id: t.id, kind: .audio, label: Self.label(t, index: i), languageCode: t.language)
        }
        if audio != snapshot.audioTracks { snapshot.audioTracks = audio }
        let subtitleTracks = player.subtitleTracks
        rebuildTrackMap(subtitleTracks)
        let subs = subtitleTracks.enumerated().map { i, t in
            MediaTrack(id: t.id, kind: .subtitle, label: Self.label(t, index: i), languageCode: t.language,
                       isBitmap: Self.isBitmapSubtitle(codec: t.codecString), format: Self.subtitleFormat(codec: t.codecString),
                       drawnByBluebox: overlayDraws(t.id))
        }
        if subs != snapshot.embeddedSubtitles { snapshot.embeddedSubtitles = subs }
        snapshot.selectedAudioID = player.selectedAudioTrack?.id
        snapshot.selectedEmbeddedSubtitleID = desiredSubtitleID
    }

    /// VLC picks "default" tracks itself; Bluebox's session decides. The audio
    /// and the subtitle are each put back on their own: a subtitle already
    /// right never skips the audio (VLC can fall back to the file's default
    /// audio, another language, when tracks change).
    private func applyTrackSelection() {
        rebuildTrackMap(player.subtitleTracks)
        // A track Bluebox's overlay draws is off in VLC.
        let overlay = overlayDraws(desiredSubtitleID)
        let vlcSubtitleID = overlay ? nil : desiredSubtitleID
        if snapshot.drawsEmbeddedSubtitles == overlay { snapshot.drawsEmbeddedSubtitles = !overlay }
        if player.selectedSubtitleTrack?.id != vlcSubtitleID {
            if let id = vlcSubtitleID {
                if let track = player.subtitleTracks.first(where: { $0.id == id }) { player.selectedSubtitleTrack = track }
            } else if player.selectedSubtitleTrack != nil {
                player.selectedSubtitleTrack = nil
            }
        }
        if let id = desiredAudioID, player.selectedAudioTrack?.id != id,
           let track = player.audioTracks.first(where: { $0.id == id }) {
            player.selectedAudioTrack = track
        }
    }

    // MARK: Text tracks drawn by Bluebox

    /// Starts reading the file's text tracks when it may be Matroska.
    private func prepareTextFeed(for resource: PlaybackResource) {
        if textFeedURL == resource.url, textFeed != nil { return }
        textFeed = nil; textFeedURL = nil; fileTracks = [:]
        let container = (resource.variant.container ?? resource.url.pathExtension).lowercased()
        guard Self.matroskaContainers.contains(container),
              let source = byteSource(for: resource.url, headers: resource.httpHeaders) else { return }
        let feed = EmbeddedTextFeed(source: source)
        feed.onChange = { [weak self] in self?.textFeedChanged() }
        textFeed = feed
        textFeedURL = resource.url
        feed.start()
    }

    /// "" is a URL without an extension (some streams): worth a look at its first bytes.
    static let matroskaContainers: Set<String> = ["mkv", "mk3d", "webm", ""]

    /// The tracks were read, an ASS track's verdict came in, or new lines arrived.
    private func textFeedChanged() {
        guard resource != nil else { return }
        applyTrackSelection()
        publishTracks()
        updateOverlayText()
    }

    /// The file's track behind a VLC subtitle track. VLC lists the file's
    /// subtitle tracks in their order, after any closed captions it found in
    /// the video; a list that doesn't line up (or a format that doesn't match)
    /// leaves every track to VLC.
    private func feedTrack(for vlcID: String?) -> MatroskaTrack? {
        vlcID.flatMap { fileTracks[$0] }
    }

    /// Matches VLC's subtitle tracks to the file's (`fileTracks`), when either list changes.
    private func rebuildTrackMap(_ tracks: [Track]) {
        guard let feed = textFeed, !feed.failed, !feed.tracks.isEmpty else {
            if !fileTracks.isEmpty { fileTracks = [:] }
            return
        }
        let listed = tracks.map { (id: $0.id, format: Self.subtitleFormat(codec: $0.codecString)) }
        var map: [String: MatroskaTrack] = [:]
        for t in listed { map[t.id] = Self.matroskaTrack(for: t.id, listed: listed, fileTracks: feed.tracks) }
        if map != fileTracks { fileTracks = map }
    }

    static func matroskaTrack(for vlcID: String, listed: [(id: String, format: String?)], fileTracks: [MatroskaTrack]) -> MatroskaTrack? {
        let own = listed.filter { $0.format != "CC" }
        guard !fileTracks.isEmpty, own.count == fileTracks.count, let i = own.firstIndex(where: { $0.id == vlcID }) else { return nil }
        let track = fileTracks[i]
        guard let codec = track.textCodec else { return track }
        let expected = switch codec { case .srt: "SRT"; case .webVTT: "WebVTT"; case .ass, .ssa: "ASS" }
        return own[i].format == expected ? track : nil
    }

    /// True when Bluebox's overlay draws this VLC track (and VLC doesn't).
    private func overlayDraws(_ vlcID: String?) -> Bool {
        guard let feed = textFeed, let track = feedTrack(for: vlcID), track.textCodec != nil else { return false }
        return feed.verdict(track: track.number) == .bluebox
    }

    // MARK: Lines for the Lines page, and lines in the picture

    public func embeddedSubtitleCues() -> [SubtitleCue] {
        guard let feed = textFeed, let track = feedTrack(for: desiredSubtitleID), track.textCodec != nil else { return [] }
        // A local file can give every line at once; a stream only what's read around the playhead.
        if wholeTrackRead != track.number, textFeedURL?.isFileURL == true, let duration = snapshot.duration {
            wholeTrackRead = track.number
            feed.readAll(track: track.number, until: duration + 1)
        }
        return feed.cues(track: track.number)
    }

    /// Draws the lines into the video itself with libVLC's logo overlay (a
    /// picture of the block, drawn by `SubtitleBurnIn` in the user's style),
    /// so Picture in Picture shows them. Positioned in the video's pixels.
    public func setSubtitleBurnIn(_ burnIn: SubtitleBurnIn?) {
        guard burnIn != self.burnIn else { return }
        self.burnIn = burnIn
        let size = snapshot.presentationSize
        guard let burnIn, size.width >= 16, let rendered = burnIn.render(frame: size),
              let png = SubtitleBurnIn.png(rendered.image) else {
            player.withLogo { $0.isEnabled = false }
            return
        }
        // A new name each time: libVLC reloads the picture when the file setting changes.
        burnInFile = (burnInFile + 1) % 2
        let url = FileManager.default.temporaryDirectory.appending(path: "bluebox-subtitle-\(burnInFile).png")
        guard (try? png.write(to: url)) != nil else {
            player.withLogo { $0.isEnabled = false }
            return
        }
        let origin = rendered.topLeft
        player.withLogo { logo in
            logo.setFile(url.path)
            logo.position = -1  // x and y in the video's pixels
            logo.x = Int(origin.x)
            logo.y = Int(origin.y)
            logo.opacity = 255
            logo.isEnabled = true
        }
    }

    /// Publishes the overlay's lines for the subtitle clock, and keeps the feed reading around it.
    private func updateOverlayText() {
        guard let feed = textFeed, !feed.failed, !feed.tracks.isEmpty, resource != nil else {
            if snapshot.embeddedSubtitleText != nil { snapshot.embeddedSubtitleText = nil }
            if snapshot.secondaryEmbeddedSubtitleText != nil { snapshot.secondaryEmbeddedSubtitleText = nil }
            return
        }
        // The file's clock: VLC's delay moves lines later, so look them up earlier.
        let t = subtitleClock() - subtitleDelay
        let primary = feedTrack(for: desiredSubtitleID).flatMap { $0.textCodec == nil ? nil : $0 }
        let secondary = feedTrack(for: desiredSecondaryID).flatMap { $0.textCodec == nil ? nil : $0 }
        var wanted = Set([primary, secondary].compactMap { $0?.number })
        // ASS tracks are only known to be plain once some lines are read: one at a
        // time, so the second-line list can offer them.
        if wanted.allSatisfy({ feed.verdict(track: $0) != .pending }),
           let next = feed.tracks.first(where: { $0.textCodec?.isASS == true && feed.verdict(track: $0.number) == .pending }) {
            wanted.insert(next.number)
        }
        feed.follow(tracks: wanted, at: t)
        func line(_ track: MatroskaTrack?) -> String? {
            guard let track, feed.verdict(track: track.number) == .bluebox else { return nil }
            return feed.text(track: track.number, at: t)
        }
        let text = line(primary), second = line(secondary)
        if snapshot.embeddedSubtitleText != text { snapshot.embeddedSubtitleText = text }
        if snapshot.secondaryEmbeddedSubtitleText != second { snapshot.secondaryEmbeddedSubtitleText = second }
    }

    /// The playhead between VLC's updates, at the playback rate (see `PlayheadClock`).
    private func subtitleClock() -> TimeInterval {
        clock.time(position: snapshot.position, playing: snapshot.status == .playing, rate: snapshot.rate)
    }

    /// Picture subtitle codecs (VLC FourCCs): PGS, VobSub, DVB, XSUB, CVD/SVCD.
    static func isBitmapSubtitle(codec: String?) -> Bool {
        guard let c = codec?.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
        return ["pgs", "pgss", "spu", "spub", "dvbs", "xsub", "cvd", "ogt", "scte", "kate"].contains(c)
    }

    /// A subtitle codec's everyday name (VLC FourCCs).
    static func subtitleFormat(codec: String?) -> String? {
        guard let c = codec?.lowercased().trimmingCharacters(in: .whitespaces) else { return nil }
        switch c {
        case "subt": return "SRT"
        case "ssa", "ass": return "ASS"
        case "pgs", "pgss": return "PGS"
        case "spu", "spub": return "VobSub"
        case "dvbs": return "DVB"
        case "wvtt", "webvtt": return "WebVTT"
        case "ttml", "dfxp": return "TTML"
        case "tx3g": return "Text"
        case "cea6", "c608", "c708", "cea7": return "CC"
        default: return c.uppercased()
        }
    }

    static func label(_ track: Track, index: Int) -> String {
        let name = track.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        if let lang = track.language, let display = Locale.current.localizedString(forLanguageCode: lang) {
            return display
        }
        return "Track \(index + 1)"
    }

    private func failureError() -> PlaybackError {
        guard let resource else { return .decodeFailed("VLC couldn't play this file.") }
        if !resource.url.isFileURL, snapshot.duration == nil {
            return .unreachable("VLC couldn't open the stream.")
        }
        return .decodeFailed("VLC couldn't play this file.")
    }

    private func fail(_ error: PlaybackError) {
        if case .failed = snapshot.status { return }
        Log.playback.error("VLC playback failed: \(error.localizedDescription, privacy: .public)")
        intendedPaused = true
        if player.state != .idle, player.state != .stopped { player.stop() }
        snapshot.status = .failed(error)
    }

    static func seconds(_ d: Duration) -> TimeInterval { Double(d.milliseconds) / 1000 }

    // MARK: Audio session

    /// `.playback` so audio plays with the ringer off; VLC's audio unit needs an active session.
    private static func activateAudioSession() async {
        #if os(iOS)
        await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback { try? session.setCategory(.playback, mode: .moviePlayback) }
            try? session.setActive(true)
        }.value
        #endif
    }
}
