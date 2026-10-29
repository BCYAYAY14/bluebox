import CoreGraphics
import Domain
import Foundation
import Observation
import Subtitles

/// What is playing, independent of where the bytes come from.
public struct NowPlayingItem: Hashable, Sendable {
    /// Movie key or episode key; progress is stored under this.
    public let key: MediaKey
    public let title: String
    /// "S1·E3 · Episode name", or the year for movies.
    public let subtitle: String?
    public let artworkURL: URL?
    public init(key: MediaKey, title: String, subtitle: String? = nil, artworkURL: URL? = nil) {
        self.key = key; self.title = title; self.subtitle = subtitle; self.artworkURL = artworkURL
    }
}

public enum SubtitleSelection: Hashable, Sendable {
    case off
    case embedded(String)
    case external(String)
}

/// Supplies the episode after `key`, already resolved to a playable resource.
public typealias NextItemProvider = @MainActor @Sendable (MediaKey) async -> (NowPlayingItem, PlaybackResource)?

/// Drives one playback session: resume, progress persistence, subtitles,
/// speed, and up-next. UI binds to this; the engine stays swappable.
@Observable
@MainActor
public final class PlayerSession {
    public struct UpNext: Equatable, Sendable {
        public let item: NowPlayingItem
        public var secondsRemaining: Int
    }

    public private(set) var snapshot = PlaybackSnapshot()
    public private(set) var item: NowPlayingItem?
    public private(set) var externalSubtitles: [MediaTrack] = []
    public private(set) var subtitleSelection: SubtitleSelection = .off
    public private(set) var subtitleOffset = SubtitleOffset()
    public private(set) var subtitleText: String?
    /// Second subtitle track shown with the first (dual subtitles). External tracks only.
    public private(set) var secondarySubtitleID: String?
    public private(set) var secondarySubtitleText: String?
    public private(set) var subtitleError: String?
    public private(set) var upNext: UpNext?

    // VLC-style tools
    /// Picture framing (aspect, crop, zoom, rotation). The view applies it.
    public var videoFraming = VideoFraming()
    public private(set) var videoAdjustments = VideoAdjustments()
    /// Dialogue boost and night mode; carried over when the engine changes.
    public private(set) var audioEffects = AudioEffects()
    /// A–B repeat: playback jumps back to `loopStart` on reaching `loopEnd`.
    public private(set) var loopStart: TimeInterval?
    public private(set) var loopEnd: TimeInterval?
    public enum SleepTimer: Equatable, Sendable { case off, at(Date), endOfItem }
    public private(set) var sleepTimer: SleepTimer = .off
    /// Output volume 0…1 and mute; kept across episodes and engine swaps.
    public private(set) var volume: Float = 1
    public private(set) var isMuted = false
    /// Sound against picture, in seconds (positive plays it later). VLC only.
    public private(set) var audioDelay: TimeInterval = 0
    /// Also sent to the engine, which draws embedded text subtitles itself (VLC).
    public var subtitleStyle = SubtitleStyle() {
        didSet { if subtitleStyle != oldValue { engine.setEmbeddedSubtitleStyle(subtitleStyle) } }
    }
    /// True while the subtitle panel is open (see `PlaybackEngine.setSubtitleRestyleHeld`).
    public var holdsSubtitleRestyle = false {
        didSet { if holdsSubtitleRestyle != oldValue { engine.setSubtitleRestyleHeld(holdsSubtitleRestyle) } }
    }
    /// The audio and subtitle choices made in this session, applied to every
    /// item it plays next (Up Next, Next Episode, the Episodes list).
    public private(set) var rememberedAudio: TrackChoice?
    public private(set) var rememberedSubtitle: TrackChoice?
    /// Set while the remembered choices wait for the new item's tracks.
    @ObservationIgnored private var restoreTracksPending = false
    /// The play/pause state just asked for, shown until the engine agrees.
    public private(set) var optimisticPlaying: Bool?
    @ObservationIgnored private var optimisticTask: Task<Void, Never>?
    /// Where a seek is headed, shown on the timeline until the engine gets there.
    public private(set) var seekTarget: TimeInterval?
    /// When false, an ending episode doesn't count down into the next one (Settings › Playback).
    public var autoplayNext = true

