@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Domain
import Foundation

/// AVFoundation-backed engine. Handles MP4/MOV/M4V and HLS with the codecs the
/// OS supports (H.264, HEVC; AV1 only on hardware with an AV1 decoder).
@MainActor
public final class AVPlayerEngine: PlaybackEngine {
    public static let supportedContainers: Set<String> = ["mp4", "m4v", "mov", "m3u8", "mp3", "m4a", "ts"]

    /// A torrent served by the in-app stream server.
    nonisolated static func isLocalStream(_ url: URL) -> Bool {
        url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")
    }

    public let player = AVPlayer()
    public private(set) var snapshot = PlaybackSnapshot() {
        didSet { if snapshot != oldValue { onChange?(snapshot) } }
    }
    public var onChange: ((PlaybackSnapshot) -> Void)?

    private var item: AVPlayerItem?
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var notificationTasks: [Task<Void, Never>] = []
    private var scopedRoot: URL?
    private var isSeeking = false
    /// Bumped by every seek, so an older seek finishing late doesn't clear `isSeeking`.
    private var seekGeneration = 0
    /// Latest timeline position while scrubbing, waiting for the seek in flight.
    private var scrubTarget: TimeInterval?
    private var chaseInFlight = false
    private var videoCodec: String?
    private var resource: PlaybackResource?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var legibleOutput: AVPlayerItemLegibleOutput?
    private let legibleReceiver = LegibleReceiver()
    private var asset: AVURLAsset?
    private let adjustmentsBox = AdjustmentsBox()
    private var adjustments = VideoAdjustments()
    private let audioSwitches = AudioEffectsSwitch()
    private var audioEffects = AudioEffects()
    private var watchdog = PlaybackWatchdog()
    private var watchdogTask: Task<Void, Never>?
    private var isRecovering = false
    /// The user pressed play and hasn't paused since; recovery resumes only then.
    private var wantsPlayback = false

    /// Reads custom-scheme URLs (torrents that are still downloading).
    private let streams: (any StreamDataProvider)?
    private var streamLoader: StreamResourceLoader?

    public init(streams: (any StreamDataProvider)? = nil) {
        self.streams = streams
        player.automaticallyWaitsToMinimizeStalling = true
        #if os(iOS)
        player.allowsExternalPlayback = true  // AirPlay video
        #endif
        player.appliesMediaSelectionCriteriaAutomatically = false
    }

    public func load(_ resource: PlaybackResource, startAt: TimeInterval?) async throws {
        stop()
        guard Self.canAttempt(container: resource.variant.container ?? resource.url.pathExtension) else {
            fail(.unsupportedFormat(resource.variant.container ?? resource.url.pathExtension))
            throw PlaybackError.unsupportedFormat(resource.variant.container ?? "unknown")
        }
        snapshot = PlaybackSnapshot()
        snapshot.status = .loading
        watchdog.reset()
        self.resource = resource

        if let root = resource.securityScopedRoot, root.startAccessingSecurityScopedResource() {
            scopedRoot = root
        }

        do {
            try await attach(resource, startAt: startAt, isResume: true)
        } catch let e as PlaybackError {
            fail(e); throw e
        }
        startWatchdog()
    }

