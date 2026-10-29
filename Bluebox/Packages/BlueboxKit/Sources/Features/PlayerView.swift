import AVFoundation
import DesignSystem
import Domain
import Downloads
import Metadata
import Playback
import SkipSegments
import Subtitles
import SwiftUI
import TorrentStreaming
import VLCPlayback

struct PlayerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    let session: PlayerSession
    @StateObject private var pip = PictureInPictureModel()
    @State private var controlsVisible = true
    @State private var lastInteraction = Date()
    @State private var scrubFraction: Double?
    @State private var jumping = false
    @State private var toast: PlayerToast?
    /// The toast's button (Undo), when it has one.
    @State private var toastAction: (() -> Void)?
    /// The card open over the video (Audio & Subtitles, Episodes, Speed, Tools, Chapters).
    @State private var panel: PlayerPanelKind?
    /// Where each card's button sits in the stage, so the card opens over it.
    @State private var anchors: [PlayerPanelKind: CGRect] = [:]
    /// The top of the bottom bar in the stage (cards stay above it on the Mac).
    @State private var barTop: CGFloat = 0
    /// The page a card opens on (debug launch arguments).
    @State private var toolsStartPage: ToolsPage?
    @State private var tracksStartPage: TracksPage?
    /// Tools › Stats: engine numbers over the top-left of the video.
    @State private var statsShown = false
    /// The speed before a hold (→ on the Mac, a long press on iPhone) took it to 2×.
    @State private var boostedFrom: Float?
    /// When → went down, to tell a tap (skip) from a hold (2×).
    @State private var rightArrowDown: Date?
    /// The pointer is over the volume control (Mac): its slider shows.
    @State private var volumeExpanded = false
    @State private var episodes = PlayerEpisodes()
    /// The episode the Episodes panel is switching to.
    @State private var switchingTo: MediaKey?
    /// Height of the timeline and tool row, so subtitles and panels sit above them.
    @State private var bottomBarHeight: CGFloat = 0
    /// The subtitle look just changed: the sample line shows for a moment.
    @State private var showsStylePreview = false
    @State private var stylePreviewTask: Task<Void, Never>?
    /// Torrent swarm numbers while the video opens or stalls.
    @State private var swarm: SwarmStats?
    @State private var loadingSince: Date?
    /// Downloaded parts of a torrent stream, as fractions of the file.
    @State private var available: [ClosedRange<Double>] = []
    /// iPhone: the window didn't turn as asked (a prompt offers to try again).
    @State private var showsRotatePrompt = false
    @State private var zoomBase: Double?
    @State private var panBase: CGPoint?
    @State private var importingSubtitle = false
    @State private var searchingSubtitles = false
    /// iPhone/iPad screen lock: hides every control but Unlock.
    @State private var locked = false
    /// Bumped to spin the skip glyphs.
    @State private var skipBack = 0
    @State private var skipForward = 0
    /// A drag or pinch on the subtitles is under way: video gestures stand down.
    @State private var subtitleEditing = false
    /// The pointer rests on the controls (Mac): don't hide them under it.
    @State private var hoveringControls = false
    /// Double-tap skip feedback (iOS).
    @State private var skipFlash: SkipFlash?
    @State private var stageWidth: CGFloat = 0
    /// Skip Intro, Recap and Credits for the current item.
    @State private var skip = SkipController()
    /// Preview frames for the scrubber, when the video can provide them.
    @State private var thumbnails: ScrubThumbnailer?
    /// Picture in Picture for VLC playback (AVPlayer's is `pip`).
    @State private var vlcPiP = VLCPictureInPicture()
    @State private var handoff = WatchHandoff()
    /// The scrubber shows its bubble and preview frame: the Skip pill steps aside.
    @State private var previewing = false
    /// "Try Another Release" from the error card.
    @State private var releaseRequest: TitleDetailView.ReleaseRequest?
    /// The stage's size, to redraw a paused AVPlayer frame after it changes.
    @State private var stageSize: CGSize = .zero
    #if os(macOS)
    @State private var window = PlayerWindowModel()
    #endif
    @FocusState private var focused: Bool

    private var hasNext: Bool { episodes.next != nil }
    private var hasPrevious: Bool { episodes.previous != nil }

    private var avPlayer: AVPlayer? { (session.engine as? AVPlayerEngine)?.player }
    private var vlcEngine: VLCEngine? { session.engine as? VLCEngine }

    struct SkipFlash: Equatable {
        let forward: Bool
        let seconds: Int
        let id = UUID()
    }

    /// The stage's coordinate space: card anchors and the bar are measured in it.
    nonisolated static let stageSpace = "playerStage"

    private var platform: PlayerBarLayout.Platform {
        #if os(macOS)
        .mac
        #else
        horizontalSizeClass == .regular && verticalSizeClass == .regular ? .pad : .phone
        #endif
    }

    private var barLayout: PlayerBarLayout { PlayerBarLayout.make(platform: platform, width: stageSize.width) }

    private var barContext: PlayerBarLayout.Context {
        PlayerBarLayout.Context(isSeries: episodes.isSeries, hasPreviousEpisode: hasPrevious, hasNextEpisode: hasNext,
                                chapterCount: session.snapshot.chapters.count, pipAvailable: pipAvailable,
                                isSwitching: session.isLoadingNext)
    }

    var body: some View {
        stage
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        #if os(iOS)
        .blueboxMenuHost()  // a full-screen cover: menus draw over the video, not under it
        #endif
        .sheet(isPresented: $jumping) { JumpToTimeSheet(duration: session.snapshot.duration ?? 0) { t in Task { await session.seek(to: t) } } }
        // On its own view: one sheet per view (see the tools sheet above).
        .background {
            Color.clear.sheet(item: $releaseRequest) { request in
                ReleasePickerSheet(item: request.item) { release in
                    // A fresh player for the new release (the failed one is let go properly).
                    Task {
                        await app.closePlayer()
                        await app.play(request.item, release: release)
                    }
                }
            }
        }
        #if os(macOS)
        .background(WindowReader { window.attach($0) })
        .onAppear { window.onEscapeInWindow = { if panel != nil { closePanel() } else { Task { await app.closePlayer() } } } }
        .onDisappear { window.detach() }
        #else
        // iPhone: landscape while the player is up, portrait again as it closes.
        .onAppear {
            PlayerOrientation.enterPlayer()
            checkOrientation(after: 1.2)
        }
        .onDisappear { PlayerOrientation.leavePlayer() }
        .onChange(of: app.activePlayer == nil) { _, closed in if closed { PlayerOrientation.leavePlayer() } }
        #endif
    }

    private var canSearchSubtitles: Bool { app.hasOpenSubtitlesKey && session.item?.key.tmdbID != nil }

    /// Controls draw over the video unless a message card (error, end of
    /// film) asks what to do next. They stay while a panel card is open.
    private var controlsShown: Bool {
        !showsCard && (controlsVisible || panel != nil || session.snapshot.status != .playing)
    }

    /// The video is opening or stalled (not while scrubbing, which pauses on purpose).
    private var waiting: Bool {
        !session.isScrubbing && (session.snapshot.status == .buffering || session.snapshot.status == .loading)
    }

    /// The error card or the end-of-film card is up.
    private var showsCard: Bool { session.error != nil || showsEndCard }

    /// A film (or an episode with nothing queued after it) played to the end.
    private var showsEndCard: Bool {
        session.snapshot.status == .ended && session.upNext == nil && !session.isLoadingNext && session.item != nil
    }

    private var stage: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                let layout = VideoLayout(container: geo.size, natural: session.snapshot.presentationSize, framing: session.videoFraming)
                ZStack(alignment: .topLeading) {
                    if let avPlayer {
                        videoLayer(layout: layout) { framed in VideoSurface(player: avPlayer, pip: pip, stretch: framed) }
                    } else if let vlcEngine {
                        videoLayer(layout: layout) { framed in
                            VLCVideoSurface(engine: vlcEngine, stretch: framed, pip: vlcPiP).allowsHitTesting(false)
                        }
                    }
                    SubtitleOverlay(primary: session.subtitleText, secondary: session.secondarySubtitleText,
                                    style: Bindable(app).subtitleStyle,
                                    videoRect: layout.visibleRect.isEmpty ? CGRect(origin: .zero, size: geo.size) : layout.visibleRect,
                                    // Above the timeline whenever it shows, the tools' sample line too.
                                    controlsVisible: controlsShown,
                                    controlsInset: subtitleControlsInset(height: geo.size.height),
                                    // Only while the look is being changed, and only where no real line is.
                                    placeholder: showsStylePreview && panel == .tracks && !vlcDrawsSubtitles ? "Subtitles look like this." : nil,
                                    onEditingChanged: { editing in
                                        subtitleEditing = editing
                                        lastInteraction = Date()
                                    })
                }
            }
            .ignoresSafeArea()
            // Taps go to the picture layer only: on the whole stage, the
            // double-tap recogniser would swallow taps meant for the buttons.
            // Mac: click shows or hides the controls, double-click toggles full screen.
            // iOS: tap shows or hides them; double-tap the left or right third skips.
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .local) { doubleTap(at: $0) }
            .onTapGesture { toggleControls() }
            #if os(iOS)
            // Press and hold the video to play at 2× (YouTube's gesture).
            .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 30, perform: {
                guard !locked, !subtitleEditing, session.appearsPlaying else { return }
                startBoost()
            }, onPressingChanged: { pressing in
                if !pressing { endBoost() }
            })
            #endif
            if let skipFlash { skipIndicator(skipFlash) }
            // Mac: nothing sits over the middle of the picture except the
            // buffering ring while it waits (touch shows it in place of play).
            if platform == .mac, waiting, !showsCard { bufferingRing(size: 46).allowsHitTesting(false).transition(.opacity) }
            if panel != nil, controlsShown {
                // Clicking or tapping outside the card closes it, like a menu. Under
                // the controls, so another bar button switches cards in one click.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { closePanel() }
                    .accessibilityHidden(true)
            }
            if controlsShown {
                controls.transition(.opacity)
            }
            if !locked, !previewing, panel == nil, session.upNext == nil, !showsCard {
                SkipPill(skip: skip, onAccept: { perform(skip.accept()) }, onWrongTime: wrongSkipTime, onAlways: alwaysSkip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, stageSize.height < 500 ? Spacing.l : Spacing.xl)
                    // Above the bar while it shows; low in the corner otherwise.
                    .padding(.bottom, controlsShown ? max(stageSize.height - barTop, 0) + Spacing.s : (stageSize.height < 500 ? 20 : 40))
                    .animation(Motion.standard(reduceMotion), value: controlsShown)
                    .animation(Motion.standard(reduceMotion), value: skip.offer)
            }
            if let panel, controlsShown {
                panelCard(panel).zIndex(2)
            }
            if statsShown, !locked {
                PlayerStatsOverlay(session: session, onClose: { statsShown = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, controlsShown ? (stageSize.height < 500 ? 56 : 64) : Spacing.l)
                    .padding(.leading, Spacing.l)
                    .transition(.opacity)
                    .zIndex(1)
            }
            if boostedFrom != nil {
                Label("2×", systemImage: "forward.fill")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, Spacing.m).padding(.vertical, 6)
                    .background(.black.opacity(0.7), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, Spacing.xl)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Playing at double speed")
                    .zIndex(5)
            }
            #if os(iOS)
            if showsRotatePrompt { rotatePrompt.zIndex(3) }
            #endif
            if let upNext = session.upNext { upNextCard(upNext) }
            if session.isLoadingNext {
                HStack(spacing: Spacing.s) {
                    ProgressView().tint(.white)
                    Text(switchingTo.map { k in k.episodeNumbers.map { "Opening S\($0.season)·E\($0.episode)…" } ?? "Opening…" }
                         ?? "Finding the next episode…").font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.m)
                .background(.black.opacity(0.75), in: Capsule())
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
            if let error = session.error { errorOverlay(error).zIndex(4) }
            else if showsEndCard { endCard.zIndex(4) }
            if app.networkSwitchedToCellularDuringPlayback, !locked {
                MobileDataBanner(
                    onContinue: { app.dismissMobileDataBanner() },
                    onLowerQuality: { Task { await app.lowerQualityForMobileData() } },
                    onPause: {
                        if session.snapshot.status == .playing { session.togglePlayPause() }
                        app.dismissMobileDataBanner()
                        poke()
                    })
                    .frame(maxHeight: .infinity, alignment: .top)
                    // A strip just under the top bar, clear of the play and skip buttons.
                    .padding(.top, controlsShown ? (stageSize.height < 500 ? 58 : 70) : Spacing.m)
                    .padding(.horizontal, Spacing.l)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
            }
            if let toast {
                toastView(toast)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 70)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(5)
            }
        }
        .animation(Motion.standard(reduceMotion), value: app.networkSwitchedToCellularDuringPlayback)
        .animation(Motion.snappy(reduceMotion), value: boostedFrom != nil)
        .animation(Motion.standard(reduceMotion), value: statsShown)
        .animation(Motion.standard(reduceMotion), value: showsCard)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.28), value: panel)
        .coordinateSpace(.named(Self.stageSpace))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { stageWidth = $0.width; stageSize = $0 }
        #if os(iOS)
        // A paused AVPlayer layer can come back black after the stage changes
        // size (rotation on iPad): ask for the same frame again once it settles.
        .onChange(of: stageSize) { if showsRotatePrompt, PlayerOrientation.isSettled { showsRotatePrompt = false } }
        .task(id: stageSize) {
            guard let avPlayer, session.snapshot.status == .paused, stageSize != .zero else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, session.snapshot.status == .paused else { return }
            await avPlayer.seek(to: avPlayer.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        #endif
        .simultaneousGesture(MagnifyGesture()
            .onChanged { v in
                guard !locked, !subtitleEditing else { return }
                let base = zoomBase ?? session.videoFraming.zoom
                zoomBase = base
                session.videoFraming.setZoom(base * v.magnification)
            }
            .onEnded { _ in zoomBase = nil })
        .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard session.videoFraming.zoom > 1, !subtitleEditing, scrubFraction == nil else { return }
                let base = panBase ?? CGPoint(x: session.videoFraming.panX, y: session.videoFraming.panY)
                panBase = base
                session.videoFraming.setPan(x: base.x - v.translation.width / 300, y: base.y - v.translation.height / 300)
            }
            .onEnded { _ in panBase = nil })
        #if os(macOS)
        .onContinuousHover { phase in if case .active = phase { poke() } }
        #endif
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onChange(of: panel) { _, open in if open == nil { focused = true } }
        .modifier(PlayerKeys(actions: keyActions))
        .task(id: session.snapshot.status == .playing) { await autoHide() }
        .task(id: session.item?.key) {
            // Metadata only: resolving the next episode here would start its stream,
            // which for add-on torrents replaces the one playing now.
            await episodes.load(for: session.item?.key, app: app)
        }
        .onChange(of: app.subtitleStyle, initial: true) { old, new in
            session.subtitleStyle = new
            guard old != new else { return }
            showsStylePreview = true
            stylePreviewTask?.cancel()
            stylePreviewTask = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.25)) { showsStylePreview = false }
            }
        }
        // How long it's been loading, for the loading words.
        .onChange(of: session.snapshot.status == .loading || session.snapshot.status == .buffering, initial: true) { _, waiting in
            loadingSince = waiting ? (loadingSince ?? Date()) : nil
        }
        // Torrent streams: swarm numbers for the loading words, and which parts
        // of the file are in for the timeline. Every second while it waits,
        // every two while it plays.
        .task(id: session.currentResource?.url) {
            swarm = nil; available = []
            guard let resource = session.currentResource,
                  resource.url.host == "127.0.0.1" || resource.url.host == "localhost",
                  resource.variant.sourceID == app.addons.id else { return }
            while !Task.isCancelled {
                swarm = await app.addons.streamStats()
                available = TorrentStreamer.downloadedRanges(for: resource.url)?.fractions ?? []
                let waiting = session.snapshot.status == .loading || session.snapshot.status == .buffering
                try? await Task.sleep(for: .seconds(waiting ? 1 : 2))
            }
        }
        .onChange(of: session.snapshot.position) {
            app.updateNowPlaying()
            followSkipSegments()
            advertiseHandoff()
        }
        .onChange(of: session.snapshot.status) {
            app.updateNowPlaying()
            advertiseHandoff(force: true)
        }
        .onChange(of: session.item?.key) {
            skip.reset()
            thumbnails = nil
            switchingTo = nil
            if panel == .episodes { closePanel() }
        }
        // Chapters and the length arrive after loading; look again when they do.
        .task(id: skipLookupID) {
            try? await Task.sleep(for: .milliseconds(600))  // let chapters settle
            guard !Task.isCancelled, let query = await app.skipQuery(for: session) else { return }
            await skip.load(query)
            followSkipSegments()
        }
        .task(id: thumbnailID) {
            thumbnails = nil
            guard app.settings.scrubThumbnails, let resource = session.currentResource,
                  let duration = session.snapshot.duration, duration > 0 else { return }
            thumbnails = ScrubThumbnailer.make(for: resource, duration: duration, usesVLC: vlcEngine != nil)
        }
        .onAppear {
            skip.onCountdownFinished = { Task { await session.playNext() } }
            advertiseHandoff(force: true)
            #if DEBUG
            // Screenshots: `-player-subtitle <n>` turns on the nth subtitle track from the video,
            // `-player-subtitle-preset <name>` gives subtitles that look (throwaway -ui-testing prefs).
            if let n = AppModel.debugValue("-player-subtitle").flatMap(Int.init) {
                Task {
                    for _ in 0..<40 where session.snapshot.embeddedSubtitles.count <= n { try? await Task.sleep(for: .milliseconds(250)) }
                    if session.snapshot.embeddedSubtitles.indices.contains(n) {
                        session.selectSubtitle(.embedded(session.snapshot.embeddedSubtitles[n].id))
                    }
                    if let name = AppModel.debugValue("-player-subtitle-preset"), let p = SubtitleStyle.Preset(rawValue: name) {
                        try? await Task.sleep(for: .seconds(2))
                        app.subtitleStyle = app.subtitleStyle.applying(p)
                    }
                }
            }
            // Screenshots: `-player-popover tracks|episodes|speed|tools|chapters` opens that card once
            // the video plays; `-player-page <page>` opens a page in it (style, timing, secondLine,
            // picture, sound, audioDelay, sleep, skip, shortcuts); `-player-rate 1.15` sets the speed,
            // `-player-stats` shows Stats.
            if let which = AppModel.debugValue("-player-popover").flatMap(PlayerPanelKind.init(rawValue:)) {
                let page = AppModel.debugValue("-player-page")
                toolsStartPage = page.flatMap(ToolsPage.init(rawValue:))
                tracksStartPage = page.flatMap(TracksPage.init(rawValue:))
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    if let r = AppModel.debugValue("-player-rate").flatMap(Float.init) { session.setRate(r) }
                    if (ProcessInfo.processInfo.arguments + AppModel.environmentDebugArguments).contains("-player-stats") { statsShown = true }
                    panel = which
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-player-mobile-banner") {
                // Screenshots: the "Now using mobile data" banner.
                Task { try? await Task.sleep(for: .seconds(2)); app.settings.networkSwitchedToCellularDuringPlayback = true }
            }
            if let after = AppModel.debugPauseAfter {
                Task { try? await Task.sleep(for: .seconds(after)); session.togglePlayPause(); poke() }
            }
            if let after = AppModel.debugValue("-player-night").flatMap(Double.init) {
                Task {
                    try? await Task.sleep(for: .seconds(after))
                    session.setAudioEffects(AudioEffects(dialogueBoost: true, nightMode: true))
                }
            }
            if let after = AppModel.debugPiPAfter {
                Task {
                    try? await Task.sleep(for: .seconds(after))
                    NSLog("PLAYERFX pip before: vlc=%d supported=%d available=%d possible=%d", vlcEngine != nil ? 1 : 0,
                          VLCPictureInPicture.isSupported ? 1 : 0, vlcPiP.isAvailable ? 1 : 0, vlcPiP.isPossible ? 1 : 0)
                    if vlcEngine != nil { vlcPiP.toggle() } else { pip.toggle() }
                    try? await Task.sleep(for: .seconds(4))
                    NSLog("PLAYERFX pip after: active=%d possible=%d", vlcPiP.isActive ? 1 : 0, vlcPiP.isPossible ? 1 : 0)
                }
            }
            #endif
        }
        .onDisappear {
            handoff.invalidate()
            vlcPiP.stop()
        }
        .fileImporter(isPresented: $importingSubtitle,
                      allowedContentTypes: ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                session.importSubtitle(url)
            }
        }
        .sheet(isPresented: $searchingSubtitles) {
            if let key = session.item?.key {
                SubtitleSearchSheet(key: key) { url in session.importSubtitle(url) }
            }
        }
        #if os(iOS)
        // iPhone: the status bar and home indicator stay hidden the whole time
        // the player is up, not just while the controls are. Showing them with
        // the controls (which stay up while paused) lifted SpringBoard's
        // full-screen suppression of the Dynamic Island, and the island then
        // showed Bluebox's own Now Playing activity over the paused video.
        // Leaving the app still shows it (and starts PiP). iPad has no island.
        .statusBarHidden(PlayerOrientation.isPhone || !controlsVisible)
        .persistentSystemOverlays(PlayerOrientation.isPhone || !controlsVisible ? .hidden : .automatic)
        #endif
        .accessibilityAction(named: "Play or Pause") { session.togglePlayPause() }
    }

    // MARK: Skip Intro and Handoff

    private var skipLookupID: String {
        let s = session.snapshot
        let key = session.item?.key.rawValue ?? ""
        let crowd = session.item.map { app.settings.crowdSkipsAllowed(for: $0.key) } ?? true
        return "\(key)|\(s.chapters.count)|\(s.duration.map { Int($0 / 60) } ?? -1)|\(crowd)"
    }

    private var thumbnailID: String {
        "\(session.item?.key.rawValue ?? "")|\((session.snapshot.duration ?? 0) > 0)|\(app.settings.scrubThumbnails)"
    }

    private func followSkipSegments() {
        guard let key = session.item?.key else { return }
        let settings = app.settings
        let action = skip.update(position: session.snapshot.position, duration: session.snapshot.duration,
                                 modes: settings.skipModes(for: key), hasNext: hasNext,
                                 autoplayNext: settings.autoplayNextEpisode,
                                 enabled: settings.skipsAllowed(for: key), isScrubbing: session.isScrubbing,
                                 offerAlways: { part in
                                     guard settings.offersAlwaysSkip(part, for: key) else { return false }
                                     settings.markAlwaysSkipOffered(part, for: key)
                                     return true
                                 })
        if let action {
            perform(action)
            if case .seek = action {
                let kind = skip.activeSegment.map { ShowSkipRules.Part($0.kind) } ?? .intro
                if settings.alwaysSkips(kind, for: key) {
                    // The show's own rule did it: say so, with the way back.
                    flash("Skipped \(kind.title.lowercased()) · always for this show", action: "Stop") {
                        settings.setAlwaysSkip(false, kind, for: key)
                    }
                } else {
                    flash("Skipped \(kind.title.lowercased())")
                }
            }
        }
    }

    /// "Always for this show": remember it, and skip this one now.
    private func alwaysSkip(_ part: ShowSkipRules.Part) {
        guard let key = session.item?.key else { return }
        app.settings.setAlwaysSkip(true, part, for: key)
        perform(skip.accept())
        flash("Always skipping the \(part.title.lowercased()) of this show", action: "Undo") {
            app.settings.setAlwaysSkip(false, part, for: key)
        }
    }

    private func perform(_ action: SkipController.Action?) {
        switch action {
        case .seek(let t): Task { await session.seek(to: t) }
        case .playNext: Task { await session.playNext() }
        case nil: break
        }
        poke()
    }

    /// "Wrong time?": stop using crowd timestamps for this show and look again.
    private func wrongSkipTime() {
        guard let key = session.item?.key else { return }
        let source = skip.activeSegment?.source.displayName ?? "Community"
        app.settings.setCrowdSkipsAllowed(false, for: key)
        skip.reset()
        flash("\(source) timestamps off for this show", action: "Undo") {
            app.settings.setCrowdSkipsAllowed(true, for: key)
            skip.reset()
            flash("\(source) timestamps back on")
        }
    }

    private func advertiseHandoff(force: Bool = false) {
        guard app.settings.handoff, let payload = app.handoffPayload(for: session) else { return }
        handoff.update(payload, force: force)
    }

    // MARK: Taps

    /// Double-click toggles full screen (Mac); double-tap the left or right
    /// third skips, the middle plays or pauses (iOS).
    private func doubleTap(at location: CGPoint) {
        guard !locked else { return }
        #if os(macOS)
        window.toggleFullScreen()
        #else
        let third = max(stageWidth, 1) / 3
        if location.x < third { doubleTapSkip(forward: false) }
        else if location.x > third * 2 { doubleTapSkip(forward: true) }
        else { session.togglePlayPause(); poke() }
        #endif
    }

    private func doubleTapSkip(forward: Bool) {
        let seconds = forward ? app.settings.skipForwardSeconds : app.settings.skipBackSeconds
        // Repeated double-taps on the same side add up, like YouTube.
        let total = (skipFlash?.forward == forward ? skipFlash?.seconds ?? 0 : 0) + seconds
        Task { await session.skip(by: forward ? Double(seconds) : -Double(seconds)) }
        if forward { skipForward += 1 } else { skipBack += 1 }
        let flash = SkipFlash(forward: forward, seconds: total)
        withAnimation(.easeOut(duration: 0.15)) { skipFlash = flash }
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            if skipFlash == flash { withAnimation(.easeIn(duration: 0.25)) { skipFlash = nil } }
        }
    }

    private func skipIndicator(_ flash: SkipFlash) -> some View {
        HStack {
            if flash.forward { Spacer(minLength: 0) }
            VStack(spacing: 6) {
                Image(systemName: flash.forward ? "goforward" : "gobackward").font(.title.weight(.semibold))
                Text("\(flash.seconds) seconds").font(.footnote.weight(.semibold)).monospacedDigit()
            }
            .frame(width: 130, height: 130)
            .background(.black.opacity(0.45), in: Circle())
            .padding(.horizontal, Spacing.xxl)
            if !flash.forward { Spacer(minLength: 0) }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    // MARK: Keys

    private var keyActions: PlayerKeys.Actions {
        PlayerKeys.Actions(
            playPause: { session.togglePlayPause(); poke() },
            skip: { forward in skipBy(forward: forward) },
            forwardKey: forwardKey,
            close: {
                if panel != nil { closePanel() } else { Task { await app.closePlayer() } }
            },
            stepSpeed: { steps in
                let r = PlaybackSpeed.stepped(session.snapshot.rate, by: steps)
                session.setRate(r)
                flash("Speed \(PlaybackSpeed.label(r))")
            },
            volume: { d in
                session.setVolume(session.volume + d)
                flash(session.volume < 0.005 ? "Muted" : "Volume \(Int((session.volume * 100).rounded()))%")
                poke()
            },
            mute: { session.setMuted(!session.isMuted); flash(session.isMuted ? "Muted" : "Sound on") },
            episodes: { if episodes.isSeries { toggle(.episodes) } },
            episodeStep: { forward in stepEpisode(forward: forward) },
            nudgeSubtitles: { d in
                session.nudgeSubtitles(by: d)
                flash(session.canAdjustSubtitleTiming ? "Subtitle delay \(session.subtitleOffset.label)" : "Timing works with subtitle files")
            },
            subtitleSize: { d in
                app.subtitleStyle.relativeSize = SubtitleStyle.clampSize(app.subtitleStyle.relativeSize + d)
                flash("Subtitle size \(Int((app.subtitleStyle.relativeSize / 0.045 * 100).rounded()))%")
            },
            cycleSubtitles: cycleSubtitles,
            cycleAudio: cycleAudio,
            stepFrame: { session.stepFrame(by: $0) },
            aspect: cycleAspect, crop: cycleCrop, zoom: cycleZoom,
            rotate: { session.videoFraming.rotate(); flash("Rotated \(Int(session.videoFraming.rotationDegrees))°") },
            loop: cycleLoop,
            snapshot: { Task { await saveSnapshot() } },
            tools: { toggle(.tools) },
            jump: { jumping = true },
            chapter: { offset in Task { await session.jumpToChapter(offset: offset) } }
        )
    }

    private func skipBy(forward: Bool) {
        Task { await session.skip(by: forward ? Double(app.settings.skipForwardSeconds) : -Double(app.settings.skipBackSeconds)) }
        if forward { skipForward += 1 } else { skipBack += 1 }
        poke()
    }

    private func cycleLoop() {
        session.cycleLoop()
        flash(session.loopEnd != nil ? "Repeating A–B" : session.loopStart != nil ? "A set. Press L again at B." : "Repeat off")
    }

    /// → on the Mac: a tap skips forward; held, it plays at 2× until released.
    private func forwardKey(_ phase: KeyPress.Phases) {
        switch phase {
        case .down:
            rightArrowDown = Date()
        case .repeat:
            guard let down = rightArrowDown, boostedFrom == nil, Date().timeIntervalSince(down) > 0.3,
                  session.appearsPlaying else { return }
            startBoost()
        case .up:
            if boostedFrom != nil { endBoost() } else if rightArrowDown != nil { skipBy(forward: true) }
            rightArrowDown = nil
        default:
            break
        }
    }

    /// Plays at 2× while a key or finger is held.
    private func startBoost() {
        guard boostedFrom == nil else { return }
        boostedFrom = session.snapshot.rate
        session.setRate(PlaybackSpeed.hold)
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func endBoost() {
        guard let rate = boostedFrom else { return }
        boostedFrom = nil
        session.setRate(rate)
    }

    /// Previous or next episode in a series, else chapter (the bar's ⏮ ⏭).
    private func stepEpisode(forward: Bool) {
        switch PlayerBarLayout.stepTarget(barContext) {
        case .episode:
            if forward, hasNext { Task { await session.playNext() } }
            else if !forward, let previous = episodes.previous { play(episode: previous.key) }
        case .chapter:
            Task { await session.jumpToChapter(offset: forward ? 1 : -1) }
        case .none:
            break
        }
        poke()
    }

    private func cycleSubtitles() {
        let all: [SubtitleSelection] = [.off] + session.snapshot.embeddedSubtitles.map { .embedded($0.id) }
            + session.externalSubtitles.map { .external($0.id) }
        let next = all[((all.firstIndex(of: session.subtitleSelection) ?? 0) + 1) % all.count]
        session.selectSubtitle(next)
        let label: String = switch next {
        case .off: "Off"
        case .embedded(let id), .external(let id):
            TrackLabel.labels(for: session.allSubtitleTracks)[id]?.spoken ?? "On"
        }
        flash("Subtitles: \(label)")
    }

    private func cycleAudio() {
        let tracks = session.snapshot.audioTracks
        guard tracks.count > 1 else { flash("Only one audio track"); return }
        let i = tracks.firstIndex { $0.id == session.snapshot.selectedAudioID } ?? -1
        let next = tracks[(i + 1) % tracks.count]
        session.selectAudio(next.id)
        flash("Audio: \(TrackLabel.labels(for: tracks)[next.id]?.spoken ?? next.label)")
    }

    // MARK: Video

    /// The player layer sized and offset for aspect, crop and zoom, inside a
    /// clipped box that is flipped and rotated as a whole.
    private func videoLayer<Surface: View>(layout: VideoLayout, @ViewBuilder surface: @escaping (Bool) -> Surface) -> some View {
        let f = session.videoFraming
        let framed = session.snapshot.presentationSize != .zero
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                surface(framed)
                    .frame(width: framed ? layout.videoFrame.width : layout.box.width,
                           height: framed ? layout.videoFrame.height : layout.box.height)
                    .offset(x: framed ? layout.videoFrame.minX : 0, y: framed ? layout.videoFrame.minY : 0)
            }
            .frame(width: layout.box.width, height: layout.box.height, alignment: .topLeading)
            .clipped()
            .scaleEffect(x: f.flipHorizontal ? -1 : 1, y: f.flipVertical ? -1 : 1)
            .rotationEffect(.degrees(layout.rotationDegrees))
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityLabel("Video")
    }

    private func cycleAspect() {
        let all = VideoFraming.Ratio.allCases
        let next = all[((all.firstIndex(of: session.videoFraming.aspect) ?? 0) + 1) % all.count]
        session.videoFraming.aspect = next
        flash("Aspect ratio: \(next.label)")
    }

    private func cycleCrop() {
        let all: [VideoFraming.Ratio] = [.auto, .r16x9, .r1_85, .r2_35, .r2_39, .r4x3]
        let next = all[((all.firstIndex(of: session.videoFraming.crop) ?? 0) + 1) % all.count]
        session.videoFraming.crop = next
        flash("Crop: \(next == .auto ? "None" : next.label)")
    }

    private func cycleZoom() {
        let steps = [1.0, 1.25, 1.5, 2]
        let i = steps.firstIndex { abs($0 - session.videoFraming.zoom) < 0.01 } ?? 0
        session.videoFraming.setZoom(steps[(i + 1) % steps.count])
        flash(String(format: "Zoom %.2g×", session.videoFraming.zoom))
    }

    /// A short message at the top. With an action (Undo) it stays longer and can be tapped.
    private func flash(_ message: String, action title: String? = nil, perform: (() -> Void)? = nil) {
        let shown = PlayerToast(message: message, actionTitle: perform == nil ? nil : title)
        withAnimation(.easeOut(duration: 0.15)) { toast = shown }
        toastAction = perform
        Task {
            try? await Task.sleep(for: .seconds(perform == nil ? 1.6 : 5))
            if toast == shown { withAnimation(.easeIn(duration: 0.25)) { toast = nil }; toastAction = nil }
        }
    }

    private func toastView(_ t: PlayerToast) -> some View {
        HStack(spacing: Spacing.m) {
            Text(t.message).font(.subheadline.weight(.semibold))
            if let title = t.actionTitle, let action = toastAction {
                Button {
                    withAnimation(.easeIn(duration: 0.2)) { toast = nil }
                    toastAction = nil
                    action()
                } label: {
                    Text(title).font(.subheadline.weight(.bold)).foregroundStyle(Palette.brandBright)
                        .padding(.horizontal, Spacing.s)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("toastAction")
            }
        }
        .padding(.leading, Spacing.l)
        .padding(.trailing, t.actionTitle == nil ? Spacing.l : Spacing.s)
        .padding(.vertical, t.actionTitle == nil ? Spacing.s : 2)
        .background(.black.opacity(0.8), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .allowsHitTesting(t.actionTitle != nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private func saveSnapshot() async {
        guard let image = await session.captureFrame() else { flash("Couldn't capture this frame"); return }
        do {
            let place = try await SnapshotSaver.save(image, title: session.item?.title ?? "Bluebox", at: session.snapshot.position)
            flash("Saved to \(place)")
        } catch {
            flash(error.localizedDescription)
        }
    }

    // MARK: Controls

    private var controls: some View {
        GeometryReader { geo in
            // Phones in landscape are short: tighter padding and smaller centre glyphs.
            let short = geo.size.height < 500
            ZStack {
                LinearGradient(stops: [.init(color: .black.opacity(0.72), location: 0), .init(color: .clear, location: 0.26),
                                       .init(color: .clear, location: 0.55), .init(color: .black.opacity(0.9), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                if locked {
                    lockedOverlay
                } else {
                    VStack(spacing: 0) {
                        topBar.onHover { hoveringControls = $0 }
                        Spacer(minLength: 0)
                        if platform != .mac {
                            // Out of the way while scrubbing, so the frame underneath shows.
                            centerButtons(short: short)
                                .opacity(scrubFraction == nil ? 1 : 0)
                                .allowsHitTesting(scrubFraction == nil)
                                .animation(.easeOut(duration: 0.15), value: scrubFraction == nil)
                            Spacer(minLength: 0)
                        }
                        bottomBar(short: short).onHover { hoveringControls = $0 }
                    }
                    .padding(.horizontal, short ? Spacing.l : Spacing.l)
                    .padding(.top, short ? Spacing.s : Spacing.m)
                    .padding(.bottom, short ? Spacing.xs : Spacing.m)
                }
            }
        }
    }

    /// With the screen locked, only an Unlock button shows, so a pocket or a
    /// child can't stop the film.
    private var lockedOverlay: some View {
        VStack {
            Spacer()
            Button { withAnimation(Motion.snappy(reduceMotion)) { locked = false }; poke() } label: {
                VStack(spacing: Spacing.s) {
                    Image(systemName: "lock.fill").font(.title2)
                        .frame(width: 56, height: 56)
                        .background(.black.opacity(0.5), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.4)))
                    Text("Screen locked · Tap to unlock").font(.caption.weight(.semibold))
                        .shadow(color: .black.opacity(0.6), radius: 4)
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Unlock Controls")
            .padding(.bottom, Spacing.xxl)
        }
    }

    /// Close on the left; the title in the middle on touch (on the Mac it's in
    /// the bottom bar); AirPlay, and on touch PiP and rotation, on the right.
    private var topBar: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            PlayerIconButton(symbol: "chevron.backward", label: "Close Player", size: 20) { Task { await app.closePlayer() } }
                .accessibilityIdentifier("closePlayer")
            Spacer(minLength: Spacing.s)
            if !barLayout.showsTitle {
                titleView(stacked: true)
                Spacer(minLength: Spacing.s)
            }
            HStack(spacing: Spacing.xs) {
                if platform != .mac, pipAvailable {
                    PlayerIconButton(symbol: pipActive ? "pip.exit" : "pip.enter",
                                     label: pipActive ? "Exit Picture in Picture" : "Picture in Picture") { togglePiP() }
                        .accessibilityIdentifier("vlcPiP")
                }
                if let avPlayer {  // AirPlay is AVKit-only
                    AirPlayButton(player: avPlayer)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("AirPlay")
                        .help("AirPlay")
                }
                #if os(iOS)
                if PlayerOrientation.isPhone {
                    // Landscape ⇄ portrait, for watching upright (or turning back).
                    PlayerIconButton(symbol: PlayerOrientation.mode == .landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate",
                                     label: PlayerOrientation.mode == .landscape ? "Watch in Portrait" : "Watch in Landscape") {
                        PlayerOrientation.toggle()
                        checkOrientation(after: 1.2)
                        poke()
                    }
                    .accessibilityIdentifier("rotateButton")
                }
                #endif
            }
            // Balances the close button so the title stays centred.
            .frame(minWidth: 44, alignment: .trailing)
        }
    }

    /// "Harbor Lights · S2:E3 Signal Fires": one line in the bar, two in the top bar.
    @ViewBuilder private func titleView(stacked: Bool) -> some View {
        let title = session.item?.title ?? ""
        let sub = session.item?.subtitle
        Group {
            if stacked {
                VStack(spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    if let sub { Text(sub).font(.subheadline).foregroundStyle(Palette.textSecondary).lineLimit(1) }
                }
                .multilineTextAlignment(.center)
            } else {
                (Text(title).font(.subheadline.weight(.bold))
                 + Text(sub.map { "  ·  \($0)" } ?? "").font(.subheadline.weight(.medium)).foregroundStyle(Palette.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Touch: back, play and forward over the middle of the picture; the play
    /// button becomes the buffering ring while the video waits.
    private func centerButtons(short: Bool) -> some View {
        let playing = session.appearsPlaying
        return HStack(spacing: short ? 56 : 72) {
            Button { skipBy(forward: false) } label: {
                Image(systemName: "gobackward.\(app.settings.skipBackSeconds)").font(.system(size: short ? 30 : 36, weight: .regular))
                    .symbolEffect(.rotate.counterClockwise.byLayer, options: .speed(2), value: skipBack)
                    .frame(width: 64, height: 64).contentShape(Circle())
            }
            .accessibilityLabel("Back \(app.settings.skipBackSeconds) seconds")
            .help("Back \(app.settings.skipBackSeconds) seconds (←)")
            Button { session.togglePlayPause(); poke() } label: {
                ZStack {
                    if waiting {
                        bufferingRing(size: short ? 38 : 46)
                    } else {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: short ? 48 : 60, weight: .regular))
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                }
                .frame(width: 88, height: 88).contentShape(Circle())
            }
            .accessibilityLabel(playing ? "Pause" : "Play")
            .accessibilityIdentifier("playPause")
            .help(playing ? "Pause (Space)" : "Play (Space)")
            .tapHaptic(playing)
            Button { skipBy(forward: true) } label: {
                Image(systemName: "goforward.\(app.settings.skipForwardSeconds)").font(.system(size: short ? 30 : 36, weight: .regular))
                    .symbolEffect(.rotate.clockwise.byLayer, options: .speed(2), value: skipForward)
                    .frame(width: 64, height: 64).contentShape(Circle())
            }
            .accessibilityLabel("Forward \(app.settings.skipForwardSeconds) seconds")
            .help("Forward \(app.settings.skipForwardSeconds) seconds (→)")
        }
        .buttonStyle(PressableStyle())
        .shadow(color: .black.opacity(0.5), radius: 8)
    }

    /// The ring that fills to the resume point, with the speed or peers under it.
    private func bufferingRing(size: CGFloat) -> some View {
        let s = session.snapshot
        let elapsed = loadingSince.map { Date().timeIntervalSince($0) } ?? 0
        return BufferingRing(fraction: BufferProgress.fraction(status: s.status, bufferFill: s.bufferFill, position: s.position,
                                                               bufferedUntil: s.bufferedUntil),
                             caption: BufferProgress.caption(status: s.status, torrent: swarm, elapsed: elapsed),
                             size: size)
            .overlay(alignment: .top) {
                // The longer explanation once it's been a while ("This torrent may have few seeders").
                if elapsed > 12, let detail = PlayerLoadingText.line(status: s.status, bufferFill: s.bufferFill, torrent: swarm,
                                                                    loadingNext: false, elapsed: elapsed)?.detail {
                    Text(detail).font(.caption2).foregroundStyle(Palette.textSecondary).fixedSize()
                        .shadow(color: .black.opacity(0.7), radius: 3)
                        .offset(y: size + 28)
                }
            }
    }

    /// The chapter name over the timeline, the timeline, then the control row.
    private func bottomBar(short: Bool) -> some View {
        let s = session.snapshot
        // Unknown length: no fill, no remaining time, nothing to scrub (never a full bar at 0:00).
        let timeline = PlaybackTimeline(position: session.displayPosition, duration: s.duration)
        let duration = timeline.duration ?? 0
        let shown = scrubFraction.flatMap { timeline.time(at: $0) } ?? timeline.position
        let remaining = timeline.remaining(at: shown).map { "−" + Formatters.duration($0) } ?? "--:--"
        return VStack(alignment: .leading, spacing: short ? 0 : 2) {
            chapterLabel(duration: duration)
            HStack(spacing: Spacing.m) {
                Scrubber(fraction: timeline.fraction,
                         buffered: timeline.fraction(at: s.bufferedUntil),
                         duration: duration,
                         available: available,
                         loop: session.loopStart.map { a in (a / max(duration, 1), session.loopEnd.map { $0 / max(duration, 1) }) },
                         chapterMarks: duration > 0 ? s.chapters.map { $0.start / duration } : [],
                         stalled: waiting,
                         scrubFraction: $scrubFraction,
                         onScrub: { f in
                             guard let target = timeline.time(at: f) else { return }
                             session.scrub(to: target)
                             lastInteraction = Date()
                         },
                         onCommit: { f in
                             guard let target = timeline.time(at: f) else { return }
                             Task { await session.endScrub(at: target) }
                             poke()
                         },
                         thumbnails: thumbnails,
                         onPreviewing: { previewing = $0 })
                .allowsHitTesting(timeline.isKnown)
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue(timeline.isKnown ? "\(Formatters.duration(timeline.position)) of \(Formatters.duration(duration))"
                                                     : Formatters.duration(timeline.position))
                .accessibilityAdjustableAction { dir in skipBy(forward: dir == .increment) }
                // Fixed width, so the timeline doesn't shift when 9:59 becomes 10:00.
                Text(remaining)
                    .font(.footnote.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: duration >= 3600 ? 64 : 48, alignment: .trailing)
                    .accessibilityLabel(timeline.isKnown ? "\(remaining.dropFirst()) remaining" : "Length unknown")
            }
            controlRow
            if let err = session.subtitleError {
                Label(err, systemImage: "captions.bubble").font(.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.stageSpace)) } action: {
            bottomBarHeight = $0.height
            barTop = $0.minY
        }
    }

    /// "Chapter 3 · The Lamp Room ›": opens the chapter list. Its line is kept
    /// when there are no chapters, so the bar is the same height for every video.
    @ViewBuilder private func chapterLabel(duration: TimeInterval) -> some View {
        let chapters = session.snapshot.chapters
        let index = session.currentChapterIndex
        Button { toggle(.chapters) } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet").font(.caption.weight(.bold))
                Text(index.map { i in
                    let t = chapters[i].title
                    return t.isEmpty || t == "Chapter \(i + 1)" ? "Chapter \(i + 1)" : "Chapter \(i + 1) · \(t)"
                } ?? "Chapters")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                Image(systemName: "chevron.forward").font(.caption2.weight(.bold))
            }
            .foregroundStyle(Color(white: 0.85))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerBarButtonStyle(isOn: panel == .chapters))
        .fixedSize()
        .panelAnchor(.chapters, in: $anchors)
        .opacity(chapters.isEmpty ? 0 : 1)
        .disabled(chapters.isEmpty)
        .accessibilityHidden(chapters.isEmpty)
        .accessibilityLabel("Chapters")
        .accessibilityValue(index.map { chapters[$0].title } ?? "")
        .help("Chapters (N, P)")
        .padding(.leading, -6)
        .frame(height: PlayerBarMetrics.target - 14)
    }

    /// Left: playback (Mac) or the lock (touch). Middle: the title. Right:
    /// previous and next, Episodes, Audio & Subtitles, speed and Tools, then
    /// PiP and full screen. The same controls for every video.
    private var controlRow: some View {
        let layout = barLayout
        return ZStack {
            if layout.showsTitle {
                titleView(stacked: false)
                    .frame(maxWidth: max(stageSize.width - 2 * 330, 160))
            }
            HStack(spacing: 2) {
                ForEach(layout.leading) { barItem($0) }
                Spacer(minLength: Spacing.s)
                ForEach(Array(layout.trailing.enumerated()), id: \.offset) { i, group in
                    if i > 0 { PlayerBarDivider() }
                    ForEach(group) { barItem($0) }
                }
            }
        }
        .frame(minHeight: PlayerBarMetrics.target)
    }

    @ViewBuilder private func barItem(_ item: PlayerBarItem) -> some View {
        let enabled = PlayerBarLayout.isEnabled(item, in: barContext)
        switch item {
        case .playPause:
            let playing = session.appearsPlaying
            PlayerBarButton(symbol: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play", shortcut: "Space", glyph: 18) {
                session.togglePlayPause(); poke()
            }
            .accessibilityIdentifier("playPause")
        case .skipBack:
            PlayerBarButton(symbol: "gobackward.\(app.settings.skipBackSeconds)", label: "Back \(app.settings.skipBackSeconds) Seconds",
                            shortcut: "←") { skipBy(forward: false) }
                .symbolEffect(.rotate.counterClockwise.byLayer, options: .speed(2), value: skipBack)
        case .skipForward:
            PlayerBarButton(symbol: "goforward.\(app.settings.skipForwardSeconds)", label: "Forward \(app.settings.skipForwardSeconds) Seconds",
                            shortcut: "→") { skipBy(forward: true) }
                .symbolEffect(.rotate.clockwise.byLayer, options: .speed(2), value: skipForward)
        case .volume:
            volumeControl
        case .lock:
            #if os(iOS)
            PlayerBarButton(symbol: "lock.open", label: "Lock Controls") {
                withAnimation(Motion.snappy(reduceMotion)) { locked = true }
            }
            #else
            EmptyView()
            #endif
        case .previous, .next:
            let forward = item == .next
            let target = PlayerBarLayout.stepTarget(barContext)
            let neighbour = forward ? episodes.next : episodes.previous
            let label = switch target {
            case .episode: (forward ? "Next Episode" : "Previous Episode") + (neighbour.map { ": \($0.label)" } ?? "")
            case .chapter: forward ? "Next Chapter" : "Previous Chapter"
            case .none: forward ? "Next" : "Previous"
            }
            PlayerBarButton(symbol: forward ? "forward.end.fill" : "backward.end.fill", label: label,
                            shortcut: target == .chapter ? (forward ? "N" : "P") : target == .episode ? (forward ? "⇧N" : "⇧P") : nil) {
                stepEpisode(forward: forward)
            }
            .disabled(!enabled)
            .accessibilityIdentifier(forward ? "nextEpisode" : "previousEpisode")
            .contextMenu {
                if target == .episode {
                    if let next = episodes.next {
                        Button { Task { await session.playNext() } } label: { Label("Play \(next.label)", systemImage: "forward.end.fill") }
                    }
                    if let previous = episodes.previous {
                        Button { play(episode: previous.key) } label: { Label("Play \(previous.label)", systemImage: "backward.end.fill") }
                    }
                    Button { toggle(.episodes) } label: { Label("All Episodes", systemImage: "rectangle.stack") }
                }
            }
        case .episodes:
            PlayerBarButton(symbol: "rectangle.stack", label: "Episodes", shortcut: "E", isOn: panel == .episodes) { toggle(.episodes) }
                .disabled(!enabled)
                .panelAnchor(.episodes, in: $anchors)
                .accessibilityIdentifier("episodesButton")
        case .tracks:
            PlayerBarButton(symbol: session.subtitleSelection == .off ? "captions.bubble" : "captions.bubble.fill",
                            label: "Audio & Subtitles", shortcut: "V, B", isOn: panel == .tracks) { toggle(.tracks) }
                .panelAnchor(.tracks, in: $anchors)
                .accessibilityIdentifier("tracksMenu")
        case .speed:
            let rate = session.snapshot.rate
            Button { toggle(.speed) } label: {
                Text(PlaybackSpeed.label(rate))
                    .font(.system(size: 13, weight: .heavy)).monospacedDigit()
                    .foregroundStyle(PlaybackSpeed.isNormal(rate) ? Palette.textPrimary : Palette.brandBright)
                    .padding(.horizontal, 5)
                    // Wide enough for "1.15×", so the bar doesn't move as the speed changes.
                    .frame(minWidth: PlayerBarMetrics.button + 18, minHeight: PlayerBarMetrics.button)
                    .contentTransition(.numericText())
            }
            .buttonStyle(PlayerBarButtonStyle(isOn: panel == .speed))
            .panelAnchor(.speed, in: $anchors)
            .accessibilityLabel("Playback Speed")
            .accessibilityValue(PlaybackSpeed.label(rate))
            .accessibilityIdentifier("speedButton")
            .help("Playback Speed ([ ])")
        case .tools:
            PlayerBarButton(symbol: "slider.horizontal.3", label: "Tools", shortcut: "T", isOn: panel == .tools) { toggle(.tools) }
                .panelAnchor(.tools, in: $anchors)
                .accessibilityIdentifier("playerToolsButton")
        case .pip:
            PlayerBarButton(symbol: pipActive ? "pip.exit" : "pip.enter",
                            label: pipActive ? "Exit Picture in Picture" : "Picture in Picture") { togglePiP() }
                .disabled(!enabled)
                .accessibilityIdentifier("vlcPiP")
        case .fullScreen:
            #if os(macOS)
            PlayerBarButton(symbol: window.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            label: window.isFullScreen ? "Exit Full Screen" : "Full Screen", shortcut: "F") {
                window.toggleFullScreen()
            }
            #else
            EmptyView()
            #endif
        }
    }

    /// Mac: mute on click, a slider beside it while the pointer is over it.
    private var volumeControl: some View {
        let level = session.isMuted ? 0 : session.volume
        let symbol = level < 0.005 ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        return HStack(spacing: 0) {
            PlayerBarButton(symbol: symbol, label: session.isMuted ? "Unmute" : "Mute", shortcut: "M") {
                session.setMuted(!session.isMuted); poke()
            }
            if volumeExpanded {
                Slider(value: Binding(get: { Double(level) }, set: { session.setVolume(Float($0)); lastInteraction = Date() }), in: 0...1)
                    .controlSize(.mini)
                    .tint(.white)
                    .frame(width: 80)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int((level * 100).rounded())) percent")
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .onHover { h in withAnimation(Motion.snappy(reduceMotion)) { volumeExpanded = h } }
        .help("Volume (↑ ↓, M)")
    }

    private var pipAvailable: Bool {
        if avPlayer != nil { return PictureInPictureModel.isSupported && pip.isPossible }
        return vlcEngine != nil && VLCPictureInPicture.isSupported && vlcPiP.isAvailable && (vlcPiP.isPossible || vlcPiP.isActive)
    }

    private var pipActive: Bool { avPlayer != nil ? pip.isActive : vlcPiP.isActive }

    private func togglePiP() {
        if avPlayer != nil { pip.toggle() } else { vlcPiP.toggle() }
    }

    private func toggle(_ kind: PlayerPanelKind) {
        lastInteraction = Date()
        if kind == .episodes, !episodes.isSeries { return }
        if kind == .chapters, session.snapshot.chapters.isEmpty { return }
        panel = panel == kind ? nil : kind
        if panel != nil { poke() }
    }

    private func closePanel() {
        panel = nil
        focused = true
        poke()
    }

    /// The open card, over the button that opened it.
    private func panelCard(_ kind: PlayerPanelKind) -> some View {
        let compact = stageSize.height < 500
        let wide = compact && stageSize.width >= 700
        var width = kind.width(compact: compact)
        if kind == .tools, compact, !wide { width = 340 }
        if kind == .tracks, !compact, session.snapshot.audioTracks.isEmpty { width = 260 }
        let place = PanelPlacement.frame(anchor: anchors[kind], width: width, stage: stageSize,
                                         // Mac: above the whole bar. Phones: the card may cover the timeline.
                                         barTop: platform == .mac ? barTop : nil,
                                         topInset: compact ? Spacing.s : 44)
        let inner = min(width, stageSize.width - 24) - PlayerCardMetrics.padding * 2
        return Group {
            switch kind {
            case .episodes:
                EpisodesPanel(model: episodes, currentKey: session.item?.key, switchingTo: switchingTo,
                              onPick: { play(episode: $0.key) }, onClose: closePanel)
                    .padding(PlayerCardMetrics.padding)
                    .frame(maxHeight: place.maxHeight)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                ScrollView {
                    panelContent(kind, innerWidth: inner, wide: wide)
                        .padding(PlayerCardMetrics.padding)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.automatic)
                .frame(maxHeight: place.maxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: min(width, stageSize.width - 24))
        .playerCardSurface()
        .transition(reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
        .onKeyPress(.escape) { closePanel(); return .handled }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, place.x)
        .padding(.bottom, place.bottom)
        .id(kind)
    }

    @ViewBuilder private func panelContent(_ kind: PlayerPanelKind, innerWidth: CGFloat, wide: Bool) -> some View {
        switch kind {
        case .tracks:
            TracksPanel(session: session, width: innerWidth, canSearch: canSearchSubtitles, initialPage: tracksStartPage,
                        onAddFile: { closePanel(); importingSubtitle = true },
                        onSearch: { closePanel(); searchingSubtitles = true })
        case .speed:
            SpeedPanel(rate: session.snapshot.rate) { r in session.setRate(r); lastInteraction = Date() }
        case .tools:
            ToolsPanel(session: session, skip: skip, columns: wide ? 5 : 3, statsShown: statsShown, initialPage: toolsStartPage,
                       onToggleStats: { statsShown.toggle() },
                       onLoop: cycleLoop,
                       onSnapshot: { Task { await saveSnapshot() } },
                       onJump: { closePanel(); jumping = true })
        case .chapters:
            ChaptersPanel(session: session)
        case .episodes:
            EmptyView()
        }
    }

    /// Switches episodes inside the player. Audio and subtitle choices carry over (see PlayerSession).
    private func play(episode key: MediaKey) {
        guard key != session.item?.key, !session.isLoadingNext else { return }
        switchingTo = key
        Task {
            await session.switchItem { await app.resolveEpisode(key) }
            if session.item?.key != key {
                switchingTo = nil
                flash("Couldn't open that episode")
            }
        }
    }

    /// How far subtitles move up while the controls show: clear of the timeline and tool row.
    private func subtitleControlsInset(height: CGFloat) -> CGFloat {
        barTop > 0 ? max(height - barTop, 0) + Spacing.s : (height < 500 ? 96 : 130)
    }

    /// VLC draws the subtitles from the file itself (Bluebox's overlay draws files and AVPlayer's text).
    private var vlcDrawsSubtitles: Bool {
        if case .embedded = session.subtitleSelection { return session.snapshot.drawsEmbeddedSubtitles }
        return false
    }

    #if os(iOS)
    /// "Turn your phone": shown when the window didn't turn as asked (it can't
    /// always, for instance with another app's window in front).
    private var rotatePrompt: some View {
        Button {
            PlayerOrientation.retry()
            checkOrientation(after: 1)
        } label: {
            Label(PlayerOrientation.mode == .landscape ? "Rotate to Landscape" : "Rotate to Portrait",
                  systemImage: PlayerOrientation.mode == .landscape ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, Spacing.l)
                .frame(minHeight: 44)
                .background(.black.opacity(0.75), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
        }
        .buttonStyle(PressableStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 64)
        .transition(.opacity)
        .accessibilityIdentifier("rotatePrompt")
    }

    private func checkOrientation(after seconds: Double) {
        guard PlayerOrientation.isPhone else { return }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            withAnimation(Motion.standard(reduceMotion)) { showsRotatePrompt = !PlayerOrientation.isSettled }
            guard showsRotatePrompt else { return }
            try? await Task.sleep(for: .seconds(6))
            withAnimation(Motion.standard(reduceMotion)) { showsRotatePrompt = false }
        }
    }
    #endif

    // MARK: Overlays

    private func upNextCard(_ upNext: PlayerSession.UpNext) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .top, spacing: Spacing.m) {
                ZStack {
                    ArtworkView(url: upNext.item.artworkURL, fallbackTitle: upNext.item.title, kind: .still,
                                pixelWidth: 320, showsFallbackTitle: false)
                        .frame(width: 128, height: 72)
                        .spoilerBlurred(app.featureSwitches.spoilerGuard)  // the next episode isn't watched yet
                    // The countdown, as a ring around a play mark.
                    ProgressRing(fraction: Double(upNext.secondsRemaining) / Double(max(app.settings.upNextCountdown, 1)),
                                 lineWidth: 3, tint: .white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.45), in: Circle())
                        .overlay(Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)))
                        .animation(.linear(duration: 1), value: upNext.secondsRemaining)
                }
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Up Next").font(.caption.weight(.heavy)).tracking(1.5).foregroundStyle(Palette.brandBright)
                    Text(upNext.item.subtitle ?? upNext.item.title).font(.headline).lineLimit(2)
                }
            }
            HStack(spacing: Spacing.s) {
                Button { Task { await session.playUpNext() } } label: {
                    Label("Next Episode in \(upNext.secondsRemaining)", systemImage: "play.fill")
                        .contentTransition(.numericText(countsDown: true))
                        .monospacedDigit()
                }
                .buttonStyle(PlayButtonStyle())
                Button("Cancel") { session.cancelUpNext() }.buttonStyle(GlassButtonStyle())
            }
            .animation(.default, value: upNext.secondsRemaining)
        }
        .padding(Spacing.l)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Palette.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous).strokeBorder(Palette.edge))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, 110)
    }

    /// What went wrong in plain words, and the ways forward: the same release
    /// again, another release (with add-ons), the download (if there is one).
    private func errorOverlay(_ error: PlaybackError) -> some View {
        let item = session.item
        let canTryAnother = item.map { canChooseRelease(for: $0.key) } ?? false
        var actions: [PlayerMessageCard.Action] = []
        if session.currentResource != nil {
            actions.append(.init(id: "retry", title: "Try Again", symbol: "arrow.clockwise", primary: true) { retryPlayback() })
        }
        if let item, canTryAnother {
            actions.append(.init(id: "otherRelease", title: "Try Another Release", primary: actions.isEmpty) {
                releaseRequest = TitleDetailView.ReleaseRequest(item: item)
            })
        }
        if let download = playableDownload {
            actions.append(.init(id: "playDownload", title: "Play Download", symbol: "arrow.down.circle") {
                Task {
                    await app.closePlayer()
                    await app.playDownloadChecked(download)
                }
            })
        }
        actions.append(.init(id: "close", title: "Close") { Task { await app.closePlayer() } })
        return PlayerMessageCard(symbol: "exclamationmark.triangle.fill",
                                 title: PlayerErrorText.title(for: item),
                                 message: PlayerErrorText.message(for: error, offline: app.settings.isOffline,
                                                                  canTryAnother: canTryAnother),
                                 actions: actions)
    }

    /// End of a film (or an episode with nothing after it): watch again, or back to browsing.
    private var endCard: some View {
        let item = session.item
        var actions: [PlayerMessageCard.Action] = [
            .init(id: "watchAgain", title: "Watch Again", symbol: "arrow.counterclockwise", primary: true) {
                Task { await session.seek(to: 0); session.togglePlayPause(); poke() }
            },
        ]
        if hasNext {
            actions.append(.init(id: "next", title: "Next Episode", symbol: "forward.end.alt.fill") {
                Task { await session.playNext() }
            })
        }
        actions.append(.init(id: "back", title: "Back to Browse") { Task { await app.closePlayer() } })
        return PlayerMessageCard(eyebrow: "Finished",
                                 title: [item?.title, item?.subtitle.flatMap { item?.key.episodeNumbers != nil ? $0 : nil }]
                                    .compactMap { $0 }.joined(separator: " · "),
                                 actions: actions)
    }

    /// Loads the same release again, from where it was.
    private func retryPlayback() {
        guard let item = session.item, let resource = session.currentResource else { return }
        let position = session.snapshot.position
        Task { await session.start(item, resource: resource, resume: true, startAt: position > 1 ? position : nil) }
    }

    /// Add-ons can offer other releases of catalog titles (not files or links).
    private func canChooseRelease(for key: MediaKey) -> Bool {
        app.addonSettings.isEnabled && (key.tmdbID != nil || key.imdbID != nil)
    }

    /// A finished download of what's playing, when that isn't already what failed.
    private var playableDownload: DownloadRecord? {
        guard let key = session.item?.key, session.currentResource?.variant.location != .downloaded,
              let record = app.visibleDownload(for: key), record.state == .completed else { return nil }
        return record
    }

    // MARK: Behavior

    private func toggleControls() {
        withAnimation(Motion.standard(reduceMotion)) { controlsVisible.toggle() }
        lastInteraction = Date()
        #if os(macOS)
        if !controlsVisible { window.hidePointer() }
        #endif
    }

    private func poke() {
        lastInteraction = Date()
        if !controlsVisible { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true } }
    }

    /// Controls fade 3 s after the last touch, click or pointer move while
    /// playing; never mid-scrub, with the tools open, while the pointer rests on
    /// them or while subtitles are being moved. On the Mac the pointer hides too.
    private func autoHide() async {
        while !Task.isCancelled, session.snapshot.status == .playing {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let idle = Date().timeIntervalSince(lastInteraction) > 3
            if idle, controlsVisible, scrubFraction == nil, panel == nil, !hoveringControls, !subtitleEditing, boostedFrom == nil {
                withAnimation(.easeIn(duration: 0.3)) { controlsVisible = false }
                #if os(macOS)
                window.hidePointer()
                #endif
            }
        }
    }
}