    public var error: PlaybackError? {
        if case .failed(let e) = snapshot.status { return e }
        return nil
    }

    /// Observed: it can be replaced between items (see `engineSwitcher`).
    public private(set) var engine: any PlaybackEngine
    /// Returns a different engine when the next resource needs one (e.g. an MKV
    /// episode after an MP4 one); nil keeps the current engine.
    @ObservationIgnored public var engineSwitcher: (@MainActor (PlaybackResource, any PlaybackEngine) -> (any PlaybackEngine)?)?
    @ObservationIgnored let progress: any ProgressRepository
    /// After each saved position, with whether it's still playing (sync sends it to other devices).
    @ObservationIgnored public var onProgressSaved: (@MainActor (_ playing: Bool) -> Void)?
    @ObservationIgnored let policy: ProgressPolicy
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored let deviceID: String?
    @ObservationIgnored let subtitleLoader: SubtitleLoader
    @ObservationIgnored let nextProvider: NextItemProvider?
    @ObservationIgnored let upNextCountdown: Int
    @ObservationIgnored let saveInterval: TimeInterval

    @ObservationIgnored private var resource: PlaybackResource?
    @ObservationIgnored private var externalByID: [String: ExternalSubtitle] = [:]
    @ObservationIgnored private var timeline: SubtitleTimeline?
    @ObservationIgnored private var secondaryTimeline: SubtitleTimeline?
    @ObservationIgnored private var secondaryTask: Task<Void, Never>?
    /// The first point of a two-point sync, waiting for the second.
    public private(set) var pendingSyncPoint: (cue: TimeInterval, heard: TimeInterval)?
    @ObservationIgnored private var lastSavedPosition: TimeInterval?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var upNextTask: Task<Void, Never>?
    /// What the provider returned for the Up Next card, reused when it plays.
    @ObservationIgnored private var upNextResource: (NowPlayingItem, PlaybackResource)?
    /// Called after any item starts (first play, Up Next, Next Episode), so the
    /// app can apply its playback defaults (speed, audio language, subtitle delay).
    @ObservationIgnored public var onItemStarted: (@MainActor (NowPlayingItem) async -> Void)?
    @ObservationIgnored private var subtitleTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var looping = false
    /// True while `start` swaps items: the old engine may still report positions, which
    /// mustn't be saved under the new item.
    @ObservationIgnored private var isStarting = false

    public init(
        engine: any PlaybackEngine, progress: any ProgressRepository, policy: ProgressPolicy = .standard,
        deviceID: String? = nil, subtitleLoader: SubtitleLoader = SubtitleLoader(),
        nextProvider: NextItemProvider? = nil, upNextCountdown: Int = 10, saveInterval: TimeInterval = 10,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine; self.progress = progress; self.policy = policy; self.deviceID = deviceID
        self.subtitleLoader = subtitleLoader; self.nextProvider = nextProvider
        self.upNextCountdown = upNextCountdown; self.saveInterval = saveInterval; self.now = now
        engine.onChange = { [weak self] s in self?.engineChanged(s) }
        engine.setEmbeddedSubtitleStyle(subtitleStyle)
    }

    // MARK: Lifecycle