    /// Opens the asset, builds an item and makes it current. Throws `PlaybackError`.
    /// A resume point (`isResume`) in the file's closing stretch starts over instead.
    private func attach(_ resource: PlaybackResource, startAt: TimeInterval?, isResume: Bool = false) async throws {
        let asset = AVURLAsset(url: resource.url)
        if let streams, streams.canProvide(resource.url) {
            let loader = StreamResourceLoader(provider: streams)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            streamLoader = loader
            // Waiting on peers is normal here; only reopen after a long stall.
            watchdog.stallThreshold = 60
        } else if Self.isLocalStream(resource.url) {
            // libtorrent's localhost stream server: the same, a stall is peers
            // being slow, and reopening only throws away the connection.
            watchdog.stallThreshold = 60
        } else {
            watchdog.stallThreshold = PlaybackWatchdog().stallThreshold
        }
        do {
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            guard playable else { throw PlaybackError.unsupportedFormat(resource.variant.container ?? "codec") }
            if duration.isNumeric { snapshot.duration = duration.seconds }
            audioGroup = try await asset.loadMediaSelectionGroup(for: .audible)
            legibleGroup = try await asset.loadMediaSelectionGroup(for: .legible)
        } catch {
            throw Self.map(error)
        }
        guard self.resource == resource else { throw CancellationError() }

        self.asset = asset
        videoCodec = nil
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let desc = try? await track.load(.formatDescriptions).first {
            videoCodec = Self.codecName(CMFormatDescriptionGetMediaSubType(desc))
        }
        let isHLS = (resource.variant.container ?? resource.url.pathExtension).lowercased() == "m3u8"
        snapshot.supportsVideoAdjustments = !isHLS
        snapshot.supportsAudioEffects = !isHLS  // AVFoundation ignores audio mixes for HLS
        if let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages) {
            var chapters: [Chapter] = []
            for (i, g) in groups.enumerated() {
                let start = g.timeRange.start.seconds
                guard start.isFinite else { continue }
                let item = AVMetadataItem.metadataItems(from: g.items, filteredByIdentifier: .commonIdentifierTitle).first
                let title = (try? await item?.load(.stringValue)) ?? nil
                chapters.append(Chapter(title: title ?? "Chapter \(i + 1)", start: start))
            }
            snapshot.chapters = chapters
        }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0  // let AVFoundation choose
        // Only used to notice frozen video; frames are read and dropped.
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        videoOutput = output
        // Embedded text subtitles are drawn by Bluebox so the subtitle style applies.
        let legible = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
        legible.suppressesPlayerRendering = true
        legible.setDelegate(legibleReceiver, queue: .main)
        legibleReceiver.onText = { [weak self] text in
            guard let self, self.snapshot.selectedEmbeddedSubtitleID != nil else { return }
            if self.snapshot.embeddedSubtitleText != text { self.snapshot.embeddedSubtitleText = text }
        }
        item.add(legible)
        legibleOutput = legible
        self.item = item
        observe(item)
        player.replaceCurrentItem(with: item)
        publishTracks(for: item)
        // Embedded subtitles start off; the session decides what to show.
        if let legibleGroup { item.select(nil, in: legibleGroup) }

        if !adjustments.isDefault, !isHLS { await applyComposition(to: item) }
        if audioEffects.isActive, !isHLS { await installAudioTap(on: item) }