/// The player's keyboard shortcuts (hardware keyboards on iOS too). Esc and F
/// on the Mac go through `PlayerWindowModel`, which also works without focus.
struct PlayerKeys: ViewModifier {
    struct Actions {
        let playPause: () -> Void
        let skip: (Bool) -> Void
        /// → goes through here: a tap skips, a hold plays at 2×.
        let forwardKey: (KeyPress.Phases) -> Void
        let close: () -> Void
        let stepSpeed: (Int) -> Void
        let volume: (Float) -> Void
        let mute: () -> Void
        let episodes: () -> Void
        let episodeStep: (Bool) -> Void
        let nudgeSubtitles: (Double) -> Void
        let subtitleSize: (Double) -> Void
        let cycleSubtitles: () -> Void
        let cycleAudio: () -> Void
        let stepFrame: (Int) -> Void
        let aspect: () -> Void
        let crop: () -> Void
        let zoom: () -> Void
        let rotate: () -> Void
        let loop: () -> Void
        let snapshot: () -> Void
        let tools: () -> Void
        let jump: () -> Void
        let chapter: (Int) -> Void
    }

    let actions: Actions

    func body(content: Content) -> some View {
        content
            .onKeyPress(.space) { actions.playPause(); return .handled }
            .onKeyPress(.leftArrow) { actions.skip(false); return .handled }
            .onKeyPress(keys: [.rightArrow], phases: [.down, .repeat, .up]) { press in
                actions.forwardKey(press.phase); return .handled
            }
            .onKeyPress(.upArrow) { actions.volume(0.1); return .handled }
            .onKeyPress(.downArrow) { actions.volume(-0.1); return .handled }
            #if os(iOS)
            .onKeyPress(.escape) { actions.close(); return .handled }
            #endif
            .onKeyPress(characters: .init(charactersIn: "[]{}-=_+vbaczrlstjnpmeNP,."), phases: .down) { press in
                guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
                switch press.characters {
                case "[": actions.stepSpeed(-1)
                case "]": actions.stepSpeed(1)
                case "{": actions.nudgeSubtitles(-0.1)
                case "}": actions.nudgeSubtitles(0.1)
                case "-", "_": actions.subtitleSize(-0.0045)
                case "=", "+": actions.subtitleSize(0.0045)
                case "v": actions.cycleSubtitles()
                case "b": actions.cycleAudio()
                case "a": actions.aspect()
                case "c": actions.crop()
                case "z": actions.zoom()
                case "r": actions.rotate()
                case "l": actions.loop()
                case "s": actions.snapshot()
                case "t": actions.tools()
                case "j": actions.jump()
                case "m": actions.mute()
                case "e": actions.episodes()
                case "n": actions.chapter(1)
                case "p": actions.chapter(-1)
                case "N": actions.episodeStep(true)
                case "P": actions.episodeStep(false)
                case ",": actions.stepFrame(-1)
                case ".": actions.stepFrame(1)
                default: return .ignored
                }
                return .handled
            }
    }
}

