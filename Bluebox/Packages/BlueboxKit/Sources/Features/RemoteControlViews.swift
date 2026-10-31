import DesignSystem
import Sync
import SwiftUI

/// Joins the remote channel when this device should (RemoteControl.swift).
/// On the Mac, hands the remote's app commands to `AppModel` and its
/// highlight. On iPhone and iPad, draws "Playing on Studio" over the tabs and
/// opens the remote from it, or when Play went to another device. RootView
/// applies it once; everything else lives here.
struct RemoteControlHost: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsRemote = false
    #endif

    private struct Want: Hashable {
        let wanted: Bool
        let controllable: Bool
        let player: ObjectIdentifier?
    }

    private var want: Want {
        #if os(macOS)
        // Joined whenever it may be controlled, so the remote can open things, not only steer the player.
        let allowed = app.featureSwitches.allowRemoteControl && app.account.isSignedIn
        return Want(wanted: allowed, controllable: allowed, player: app.activePlayer.map(ObjectIdentifier.init))
        #else
        // Stays joined while merely inactive (Control Center, a notification pulled down), so the remote doesn't blank and rejoin.
        return Want(wanted: app.featureSwitches.useAsRemote && app.account.isSignedIn && scenePhase != .background,
                    controllable: false, player: nil)
        #endif
    }

    func body(content: Content) -> some View {
        content
            .task(id: want) {
                #if os(macOS)
                app.remote.handler = app
                app.remoteFocus.onChange = { [weak app] in app?.remote.screenChanged() }
                app.remote.update(wanted: want.wanted, controllable: want.controllable, account: app.account, player: app.activePlayer)
                #else
                app.remote.update(wanted: want.wanted, controllable: false, account: app.account, player: nil)
                #endif
            }
            #if os(iOS)
            .overlay(alignment: .bottom) {
                if let state = app.remote.nowPlaying, app.activePlayer == nil {
                    PlayingOnMacBar(state: state, connection: app.remote.connection,
                                    togglePlay: { app.remote.send(.setPaused(!state.paused)) }, open: { showsRemote = true })
                        // Above the tab bar on iPhone; iPad has no bar at the bottom.
                        .padding(.horizontal, Spacing.m)
                        .padding(.bottom, sizeClass == .compact ? 58 : Spacing.l)
                        .transition(Motion.slide(from: .bottom, reduceMotion))
                }
            }
            .animation(Motion.standard(reduceMotion), value: app.remote.nowPlaying == nil)
            .sheet(isPresented: $showsRemote) {
                // Its own sheet: menus (the device pill's) draw here, not under it.
                RemoteControlScreen().environment(app).blueboxMenuHost()
            }
            .onChange(of: showsRemote) { _, open in app.remote.screenOpen = open }
            .onChange(of: app.remote.presentRequest) { showsRemote = true }
            .onChange(of: scenePhase) { _, phase in if phase == .active { app.remote.wake() } }
            #if DEBUG
            .task {
                // Screenshots of the remote (`-seed-remote`): open it once the seeded state shows.
                let args = ProcessInfo.processInfo.arguments
                guard args.contains("-show-remote") else { return }
                try? await Task.sleep(for: .seconds(1))
                showsRemote = true
            }
            #endif
            #endif
    }
}

/// "Play on" (the new remote, question 7): This iPhone, or a device online
/// on the account, playing ones first. With one chosen, Play plays there and
/// title pages open there too. Hidden on the Mac and while nothing's online.
struct PlayOnButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        #if os(iOS)
        let remote = app.remote
        if app.featureSwitches.useAsRemote, !remote.devices.isEmpty || remote.target != nil {
            let chosen = remote.devices.first { $0.id == remote.target }
            // Bluebox's own menu, as everywhere else. Picking a device opens its remote too (`RemoteControl.choose`).
            BlueboxMenu(String(localized: "Play On")) {
                BlueboxMenuSection(String(localized: "Play On")) {
                    BlueboxMenuButton(String(localized: "This iPhone"), systemImage: "iphone", checked: remote.target == nil) { remote.choose(nil) }
                    for d in remote.devices {
                        BlueboxMenuButton(d.name, systemImage: Self.symbol(d.kind),
                                          subtitle: d.playing.map { String(localized: "Playing \($0)") } ?? String(localized: "Idle"),
                                          checked: remote.target == d.id) { remote.choose(d.id) }
                    }
                }
                // Back to the remote without picking again, playing or not.
                if remote.controlled != nil {
                    BlueboxMenuSection {
                        BlueboxMenuButton(String(localized: "Open Remote"), systemImage: "appletvremote.gen4") { remote.openRemote() }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: chosen.map { Self.symbol($0.kind) } ?? "tv.and.mediabox")
                        .font(.footnote.weight(.semibold))
                    if let chosen {
                        Text(verbatim: chosen.name).font(.footnote.weight(.semibold)).lineLimit(1)
                    }
                }
                .foregroundStyle(chosen == nil ? Palette.textPrimary : Palette.brandBright)
                .padding(.horizontal, chosen == nil ? 7 : 10)
                .frame(minWidth: 32, minHeight: 32)
                .background(chosen == nil ? Palette.elevated : Palette.wash, in: Capsule())
                .overlay(Capsule().strokeBorder(chosen == nil ? Palette.edge : Palette.brand.opacity(0.5)))
                .contentShape(Capsule())
            }
            .accessibilityLabel(chosen.map { "Playing on \($0.name)" } ?? String(localized: "Play On"))
        }
        #endif
    }

    static func symbol(_ kind: RemoteDevice.Kind) -> String {
        switch kind {
        case .mac: "laptopcomputer"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .appleTV: "appletv"
        }
    }
}