    /// Loads and starts playback, resuming from saved progress when appropriate.
    /// - Parameter startAt: an explicit position (Handoff) that wins over `resume`
    ///   and saved progress.
    public func start(_ item: NowPlayingItem, resource: PlaybackResource, resume: Bool = true,
                      startAt explicitStart: TimeInterval? = nil, autoplay: Bool = true) async {
        await persistProgress()
        cancelUpNext()
        isStarting = true
        defer { isStarting = false }
        engine.pause()
        self.item = item
        self.resource = resource
        lastSavedPosition = nil
        timeline = nil; subtitleText = nil; subtitleError = nil; subtitleSelection = .off
        secondaryTimeline = nil; secondarySubtitleID = nil; secondarySubtitleText = nil; pendingSyncPoint = nil
        loopStart = nil; loopEnd = nil
        isScrubbing = false; resumesAfterScrub = false
        videoFraming = VideoFraming()
        externalByID = Dictionary(resource.externalSubtitles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        externalSubtitles = resource.externalSubtitles.map {
            MediaTrack(id: $0.id, kind: .subtitle, label: $0.label, languageCode: $0.languageCode, isExternal: true)
        }

        if let replacement = engineSwitcher?(resource, engine) { replaceEngine(with: replacement) }

        let saved = resume && explicitStart == nil ? (try? await progress.progress(for: item.key)) ?? nil : nil
        let startAt = explicitStart.flatMap { $0 > 0 ? $0 : nil } ?? policy.resumePosition(for: saved)
        do {
            try await engine.load(resource, startAt: startAt)
        } catch {
            return  // engine published .failed
        }
        lastSavedPosition = startAt ?? 0
        engine.setEmbeddedSubtitleDelay(subtitleOffset.seconds)
        engine.setVolume(volume, muted: isMuted)
        engine.setAudioDelay(audioDelay)
        applyPreferredSubtitle()
        restoreTracksPending = rememberedAudio != nil || rememberedSubtitle != nil
        restoreRememberedTracks()
        if autoplay { engine.play() }
        // Every item, including Up Next and Next Episode, gets the app's playback defaults.
        await onItemStarted?(item)
    }

    private func replaceEngine(with replacement: any PlaybackEngine) {
        let rate = engine.snapshot.rate
        engine.onChange = nil
        engine.stop()
        engine = replacement
        engine.onChange = { [weak self] s in self?.engineChanged(s) }
        engine.setRate(rate)
        engine.setVideoAdjustments(videoAdjustments)
        engine.setAudioEffects(audioEffects)
        engine.setEmbeddedSubtitleStyle(subtitleStyle)
        engine.setEmbeddedSubtitleDelay(subtitleOffset.seconds)
        engine.setVolume(volume, muted: isMuted)
        engine.setAudioDelay(audioDelay)
        engineChanged(engine.snapshot)
    }

    /// Saves progress and releases the engine.
    public func end() async {
        cancelUpNext()
        subtitleTask?.cancel()
        secondaryTask?.cancel()
        sleepTask?.cancel(); sleepTimer = .off
        await persistProgress()
        engine.stop()
        item = nil
        resource = nil
    }

    // MARK: Transport

    /// Flips at once on screen; the engine catches up (VLC can take a moment).
    public func togglePlayPause() {
        let play = !appearsPlaying
        setOptimistic(play)
        if play { engine.play() } else { engine.pause() }
    }

    private func setOptimistic(_ playing: Bool?) {
        optimisticTask?.cancel()
        optimisticPlaying = playing
        guard playing != nil else { return }
        // Never stuck: after a couple of seconds the engine's word is final.
        optimisticTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.optimisticPlaying = nil
        }
    }

    public func seek(to seconds: TimeInterval) async {
        cancelUpNext()
        let target = max(0, snapshot.duration.map { min(seconds, max($0 - 0.5, 0)) } ?? seconds)
        seekTarget = target
        await engine.seek(to: target)
        if seekTarget == target { seekTarget = nil }
        updateSubtitleText()
        await persistProgress()
    }

    /// The position to show: where a seek is going, or where playback is.
    public var displayPosition: TimeInterval { seekTarget ?? snapshot.position }

    /// True while the user drags the timeline. Playback pauses underneath and
    /// resumes on release if it was playing.
    public private(set) var isScrubbing = false
    /// Whether playback resumes when the current scrub ends.
    public private(set) var resumesAfterScrub = false

    /// What the play/pause button should show: during a scrub, the state the
    /// player returns to, so the glyph doesn't flicker.
    public var appearsPlaying: Bool { isScrubbing ? resumesAfterScrub : (optimisticPlaying ?? snapshot.status.isActive) }

