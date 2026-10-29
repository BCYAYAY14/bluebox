import CoreGraphics
import Domain
import Foundation
import ImageIO
import Playback
import Subtitles
import SwiftVLC
#if os(iOS)
import AVFoundation
#endif

/// libVLC-backed engine (via SwiftVLC) for the containers AVFoundation can't
/// open: MKV, AVI, WebM and friends, which is most torrent releases.
///
/// Differences from `AVPlayerEngine`:
/// - Embedded subtitles are rendered by VLC inside the picture, so
///   `embeddedSubtitleText` stays nil (external subtitles are still drawn by
///   Bluebox's overlay from the snapshot time). Text tracks take the user's
///   subtitle style through VLC's text renderer options (see `styleArguments`),
///   which libVLC only reads when a video output starts: a style change moves
///   playback to a player on a matching instance, like Night Mode.
/// - No PiP/AirPlay, no buffered-range reporting, no automatic stream rebuild
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

    /// The SwiftVLC player; `VLCVideoSurface` draws it. Replaced when Night
    /// Mode changes (libVLC only takes audio filters per instance); the
    /// snapshot's `outputGeneration` changes with it.
    public private(set) var player: Player
    private var audioEffects = AudioEffects()
    /// Which libVLC instance `player` runs on (see `instanceKey`).
    private var playerInstanceKey = 0
    /// The subtitle style arguments of `player`'s instance.
    private var playerStyleArguments: [String] = []
    /// The style arguments wanted (from `setEmbeddedSubtitleStyle`).
    private var styleArguments: [String] = []
    private var restyleTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
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

    public init() {
        player = Player()
    }

    // MARK: Loading

    public func load(_ resource: PlaybackResource, startAt: TimeInterval?) async throws {
        stop()
        let container = resource.variant.container ?? resource.url.pathExtension
        guard Self.canAttempt(container: container) else {
            fail(.unsupportedFormat(container))
            throw PlaybackError.unsupportedFormat(resource.variant.container ?? "unknown")
        }
        let generation = snapshot.outputGeneration
        snapshot = PlaybackSnapshot()
        snapshot.outputGeneration = generation
        snapshot.drawsEmbeddedSubtitles = true
        snapshot.status = .loading
        self.resource = resource
        intendedPaused = true  // the session calls play() after load when it wants autoplay
        desiredSubtitleID = nil; desiredAudioID = nil; pendingSeek = nil; ended = false; chaptersLoaded = false
        pendingSeekIsResume = startAt != nil
        resumeLengthDeadline = .now + .seconds(2)
        if let startAt, startAt > 0 { snapshot.position = startAt }

        if let root = resource.securityScopedRoot, root.startAccessingSecurityScopedResource() {
            scopedRoot = root
        }
        await Self.activateAudioSession()
        guard self.resource == resource else { throw CancellationError() }
        let night = Self.instanceKey(for: audioEffects), style = styleArguments
        if night != playerInstanceKey || style != playerStyleArguments {
            // Nothing is playing yet: a player on the right instance costs nothing here.
            // The instance is made off the main thread (libVLC's setup is slow on iOS).
            let instance = await Self.preparedInstance(night: night, style: style)
            guard self.resource == resource else { throw CancellationError() }
            player = Player(instance: instance)
            playerInstanceKey = night
            playerStyleArguments = style
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
        do { media = try Media(url: resource.url) } catch {
            throw PlaybackError.unreachable(error.localizedDescription)
        }
        let start = startAt.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        pendingSeek = start
        heldForStartSeek = start != nil
        for option in Self.mediaOptions(for: resource, startAt: start) { media.addOption(option) }
        applyAdjustments()
        applyEqualizer()
        do { try player.play(media) } catch {
            throw PlaybackError.decodeFailed(error.localizedDescription)
        }
        if snapshot.rate != 1 { try? player.setPlaybackRate(PlaybackRate(snapshot.rate)) }
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
            default: Log.playback.notice("VLC ignores HTTP header \(name, privacy: .public)")
            }
        }
        return options
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
            d.droppedFrames = Int(stats.lostPictures)
        }
        return d
    }

    public func setRate(_ rate: Float) {
        let r = min(max(rate, 0.25), 4)
        snapshot.rate = r
        try? player.setPlaybackRate(PlaybackRate(r))
    }

    public func selectAudio(_ trackID: String?) {
        desiredAudioID = trackID
        let track = trackID.flatMap { id in player.audioTracks.first { $0.id == id } } ?? player.audioTracks.first
        if let track { player.selectedAudioTrack = track }
        snapshot.selectedAudioID = track?.id
    }

    public func selectEmbeddedSubtitle(_ trackID: String?) {
        desiredSubtitleID = trackID.flatMap { id in player.subtitleTracks.contains { $0.id == id } ? id : nil }
        applySubtitleSelection()
        snapshot.selectedEmbeddedSubtitleID = desiredSubtitleID
        scheduleRestyleIfNeeded()
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

    /// The text renderer's options only take effect when a video output starts,
    /// and changing them live would touch the output from the main thread
    /// (which can deadlock with VideoToolbox). So the next load uses them, and
    /// while a text track shows, playback moves to a restyled player once the
    /// changes pause for a moment.
    public func setEmbeddedSubtitleStyle(_ style: SubtitleStyle) {
        let args = Self.styleArguments(for: style)
        guard args != styleArguments else { return }
        styleArguments = args
        Self.prewarm(night: Self.instanceKey(for: audioEffects), style: args)
        scheduleRestyleIfNeeded()
    }

    /// True when a text subtitle (not a picture one) from the file is showing.
    private var showsEmbeddedTextSubtitle: Bool {
        guard let id = desiredSubtitleID else { return false }
        return snapshot.embeddedSubtitles.first { $0.id == id }.map { !$0.isBitmap } ?? false
    }

    private func scheduleRestyleIfNeeded() {
        restyleTask?.cancel()
        guard resource != nil, styleArguments != playerStyleArguments, showsEmbeddedTextSubtitle else { return }
        restyleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self, self.styleArguments != self.playerStyleArguments,
                  self.showsEmbeddedTextSubtitle, self.snapshot.status != .loading else { return }
            self.replacePlayer()
        }
    }

    /// libVLC text renderer arguments for a subtitle style. Sizes are relative
    /// to the picture like Bluebox's own: VLC's default text is about 1/20 of
    /// the video height, scaled by `sub-text-scale`.
    static func styleArguments(for style: SubtitleStyle) -> [String] {
        func rgb(_ c: RGBA) -> Int { Int(c.r * 255) << 16 | Int(c.g * 255) << 8 | Int(c.b * 255) }
        func alpha(_ a: Double) -> Int { Int((min(max(a, 0), 1) * 255).rounded()) }
        let scale = Int((SubtitleStyle.clampSize(style.relativeSize) / 0.05 * 100).rounded())
        let outline: Int = switch style.outlineWidth { case ..<0.1: 0; case ..<1.5: 2; case ..<3.5: 4; default: 6 }
        let font: String = style.fontName ?? {
            switch style.design {
            case .system: "Helvetica Neue"
            case .rounded: "Arial Rounded MT Bold"
            case .serif: "Georgia"
            case .monospaced: "Menlo"
            }
        }()
        var args = [
            "--sub-text-scale=\(min(max(scale, 10), 500))",
            "--freetype-font=\(font)",
            "--freetype-color=\(rgb(style.textColor))",
            "--freetype-opacity=\(alpha(style.textColor.a))",
            style.weight == .regular || style.weight == .medium ? "--no-freetype-bold" : "--freetype-bold",
            "--freetype-outline-thickness=\(outline)",
            "--freetype-outline-color=\(rgb(style.outlineColor))",
            "--freetype-outline-opacity=\(outline == 0 ? 0 : 255)",
            "--freetype-shadow-opacity=\(style.shadow ? alpha(style.shadowOpacity * 0.8) : 0)",
            "--freetype-shadow-color=0",
            "--freetype-shadow-angle=-90",
            "--freetype-shadow-distance=0.05",
            "--freetype-background-opacity=\(alpha(style.backgroundOpacity))",
            "--freetype-background-color=\(rgb(style.backgroundColor))",
        ]
        // Distance from the bottom, beyond VLC's own, in pixels of a 1080-line picture.
        if style.anchor == .bottom, style.verticalMargin > SubtitleStyle.defaultMargin + 0.005 {
            args.append("--sub-margin=\(Int((style.verticalMargin - SubtitleStyle.defaultMargin) * 1080))")
        }
        return args
    }

    public func stop() {
        eventTask?.cancel(); eventTask = nil
        tickTask?.cancel(); tickTask = nil
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

    /// Dialogue Boost is VLC's equalizer, applied live. Night Mode is VLC's
    /// compressor, which libVLC only accepts as an instance argument (and
    /// `set_equalizer` would overwrite it), so turning it on or off moves
    /// playback to a player on a suitably configured instance, at the same
    /// second. With Night Mode on, the instance carries the equalizer too.
    public func setAudioEffects(_ e: AudioEffects) {
        audioEffects = e
        if Self.instanceKey(for: e) != playerInstanceKey {
            replacePlayer()
        } else {
            applyEqualizer()
        }
    }

    /// 0: the shared instance; 1: compressor; 2: compressor and dialogue equalizer.
    static func instanceKey(for e: AudioEffects) -> Int { e.nightMode ? (e.dialogueBoost ? 2 : 1) : 0 }

    /// Speech presence up, rumble and hiss down, on VLC's ten bands
    /// (60, 170, 310, 600 Hz, 1, 3, 6, 12, 14, 16 kHz).
    static let dialogueBands: [Float] = [-4, -3, -1, 1, 3, 5, 4, 0, -1, -2]
    static let dialoguePreamp: Float = -3

    /// libVLC arguments for a Night Mode instance: a feed-forward compressor
    /// (−24 dB threshold, 4:1, +8 dB make-up), optionally after the dialogue equalizer.
    static func nightArguments(dialogueBoost: Bool) -> [String] {
        var args = [
            "--audio-filter=\(dialogueBoost ? "equalizer:" : "")compressor",
            "--compressor-rms-peak=0.2", "--compressor-attack=10", "--compressor-release=250",
            "--compressor-threshold=-24", "--compressor-ratio=4", "--compressor-knee=6", "--compressor-makeup-gain=8",
        ]
        if dialogueBoost {
            args += ["--equalizer-bands=\(dialogueBands.map { String(format: "%.1f", $0) }.joined(separator: " "))",
                     "--equalizer-preamp=\(String(format: "%.1f", dialoguePreamp))"]
        }
        return args
    }

    private static var instances: [String: VLCInstance] = [:]
    /// Arguments libVLC refused (an option this build lacks): not tried again.
    private static var refused: Set<String> = []

    static func arguments(night: Int, style: [String]) -> [String] {
        (night == 0 ? [] : nightArguments(dialogueBoost: night == 2)) + style
    }

    /// The instance for Night Mode and a subtitle style: the plain shared
    /// instance when neither is set, or when libVLC turns the arguments down.
    private static func instance(night: Int, style: [String]) -> VLCInstance {
        let extra = arguments(night: night, style: style)
        guard !extra.isEmpty else { return .shared }
        let key = extra.joined(separator: " ")
        if let made = instances[key] { return made }
        if !refused.contains(key) {
            do {
                let made = try VLCInstance(arguments: VLCInstance.defaultArguments + extra)
                instances[key] = made
                return made
            } catch {
                refused.insert(key)
                Log.playback.error("VLC instance with \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        // Night Mode matters more than the subtitle look: keep it without the style.
        return style.isEmpty ? .shared : instance(night: night, style: [])
    }

    /// The instance for these arguments, made off the main thread if it's new.
    private static func preparedInstance(night: Int, style: [String]) async -> VLCInstance {
        let extra = arguments(night: night, style: style)
        let key = extra.joined(separator: " ")
        if extra.isEmpty || instances[key] != nil || refused.contains(key) { return instance(night: night, style: style) }
        let made = await Task.detached(priority: .userInitiated) {
            try? VLCInstance(arguments: VLCInstance.defaultArguments + extra)
        }.value
        if let made { if instances[key] == nil { instances[key] = made } } else { refused.insert(key) }
        return instance(night: night, style: style)
    }

    /// Makes the instance for the next video off the main thread (plugin setup is slow on iOS).
    private static func prewarm(night: Int, style: [String]) {
        let extra = arguments(night: night, style: style)
        let key = extra.joined(separator: " ")
        guard !extra.isEmpty, instances[key] == nil, !refused.contains(key) else { return }
        Task.detached(priority: .utility) {
            let made = try? VLCInstance(arguments: VLCInstance.defaultArguments + extra)
            await MainActor.run {
                if let made { if instances[key] == nil { instances[key] = made } } else { refused.insert(key) }
            }
        }
    }

    private func applyEqualizer() {
        // Night Mode instances carry their own equalizer setting.
        guard playerInstanceKey == 0 else { return }
        if audioEffects.dialogueBoost {
            guard player.equalizer == nil else { return }
            let eq = Equalizer()
            eq.preampGain = EqualizerGain(Self.dialoguePreamp)
            try? eq.setBands(Self.dialogueBands)
            player.equalizer = eq
        } else if player.equalizer != nil {
            player.equalizer = nil
        }
    }

    /// Swaps in a player on the instance the effects need, reopening the media where it was.
    ///
    /// It reopens through `load`, the same path as a new video (stop, a player
    /// on the new instance, open, seek): swapping the player under a running
    /// video output left the picture black and paused.
    private func replacePlayer() {
        guard let resource else { return }
        if case .failed = snapshot.status { return }
        let position = snapshot.position
        let wasPlaying = !intendedPaused
        let subtitle = desiredSubtitleID, audio = desiredAudioID, rate = snapshot.rate
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.load(resource, startAt: max(position, 0.5)) } catch { return }
            guard self.resource == resource else { return }
            // VLC keeps track ids for the same file: the same tracks come back on.
            self.desiredAudioID = audio
            self.desiredSubtitleID = subtitle
            self.snapshot.selectedEmbeddedSubtitleID = subtitle
            self.applySubtitleSelection()
            if rate != 1 { self.setRate(rate) }
            if wasPlaying { self.play() }
        }
    }

    public func stepFrame(by count: Int) {
        guard resource != nil, count != 0 else { return }
        pause()
        if count > 0 {
            for _ in 0..<count { player.nextFrame() }
            snapshot.position = Self.seconds(player.currentTime)
        } else {
            // VLC can only step forward; step back with an exact seek.
            let fps = player.videoTracks.first(where: \.isSelected)?.frameRate ?? player.videoTracks.first?.frameRate ?? 24
            let target = max(0, snapshot.position + Double(count) / max(fps, 1))
            Task { await seek(to: target) }
        }
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
            applySubtitleSelection()
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
        if state == .playing || state == .paused, snapshot.bufferFill != nil { snapshot.bufferFill = nil }
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
        let subs = player.subtitleTracks.enumerated().map { i, t in
            MediaTrack(id: t.id, kind: .subtitle, label: Self.label(t, index: i), languageCode: t.language,
                       isBitmap: Self.isBitmapSubtitle(codec: t.codecString))
        }
        if subs != snapshot.embeddedSubtitles { snapshot.embeddedSubtitles = subs }
        snapshot.selectedAudioID = player.selectedAudioTrack?.id
        snapshot.selectedEmbeddedSubtitleID = desiredSubtitleID
    }

    /// VLC picks "default" subtitle tracks itself; Bluebox's session decides.
    private func applySubtitleSelection() {
        let current = player.selectedSubtitleTrack?.id
        guard current != desiredSubtitleID else { return }
        if let id = desiredSubtitleID {
            if let track = player.subtitleTracks.first(where: { $0.id == id }) { player.selectedSubtitleTrack = track }
        } else {
            player.selectedSubtitleTrack = nil
        }
        if let id = desiredAudioID, player.selectedAudioTrack?.id != id,
           let track = player.audioTracks.first(where: { $0.id == id }) {
            player.selectedAudioTrack = track
        }
    }

    /// Picture subtitle codecs (VLC FourCCs): PGS, VobSub, DVB, XSUB, CVD/SVCD.
    static func isBitmapSubtitle(codec: String?) -> Bool {
        guard let c = codec?.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
        return ["pgs", "pgss", "spu", "spub", "dvbs", "xsub", "cvd", "ogt", "scte", "kate"].contains(c)
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