#if os(iOS)
/// The link's state (question 6): a green dot and the device's name, amber
/// while reconnecting, red with Try Again when the Mac stopped answering. Its
/// menu picks another device (question 8).
struct RemoteDevicePill: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let remote = app.remote
        let name = remote.controlled?.name ?? remote.nowPlaying?.deviceName ?? String(localized: "Mac")
        HStack(spacing: Spacing.s) {
            BlueboxMenu(String(localized: "Control")) {
                BlueboxMenuSection(String(localized: "Control")) {
                    let current = remote.target ?? remote.controlled?.id
                    for d in remote.devices {
                        BlueboxMenuButton(d.name, systemImage: PlayOnButton.symbol(d.kind),
                                          subtitle: d.playing.map { String(localized: "Playing \($0)") } ?? String(localized: "Idle"),
                                          checked: current == d.id) { remote.target = d.id }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(dot(remote.connection)).frame(width: 7, height: 7)
                    Group {
                        switch remote.connection {
                        case .connected: Text(verbatim: name)
                        case .connecting, .off: Text("Reconnecting…")
                        case .notAnswering: Text("Not answering")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    if remote.devices.count > 1 {
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Palette.textSecondary)
                    }
                }
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 10).frame(height: 30)
                .background(Palette.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.edge))
            }
            .disabled(remote.devices.count < 2)
            if remote.connection == .notAnswering {
                Button("Try Again") { remote.retry() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.brandBright)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func dot(_ c: RemoteControl.Connection) -> Color {
        switch c {
        case .connected: .green
        case .connecting, .off: .orange
        case .notAnswering: .red
        }
    }
}

/// "Playing on Studio": the title, a thin line in the theme colour for where it is, and play/pause. Tap for the remote.
struct PlayingOnMacBar: View {
    let state: RemoteNowPlaying
    let connection: RemoteControl.Connection
    let togglePlay: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            Button(action: open) {
                HStack(spacing: Spacing.m) {
                    Image(systemName: "laptopcomputer")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 28)
                        .overlay(alignment: .topTrailing) {
                            if connection != .connected {
                                Circle().fill(connection == .notAnswering ? Color.red : .orange).frame(width: 7, height: 7)
                            }
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Playing on \(state.deviceName)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Palette.textSecondary)
                        Text(verbatim: state.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 1))
            .accessibilityLabel("Playing on \(state.deviceName): \(state.title)")
            .accessibilityHint("Opens the remote")

            Button(action: togglePlay) {
                Image(systemName: state.paused ? "play.fill" : "pause.fill")
                    .font(.title3)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(haptic: true))
            .accessibilityLabel(state.paused ? "Play" : "Pause")
        }
        .padding(.leading, Spacing.m).padding(.trailing, Spacing.xs)
        .frame(height: 56)
        .opacity(connection == .connected ? 1 : 0.6)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .overlay(alignment: .bottom) {
            // The theme colour for state: how far through it is.
            GeometryReader { g in
                Capsule().fill(Palette.brand)
                    .frame(width: g.size.width * progress(state), height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, Radius.hero)
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous).strokeBorder(Palette.edge))
    }

    private func progress(_ s: RemoteNowPlaying) -> CGFloat {
        guard let d = s.duration, d > 0 else { return 0 }
        return CGFloat(min(max(s.position / d, 0), 1))
    }
}