    /// Live preview while dragging the timeline: fast, approximate seeks.
    public func scrub(to seconds: TimeInterval) {
        if !isScrubbing {
            isScrubbing = true
            cancelUpNext()
            resumesAfterScrub = snapshot.status.isActive
            if resumesAfterScrub { engine.pause() }
        }
        engine.scrub(to: seconds)
    }

    /// Ends a scrub with one exact seek, then resumes if it was playing.
    public func endScrub(at seconds: TimeInterval) async {
        let resume = isScrubbing ? resumesAfterScrub : snapshot.status.isActive
        isScrubbing = false
        resumesAfterScrub = false
        await seek(to: seconds)
        if resume, !isScrubbing { engine.play() }
    }

    /// Taps in quick succession add up (from where the last one was headed).
    public func skip(by delta: TimeInterval) async {
        await seek(to: displayPosition + delta)
    }

    public func setRate(_ rate: Float) { engine.setRate(rate) }

    public func setVolume(_ volume: Float) {
        self.volume = min(max(volume.isFinite ? volume : 1, 0), 1)
        if self.volume > 0 { isMuted = false }
        engine.setVolume(self.volume, muted: isMuted)
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        // Unmuting at zero would stay silent: come back at a usable level.
        if !muted, volume < 0.05 { volume = 0.5 }
        engine.setVolume(volume, muted: isMuted)
    }

    public var supportsAudioDelay: Bool { engine.supportsAudioDelay }

    /// Audio delay in 1 ms resolution, within ±5 s.
    public func setAudioDelay(_ seconds: TimeInterval) {
        audioDelay = min(max(((seconds.isFinite ? seconds : 0) * 1000).rounded() / 1000, -5), 5)
        engine.setAudioDelay(audioDelay)
    }

    /// - Parameter remember: a person chose it: keep the language for the next items.
    public func selectAudio(_ id: String?, remember: Bool = true) {
        engine.selectAudio(id)
        if remember, let id, let t = snapshot.audioTracks.first(where: { $0.id == id }) {
            rememberedAudio = TrackChoice(t, index: snapshot.audioTracks.firstIndex(of: t))
            restoreTracksPending = false
        }
    }

    // MARK: Tools

    public func setAudioEffects(_ e: AudioEffects) {
        audioEffects = e
        engine.setAudioEffects(e)
    }

    /// What's loaded now (for preview thumbnails and Handoff). Not observed.
    public var currentResource: PlaybackResource? { resource }

    public func setVideoAdjustments(_ a: VideoAdjustments) {
        videoAdjustments = a
        engine.setVideoAdjustments(a)
    }

    public func stepFrame(by count: Int) {
        cancelUpNext()
        engine.stepFrame(by: count)
    }

    public func captureFrame() async -> CGImage? { await engine.captureFrame() }

    /// First press sets A, second sets B (after A), third clears.
    public func cycleLoop() {
        let now = snapshot.position
        if loopStart == nil { loopStart = now }
        else if loopEnd == nil, now > (loopStart ?? 0) + 0.5 { loopEnd = now }
        else { loopStart = nil; loopEnd = nil }
    }

    public func clearLoop() { loopStart = nil; loopEnd = nil }

    public var currentChapterIndex: Int? {
        snapshot.chapters.lastIndex { $0.start <= snapshot.position + 0.5 }
    }

    public func jumpToChapter(offset: Int) async {
        let chapters = snapshot.chapters
        guard !chapters.isEmpty else { return }
        let current = currentChapterIndex ?? -1
        // "Previous" within the first few seconds of a chapter goes to the one before.
        var target = current + offset
        if offset < 0, let i = currentChapterIndex, snapshot.position - chapters[i].start > 3 { target = i }
        guard chapters.indices.contains(target) else { return }
        await seek(to: chapters[target].start)
    }