/// "Now using mobile data": shown when Wi‑Fi drops mid-stream (iPhone and
/// iPad). A solid one-line strip under the top bar with Pause, Lower Quality
/// and Continue at its trailing edge; two lines only where that can't fit.
struct MobileDataBanner: View {
    let onContinue: () -> Void
    let onLowerQuality: () -> Void
    let onPause: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.m) {
                message
                Spacer(minLength: Spacing.s)
                buttons
            }
            VStack(alignment: .leading, spacing: 0) {
                message.padding(.top, Spacing.s)
                buttons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, Spacing.xs)
        .frame(maxWidth: 680)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous).strokeBorder(Palette.edge))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mobileDataBanner")
    }

    private var message: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.brandBright)
            Text("Now using mobile data").font(.subheadline.weight(.bold)).foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now using mobile data. Wi‑Fi dropped, so streaming uses your data plan.")
    }

    private var buttons: some View {
        HStack(spacing: Spacing.xs) {
            Button("Pause", action: onPause).buttonStyle(BannerButtonStyle(primary: false))
            Button("Lower Quality", action: onLowerQuality).buttonStyle(BannerButtonStyle(primary: false))
            Button("Continue", action: onContinue).buttonStyle(BannerButtonStyle(primary: true))
        }
        .fixedSize()
    }
}