/// The remote (the new remote, 31 Oct 2026). Playing: a touch pad first
/// (swipe to scrub, tap to pause), the timeline under it, ±10 s, Audio &
/// Subtitles, Next and the Mac's volume. Touch: the same pad moves the Mac's
/// highlight and presses it, with Back, Home and Search; what's highlighted
/// is named above it. Every player control answers at once
/// (`RemoteControl.send`); the Mac's next state settles it.
struct RemoteControlScreen: View {
    enum Mode: Hashable { case playing, touch }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .playing
    @State private var showsTracks = false

    var body: some View {
        let remote = app.remote
        let playing = remote.nowPlaying
        VStack(spacing: 0) {
            HStack {
                RemoteDevicePill()
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Palette.elevated, in: Circle())
                        .overlay(Circle().strokeBorder(Palette.edge))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, Spacing.l).padding(.top, Spacing.m)

            if playing != nil {
                // Bluebox's own chips, as Library and New & Hot use: never the system's segmented control.
                HStack(spacing: Spacing.s) {
                    CategoryChip("Playing", selected: mode == .playing) { mode = .playing }
                    CategoryChip("Touch", selected: mode == .touch) { mode = .touch }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.xl).padding(.top, Spacing.m)
            }

            Group {
                if let s = playing, mode == .playing {
                    PlayingRemote(state: s, showsTracks: $showsTracks)
                } else if remote.controlled != nil {
                    TouchRemote()
                } else {
                    Spacer()
                    ContentUnavailableView("No Mac to Control", systemImage: "laptopcomputer",
                                           description: Text("Open Bluebox on your Mac, with Allow Remote Control on in Settings › Privacy."))
                    Spacer()
                }
            }
            // A tap that can't land shouldn't look like it did.
            .opacity(remote.connection == .connected ? 1 : 0.45)
            .disabled(remote.connection != .connected && remote.connection != .notAnswering)
        }
        .background(Palette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationBackground(Palette.background)
        .sheet(isPresented: $showsTracks) {
            if let s = playing { RemoteTracksSheet(state: s).environment(app) }
        }
        #if DEBUG
        .task {
            // Screenshots: `-remote-touch` opens on Touch, `-remote-tracks` on Audio & Subtitles.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-remote-touch") { mode = .touch }
            if args.contains("-remote-tracks") { try? await Task.sleep(for: .milliseconds(600)); showsTracks = true }
        }
        #endif
    }
}

/// While something plays: the pad (swipe scrubs live, tap pauses), then the
/// timeline, transport, Audio & Subtitles, Next, ⋯ and volume.
private struct PlayingRemote: View {
    let state: RemoteNowPlaying
    @Binding var showsTracks: Bool
    @Environment(AppModel.self) private var app
    /// While scrubbing (the pad or the timeline): where it's going.
    @State private var scrubbing: TimeInterval?
    /// Where a pad swipe started: it moves from there, not from the drawn (moving) position.
    @State private var scrubStart: TimeInterval?
    @State private var volume: Float?
    @State private var lastVolumeSend = Date.distantPast

    var body: some View {
        let s = state
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: s.title)
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if let subtitle = s.subtitle {
                    Text(verbatim: subtitle).font(Typography.meta).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)

            RemoteTouchPad(hint: "Swipe to scrub · Tap to pause", onTap: { app.remote.send(.setPaused(!s.paused)) },
                           onHorizontalDrag: { fraction, ended in scrub(by: fraction, ended: ended) })
                .overlay {
                    if let t = scrubbing {
                        Text(Formatters.duration(t))
                            .font(.largeTitle.weight(.bold).monospacedDigit())
                            .foregroundStyle(Palette.textPrimary)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)

            timeline(s).padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)