    public func setSleepTimer(_ timer: SleepTimer) {
        sleepTask?.cancel(); sleepTask = nil
        sleepTimer = timer
        guard case .at(let date) = timer else { return }
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.engine.pause()
            self.sleepTimer = .off
        }
    }

    // MARK: Subtitles

    public var allSubtitleTracks: [MediaTrack] { snapshot.embeddedSubtitles + externalSubtitles }

    /// - Parameter remember: a person chose it: keep the language (or Off) for the next items.
    public func selectSubtitle(_ selection: SubtitleSelection, remember: Bool = true) {
        if remember {
            switch selection {
            case .off: rememberedSubtitle = .off
            case .embedded(let id), .external(let id):
                let all = allSubtitleTracks
                if let t = all.first(where: { $0.id == id }) { rememberedSubtitle = TrackChoice(t, index: all.firstIndex(of: t)) }
            }
            restoreTracksPending = false
        }
        subtitleTask?.cancel()
        subtitleError = nil
        subtitleSelection = selection
        switch selection {
        case .off:
            engine.selectEmbeddedSubtitle(nil)
            timeline = nil
        case .embedded(let id):
            timeline = nil
            engine.selectEmbeddedSubtitle(id)
        case .external(let id):
            engine.selectEmbeddedSubtitle(nil)
            timeline = nil
            guard let sub = externalByID[id] else { return }
            let loader = subtitleLoader
            subtitleTask = Task { [weak self] in
                do {
                    let t = try await loader.load(sub.url, format: SubtitleFormat(fileExtension: sub.format))
                    guard !Task.isCancelled, let self, self.subtitleSelection == selection else { return }
                    self.timeline = t
                    self.updateSubtitleText()
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.subtitleError = (error as? LocalizedError)?.errorDescription ?? "Subtitles couldn't be loaded."
                    self.subtitleSelection = .off
                }
            }
        }
        updateSubtitleText()
    }

    /// Adds a user-imported subtitle file and selects it.
    public func importSubtitle(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let sub = ExternalSubtitle(id: "import-\(url.lastPathComponent)", url: url, languageCode: nil,
                                   label: url.deletingPathExtension().lastPathComponent, format: ext)
        externalByID[sub.id] = sub
        if !externalSubtitles.contains(where: { $0.id == sub.id }) {
            externalSubtitles.append(MediaTrack(id: sub.id, kind: .subtitle, label: sub.label, languageCode: nil, isExternal: true))
        }
        // A file for this video only: what's remembered for the next ones stays as it was.
        selectSubtitle(.external(sub.id), remember: false)
    }

    /// Timing applies to subtitle files (external tracks). Embedded tracks are
    /// decoded in sync with the video by AVFoundation, which has no delay API.
    public var canAdjustSubtitleTiming: Bool {
        switch subtitleSelection {
        case .external: true
        // VLC delays the tracks it draws itself (spu-delay).
        case .embedded: snapshot.drawsEmbeddedSubtitles
        case .off: false
        }
    }

    /// "Sync to a line", drift and frame-rate fixes need the lines themselves: files only.
    public var canRetimeSubtitleLines: Bool {
        if case .external = subtitleSelection { return true }
        return false
    }

    private func pushSubtitleDelay() { engine.setEmbeddedSubtitleDelay(subtitleOffset.seconds) }

    /// Shows a second external track alongside the main one (nil turns it off).
    public func selectSecondarySubtitle(_ id: String?) {
        secondaryTask?.cancel()
        secondaryTimeline = nil; secondarySubtitleText = nil
        secondarySubtitleID = id
        guard let id, let sub = externalByID[id] else { secondarySubtitleID = nil; return }
        let loader = subtitleLoader
        secondaryTask = Task { [weak self] in
            guard let t = try? await loader.load(sub.url, format: SubtitleFormat(fileExtension: sub.format)),
                  !Task.isCancelled, let self, self.secondarySubtitleID == id else { return }
            self.secondaryTimeline = t
            self.updateSubtitleText()
        }
    }

    public func setSubtitleSpeed(_ scale: Double) {
        subtitleOffset.setScale(scale)
        updateSubtitleText()
    }

    public func convertSubtitleFrameRate(subtitleFPS: Double, videoFPS: Double) {
        subtitleOffset.convertFrameRate(subtitleFPS: subtitleFPS, videoFPS: videoFPS)
        updateSubtitleText()
    }

    /// Lines around now, for "sync this line".
    public var nearbyCues: [SubtitleCue] {
        timeline?.cues(near: snapshot.position, offset: subtitleOffset) ?? []
    }

    /// The user just heard `cue`: shift timing so it starts now. Calling this
    /// a second time, at least 10 s of video later, also fits the speed.
    public func syncCue(_ cue: SubtitleCue) {
        let heard = snapshot.position
        if let first = pendingSyncPoint, subtitleOffset.align(first, (cue: cue.start, heard: heard)) {
            pendingSyncPoint = nil
        } else {
            subtitleOffset.align(cueStart: cue.start, to: heard)
            pendingSyncPoint = (cue: cue.start, heard: heard)
        }
        pushSubtitleDelay()
        updateSubtitleText()
    }

    public func clearPendingSync() { pendingSyncPoint = nil }

    public func nudgeSubtitles(by delta: TimeInterval) {
        subtitleOffset.nudge(by: delta)
        pushSubtitleDelay()
        updateSubtitleText()
    }

    public func resetSubtitleOffset() {
        pendingSyncPoint = nil
        subtitleOffset.reset()
        pushSubtitleDelay()
        updateSubtitleText()
    }

    private func applyPreferredSubtitle() {
        guard rememberedSubtitle == nil, let lang = subtitleStyle.preferredLanguage else { return }
        if let t = TrackChoice(languageCode: lang).best(in: externalSubtitles) {
            selectSubtitle(.external(t.id), remember: false)
        } else if let t = TrackChoice(languageCode: lang).best(in: snapshot.embeddedSubtitles) {
            selectSubtitle(.embedded(t.id), remember: false)
        }
        if let second = subtitleStyle.secondaryLanguage, second != lang,
           let t = TrackChoice(languageCode: second).best(in: externalSubtitles) {
            selectSecondarySubtitle(t.id)
        }
    }

    /// Applies this session's audio and subtitle choices to the item that just
    /// started, once its tracks are known. Called again as tracks arrive.
    private func restoreRememberedTracks() {
        guard restoreTracksPending else { return }
        let s = snapshot
        // Tracks show up once the engine has opened the file.
        let known = !s.audioTracks.isEmpty || !s.embeddedSubtitles.isEmpty
        if let audio = rememberedAudio, !s.audioTracks.isEmpty, let t = audio.best(in: s.audioTracks), t.id != s.selectedAudioID {
            engine.selectAudio(t.id)
        }
        if let sub = rememberedSubtitle {
            if sub.isOff {
                if subtitleSelection != .off { selectSubtitle(.off, remember: false) }
            } else if let t = sub.best(in: s.embeddedSubtitles + externalSubtitles) {
                let selection: SubtitleSelection = t.isExternal ? .external(t.id) : .embedded(t.id)
                if selection != subtitleSelection { selectSubtitle(selection, remember: false) }
            }
        }
        if known, s.status == .playing || s.status == .paused { restoreTracksPending = false }
    }

    private func updateSubtitleText() {
        let text: String?
        if case .embedded = subtitleSelection { text = snapshot.embeddedSubtitleText }
        else { text = timeline?.text(at: snapshot.position, offset: subtitleOffset) }
        if text != subtitleText { subtitleText = text }
        let second = secondaryTimeline?.text(at: snapshot.position, offset: subtitleOffset)
        if second != secondarySubtitleText { secondarySubtitleText = second }
    }

    // MARK: Up next

    /// Plays the episode the Up Next card shows, with the resource resolved
    /// when the card appeared (the provider isn't asked twice).
    public func playUpNext() async {
        guard let next = upNext?.item else { return }
        let resolved = upNextResource
        cancelUpNext()
        if let resolved, resolved.0 == next {
            await start(resolved.0, resource: resolved.1, resume: true)
            return
        }
        guard let provider = nextProvider, let current = item,
              let (nextItem, res) = await provider(current.key), nextItem == next else { return }
        await start(nextItem, resource: res, resume: true)
    }

    /// True while Next Episode is finding the next one. The current episode is
    /// paused meanwhile: resolving can replace the stream it plays from (add-on
    /// torrents run one stream at a time), so it can't keep playing reliably.
    public private(set) var isLoadingNext = false

    /// Skips straight to the next episode, if one is available. If it can't be
    /// found, the current episode carries on where it was.
    public func playNext() async {
        guard let provider = nextProvider, let current = item else { return }
        await switchItem { await provider(current.key) }
    }

    /// Plays another item (an episode from the list) in this session. The
    /// current one pauses while `resolve` finds it, and carries on if it can't.
    public func switchItem(_ resolve: @MainActor () async -> (NowPlayingItem, PlaybackResource)?) async {
        guard let current = item, !isLoadingNext else { return }
        cancelUpNext()
        let wasPlaying = snapshot.status.isActive
        let position = snapshot.position
        engine.pause()
        isLoadingNext = true
        defer { isLoadingNext = false }
        guard let (next, res) = await resolve(), item == current else {
            // Nothing next (or the stream went away while looking): resume in place.
            guard item == current else { return }
            if abs(snapshot.position - position) > 1 { await engine.seek(to: position) }
            if wasPlaying { engine.play() }
            return
        }
        await start(next, resource: res, resume: true)
    }

    public func cancelUpNext() {
        upNextTask?.cancel()
        upNextTask = nil
        upNext = nil
        upNextResource = nil
    }

    private func beginUpNext() {
        guard autoplayNext, upNext == nil, upNextTask == nil, let provider = nextProvider, let current = item else { return }
        upNextTask = Task { [weak self] in
            guard let resolved = await provider(current.key), !Task.isCancelled, let self else { return }
            self.upNextResource = resolved
            self.upNext = UpNext(item: resolved.0, secondsRemaining: self.upNextCountdown)
            while let remaining = self.upNext?.secondsRemaining, remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.upNext?.secondsRemaining -= 1
            }
            if Task.isCancelled { return }
            self.upNextTask = nil
            await self.playUpNext()
        }
    }

    // MARK: Engine events

    private func engineChanged(_ s: PlaybackSnapshot) {
        let old = snapshot
        snapshot = s
        if let o = optimisticPlaying, s.status.isActive == o || s.status == .ended || s.status.isFailure
            || (!o && s.status == .paused) { setOptimistic(nil) }
        updateSubtitleText()
        if restoreTracksPending, !isStarting, s.audioTracks != old.audioTracks || s.embeddedSubtitles != old.embeddedSubtitles
            || s.status != old.status { restoreRememberedTracks() }
        guard item != nil, !isStarting else { return }

        let statusChanged = old.status != s.status
        if statusChanged, s.status == .paused || s.status == .ended {
            scheduleSave()
        } else if s.status == .playing, abs(s.position - (lastSavedPosition ?? 0)) >= saveInterval {
            scheduleSave()
        }
        if statusChanged, s.status == .ended {
            if sleepTimer == .endOfItem { sleepTimer = .off; return }  // stop here instead of autoplaying
            beginUpNext()
        }
        if let a = loopStart, let b = loopEnd, s.position >= b, !looping, !isScrubbing {
            looping = true
            Task { [weak self] in await self?.engine.seek(to: a); self?.looping = false }
        }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            await self?.writeProgress()
            self?.saveTask = nil
        }
    }

    /// Writes the current position now (awaiting any in-flight save first).
    public func persistProgress() async {
        await saveTask?.value
        await writeProgress()
    }

    private func writeProgress() async {
        guard let item, !isStarting, snapshot.status != .loading, snapshot.status != .idle else { return }
        if case .failed = snapshot.status { return }
        let position = snapshot.position
        // Don't record "watched 0s" for something the user opened and closed.
        if (lastSavedPosition ?? 0) == 0, position < 1 { return }
        let record = policy.record(key: item.key, position: position, duration: snapshot.duration, at: now(), deviceID: deviceID)
        lastSavedPosition = position
        do {
            try await progress.save(record)
            onProgressSaved?(snapshot.status == .playing)
        } catch { Log.playback.error("Progress save failed: \(String(describing: error), privacy: .public)") }
    }
}
