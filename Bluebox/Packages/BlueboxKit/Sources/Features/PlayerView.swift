import AVFoundation
import DesignSystem
import Domain
import Downloads
import Metadata
import Playback
import SkipSegments
import Sync
import Subtitles
import SwiftUI
import TorrentStreaming
import VLCPlayback

struct PlayerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    let session: PlayerSession
    @StateObject private var pip = PictureInPictureModel()
    @State private var controlsVisible = true
    /// A hold on Next or Previous Episode opens its menu instead of stepping.
    @State private var stepGate = QuickActionGate()
    @State private var lastInteraction = Date()
    @State private var scrubFraction: Double?
    @State private var jumping = false
    @State private var toast: PlayerNotice?
    /// Sync to the Audio, here rather than in its page so it outlives the card.
    @State private var audioSync = SubtitleAudioSync()
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
    /// Subtitle Style is open beside the video.
    @State private var styleOpen = false
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
    /// The spinner is up: a stall has lasted a moment (short hiccups don't flash it).
    @State private var showsWaiting = false
    /// Downloaded parts of a torrent stream, as fractions of the file.
    @State private var available: [ClosedRange<Double>] = []
    /// The same in bytes, for Stats' pieces ahead.
    @State private var fileRanges: TorrentFileRanges?
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
    #else
    /// The swipe under way (Settings › Playback › Swipe Gestures).
    @State private var swipe: PlayerSwipe?
    @State private var swipeSeekTarget: Double?
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
        partyLayout
        .animation(Motion.snappy(reduceMotion), value: styleOpen)
        .animation(Motion.snappy(reduceMotion), value: app.party?.chatOpen)
        .background { partyKeys }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        #if os(iOS)
        .blueboxMenuHost()  // a full-screen cover: menus draw over the video, not under it
        #endif
        // The phone's remote shows the same skip button (the better remote, question 8).
        .onChange(of: skip.offer, initial: true) { _, offer in
            app.remoteSkip = offer.map { o in (SkipSegmentPlanner.title(for: o), { perform(skip.accept()) }) }
        }
        .onDisappear { app.remoteSkip = nil }
        .sheet(isPresented: $jumping) { JumpToTimeSheet(duration: session.snapshot.duration ?? 0, position: session.displayPosition) { t in Task { await session.seek(to: t) } } }
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
        .onAppear {
            window.onEscapeInWindow = {
                if panel != nil { closePanel() } else if styleOpen { closeStyle() } else { Task { await app.closePlayer() } }
            }
            window.onEscapeWithCard = {
                if panel != nil { closePanel(); return true }
                if styleOpen { closeStyle(); return true }
                return false
            }
            window.onWindowClose = { Task { await app.closePlayer() } }
        }
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

    private var canSearchSubtitles: Bool { app.canSearchSubtitlesOnline(for: session.item?.key) }

    // MARK: Watch Party

    /// Mac and iPad: the party's panel beside the video. iPhone: over the
    /// right of the video in landscape, under it upright (PartyPanel).
    @ViewBuilder private var partyLayout: some View {
        let party = app.party
        let panelOpen = party?.chatOpen == true
        #if os(iOS)
        if platform == .phone, let party, panelOpen, verticalSizeClass == .regular {
            // Upright: the film on top, the chat under it, like a live stream.
            VStack(spacing: 0) {
                stage.aspectRatio(16 / 9, contentMode: .fit)
                PartyPanel(party: party, compact: true)
            }
        } else if platform == .phone, let party, panelOpen {
            stage.overlay(alignment: .trailing) {
                PartyPanel(party: party, compact: true)
                    .frame(width: min(max(stageSize.width / 3, 260), 340))
                    .opacity(0.97)
                    .transition(.move(edge: .trailing))
            }
        } else {
            sideBySide(party: party, panelOpen: panelOpen)
        }
        #else
        sideBySide(party: party, panelOpen: panelOpen)
        #endif
    }

    private func sideBySide(party: WatchParty?, panelOpen: Bool) -> some View {
        HStack(spacing: 0) {
            stage
            if styleOpen {
                SubtitleStyleInspector(style: Bindable(app).subtitleStyle, session: session, onClose: closeStyle)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
            } else if let party, panelOpen {
                PartyPanel(party: party)
                    .frame(width: PartyPanel.width)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
            }
        }
    }

    /// ⌘/ opens and closes the chat; ⌥1–6 react.
    @ViewBuilder private var partyKeys: some View {
        if let party = app.party {
            ZStack {
                Button("Party Chat") { party.chatOpen.toggle() }.keyboardShortcut("/", modifiers: .command)
                ForEach(Array(TogetherReaction.quick.enumerated()), id: \.offset) { i, emoji in
                    Button("React \(emoji)") { party.react(emoji) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .option)
                }
            }
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    /// Controls draw over the video unless a message card (error, end of
    /// film) asks what to do next. They stay while a panel card is open, and
    /// while the video opens or stalls; playing or paused they fade when idle.
    private var controlsShown: Bool {
        let status = session.snapshot.status
        return !showsCard && (controlsVisible || panel != nil || (status != .playing && status != .paused))
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
            && app.party?.room.upNext == nil
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
                    // While the lines are drawn into the picture (PiP, AirPlay) the overlay stands aside.
                    let inPicture = session.drawsSubtitlesInPicture || session.snapshot.isExternalPlaybackActive
                    SubtitleOverlay(primary: inPicture ? nil : session.subtitleText, secondary: inPicture ? nil : session.secondarySubtitleText,
                                    style: Bindable(app).subtitleStyle,
                                    videoRect: layout.visibleRect.isEmpty ? CGRect(origin: .zero, size: geo.size) : layout.visibleRect,
                                    // Down into the black bar under a letterboxed picture, or up into the one above.
                                    stageRect: CGRect(origin: .zero, size: geo.size),
                                    // Above the timeline whenever it shows, the tools' sample line too.
                                    controlsVisible: controlsShown,
                                    controlsInset: subtitleControlsInset(height: geo.size.height),
                                    controlsTopInset: subtitleControlsTopInset,
                                    // While the look is being changed, and only where no real line is.
                                    placeholder: (styleOpen || (showsStylePreview && panel == .tracks)) && !vlcDrawsSubtitles ? "Subtitles look like this." : nil,
                                    onEditingChanged: { editing in
                                        subtitleEditing = editing
                                        lastInteraction = Date()
                                    })
                }
            }
            .ignoresSafeArea()
            // Taps go to the picture layer only: on the whole stage, the
            // double-tap recogniser would swallow taps meant for the buttons.
            // Mac: click plays or pauses, double-click toggles full screen.
            // iOS: tap shows or hides them; double-tap the left or right third skips.
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .local) { doubleTap(at: $0) }
            .onTapGesture { singleTap() }
            #if os(iOS)
            // Press and hold the video to play at 2× (YouTube's gesture).
            .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 30, perform: {
                guard !locked, !subtitleEditing, session.appearsPlaying else { return }
                startBoost()
            }, onPressingChanged: { pressing in
                if !pressing { endBoost() }
            })
            .simultaneousGesture(swipeGesture, isEnabled: app.settings.swipeGestures)
            #endif
            if let skipFlash { skipIndicator(skipFlash) }
            // Mac: nothing sits over the middle of the picture except the
            // buffering ring while it waits (touch shows it in place of play).
            // Not over an open card (the timeline shows the stall there).
            if platform == .mac, showsWaiting, !showsCard, panel == nil {
                bufferingRing(size: 46).allowsHitTesting(false).transition(.opacity)
            }
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
            if let party = app.party, !locked {
                PartyOverlay(party: party, controlsShown: controlsShown,
                             topInset: stageSize.height < 500 ? 56 : 64,
                             bottomInset: controlsShown ? max(stageSize.height - barTop, 0) : Spacing.l)
                    .zIndex(1)
            }
            if !locked, !previewing, panel == nil, session.upNext == nil, !showsCard {
                SkipPill(skip: skip, controlsShown: controlsShown, onAccept: { perform(skip.accept()) }, onWrongTime: wrongSkipTime, onAlways: alwaysSkip)
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
                let statsTop = controlsShown ? (stageSize.height < 500 ? 56 : 64) : Spacing.l
                let statsBottom = controlsShown && barTop > 0 ? max(stageSize.height - barTop, 0) + Spacing.s : Spacing.l
                PlayerStatsCard(session: session, swarm: swarm, fileRanges: fileRanges,
                                maxHeight: stageSize.height - statsTop - statsBottom,
                                onCopied: { flash("Diagnostics copied · no links, keys or names", symbol: "doc.on.doc") },
                                onClose: { statsShown = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, statsTop)
                    .padding(.leading, Spacing.l)
                    .transition(.opacity)
                    .zIndex(1)
            }
            if boostedFrom != nil {
                Label("2×", systemImage: "forward.fill")
                    .font(.callout.weight(.bold))
                    .labelStyle(NoticeLabelStyle())
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .playerNoticeSurface()
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
            if let upNext = session.upNext { upNextCard(upNext).transition(Motion.nudge(from: .bottom, reduceMotion)) }
            if session.isLoadingNext {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(Palette.brandBright)
                    Text(switchingTo.map { k in k.episodeNumbers.map { "Opening S\($0.season)·E\($0.episode)…" } ?? "Opening…" }
                         ?? "Finding the next episode…").font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .playerNoticeSurface()
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
                    // A nudge, not `.move`: the frame is the stage's height, so a move flew it in from far above.
                    .transition(Motion.nudge(from: .top, reduceMotion))
                    .zIndex(3)
            }
            if let toast {
                PlayerNoticeView(notice: toast, action: toastAction.map { action in {
                    withAnimation(Motion.disappear) { self.toast = nil }
                    toastAction = nil
                    action()
                } })
                .id(toast.kind)
                .padding(.horizontal, Spacing.l)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 70)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                .zIndex(5)
            }
        }
        .animation(Motion.standard(reduceMotion), value: app.networkSwitchedToCellularDuringPlayback)
        .animation(Motion.snappy(reduceMotion), value: boostedFrom != nil)
        .animation(Motion.standard(reduceMotion), value: statsShown)
        .animation(Motion.standard(reduceMotion), value: showsCard)
        .animation(Motion.standard(reduceMotion), value: session.upNext == nil)
        .animation(Motion.standard(reduceMotion), value: session.isLoadingNext)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.28), value: panel)
        .coordinateSpace(.named(Self.stageSpace))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            stageWidth = size.width; stageSize = size
            #if os(iOS)
            // A phone on its side: denser cards (see PanelMetrics.dense).
            PanelMetrics.dense = size.height < 500
            #endif
        }
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
        // A sync that finishes with its card closed says so here, with Undo.
        .onChange(of: audioSync.phase) { _, phase in
            guard panel != .tracks else { return }
            switch phase {
            case .done(let offset, _, let drift):
                flash("Synced to the audio · \(offset.label)" + (drift ? ", drift fixed" : ""), symbol: "waveform", action: "Undo") {
                    audioSync.undo(session)
                }
            case .failed(let message): flash(message, symbol: "waveform.slash", style: .warning)
            default: break
            }
        }
        .onDisappear {
            audioSync.cancel(); app.noteAirPlayingVideo(false)
            #if os(iOS)
            ScreenBrightness.restore()
            #endif
        }
        // Picture in Picture can't show the overlay: the lines go into the picture.
        .onChange(of: pipActive, initial: true) { _, active in session.drawsSubtitlesInPicture = active }
        // Release ranking prefers MP4 while the video goes to AirPlay.
        .onChange(of: session.snapshot.isExternalPlaybackActive, initial: true) { _, active in app.noteAirPlayingVideo(active) }
        .modifier(PlayerKeys(actions: keyActions))
        .task(id: session.snapshot.status == .playing || session.snapshot.status == .paused) { await autoHide() }
        // Pausing shows the controls (they fade again after a while, so a paused frame reads as it played).
        .onChange(of: session.snapshot.status == .paused) { _, paused in if paused { poke() } }
        // The profile's equaliser changed elsewhere (Settings, another device): hear it now.
        .onChange(of: app.equalizer) { _, eq in
            guard session.audioEffects.equalizer != eq else { return }
            var n = session.audioEffects; n.equalizer = eq; session.setAudioEffects(n)
        }
        // VLC draws the video's own text tracks in the picture: they move clear of the controls the same way.
        .onChange(of: engineSubtitleStyle, initial: true) { _, style in session.subtitleStyle = style }
        .task(id: session.item?.key) {
            // Metadata only: resolving the next episode here would start its stream,
            // which for add-on torrents replaces the one playing now.
            await episodes.load(for: session.item?.key, app: app)
        }
        // The credits countdown only runs while it can be seen and playback runs.
        .onChange(of: session.snapshot.status != .playing || panel != nil || previewing || locked || showsCard, initial: true) { _, held in
            skip.holdsCountdown = held
        }
        // A card left open under the error or end card would come back after it (and eat the first Esc).
        .onChange(of: showsCard) { _, card in if card, panel != nil { closePanel() } }
        // The bar can vanish under the pointer (an error or end card) without a hover-out.
        .onChange(of: controlsShown) { _, shown in if !shown { hoveringControls = false; previewing = false } }
        // A 2× hold whose key-up or finger-up never comes (the app lost focus, the item changed) ends here.
        .onChange(of: scenePhase) { _, phase in if phase != .active { rightArrowDown = nil; endBoost() } }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            rightArrowDown = nil; endBoost()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            rightArrowDown = nil; endBoost()
        }
        #endif
        .onChange(of: app.subtitleStyle, initial: true) { old, new in
            guard old != new else { return }
            showsStylePreview = true
            stylePreviewTask?.cancel()
            stylePreviewTask = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                withAnimation(Motion.disappear) { showsStylePreview = false }
            }
        }
        // How long it's been loading, for the loading words.
        .onChange(of: session.snapshot.status == .loading || session.snapshot.status == .buffering, initial: true) { _, waiting in
            loadingSince = waiting ? (loadingSince ?? Date()) : nil
        }
        // The spinner waits a moment before it shows, so a short stall (a seek,
        // a card opening while the stream catches up) passes without it. A video
        // that is still opening shows it straight away.
        .task(id: waiting) {
            guard waiting else {
                if showsWaiting { withAnimation(Motion.disappear) { showsWaiting = false } }
                return
            }
            let opening = session.snapshot.status == .loading && session.snapshot.duration == nil
            if !opening { try? await Task.sleep(for: .milliseconds(900)) }
            guard !Task.isCancelled, waiting else { return }
            withAnimation(Motion.appear) { showsWaiting = true }
        }
        // Torrent streams: swarm numbers for the loading words, and which parts
        // of the file are in for the timeline. Every second while it waits,
        // every two while it plays.
        .task(id: session.currentResource?.url) {
            swarm = nil; available = []; fileRanges = nil
            guard let resource = session.currentResource,
                  resource.url.host == "127.0.0.1" || resource.url.host == "localhost",
                  resource.variant.sourceID == app.addons.id else { return }
            while !Task.isCancelled {
                swarm = await app.addons.streamStats()
                fileRanges = TorrentStreamer.downloadedRanges(for: resource.url)
                available = fileRanges?.fractions ?? []
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
            rightArrowDown = nil; endBoost()
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
                    if which == .tracks, page == "style" { openStyle() } else { panel = which }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-player-jump") {
                // Screenshots: Jump to Time, once the video plays.
                Task { try? await Task.sleep(for: .seconds(3)); jumping = true }
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
                SubtitleSearchSheet(key: key, release: session.currentResource?.variant.displayName,
                                    title: session.item?.title) { url in session.importSubtitle(url) }
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
                    flash("Skipped \(kind.title.lowercased()) · always for this show", symbol: "forward.end.fill", action: "Stop") {
                        settings.setAlwaysSkip(false, kind, for: key)
                    }
                } else {
                    flash("Skipped \(kind.title.lowercased())", symbol: "forward.end.fill")
                }
            }
        }
    }

    /// "Always for this show": remember it, and skip this one now.
    private func alwaysSkip(_ part: ShowSkipRules.Part) {
        guard let key = session.item?.key else { return }
        app.settings.setAlwaysSkip(true, part, for: key)
        perform(skip.accept())
        flash("Always skipping the \(part.title.lowercased()) of this show", symbol: "forward.end.alt.fill", action: "Undo") {
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
        flash("\(source) timestamps off for this show", symbol: "clock.badge.xmark", action: "Undo") {
            app.settings.setCrowdSkipsAllowed(true, for: key)
            skip.reset()
            flash("\(source) timestamps back on", symbol: "clock.badge.checkmark")
        }
    }

    private func advertiseHandoff(force: Bool = false) {
        guard app.settings.handoff, let payload = app.handoffPayload(for: session) else { return }
        handoff.update(payload, force: force)
    }

    // MARK: Taps

    /// Click plays or pauses (Mac, as in QuickTime); tap shows or hides the controls (iOS).
    private func singleTap() {
        #if os(macOS)
        guard !locked else { return }
        session.togglePlayPause(); poke()
        #else
        toggleControls()
        #endif
    }

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

    #if os(iOS)
    /// Sideways seeks (on release, so a stream isn't asked for every point on
    /// the way); up and down on the left sets brightness, on the right volume.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { v in
                guard !locked, !subtitleEditing, panel == nil, scrubFraction == nil,
                      session.videoFraming.zoom <= 1 else { return }
                if swipe == nil {
                    // A 2× hold that then moves stays a hold.
                    guard boostedFrom == nil, let kind = PlayerSwipe.kind(startLocation: v.startLocation, translation: v.translation, in: stageSize)
                    else { return }
                    let start = switch kind {
                    case .seek: session.snapshot.position
                    case .brightness: ScreenBrightness.level
                    case .volume: Double(session.volume)
                    }
                    swipe = PlayerSwipe(kind: kind, start: start)
                }
                guard let swipe else { return }
                switch swipe.kind {
                case .seek:
                    let target = PlayerSwipe.seekTarget(from: swipe.start, dx: v.translation.width, width: stageSize.width,
                                                        duration: session.snapshot.duration)
                    swipeSeekTarget = target
                    let delta = target - swipe.start
                    flash("\(delta < 0 ? "−" : "+")\(Formatters.duration(abs(delta))) · \(Formatters.duration(target))",
                          symbol: delta < 0 ? "backward.fill" : "forward.fill", kind: "swipeSeek")
                case .brightness:
                    let level = PlayerSwipe.level(from: swipe.start, dy: v.translation.height, height: stageSize.height)
                    ScreenBrightness.set(level)
                    flash("Brightness \(Int((level * 100).rounded()))%", symbol: "sun.max.fill", level: level, kind: "brightness")
                case .volume:
                    let level = PlayerSwipe.level(from: swipe.start, dy: v.translation.height, height: stageSize.height)
                    session.setVolume(Float(level))
                    flash(level < 0.005 ? "Muted" : "Volume \(Int((level * 100).rounded()))%",
                          symbol: Self.volumeSymbol(Float(level)), level: level, kind: "volume")
                }
            }
            .onEnded { _ in
                if swipe?.kind == .seek, let target = swipeSeekTarget {
                    Task { await session.seek(to: target) }
                }
                swipe = nil
                swipeSeekTarget = nil
            }
    }
    #endif

    private func doubleTapSkip(forward: Bool) {
        let seconds = forward ? app.settings.skipForwardSeconds : app.settings.skipBackSeconds
        // Repeated double-taps on the same side add up, like YouTube.
        let total = (skipFlash?.forward == forward ? skipFlash?.seconds ?? 0 : 0) + seconds
        Task { await session.skip(by: forward ? Double(seconds) : -Double(seconds)) }
        if forward { skipForward += 1 } else { skipBack += 1 }
        let flash = SkipFlash(forward: forward, seconds: total)
        withAnimation(Motion.appear) { skipFlash = flash }
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            if skipFlash == flash { withAnimation(Motion.disappear) { skipFlash = nil } }
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
                boostedFrom = nil  // a speed picked during a 2× hold is the one kept
                let r = PlaybackSpeed.stepped(session.snapshot.rate, by: steps)
                session.setRate(r)
                flash("Speed \(PlaybackSpeed.label(r))", symbol: "gauge.with.needle")
            },
            volume: { d in
                session.setVolume(session.volume + d)
                flash(session.volume < 0.005 ? "Muted" : "Volume \(Int((session.volume * 100).rounded()))%",
                      symbol: Self.volumeSymbol(session.volume), level: Double(session.volume), kind: "volume")
                poke()
            },
            mute: { session.setMuted(!session.isMuted); flash(session.isMuted ? "Muted" : "Sound on", symbol: Self.volumeSymbol(session.volume, muted: session.isMuted), kind: "volume") },
            episodes: { if episodes.isSeries { toggle(.episodes) } },
            episodeStep: { forward in stepEpisode(forward: forward) },
            nudgeSubtitles: { d in
                session.nudgeSubtitles(by: d)
                flash(session.canAdjustSubtitleTiming ? "Subtitle delay \(session.subtitleOffset.label)" : "Timing works with subtitle files",
                      symbol: "captions.bubble", kind: "subtitleDelay")
            },
            subtitleSize: { d in
                app.subtitleStyle.relativeSize = SubtitleStyle.clampSize(app.subtitleStyle.relativeSize + d)
                flash("Subtitle size \(Int((app.subtitleStyle.relativeSize / 0.045 * 100).rounded()))%", symbol: "textformat.size")
            },
            cycleSubtitles: cycleSubtitles,
            cycleAudio: cycleAudio,
            stepFrame: { session.stepFrame(by: $0) },
            aspect: cycleAspect, crop: cycleCrop, zoom: cycleZoom,
            rotate: { session.videoFraming.rotate(); flash("Rotated \(Int(session.videoFraming.rotationDegrees))°", symbol: "rotate.right") },
            loop: cycleLoop,
            snapshot: { Task { await saveSnapshot() } },
            tools: { toggle(.tools) },
            jump: { jumping = true },
            chapter: { offset in Task { await session.jumpToChapter(offset: offset) } },
            line: { next in
                Task {
                    let moved = await session.jumpToLine(next: next)
                    if !moved { flash(session.subtitleSelection == .off ? "Subtitles are off" : next ? "No next line" : "No earlier line", symbol: "captions.bubble") }
                }
                poke()
            },
            toggleSubtitles: {
                let now = session.toggleSubtitles()
                let label: String = switch now {
                case .off: "Off"
                case .embedded(let id), .external(let id): TrackLabel.labels(for: session.allSubtitleTracks)[id]?.spoken ?? "On"
                }
                flash(now == .off && session.allSubtitleTracks.isEmpty ? "No subtitles" : "Subtitles: \(label)",
                      symbol: now == .off ? "captions.bubble" : "captions.bubble.fill", kind: "subtitles")
            },
            seekPercent: { n in
                guard let duration = session.snapshot.duration, duration > 0 else { return }
                Task { await session.seek(to: duration * Double(n) / 10) }
                flash("\(n * 10)% through", symbol: "clock", level: Double(n) / 10, kind: "seekPercent")
                poke()
            }
        )
    }

    private func skipBy(forward: Bool) {
        Task { await session.skip(by: forward ? Double(app.settings.skipForwardSeconds) : -Double(app.settings.skipBackSeconds)) }
        if forward { skipForward += 1 } else { skipBack += 1 }
        poke()
    }

    private func cycleLoop() {
        session.cycleLoop()
        flash(session.loopEnd != nil ? "Repeating A–B" : session.loopStart != nil ? "A set. Press L again at B." : "Repeat off", symbol: "repeat")
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
        flash("Subtitles: \(label)", symbol: "captions.bubble.fill", kind: "subtitles")
    }

    private func cycleAudio() {
        let tracks = session.snapshot.audioTracks
        guard tracks.count > 1 else { flash("Only one audio track", symbol: "waveform"); return }
        let i = tracks.firstIndex { $0.id == session.snapshot.selectedAudioID } ?? -1
        let next = tracks[(i + 1) % tracks.count]
        session.selectAudio(next.id)
        flash("Audio: \(TrackLabel.labels(for: tracks)[next.id]?.spoken ?? next.label)", symbol: "waveform")
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
        flash("Aspect ratio: \(next.label)", symbol: "aspectratio")
    }

    private func cycleCrop() {
        let all: [VideoFraming.Ratio] = [.auto, .r16x9, .r1_85, .r2_35, .r2_39, .r4x3]
        let next = all[((all.firstIndex(of: session.videoFraming.crop) ?? 0) + 1) % all.count]
        session.videoFraming.crop = next
        flash("Crop: \(next == .auto ? "None" : next.label)", symbol: "crop")
    }

    private func cycleZoom() {
        let steps = [1.0, 1.25, 1.5, 2]
        let i = steps.firstIndex { abs($0 - session.videoFraming.zoom) < 0.01 } ?? 0
        session.videoFraming.setZoom(steps[(i + 1) % steps.count])
        flash(String(format: "Zoom %.2g×", session.videoFraming.zoom), symbol: "plus.magnifyingglass")
    }

    /// A short message at the top. With an action (Undo) it stays longer and can
    /// be tapped. Another of the same kind (volume again) updates it in place.
    private func flash(_ message: String, symbol: String? = nil, level: Double? = nil,
                       style: PlayerNotice.Style = .normal, kind: String? = nil,
                       action title: String? = nil, perform: (() -> Void)? = nil) {
        let kind = kind ?? symbol ?? message
        let shown = PlayerNotice(message: message, symbol: symbol, level: level, style: style,
                                 actionTitle: perform == nil ? nil : title, kind: kind)
        if let current = toast, current.kind == kind {
            withAnimation(.snappy(duration: 0.18)) { toast = shown }
        } else {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.2)) { toast = shown }
        }
        toastAction = perform
        AccessibilityNotification.Announcement(message).post()
        let stay: Double = perform != nil ? 5 : style == .warning ? 3 : 1.6
        Task {
            try? await Task.sleep(for: .seconds(stay))
            if toast?.id == shown.id { withAnimation(Motion.disappear) { toast = nil }; toastAction = nil }
        }
    }

    private static func volumeSymbol(_ volume: Float, muted: Bool = false) -> String {
        if muted || volume < 0.005 { return "speaker.slash.fill" }
        return volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    private func saveSnapshot() async {
        guard let image = await session.captureFrame() else { flash("Couldn't capture this frame", symbol: "camera", style: .warning); return }
        do {
            let place = try await SnapshotSaver.save(image, title: session.item?.title ?? "Bluebox", at: session.snapshot.position)
            flash("Saved to \(place)", symbol: "camera.fill")
        } catch {
            flash(error.localizedDescription, symbol: "exclamationmark.triangle.fill", style: .warning)
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
                if let party = app.party { PartyChatButton(party: party) }
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
                } else if vlcEngine != nil {
                    // Dimmed rather than gone, so it can say why and point at an MP4 release.
                    PlayerIconButton(symbol: "airplay.video", label: "AirPlay Isn't Available with VLC") { explainNoAirPlay() }
                        .opacity(0.4)
                        .accessibilityIdentifier("airPlayUnavailable")
                }
                openInMenu
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

    /// Open In…: the installed players, for what's playing. It closes here and
    /// opens there, from the start or wherever that app remembers.
    @ViewBuilder private var openInMenu: some View {
        let players = ExternalPlayer.installed
        if let item = session.item, let resource = session.currentResource, ExternalPlayer.canOpen(resource), !players.isEmpty {
            BlueboxMenu("Open In") {
                ExternalPlayerMenuSection(players: players) { player in
                    Task {
                        await app.closePlayer()
                        await app.play(item, variant: resource.variant, in: player)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Open In")
            .help("Open in Another App")
            .accessibilityIdentifier("openInMenu")
        }
    }

    /// VLC plays MKV and the rest, but only AVPlayer can AirPlay: says so, and
    /// offers the release picker (with add-ons) to choose an MP4 instead.
    private func explainNoAirPlay() {
        let container = (session.currentResource?.variant.container ?? session.currentResource?.url.pathExtension)
            .flatMap { $0.isEmpty ? nil : $0.uppercased() }
        let message = "This video plays in VLC\(container.map { " (\($0))" } ?? ""), which can't AirPlay. An MP4 release can."
        if let item = session.item, canChooseRelease(for: item.key) {
            flash(message, symbol: "airplay.video", kind: "airPlay", action: "Releases…") {
                releaseRequest = TitleDetailView.ReleaseRequest(item: item)
            }
        } else {
            flash(message, symbol: "airplay.video", style: .warning, kind: "airPlay")
        }
        poke()
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
            .help("Back \(app.settings.skipBackSeconds) seconds (←). Previous subtitle line: ⇧←")
            Button { session.togglePlayPause(); poke() } label: {
                ZStack {
                    if showsWaiting {
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
            .help("Forward \(app.settings.skipForwardSeconds) seconds (→). Next subtitle line: ⇧→")
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
                         stalled: showsWaiting,
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
                guard !stepGate.consumeHold() else { return }
                stepEpisode(forward: forward)
            }
            .disabled(!enabled)
            .accessibilityIdentifier(forward ? "nextEpisode" : "previousEpisode")
            .modifier(EpisodeStepMenu(enabled: target == .episode, gate: stepGate, next: episodes.next?.label, previous: episodes.previous?.label,
                                      playNext: { Task { await session.playNext() } },
                                      playPrevious: { if let p = episodes.previous { play(episode: p.key) } },
                                      allEpisodes: { toggle(.episodes) }))
        case .episodes:
            PlayerBarButton(symbol: "rectangle.stack", label: "Episodes", shortcut: "E", isOn: panel == .episodes) { toggle(.episodes) }
                .disabled(!enabled)
                .panelAnchor(.episodes, in: $anchors)
                .accessibilityIdentifier("episodesButton")
        case .tracks:
            PlayerBarButton(symbol: session.subtitleSelection == .off ? "captions.bubble" : "captions.bubble.fill",
                            label: "Audio & Subtitles", shortcut: "V, C, B", isOn: panel == .tracks) { toggle(.tracks) }
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
        if panel == .episodes {
            // Opens on the season playing (not the one last browsed), and retries a list that failed to load.
            let key = session.item?.key
            Task {
                await episodes.load(for: key, app: app)
                if let s = key?.episodeNumbers?.season, episodes.season != s { await episodes.show(season: s, app: app) }
            }
        }
    }

    private func closePanel() {
        panel = nil
        focused = true
        poke()
    }

    /// The open card, over the button that opened it.
    private func panelCard(_ kind: PlayerPanelKind) -> some View {
        let compact = stageSize.height < 500
        let width = kind.width(compact: compact)
        let place = PanelPlacement.frame(anchor: anchors[kind], width: width, stage: stageSize,
                                         // Mac: above the whole bar. Phones: the card may cover the timeline.
                                         barTop: platform == .mac ? barTop : nil,
                                         // Clear of the title row, which stays readable.
                                         topInset: compact ? subtitleControlsTopInset : 44)
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
                    panelContent(kind, innerWidth: inner)
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

    @ViewBuilder private func panelContent(_ kind: PlayerPanelKind, innerWidth: CGFloat) -> some View {
        switch kind {
        case .tracks:
            TracksPanel(session: session, width: innerWidth, canSearch: canSearchSubtitles, initialPage: tracksStartPage,
                        onAddFile: { closePanel(); importingSubtitle = true },
                        onSearch: { closePanel(); searchingSubtitles = true },
                        onStyle: openStyle)
                .environment(audioSync)
        case .speed:
            SpeedPanel(rate: session.snapshot.rate,
                       remaining: session.snapshot.duration.map { max($0 - session.snapshot.position, 0) }) { r in
                boostedFrom = nil
                session.setRate(r); lastInteraction = Date()
            }
        case .tools:
            ToolsPanel(session: session, skip: skip, columns: 3, statsShown: statsShown, initialPage: toolsStartPage,
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
                flash("Couldn't open that episode", symbol: "exclamationmark.triangle.fill", style: .warning)
            }
        }
    }

    /// How far subtitles move up while the controls show: clear of the timeline and tool row.
    /// The title row at the top while the controls show (top subtitles stay under it).
    private var subtitleControlsTopInset: CGFloat { stageSize.height < 500 ? 56 : 64 }

    /// The style the engine draws with: the user's, with bottom (or top) subtitles
    /// that VLC draws in the picture moved clear of the controls while they show,
    /// by the same rule as Bluebox's overlay. Never saved.
    private var engineSubtitleStyle: SubtitleStyle {
        var s = app.subtitleStyle
        guard vlcDrawsSubtitles, controlsShown, stageSize.height > 0 else { return s }
        let h = Double(stageSize.height)
        let m = s.restingMargin(coveredBottom: Double(subtitleControlsInset(height: stageSize.height)) / h,
                                coveredTop: Double(subtitleControlsTopInset) / h)
        if s.anchor != .middle { s.verticalMargin = m }
        return s
    }

    private func openStyle() {
        panel = nil
        styleOpen = true
        poke()
    }

    private func closeStyle() {
        styleOpen = false
        focused = true
        poke()
    }

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
                .font(.callout.weight(.semibold))
                .labelStyle(NoticeLabelStyle())
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .playerNoticeSurface()
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
        if !controlsVisible { withAnimation(Motion.appear) { controlsVisible = true } }
    }

    /// Controls fade 3 s after the last touch, click or pointer move while
    /// playing or paused; never mid-scrub, with the tools open, while the pointer rests on
    /// them or while subtitles are being moved. On the Mac the pointer hides too.
    private func autoHide() async {
        while !Task.isCancelled, session.snapshot.status == .playing || session.snapshot.status == .paused {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let idle = Date().timeIntervalSince(lastInteraction) > 3
            if idle, controlsVisible, scrubFraction == nil, panel == nil, !hoveringControls, !subtitleEditing, boostedFrom == nil {
                withAnimation(Motion.disappear) { controlsVisible = false }
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
        /// ⇧← ⇧→: previous (replaying the one just heard) or next subtitle line.
        let line: (Bool) -> Void
        /// C: subtitles off, and back on.
        let toggleSubtitles: () -> Void
        /// 0–9: to 0–90% of the video.
        let seekPercent: (Int) -> Void
    }

    let actions: Actions

    func body(content: Content) -> some View {
        content
            .onKeyPress(.space) { actions.playPause(); return .handled }
            .onKeyPress(keys: [.leftArrow], phases: .down) { press in
                if press.modifiers.contains(.shift) { actions.line(false) } else { actions.skip(false) }
                return .handled
            }
            .onKeyPress(keys: [.rightArrow], phases: [.down, .repeat, .up]) { press in
                if press.modifiers.contains(.shift) {
                    if press.phase == .down { actions.line(true) }
                    return .handled
                }
                actions.forwardKey(press.phase); return .handled
            }
            .onKeyPress(.upArrow) { actions.volume(0.1); return .handled }
            .onKeyPress(.downArrow) { actions.volume(-0.1); return .handled }
            #if os(iOS)
            .onKeyPress(.escape) { actions.close(); return .handled }
            #endif
            .onKeyPress(characters: .init(charactersIn: "[]{}-=_+vbacCzrlstjnpmeNP,.<>0123456789"), phases: .down) { press in
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
                case "c": actions.toggleSubtitles()
                case "C": actions.crop()
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
                case ",", "<": actions.stepFrame(-1)
                case ".", ">": actions.stepFrame(1)
                case let d where d.count == 1 && d.first!.isASCII && d.first!.isNumber:
                    // Shift with a digit types a symbol on most layouts; plain digits only.
                    guard press.modifiers.isEmpty, let n = Int(d) else { return .ignored }
                    actions.seekPercent(n)
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
        .animation(Motion.hover, value: hovering)
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

/// Search Online: every site that's on (OpenSubtitles, Subdl, Podnapisi,
/// the Jellyfin server) at once, one list with the best match for this
/// release first and the site under each; the chosen one is added.
struct SubtitleSearchSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let key: MediaKey
    /// The release playing (file or release name), to rank matches.
    var release: String?
    var title: String?
    let onPick: (URL) -> Void
    @State private var results: [OnlineSubtitle]?
    @State private var failures: [String] = []
    @State private var error: String?
    @State private var downloading: String?

    var body: some View {
        NavigationStack {
            Group {
                if let results, results.isEmpty {
                    ContentUnavailableView("No subtitles found", systemImage: "captions.bubble",
                                           description: Text("Try another preferred language, or turn on more sites, in Settings › Subtitles."))
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
                VStack(spacing: 4) {
                    if let error { Text(error).font(.footnote).foregroundStyle(Palette.warning) }
                    if !failures.isEmpty {
                        Text("\(failures.joined(separator: ", ")) didn't answer.").font(.footnote).foregroundStyle(Palette.textSecondary)
                    }
                    Text("Sites: \(app.enabledSubtitleSites.map(\.title).joined(separator: ", ")). Choose in Settings › Subtitles.")
                        .font(.caption).foregroundStyle(Palette.textTertiary)
                }
                .padding()
            }
            .navigationTitle("Subtitles")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .frame(minWidth: 460, minHeight: 420)
        .preferredColorScheme(.dark)
        .task {
            let found = await app.searchAllSubtitles(for: key, release: release, title: title)
            results = found.results
            failures = found.failures
            if found.results.isEmpty, !found.failures.isEmpty, found.failures.count == app.enabledSubtitleSites.filter(app.canAsk).count {
                error = "No site could be reached. Check your connection and keys in Settings › Subtitles."
            }
        }
    }

    /// "OpenSubtitles · English · ✓ Exact · SDH"
    private func details(_ r: OnlineSubtitle) -> String {
        var parts = [r.site.title]
        parts.append(r.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? r.language ?? "Unknown")
        if r.site == .jellyfin { parts.append("Server") }
        else if let release, SubtitleSearchMerge.matchScore(r.release, release) >= SubtitleSearchMerge.exactThreshold { parts.append("✓ Exact") }
        if r.downloadCount > 0 { parts.append("\(r.downloadCount) downloads") }
        if r.hearingImpaired { parts.append("SDH") }
        if r.machineTranslated { parts.append("Machine translated") }
        return parts.joined(separator: " · ")
    }

    private func pick(_ r: OnlineSubtitle) async {
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

/// Seek to a typed time (h:mm:ss, mm:ss or seconds). The placeholder is where
/// you are now, so its shape always fits the video, and the footer says why Go
/// is greyed out rather than leaving it to be guessed.
struct JumpToTimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let duration: TimeInterval
    var position: TimeInterval = 0
    let onJump: (TimeInterval) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let check = Self.check(text, duration: duration)
        NavigationStack {
            Form {
                Section {
                    TextField(Formatters.duration(position), text: $text)
                        .font(.title2.monospacedDigit())
                        .focused($focused)
                        .autocorrectionDisabled()
                        .onSubmit(jump)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                        .accessibilityIdentifier("jumpTimeField")
                } footer: {
                    footer(check)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Jump to Time")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Go", action: jump).disabled(check.time == nil) }
            }
        }
        .onAppear { focused = true }
        .frame(minWidth: 360, minHeight: 220)
        .preferredColorScheme(.dark)
        #if os(iOS)
        // One field and a line: a short sheet, not a screen of empty space.
        .presentationDetents([.height(230)])
        .presentationDragIndicator(.visible)
        #endif
    }

    @ViewBuilder private func footer(_ check: Check) -> some View {
        switch check {
        case .empty, .ok:
            if duration > 0 {
                Text("Minutes and seconds, or hours, minutes and seconds. It's \(Formatters.duration(duration)) long.")
            } else {
                Text("Minutes and seconds, or hours, minutes and seconds.")
            }
        case .unreadable:
            Text("Type a time like \(Formatters.duration(position)).").foregroundStyle(Palette.warning)
        case .pastEnd:
            Text("That's after the end, at \(Formatters.duration(duration)).").foregroundStyle(Palette.warning)
        }
    }

    enum Check: Equatable {
        case empty, unreadable, pastEnd, ok(TimeInterval)
        var time: TimeInterval? { if case .ok(let t) = self { t } else { nil } }
    }

    static func check(_ text: String, duration: TimeInterval) -> Check {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        guard let t = parse(text) else { return .unreadable }
        if duration > 0, t > duration { return .pastEnd }
        return .ok(t)
    }

    private func jump() {
        guard let t = Self.check(text, duration: duration).time else { return }
        onJump(t)
        dismiss()
    }

    static func parse(_ s: String) -> TimeInterval? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}

/// Next and Previous Episode's menu on a hold or right-click: the episode
/// either side and All Episodes, in Bluebox's menu over the video.
private struct EpisodeStepMenu: ViewModifier {
    let enabled: Bool
    let gate: QuickActionGate
    let next: String?
    let previous: String?
    let playNext: @MainActor () -> Void
    let playPrevious: @MainActor () -> Void
    let allEpisodes: @MainActor () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.blueboxContextMenu(String(localized: "Episodes"), gate: gate) {
                if let next { BlueboxMenuButton(String(localized: "Play \(next)"), systemImage: "forward.end.fill", action: playNext) }
                if let previous { BlueboxMenuButton(String(localized: "Play \(previous)"), systemImage: "backward.end.fill", action: playPrevious) }
                BlueboxMenuButton("All Episodes", systemImage: "rectangle.stack", action: allEpisodes)
            }
        } else {
            content
        }
    }
}