            HStack(spacing: Spacing.xxxl) {
                transportButton("gobackward.10", label: "Back 10 Seconds") { app.remote.skip(by: -10) }
                Button { app.remote.send(.setPaused(!s.paused)) } label: {
                    Image(systemName: s.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 64, height: 64)
                        .background(Color.white, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle(haptic: true))
                .accessibilityLabel(s.paused ? "Play" : "Pause")
                transportButton("goforward.10", label: "Forward 10 Seconds") { app.remote.skip(by: 10) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.m)

            HStack(spacing: Spacing.s) {
                Button { showsTracks = true } label: {
                    Label("Audio & Subtitles", systemImage: "captions.bubble")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(s.audioTracks.isEmpty && s.subtitleTracks.isEmpty)
                if s.hasNext {
                    Button { app.remote.send(.nextEpisode) } label: {
                        Label("Next", systemImage: "forward.end.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel("Next Episode")
                }
                // One action, so a button, not a ⋯ menu holding a single item.
                Button { app.remote.send(.closePlayer) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Close Player")
            }
            .padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)

            volumeRow(s).padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)
            Spacer(minLength: Spacing.l)
        }
    }

    /// A swipe across the whole pad moves five minutes, in proportion; the Mac's picture follows.
    private func scrub(by fraction: CGFloat, ended: Bool) {
        let duration = state.duration ?? 0
        guard duration > 0 else { return }
        let start = scrubStart ?? state.position
        scrubStart = start
        let target = min(max(start + Double(fraction) * 300, 0), duration)
        if ended {
            app.remote.endScrub(at: target)
            scrubbing = nil
            scrubStart = nil
        } else {
            scrubbing = target
            app.remote.scrub(to: target)
        }
    }

    private func timeline(_ s: RemoteNowPlaying) -> some View {
        let duration = max(s.duration ?? 0, 1)
        let position = scrubbing ?? s.position
        return VStack(spacing: Spacing.xs) {
            Slider(value: Binding(get: { min(position, duration) }, set: { new in
                scrubbing = new
                app.remote.scrub(to: new)  // live: the Mac's picture follows (question 2)
            }), in: 0...duration) { editing in
                if !editing, let target = scrubbing {
                    app.remote.endScrub(at: target)
                    scrubbing = nil
                }
            }
            .tint(Palette.brand)
            .disabled(s.duration == nil)
            .accessibilityLabel("Position")
            .accessibilityValue(Formatters.duration(position))
            HStack {
                Text(Formatters.duration(position))
                Spacer()
                Text("-" + Formatters.duration(max(duration - position, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Palette.textSecondary)
        }
    }

    private func volumeRow(_ s: RemoteNowPlaying) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "speaker.fill").foregroundStyle(Palette.textSecondary)
            Slider(value: Binding(get: { Double(volume ?? s.volume) }, set: { new in
                volume = Float(new)
                // While dragging, a few updates a second is plenty.
                if Date().timeIntervalSince(lastVolumeSend) > 0.2 { lastVolumeSend = Date(); app.remote.send(.volume(Float(new))) }
            }), in: 0...1) { editing in
                if !editing, let v = volume { app.remote.send(.volume(v)); volume = nil }
            }
            .tint(Palette.textPrimary)
            .accessibilityLabel("Mac Volume")
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(Palette.textSecondary)
        }
        .font(.footnote)
    }

    private func transportButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(haptic: true))
        .accessibilityLabel(label)
    }
}

/// Getting around the Mac: the pad moves its highlight (a swipe per step) and
/// a tap presses it; Back, Home and Search under it. What's highlighted on
/// the Mac is named above, so you can drive without looking up.
private struct TouchRemote: View {
    @Environment(AppModel.self) private var app
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let remote = app.remote
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: remote.screen?.title ?? remote.controlled?.name ?? "")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(verbatim: remote.screen?.focusedLabel ?? String(localized: "Swipe to highlight something"))
                    .font(Typography.meta)
                    .foregroundStyle(remote.screen?.focusedLabel == nil ? Palette.textTertiary : Palette.brandBright)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)

            if searching {
                TextField("Search on \(remote.controlled?.name ?? "Mac")", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { remote.send(.go(.search(query))); searching = false }
                    .padding(.horizontal, Spacing.xl).padding(.top, Spacing.m)
                    // Typed straight through to the Mac, a moment after you stop.
                    .task(id: query) {
                        guard !query.isEmpty else { return }
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        remote.send(.go(.search(query)))
                    }
            }

            RemoteTouchPad(hint: "Swipe to move · Tap to open", onTap: { remote.send(.select) }, onSwipe: { remote.send(.move($0)) })
                .padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)
                .frame(maxHeight: 320)

            HStack(spacing: Spacing.s) {
                Button { remote.send(.go(.back)) } label: { Label("Back", systemImage: "chevron.backward").fixedSize() }
                Button { remote.send(.go(.home)) } label: { Label("Home", systemImage: "house").fixedSize() }
                Button {
                    searching = true
                    searchFocused = true
                    remote.send(.go(.search("")))
                } label: { Label("Search", systemImage: "magnifyingglass").fixedSize() }
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)

            if let s = remote.nowPlaying {
                Button { remote.send(.setPaused(!s.paused)) } label: {
                    Label(s.paused ? "Play" : "Pause", systemImage: s.paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, Spacing.s)
            }
            Spacer(minLength: Spacing.l)
        }
    }
}