        let start = isResume ? ProgressPolicy.standard.startPosition(resumingAt: startAt, duration: snapshot.duration) : startAt
        if let start, start > 0 {
            await seek(to: start)
        }
    }

    // MARK: Picture

    public func setVideoAdjustments(_ a: VideoAdjustments) {
        var a = a; a.clamp()
        let wasDefault = adjustments.isDefault
        adjustments = a
        adjustmentsBox.set(a)
        guard let item, snapshot.supportsVideoAdjustments else { return }
        if a.isDefault {
            item.videoComposition = nil  // full quality (and HDR) when nothing is adjusted
        } else if wasDefault || item.videoComposition == nil {
            Task { await applyComposition(to: item) }
        } else if player.timeControlStatus == .paused {
            // A paused frame isn't re-rendered on its own; redraw it in place.
            Task { await seek(to: snapshot.position) }
        }
    }

    // MARK: Sound

    public func setAudioEffects(_ e: AudioEffects) {
        audioEffects = e
        audioSwitches.set(e)  // the tap reads this live; no rebuild needed
        guard e.isActive, let item, item.audioMix == nil, snapshot.supportsAudioEffects else { return }
        Task { await installAudioTap(on: item) }
    }

    /// Puts the effects tap on every audio track. It stays once installed and
    /// passes audio through untouched while both effects are off.
    private func installAudioTap(on item: AVPlayerItem) async {
        guard let asset, item.audioMix == nil,
              let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              item === self.item, item.audioMix == nil else { return }
        item.audioMix = AudioEffectsTap.audioMix(for: tracks, switches: audioSwitches)
    }

    private func applyComposition(to item: AVPlayerItem) async {
        guard let asset else { return }
        let box = adjustmentsBox
        guard let composition = try? await AVVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
            request.finish(with: box.apply(to: request.sourceImage).cropped(to: request.sourceImage.extent), context: nil)
        }) else { return }
        guard item === self.item else { return }
        item.videoComposition = composition
    }

    public func stepFrame(by count: Int) {
        guard let item, count != 0 else { return }
        player.pause()
        item.step(byCount: count)
        let t = item.currentTime().seconds
        if t.isFinite { snapshot.position = t }
    }

    public func captureFrame() async -> CGImage? {
        guard let item else { return nil }
        let time = item.currentTime()
        if let asset, snapshot.supportsVideoAdjustments {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            if let composition = item.videoComposition { gen.videoComposition = composition }
            if let (image, _) = try? await gen.image(at: time) { return image }
        }
        // HLS: grab the decoded frame from the video output.
        if let output = videoOutput, let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            let ci = CIImage(cvPixelBuffer: buffer)
            return CIContext().createCGImage(ci, from: ci.extent)
        }
        return nil
    }

    public func play() {
        guard item != nil else { return }
        wantsPlayback = true
        if snapshot.status == .ended { Task { await seek(to: 0); player.playImmediately(atRate: snapshot.rate) } ; return }
        player.playImmediately(atRate: snapshot.rate)
    }

    public func pause() { wantsPlayback = false; player.pause() }

    public func seek(to seconds: TimeInterval) async {
        guard let item else { return }
        var target = max(0, seconds)
        if let d = snapshot.duration { target = min(target, max(d - 0.5, 0)) }
        isSeeking = true
        seekGeneration += 1
        let generation = seekGeneration
        scrubTarget = nil
        watchdog.noteSeek()
        snapshot.position = target
        if snapshot.status == .ended { snapshot.status = .paused }
        let time = CMTime(seconds: target, preferredTimescale: 600)
        // Exact seeks keep resume positions and scrubbing honest; tolerance only
        // matters for long-GOP HLS where it's still accurate to the frame.
        // A newer seek cancels this one; only the latest clears `isSeeking`.
        _ = await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        guard generation == seekGeneration else { return }
        isSeeking = false
        snapshot.position = item.currentTime().seconds.isFinite ? item.currentTime().seconds : target
    }

    /// Chases the finger: one keyframe-tolerant seek at a time, always to the
    /// latest target, so the picture keeps up without queueing stale seeks.
    public func scrub(to seconds: TimeInterval) {
        guard item != nil else { return }
        var target = max(0, seconds)
        if let d = snapshot.duration { target = min(target, max(d - 0.5, 0)) }
        scrubTarget = target
        if snapshot.status == .ended { snapshot.status = .paused }
        if !chaseInFlight { chaseScrub() }
    }

    private func chaseScrub() {
        guard let item, let target = scrubTarget else { chaseInFlight = false; return }
        scrubTarget = nil
        chaseInFlight = true
        isSeeking = true
        seekGeneration += 1
        let generation = seekGeneration
        watchdog.noteSeek()
        let tolerance = CMTime(seconds: 0.4, preferredTimescale: 600)
        item.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.chaseInFlight = false
                guard generation == self.seekGeneration else { return }  // an exact seek took over
                if self.scrubTarget != nil { self.chaseScrub() } else { self.isSeeking = false }
            }
        }
    }

    public func diagnostics() -> PlaybackDiagnostics {
        var d = PlaybackDiagnostics(engine: "AVPlayer")
        let ext = (resource?.variant.container ?? resource?.url.pathExtension ?? "").lowercased()
        d.container = ext == "m3u8" ? "HLS" : (ext.isEmpty ? nil : ext.uppercased())
        d.source = PlaybackDiagnostics.sourceKind(of: resource?.url)
        if let event = item?.accessLog()?.events.last {
            let observed = event.observedBitrate, indicated = event.indicatedBitrate
            if observed.isFinite, observed > 0 { d.bitrate = observed } else if indicated.isFinite, indicated > 0 { d.bitrate = indicated }
            if event.numberOfDroppedVideoFrames >= 0 { d.droppedFrames = event.numberOfDroppedVideoFrames }
        }
        d.videoCodec = videoCodec
        return d
    }

    nonisolated static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_H264: "H.264"
        case kCMVideoCodecType_HEVC, 0x68657631 /* hev1 */: "HEVC"
        case 0x61763031 /* av01 */: "AV1"
        case kCMVideoCodecType_MPEG4Video: "MPEG-4"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes4444: "ProRes"
        default:
            String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces).uppercased() ?? "Unknown"
        }
    }

    public func setVolume(_ volume: Float, muted: Bool) {
        player.volume = volume
        player.isMuted = muted
    }

    public func setRate(_ rate: Float) {
        let r = min(max(rate, 0.25), 4)
        snapshot.rate = r
        player.defaultRate = r
        if player.timeControlStatus != .paused { player.rate = r }
    }

    public func selectAudio(_ trackID: String?) {
        guard let item, let audioGroup else { return }
        let option = trackID.flatMap { id in audioGroup.options.indices.first { "a\($0)" == id }.map { audioGroup.options[$0] } }
        item.select(option ?? audioGroup.defaultOption, in: audioGroup)
        snapshot.selectedAudioID = trackID
    }

    public func selectEmbeddedSubtitle(_ trackID: String?) {
        guard let item, let legibleGroup else { return }
        let option = trackID.flatMap { id in legibleGroup.options.indices.first { "s\($0)" == id }.map { legibleGroup.options[$0] } }
        item.select(option, in: legibleGroup)
        snapshot.selectedEmbeddedSubtitleID = option == nil ? nil : trackID
        snapshot.embeddedSubtitleText = nil
    }

    public func stop() {
        player.pause()
        watchdogTask?.cancel(); watchdogTask = nil
        wantsPlayback = false
        resource = nil
        detachItem()
        if let scopedRoot { scopedRoot.stopAccessingSecurityScopedResource() }
        scopedRoot = nil
        if snapshot.status != .idle { snapshot.status = .idle }
    }

    private func detachItem() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        notificationTasks.forEach { $0.cancel() }
        notificationTasks = []
        player.replaceCurrentItem(with: nil)
        item = nil; audioGroup = nil; legibleGroup = nil; videoOutput = nil; legibleOutput = nil; asset = nil
        snapshot.embeddedSubtitleText = nil
        streamLoader?.cancelAll(); streamLoader = nil
        scrubTarget = nil; seekGeneration += 1; isSeeking = false
    }

    // MARK: Recovery

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        guard let item, !isSeeking, !isRecovering, item.status == .readyToPlay else { return }
        let state: PlaybackWatchdog.Sample.State = switch player.timeControlStatus {
        case .playing: .playing
        case .waitingToPlayAtSpecifiedRate: wantsPlayback ? .waiting : .paused
        default: .paused
        }
        let now = item.currentTime()
        var newFrame = false
        if let videoOutput, videoOutput.hasNewPixelBuffer(forItemTime: now) {
            _ = videoOutput.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil)
            newFrame = true
        }
        let watchesVideo = item.presentationSize != .zero && !player.isExternalPlaybackActive
        let sample = PlaybackWatchdog.Sample(
            state: state, position: now.seconds.isFinite ? now.seconds : snapshot.position,
            newFrame: newFrame, watchesVideo: watchesVideo, now: ProcessInfo.processInfo.systemUptime)
        perform(watchdog.observe(sample))
    }

    private func perform(_ action: PlaybackWatchdog.Action) {
        switch action {
        case .none, .giveUp: break
        case .nudgeVideo:
            Log.playback.notice("Video stopped updating while playing; restarting decode")
            let at = snapshot.position
            Task { await seek(to: at); if wantsPlayback { player.playImmediately(atRate: snapshot.rate) } }
        case .reload:
            Task { await reload() }
        }
    }

    /// Rebuilds the item at the current position, keeping track selections.
    private func reload() async {
        guard let resource, !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }
        Log.playback.notice("Reopening stream at \(self.snapshot.position, privacy: .public)s (attempt \(self.watchdog.reloads))")
        let position = snapshot.position, audio = snapshot.selectedAudioID
        let subtitle = snapshot.selectedEmbeddedSubtitleID, resume = wantsPlayback
        detachItem()
        snapshot.status = .buffering
        while true {
            do {
                try await attach(resource, startAt: position)
                break
            } catch let e as PlaybackError {
                guard self.resource == resource else { return }
                // Still offline: wait and try again while retries last.
                guard case .unreachable = e, watchdog.recoverableFailure() == .reload else { fail(e); return }
                try? await Task.sleep(for: .seconds(2))
                guard self.resource == resource else { return }
            } catch {
                return  // stopped or replaced meanwhile
            }
        }
        if audio != nil { selectAudio(audio) }
        if subtitle != nil { selectEmbeddedSubtitle(subtitle) }
        if resume { player.playImmediately(atRate: snapshot.rate) }
    }

    /// Network failures get a fresh connection before they're shown.
    private func handleFailure(_ error: PlaybackError) {
        if case .unreachable = error, resource != nil, !isRecovering, watchdog.recoverableFailure() == .reload {
            Task { await reload() }
            return
        }
        fail(error)
    }

    // MARK: Observation

    private func observe(_ item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncStatus() }
        })
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                guard item === self.item else { return }
                if item.status == .failed { self.handleFailure(Self.map(item.error)) } else { self.syncStatus() }
            }
        })
        observations.append(item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.snapshot.presentationSize = item.presentationSize }
        })
        let center = NotificationCenter.default
        notificationTasks.append(Task { [weak self] in
            for await _ in center.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                guard let self else { return }
                if let d = self.snapshot.duration { self.snapshot.position = d }
                self.snapshot.status = .ended
            }
        })
        notificationTasks.append(Task { [weak self] in
            for await n in center.notifications(named: AVPlayerItem.failedToPlayToEndTimeNotification, object: item) {
                let err = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.handleFailure(Self.map(err))
            }
        })
    }

    private func tick(_ time: CMTime) {
        guard !isSeeking, let item else { return }
        if time.seconds.isFinite { snapshot.position = time.seconds }
        if snapshot.duration == nil, item.duration.isNumeric { snapshot.duration = item.duration.seconds }
        if let range = item.loadedTimeRanges.last?.timeRangeValue {
            let end = (range.start + range.duration).seconds
            if end.isFinite { snapshot.bufferedUntil = end }
        }
    }

    private func syncStatus() {
        if case .failed = snapshot.status { return }
        if snapshot.status == .ended, player.timeControlStatus == .paused { return }
        guard item?.status == .readyToPlay else { return }
        switch player.timeControlStatus {
        case .playing: snapshot.status = .playing
        case .waitingToPlayAtSpecifiedRate: snapshot.status = .buffering
        case .paused: snapshot.status = .paused
        @unknown default: break
        }
    }

    private func publishTracks(for item: AVPlayerItem) {
        snapshot.audioTracks = audioGroup.map { g in
            g.options.enumerated().map { i, o in
                MediaTrack(id: "a\(i)", kind: .audio, label: Self.label(for: o, index: i), languageCode: o.extendedLanguageTag)
            }
        } ?? []
        // Hide forced-only tracks; AVFoundation shows them automatically with their main track.
        snapshot.embeddedSubtitles = legibleGroup.map { g in
            g.options.enumerated().compactMap { i, o in
                o.hasMediaCharacteristic(.containsOnlyForcedSubtitles) ? nil
                    : MediaTrack(id: "s\(i)", kind: .subtitle, label: Self.label(for: o, index: i), languageCode: o.extendedLanguageTag)
            }
        } ?? []
        if let audioGroup, let selected = item.currentMediaSelection.selectedMediaOption(in: audioGroup),
           let idx = audioGroup.options.firstIndex(of: selected) {
            snapshot.selectedAudioID = "a\(idx)"
        }
    }

    static func label(for option: AVMediaSelectionOption, index: Int) -> String {
        var name = option.displayName
        if name.isEmpty || name == "Unknown" { name = "Track \(index + 1)" }
        if option.hasMediaCharacteristic(.describesVideoForAccessibility) { name += " (AD)" }
        if option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility) { name += " (SDH)" }
        return name
    }

    private func fail(_ error: PlaybackError) {
        Log.playback.error("Playback failed: \(error.localizedDescription, privacy: .public)")
        player.pause()
        snapshot.status = .failed(error)
    }

    static func map(_ error: Error?) -> PlaybackError {
        guard let error else { return .decodeFailed("Unknown error") }
        if let e = error as? PlaybackError { return e }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .unreachable(ns.localizedDescription) }
        if ns.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: ns.code) {
            case .fileFormatNotRecognized, .decoderNotFound, .formatUnsupported, .contentIsUnavailable, .failedToParse:
                return .unsupportedFormat(ns.localizedDescription)
            default: break
            }
        }
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        if let underlying, underlying.domain == NSURLErrorDomain {
            return .unreachable(underlying.localizedDescription)
        }
        // CoreMedia -12746 / CoreAudio -66680: no usable audio output (seen in
        // the Simulator when the Mac's default output is a Bluetooth device).
        if let code = underlying?.code, code == -12746 || code == -66680 {
            return .decodeFailed("No audio output device is available. Check the device's sound output and try again.")
        }
        let detail = underlying.map { " (\($0.domain) \($0.code))" } ?? " (\(ns.domain) \(ns.code))"
        return .decodeFailed(ns.localizedDescription + detail)
    }
}