/// Compact solid buttons for the banner: white with black text for the main
/// one, grey for the rest. 32 pt to the eye, a full touch target to the finger.
private struct BannerButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: 32)
            .background(primary ? Color.white.opacity(configuration.isPressed ? 0.78 : 1)
                                : (configuration.isPressed ? Palette.glassFillPressed : Palette.elevated),
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .foregroundStyle(primary ? Color.black : Palette.textPrimary)
            .frame(minHeight: PanelMetrics.control)
            .contentShape(Rectangle())
    }
}

/// A round, glyph-only player button with a 44 pt target.

struct PlayerIconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 18
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(hovering ? 0.18 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

extension View {
    /// Records this control's frame in the player's stage, so its card opens over it.
    func panelAnchor(_ kind: PlayerPanelKind, in anchors: Binding<[PlayerPanelKind: CGRect]>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PlayerView.stageSpace)) } action: { anchors.wrappedValue[kind] = $0 }
    }
}

/// Finds subtitles on OpenSubtitles for what's playing and adds the chosen one.
struct SubtitleSearchSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let key: MediaKey
    let onPick: (URL) -> Void
    @State private var results: [SubtitleSearchResult]?
    @State private var error: String?
    @State private var downloading: Int?

    var body: some View {
        NavigationStack {
            Group {
                if let results, results.isEmpty {
                    ContentUnavailableView("No subtitles found", systemImage: "captions.bubble",
                                           description: Text("Try another preferred language in Settings › Subtitles."))
                } else if let results {
                    List(results) { r in
                        Button { Task { await pick(r) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.release).lineLimit(2)
                                    Text(details(r)).font(.caption).foregroundStyle(Palette.textSecondary)
                                }
                                Spacer()
                                if downloading == r.id { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(downloading != nil)
                    }
                } else if error == nil {
                    ProgressView("Searching…")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error { Text(error).font(.footnote).foregroundStyle(Palette.warning).padding() }
            }
            .navigationTitle("Subtitles")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .frame(minWidth: 460, minHeight: 420)
        .preferredColorScheme(.dark)
        .task {
            do { results = try await app.searchSubtitles(for: key) }
            catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func details(_ r: SubtitleSearchResult) -> String {
        var parts = [r.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? r.language ?? "Unknown"]
        parts.append("\(r.downloadCount) downloads")
        if r.hearingImpaired { parts.append("SDH") }
        if r.machineTranslated { parts.append("Machine translated") }
        return parts.joined(separator: " · ")
    }

    private func pick(_ r: SubtitleSearchResult) async {
        downloading = r.id; error = nil
        defer { downloading = nil }
        do {
            onPick(try await app.downloadSubtitle(r))
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Seek to a typed time (h:mm:ss, mm:ss or seconds).
struct JumpToTimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let duration: TimeInterval
    let onJump: (TimeInterval) -> Void
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("1:23:45", text: $text)
                    .font(.title2.monospacedDigit())
                    .onSubmit(jump)
                    .accessibilityIdentifier("jumpTimeField")
                if duration > 0 { Text("Length \(Formatters.duration(duration))").foregroundStyle(Palette.textSecondary) }
            }
            .formStyle(.grouped)
            .navigationTitle("Jump to Time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Go", action: jump).disabled(Self.parse(text) == nil) }
            }
        }
        .frame(minWidth: 320, minHeight: 200)
        .preferredColorScheme(.dark)
    }

    private func jump() {
        guard let t = Self.parse(text) else { return }
        onJump(duration > 0 ? min(t, duration) : t)
        dismiss()
    }

    static func parse(_ s: String) -> TimeInterval? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}

/// A message at the top of the player, optionally with one action (Undo).
struct PlayerToast: Equatable {
    let message: String
    var actionTitle: String?
    let id = UUID()
}