/// The touch surface (the new remote, question 1B). A deliberate tap (short,
/// still, away from the edges, so holding the phone doesn't pause the film)
/// presses; a swipe either moves a step per `stepLength` in its direction
/// (Touch) or reports how far across the pad it has gone (Playing, to scrub).
struct RemoteTouchPad: View {
    let hint: LocalizedStringKey
    var onTap: () -> Void
    /// Touch: one call per step.
    var onSwipe: ((RemoteDirection) -> Void)?
    /// Playing: the drag's width as a fraction of the pad's, and whether it ended.
    var onHorizontalDrag: ((CGFloat, Bool) -> Void)?

    static let stepLength: CGFloat = 56
    static let edge: CGFloat = 16

    @State private var size: CGSize = .zero
    @State private var start: (location: CGPoint, time: Date)?
    @State private var stepsTaken = CGSize.zero
    @State private var taps = 0
    @State private var steps = 0
    @GestureState private var pressing = false

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous)
            .fill(LinearGradient(colors: [Palette.elevated, Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous).strokeBorder(pressing ? Palette.brand.opacity(0.6) : Palette.edge))
            .overlay {
                Text(hint).font(.footnote).foregroundStyle(Palette.textTertiary).allowsHitTesting(false)
            }
            .frame(minHeight: 180)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .contentShape(RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous))
            .gesture(drag)
            .sensoryFeedback(.impact(weight: .medium), trigger: taps)
            .sensoryFeedback(.selection, trigger: steps)
            .accessibilityElement()
            .accessibilityLabel(hint)
            .accessibilityAddTraits(.allowsDirectInteraction)
            .accessibilityAction { press() }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($pressing) { _, state, _ in state = true }
            .onChanged { value in
                if start == nil { start = (value.startLocation, Date()); stepsTaken = .zero }
                let t = value.translation
                if let onHorizontalDrag {
                    if abs(t.width) > 8 { onHorizontalDrag(t.width / max(size.width, 1), false) }
                } else if let onSwipe {
                    // One step each `stepLength` along the main axis.
                    let horizontal = abs(t.width) >= abs(t.height)
                    let along = horizontal ? t.width : t.height
                    let done = horizontal ? stepsTaken.width : stepsTaken.height
                    let due = (along / Self.stepLength).rounded(.towardZero)
                    if due != done {
                        let direction: RemoteDirection = horizontal ? (due > done ? .right : .left) : (due > done ? .down : .up)
                        onSwipe(direction)
                        steps += 1
                        if horizontal { stepsTaken.width += due > done ? 1 : -1 } else { stepsTaken.height += due > done ? 1 : -1 }
                    }
                }
            }
            .onEnded { value in
                defer { start = nil }
                let t = value.translation
                let moved = hypot(t.width, t.height)
                if let onHorizontalDrag, abs(t.width) > 8 { onHorizontalDrag(t.width / max(size.width, 1), true); return }
                guard moved < 10, let start, Date().timeIntervalSince(start.time) < 0.4 else { return }
                let p = start.location
                let inside = p.x > Self.edge && p.y > Self.edge && p.x < size.width - Self.edge && p.y < size.height - Self.edge
                if inside { press() }
            }
    }

    private func press() {
        taps += 1
        onTap()
    }
}

/// Audio & Subtitles (question 3): both lists in one sheet. A pick is ticked
/// at once, with a ring until the Mac confirms; the sheet stays open.
private struct RemoteTracksSheet: View {
    let state: RemoteNowPlaying
    @Environment(AppModel.self) private var app

    var body: some View {
        // The live state (optimistic picks included), not the one the sheet opened with.
        let s = app.remote.nowPlaying ?? state
        let awaiting = app.remote.awaiting
        NavigationStack {
            List {
                if !s.audioTracks.isEmpty {
                    Section("Audio") {
                        ForEach(s.audioTracks) { t in
                            row(t.label, selected: s.audioID == t.id, waiting: awaiting.contains(3)) { app.remote.send(.audio(t.id)) }
                        }
                    }
                }
                Section("Subtitles") {
                    row(String(localized: "Off"), selected: s.subtitleID == nil, waiting: awaiting.contains(4)) { app.remote.send(.subtitle(nil)) }
                    ForEach(s.subtitleTracks) { t in
                        row(t.label, selected: s.subtitleID == t.id, waiting: awaiting.contains(4)) { app.remote.send(.subtitle(t.id)) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.surface)
            .navigationTitle("Audio & Subtitles")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.surface)
        .preferredColorScheme(.dark)
    }

    private func row(_ label: String, selected: Bool, waiting: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack {
                Text(verbatim: label).foregroundStyle(Palette.textPrimary)
                Spacer()
                if selected {
                    if waiting {
                        ProgressView().controlSize(.small).tint(Palette.brandBright)
                    } else {
                        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.brandBright)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .listRowBackground(Palette.elevated)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