/// Receives embedded subtitle text from AVFoundation on the main queue.
final class LegibleReceiver: NSObject, AVPlayerItemLegibleOutputPushDelegate, @unchecked Sendable {
    var onText: (@MainActor (String?) -> Void)?

    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        let text = strings.map(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let value = text.isEmpty ? nil : text
        MainActor.assumeIsolated { onText?(value) }
    }
}

/// Current picture adjustments, read by the Core Image handler on AVFoundation's thread.
final class AdjustmentsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = VideoAdjustments()
    func set(_ v: VideoAdjustments) { lock.withLock { value = v } }

    func apply(to input: CIImage) -> CIImage {
        let a = lock.withLock { value }
        var img = input
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = img; f.brightness = Float(a.brightness * 0.5); f.contrast = Float(a.contrast); f.saturation = Float(a.saturation)
            img = f.outputImage ?? img
        }
        if a.hue != 0 {
            let f = CIFilter.hueAdjust(); f.inputImage = img; f.angle = Float(a.hue * .pi / 180)
            img = f.outputImage ?? img
        }
        if a.gamma != 1 {
            let f = CIFilter.gammaAdjust(); f.inputImage = img; f.power = Float(1 / a.gamma)
            img = f.outputImage ?? img
        }
        if a.sharpness > 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = img; f.sharpness = Float(a.sharpness)
            img = f.outputImage ?? img
        }
        if a.invert {
            let f = CIFilter.colorInvert(); f.inputImage = img
            img = f.outputImage ?? img
        }
        return img
    }
}
