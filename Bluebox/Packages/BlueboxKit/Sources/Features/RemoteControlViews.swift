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
            #if os(macOS)
            // The window the remote drives first: marked items live in it (RemoteWindow).
            .background(WindowReader { window in
                guard let window else { return }
                if let platform = app.remoteFocus.platform as? RemoteWindow { platform.main = window } else {
                    app.remoteFocus.platform = RemoteWindow(main: window)
                }
            })
            // The player and the loading screen cover the window: no ring or pointer over them.
            .onChange(of: app.activePlayer != nil || app.preparingItem != nil, initial: true) { _, covered in
                app.remoteFocus.setCovered(covered)
            }
            #endif
            .task(id: want) {
                #if os(macOS)
                app.remote.handler = app
                app.remoteFocus.onChange = { [weak app] in app?.remote.screenChanged() }
                if app.remoteFocus.platform == nil { app.remoteFocus.platform = RemoteWindow(main: nil) }
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
            .fullScreenCover(isPresented: $showsRemote) {
                // Its own layer: menus (the device pill's) draw here, not under it. A full
                // screen, not a sheet: a sheet's swipe down would close it mid-swipe on the
                // pad (highlight or pointer); the chevron at the top closes it instead.
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

/// The remote (the better remote, 31 Oct 2026): one screen, made for a thumb.
/// Getting around: what's highlighted on the Mac above, with the items either
/// side of it; a large pad (`RemotePad`) that lights where your finger is;
/// Back, Home, Search and Options under it; and the pointer switch. While
/// something plays the same screen turns into the player: the timeline, a pad
/// that scrubs (with a ring round its edge for fine steps), the skip button
/// when the Mac shows one, ±10 s, tracks and volume. Every player control
/// answers at once (`RemoteControl.send`); the Mac's next state settles it.
struct RemoteControlScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
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

            Group {
                if let s = playing {
                    PlayingRemote(state: s, showsTracks: $showsTracks)
                } else if remote.controlled != nil {
                    BrowseRemote()
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
        // A menu open on the Mac (a hold): the same items here. Its own view: one sheet per view.
        .background {
            Color.clear.sheet(isPresented: Binding(
                get: { remote.screen?.menu != nil },
                set: { open in if !open, remote.screen?.menu != nil { remote.send(.go(.back)) } })) {
                RemoteMenuSheet().environment(app)
            }
        }
        #if DEBUG
        .task {
            // Screenshots: `-remote-tracks` opens Audio & Subtitles.
            if ProcessInfo.processInfo.arguments.contains("-remote-tracks") { try? await Task.sleep(for: .milliseconds(600)); showsTracks = true }
        }
        #endif
    }
}

// MARK: - Getting around

/// Getting around the Mac (questions 1 to 7): the highlight and its row
/// above the pad, the pad, and the buttons.
private struct BrowseRemote: View {
    @Environment(AppModel.self) private var app
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let remote = app.remote
        let screen = remote.screen
        // A Mac from before the better remote: no pointer, scrolling or menus.
        let full = (remote.controlled?.version ?? 0) >= 4
        let pointer = screen?.pointer == true
        VStack(spacing: 0) {
            RemoteHighlightStrip(screen: screen, pointer: pointer)
                .padding(.horizontal, Spacing.xl).padding(.top, Spacing.m)

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

            RemotePad(mode: pointer ? .pointer : .highlight,
                      hint: pointer ? "Move like a trackpad · Tap to click" : "Swipe · Fast to jump · Hold for options",
                      actions: padActions(full: full, pointer: pointer))
                .padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)
                .sensoryFeedback(.impact(weight: .heavy), trigger: screen?.bumps ?? 0)

            HStack {
                RoundRemoteButton("Back", systemImage: "chevron.backward") { remote.send(.go(.back)) }
                Spacer()
                RoundRemoteButton("Home", systemImage: "house") { remote.send(.go(.home)) }
                Spacer()
                RoundRemoteButton("Search", systemImage: "magnifyingglass") {
                    searching = true
                    searchFocused = true
                    remote.send(.go(.search("")))
                }
                Spacer()
                RoundRemoteButton("Options", systemImage: "ellipsis") { remote.send(.menu) }
                    .disabled(!full)
            }
            .padding(.horizontal, Spacing.xl + Spacing.s).padding(.top, Spacing.l)

            if full {
                Button { remote.send(.setPointer(!pointer)) } label: {
                    Label(pointer ? "Use the Highlight" : "Use a Pointer", systemImage: pointer ? "square.dashed" : "cursorarrow")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(pointer ? Color.black : Palette.textPrimary)
                        .background(pointer ? AnyShapeStyle(Color.white) : AnyShapeStyle(Palette.elevated), in: Capsule())
                        .overlay(Capsule().strokeBorder(pointer ? Color.clear : Palette.edge))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(haptic: true))
                .padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)
            }
            Spacer(minLength: Spacing.l)
        }
    }

    private func padActions(full: Bool, pointer: Bool) -> RemotePad.Actions {
        let remote = app.remote
        return RemotePad.Actions(
            tap: { remote.send(pointer ? .click : .select) },
            step: { remote.send(.move($0)) },
            jump: { d, n in remote.send(.jump(RemoteJump(d, count: n))) },
            hold: { if full { remote.send(.menu) } },
            scroll: { delta, velocity in
                guard full else { return }
                remote.send(.scroll(RemoteScroll(dx: delta.dx, dy: delta.dy, velocityX: velocity.map { Double($0.dx) },
                                                 velocityY: velocity.map { Double($0.dy) })))
            },
            twoFingerTap: { if full { remote.send(.setPointer(!pointer)) } },
            back: { remote.send(.go(.back)) },
            pointer: { remote.send(.pointer(RemotePointerMove(dx: $0.dx, dy: $0.dy))) })
    }
}

/// What's highlighted on the Mac (question 6): its row's name, the item with
/// the ones either side (posters in a row, or lines of a list), its name and
/// what a tap would do. It slides with every step, so you needn't look up.
private struct RemoteHighlightStrip: View {
    let screen: RemoteScreen?
    let pointer: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let focused = screen?.focused
        VStack(spacing: Spacing.xs) {
            Text(verbatim: (pointer ? String(localized: "Pointer") : screen?.section ?? screen?.title ?? "").uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            Group {
                if pointer {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(Palette.brandBright)
                } else if let focused, screen?.horizontal == true {
                    HStack(spacing: Spacing.s) {
                        neighbour(screen?.before)
                        tile(focused, on: true)
                        neighbour(screen?.after)
                    }
                } else if let focused {
                    VStack(spacing: 4) {
                        if let b = screen?.before { line(b, on: false) }
                        line(focused, on: true)
                        if let a = screen?.after { line(a, on: false) }
                    }
                } else {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .frame(height: 92)
            .frame(maxWidth: .infinity)

            Text(verbatim: pointer ? String(localized: "Two-finger tap for the highlight") : focused?.label ?? String(localized: "Swipe to highlight something"))
                .font(.headline)
                .foregroundStyle(focused == nil && !pointer ? Palette.textSecondary : Palette.textPrimary)
                .lineLimit(1)
            Text(verbatim: hint(focused))
                .font(Typography.meta)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
        }
        .animation(Motion.snappy(reduceMotion), value: screen?.focused)
        .accessibilityElement(children: .combine)
    }

    private func hint(_ item: RemoteScreenItem?) -> String {
        if pointer { return String(localized: "Tap to click · Two fingers scroll") }
        guard let item else { return String(localized: "Then tap to press it") }
        switch item.kind {
        case .poster: return String(localized: "Tap to open · Hold for options")
        case .toggle: return item.isOn == true ? String(localized: "On · Tap to turn off") : String(localized: "Off · Tap to turn on")
        case .field: return String(localized: "Tap to type here")
        default: return String(localized: "Tap to press · Hold for options")
        }
    }

    @ViewBuilder private func neighbour(_ item: RemoteScreenItem?) -> some View {
        if let item { tile(item, on: false) } else { Color.clear.frame(width: 52, height: 78) }
    }

    /// A poster (by its picture) or a button (by its name) in a row.
    @ViewBuilder private func tile(_ item: RemoteScreenItem, on: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: on ? 8 : 6, style: .continuous)
        if item.kind == .poster {
            ArtworkView(url: item.image, fallbackTitle: item.label, kind: .poster, pixelWidth: 185, showsFallbackTitle: false)
                .frame(width: on ? 60 : 52, height: on ? 90 : 78)
                .clipShape(shape)
                .overlay(shape.strokeBorder(on ? Palette.brand : Palette.edge, lineWidth: on ? 2.5 : 1))
                .shadow(color: on ? Palette.brand.opacity(0.5) : .clear, radius: 10)
                .opacity(on ? 1 : 0.45)
        } else {
            Text(verbatim: item.label)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, Spacing.m).frame(height: on ? 40 : 34)
                .frame(maxWidth: on ? 150 : 90)
                .foregroundStyle(Palette.textPrimary)
                .background(on ? Palette.wash : Palette.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Palette.brand : Palette.edge, lineWidth: on ? 2 : 1))
                .opacity(on ? 1 : 0.45)
        }
    }

    /// A line of a list (a Settings row, an episode), with its switch if it has one.
    private func line(_ item: RemoteScreenItem, on: Bool) -> some View {
        HStack {
            Text(verbatim: item.label).font(on ? .subheadline.weight(.semibold) : .caption).lineLimit(1)
            Spacer(minLength: Spacing.s)
            if let isOn = item.isOn {
                Capsule().fill(isOn ? Color.green : Palette.edge).frame(width: 28, height: 16)
                    .overlay(alignment: isOn ? .trailing : .leading) { Circle().fill(.white).padding(2) }
            }
        }
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, Spacing.m).frame(height: on ? 36 : 24)
        .background(on ? Palette.wash : Palette.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? Palette.brand : .clear, lineWidth: 2))
        .opacity(on ? 1 : 0.45)
        .padding(.horizontal, on ? 0 : Spacing.l)
    }
}

/// A round button with its name under it.
private struct RoundRemoteButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var prominent = false
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.prominent = prominent; self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(prominent ? Color.black : Palette.textPrimary)
                    .frame(width: 54, height: 54)
                    .background(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Palette.elevated), in: Circle())
                    .overlay(Circle().strokeBorder(prominent ? Color.clear : Palette.edge))
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(Palette.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(haptic: true))
        .accessibilityLabel(title)
    }
}

/// The open menu on the Mac (a hold, question 5), to pick from here.
private struct RemoteMenuSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let menu = app.remote.screen?.menu
        NavigationStack {
            List {
                if let menu {
                    ForEach(menu.items, id: \.index) { item in
                        Button { app.remote.send(.menuPick(item.index)) } label: {
                            HStack(spacing: Spacing.m) {
                                if let symbol = item.systemImage {
                                    Image(systemName: symbol).frame(width: 24).foregroundStyle(item.destructive ? Color.red : Palette.brandBright)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(ui: item.title).foregroundStyle(item.destructive ? Color.red : Palette.textPrimary)
                                    if let subtitle = item.subtitle {
                                        Text(verbatim: subtitle).font(.caption).foregroundStyle(Palette.textTertiary)
                                    }
                                }
                                Spacer()
                                if item.checked { Image(systemName: "checkmark").foregroundStyle(Palette.brandBright) }
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(item.disabled)
                        .listRowBackground(menu.highlighted == item.index ? Palette.wash : Palette.elevated)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.surface)
            .navigationTitle(Text(verbatim: menu?.title ?? ""))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.surface)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Playing

/// While something plays (question 8): the timeline with its chapter marks,
/// a pad that scrubs (swipe across; circle the edge for fine steps; tap to
/// pause; hold for Audio & Subtitles), the skip button when the Mac shows
/// one, and Close, ±10 s, Tracks, Play/Pause, Next and volume.
private struct PlayingRemote: View {
    let state: RemoteNowPlaying
    @Binding var showsTracks: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// While scrubbing (the pad, the ring or the timeline): where it's going.
    @State private var scrubbing: TimeInterval?
    /// Where a pad swipe started: it moves from there, not from the drawn (moving) position.
    @State private var scrubStart: TimeInterval?

    /// One full turn round the pad's edge: this many seconds.
    static let secondsPerTurn: TimeInterval = 60

    var body: some View {
        let s = state
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: s.title)
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if let subtitle = s.subtitle {
                        Text(verbatim: subtitle).font(Typography.meta).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: Spacing.m)
                if let skip = s.skipOffer {
                    // The Mac's skip button, here too.
                    Button { app.remote.send(.acceptSkip) } label: {
                        Label { Text(ui: skip) } icon: { Image(systemName: "forward.end.fill") }
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, Spacing.m).frame(height: 36)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(PressableStyle(haptic: true))
                    .transition(Motion.slide(from: .trailing, reduceMotion))
                }
            }
            .animation(Motion.standard(reduceMotion), value: s.skipOffer)
            .padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)

            timeline(s).padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)

            RemotePad(mode: .playing, hint: "Swipe to scrub · Circle the edge for fine steps\nTap to pause · Hold for Audio & Subtitles",
                      actions: RemotePad.Actions(
                        tap: { app.remote.send(.setPaused(!s.paused)) },
                        hold: { if !(s.audioTracks.isEmpty && s.subtitleTracks.isEmpty) { showsTracks = true } },
                        scrub: { fraction, ended in scrub(by: fraction, ended: ended) },
                        ring: { radians, ended in fine(by: radians, ended: ended) }))
                .overlay {
                    if let t = scrubbing {
                        Text(Formatters.duration(t))
                            .font(.largeTitle.weight(.bold).monospacedDigit())
                            .foregroundStyle(Palette.textPrimary)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)

            HStack {
                RoundRemoteButton("Close", systemImage: "xmark") { app.remote.send(.closePlayer) }
                Spacer()
                RoundRemoteButton("10 s", systemImage: "gobackward.10") { app.remote.skip(by: -10) }
                Spacer()
                RoundRemoteButton("10 s", systemImage: "goforward.10") { app.remote.skip(by: 10) }
                Spacer()
                RoundRemoteButton("Tracks", systemImage: "captions.bubble") { showsTracks = true }
                    .disabled(s.audioTracks.isEmpty && s.subtitleTracks.isEmpty)
            }
            .padding(.horizontal, Spacing.xl + Spacing.s).padding(.top, Spacing.l)

            HStack(spacing: Spacing.m) {
                Button { app.remote.send(.setPaused(!s.paused)) } label: {
                    Label(s.paused ? "Play" : "Pause", systemImage: s.paused ? "play.fill" : "pause.fill")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.white, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(haptic: true))
                if s.hasNext {
                    Button { app.remote.send(.nextEpisode) } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.headline)
                            .foregroundStyle(Palette.textPrimary)
                            .frame(width: 50, height: 50)
                            .background(Palette.elevated, in: Circle())
                            .overlay(Circle().strokeBorder(Palette.edge))
                    }
                    .buttonStyle(PressableStyle(haptic: true))
                    .accessibilityLabel("Next Episode")
                }
                volumeRocker(s)
            }
            .padding(.horizontal, Spacing.xl).padding(.top, Spacing.l)
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
        land(target, ended: ended)
    }

    /// Round the edge: a turn is a minute, for the exact frame.
    private func fine(by radians: Double, ended: Bool) {
        let duration = state.duration ?? 0
        guard duration > 0 else { return }
        let start = scrubStart ?? state.position
        scrubStart = start
        let target = min(max(start + radians / (2 * .pi) * Self.secondsPerTurn, 0), duration)
        land(target, ended: ended)
    }

    private func land(_ target: TimeInterval, ended: Bool) {
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
                app.remote.scrub(to: new)  // live: the Mac's picture follows
            }), in: 0...duration) { editing in
                if !editing, let target = scrubbing {
                    app.remote.endScrub(at: target)
                    scrubbing = nil
                }
            }
            .tint(Palette.brand)
            .disabled(s.duration == nil)
            .background(alignment: .leading) {
                // Chapter starts, as small ticks along the track.
                GeometryReader { g in
                    ForEach(Array((s.chapters ?? []).enumerated()), id: \.offset) { _, t in
                        if t > 0, t < duration {
                            Capsule().fill(Palette.textTertiary).frame(width: 2, height: 8)
                                .position(x: g.size.width * t / duration, y: g.size.height / 2)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
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

    /// The Mac's volume, a step at a time.
    private func volumeRocker(_ s: RemoteNowPlaying) -> some View {
        HStack(spacing: 0) {
            Button { app.remote.send(.volume(max(0, s.volume - 0.1))) } label: {
                Image(systemName: "minus").frame(width: 44, height: 50).contentShape(Rectangle())
            }
            .accessibilityLabel("Volume Down")
            Image(systemName: s.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityHidden(true)
            Button { app.remote.send(.volume(min(1, s.volume + 0.1))) } label: {
                Image(systemName: "plus").frame(width: 44, height: 50).contentShape(Rectangle())
            }
            .accessibilityLabel("Volume Up")
        }
        .font(.headline)
        .foregroundStyle(Palette.textPrimary)
        .buttonStyle(PressableStyle(haptic: true))
        .background(Palette.elevated, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.edge))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mac Volume")
        .accessibilityValue("\(Int((s.volume * 100).rounded())) %")
    }
}

// MARK: - The pad

/// The touch surface (questions 1 to 5 and 8). It lights where your finger
/// is. One finger: a deliberate tap (short, still, away from the edges, so
/// holding the phone doesn't press anything) presses; a swipe moves a step
/// per `stepLength`; a fast flick jumps several; holding at the edge after a
/// swipe keeps moving; a still hold opens the item's menu; a swipe in from the
/// left edge is Back. Two fingers scroll (and coast); a two-finger tap turns
/// the pointer on or off. In pointer mode one finger moves the pointer. While
/// playing, a swipe across scrubs and circling round the edge fine-scrubs.
struct RemotePad: View {
    enum Mode { case highlight, pointer, playing }

    struct Actions {
        var tap: () -> Void = {}
        var step: (RemoteDirection) -> Void = { _ in }
        var jump: (RemoteDirection, Int) -> Void = { _, _ in }
        var hold: () -> Void = {}
        /// How far two fingers moved (on the Mac's scale), and their speed when they lifted.
        var scroll: (CGVector, CGVector?) -> Void = { _, _ in }
        var twoFingerTap: () -> Void = {}
        var back: () -> Void = {}
        var pointer: (CGVector) -> Void = { _ in }
        /// Playing: the swipe's width as a fraction of the pad's, and whether it ended.
        var scrub: (CGFloat, Bool) -> Void = { _, _ in }
        /// Playing: how far round the edge the finger has gone, in radians, and whether it lifted.
        var ring: (Double, Bool) -> Void = { _, _ in }
    }

    let mode: Mode
    let hint: LocalizedStringKey
    let actions: Actions

    @State private var finger: CGPoint?
    @State private var taps = 0
    @State private var steps = 0
    @State private var holds = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous)
        ZStack {
            shape.fill(RadialGradient(colors: [Palette.elevated, Palette.surface], center: .top, startRadius: 0, endRadius: 420))
            if mode == .playing {
                // The fine-scrub ring round the edge.
                RoundedRectangle(cornerRadius: Radius.sheet - 8, style: .continuous)
                    .strokeBorder(Palette.brand.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    .padding(10)
            }
            if mode == .pointer {
                Label("Pointer", systemImage: "cursorarrow")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.brand, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(Spacing.m)
            }
            if let finger {
                Circle()
                    .fill(RadialGradient(colors: [Palette.brand.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 44))
                    .frame(width: 88, height: 88)
                    .position(finger)
                    .allowsHitTesting(false)
            }
            Text(hint)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.textTertiary)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, Spacing.l)
                .allowsHitTesting(false)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(finger != nil ? Palette.brand.opacity(0.6) : Palette.edge))
        .overlay {
            #if os(iOS)
            RemotePadSurface(mode: mode, actions: actions, finger: $finger,
                             feedback: { kind in
                                 switch kind {
                                 case .tap: taps += 1
                                 case .step: steps += 1
                                 case .hold: holds += 1
                                 }
                             })
            #endif
        }
        .frame(minHeight: 200, maxHeight: 340)
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        .sensoryFeedback(.selection, trigger: steps)
        .sensoryFeedback(.impact(weight: .heavy), trigger: holds)
        .accessibilityElement()
        .accessibilityLabel(hint)
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAction { actions.tap() }
        .accessibilityAction(named: "Up") { actions.step(.up) }
        .accessibilityAction(named: "Down") { actions.step(.down) }
        .accessibilityAction(named: "Left") { actions.step(.left) }
        .accessibilityAction(named: "Right") { actions.step(.right) }
        .accessibilityAction(named: "Options") { actions.hold() }
    }
}

#if os(iOS)
/// The pad's touches, in UIKit for more than one finger at a time.
private struct RemotePadSurface: UIViewRepresentable {
    enum Feedback { case tap, step, hold }

    let mode: RemotePad.Mode
    let actions: RemotePad.Actions
    @Binding var finger: CGPoint?
    let feedback: (Feedback) -> Void

    func makeUIView(context: Context) -> RemotePadTouchView {
        let v = RemotePadTouchView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: RemotePadTouchView, context: Context) {
        v.mode = mode
        v.actions = actions
        v.onFinger = { p in finger = p }
        v.feedback = feedback
    }
}

/// Reads one- and two-finger gestures off the pad (`RemotePad`).
final class RemotePadTouchView: UIView {
    var mode: RemotePad.Mode = .highlight
    var actions = RemotePad.Actions()
    var onFinger: (CGPoint?) -> Void = { _ in }
    fileprivate var feedback: (RemotePadSurface.Feedback) -> Void = { _ in }

    static let stepLength: CGFloat = 56
    /// A tap starting this near the edge is the hand holding the phone.
    static let edge: CGFloat = 16
    /// Where a swipe in from the left counts as Back, and where the playing ring is.
    static let edgeBand: CGFloat = 28
    /// Two fingers move the Mac's page this much more than the fingers moved.
    static let scrollScale: CGFloat = 2.5

    private var start: (point: CGPoint, time: TimeInterval)?
    private var last: (point: CGPoint, time: TimeInterval)?
    /// Recent points, for the flick's speed.
    private var trail: [(point: CGPoint, time: TimeInterval)] = []
    private var stepsTaken = CGSize.zero
    private var lastDirection: RemoteDirection?
    /// The way this swipe steps (true: across), set by its first step.
    private var axis: Bool?
    private var moved = false
    private var held = false
    private var holdTimer: Timer?
    private var repeatTimer: Timer?
    // Two fingers.
    private var twoFingers = false
    private var twoStart: (point: CGPoint, time: TimeInterval)?
    private var twoLast: CGPoint?
    private var twoTrail: [(point: CGPoint, time: TimeInterval)] = []
    private var twoMoved = false
    private var pendingScroll = CGVector.zero
    private var lastScrollSent: TimeInterval = 0
    // Pointer.
    private var pendingPointer = CGVector.zero
    private var lastPointerSent: TimeInterval = 0
    // Playing.
    private var scrubbing = false
    private var ringAngle: Double?
    private var ringTurned: Double = 0

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? touches
        if all.count >= 2 {
            beginTwoFingers(all)
            return
        }
        guard let t = touches.first else { return }
        let p = t.location(in: self), now = t.timestamp
        start = (p, now); last = (p, now); trail = [(p, now)]
        stepsTaken = .zero; lastDirection = nil; axis = nil; moved = false; held = false; scrubbing = false
        ringAngle = nil; ringTurned = 0
        onFinger(p)
        if mode == .playing, nearEdge(p) { ringAngle = angle(of: p) }
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdFired() }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if twoFingers { moveTwoFingers(event?.allTouches ?? touches); return }
        guard let t = touches.first, let start else { return }
        let p = t.location(in: self), now = t.timestamp
        let previous = last?.point ?? p
        last = (p, now)
        trail.append((p, now)); trail.removeAll { now - $0.time > 0.12 }
        onFinger(p)
        let travel = CGSize(width: p.x - start.point.x, height: p.y - start.point.y)
        if hypot(travel.width, travel.height) > 10 { moved = true; holdTimer?.invalidate() }
        guard !held else { return }
        switch mode {
        case .pointer:
            pendingPointer.dx += p.x - previous.x
            pendingPointer.dy += p.y - previous.y
            if now - lastPointerSent > 1.0 / 20 { flushPointer(now) }
        case .playing:
            if let a = ringAngle {
                // Round the edge: how far the finger has turned about the pad's centre.
                let b = angle(of: p)
                var d = b - a
                if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
                ringTurned += d
                ringAngle = b
                if moved { actions.ring(ringTurned, false) }
            } else if abs(travel.width) > 8 {
                scrubbing = true
                actions.scrub(travel.width / max(bounds.width, 1), false)
            }
        case .highlight:
            // A swipe in from the left edge is Back, not steps.
            if start.point.x < Self.edgeBand, travel.width > 0, abs(travel.width) > abs(travel.height) { return }
            // The first step picks the way; only a clear turn changes it, so a
            // swipe along a row that drifts a little doesn't drop to the next row.
            var horizontal = abs(travel.width) >= abs(travel.height)
            if let axis {
                let with = axis ? abs(travel.width) : abs(travel.height), across = axis ? abs(travel.height) : abs(travel.width)
                horizontal = across > with * 1.5 + Self.stepLength ? !axis : axis
            }
            let along = horizontal ? travel.width : travel.height
            let done = horizontal ? stepsTaken.width : stepsTaken.height
            let due = (along / Self.stepLength).rounded(.towardZero)
            if due != done {
                let d: RemoteDirection = horizontal ? (due > done ? .right : .left) : (due > done ? .down : .up)
                actions.step(d)
                feedback(.step)
                lastDirection = d
                axis = horizontal
                if horizontal { stepsTaken.width += due > done ? 1 : -1 } else { stepsTaken.height += due > done ? 1 : -1 }
            }
            updateEdgeRepeat(at: p)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if twoFingers {
            let remaining = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? []
            if remaining.isEmpty { endTwoFingers(at: touches.first?.timestamp ?? 0) }
            return
        }
        finish(touches.first, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if twoFingers { endTwoFingers(at: touches.first?.timestamp ?? 0); return }
        finish(touches.first, cancelled: true)
    }

    private func finish(_ touch: UITouch?, cancelled: Bool) {
        holdTimer?.invalidate(); repeatTimer?.invalidate(); repeatTimer = nil
        onFinger(nil)
        defer { start = nil; last = nil; trail = [] }
        guard let start, !held else { return }
        let end = touch?.location(in: self) ?? last?.point ?? start.point
        let now = touch?.timestamp ?? last?.time ?? start.time
        let travel = CGSize(width: end.x - start.point.x, height: end.y - start.point.y)
        switch mode {
        case .pointer:
            flushPointer(now)
            if !moved, !cancelled, now - start.time < 0.4 { actions.tap(); feedback(.tap) }
        case .playing:
            if ringAngle != nil, moved { actions.ring(ringTurned, true); return }
            if scrubbing { actions.scrub(travel.width / max(bounds.width, 1), true); return }
            if !moved, !cancelled, now - start.time < 0.4, inside(start.point) { actions.tap(); feedback(.tap) }
        case .highlight:
            if start.point.x < Self.edgeBand, travel.width > 70, abs(travel.width) > abs(travel.height) * 1.5 {
                actions.back(); feedback(.step); return
            }
            if !moved {
                if !cancelled, now - start.time < 0.4, inside(start.point) { actions.tap(); feedback(.tap) }
                return
            }
            // A flick: a few more steps, by how fast it was going.
            guard !cancelled, let first = trail.first, now - first.time > 0.01 else { return }
            let v = CGVector(dx: (end.x - first.point.x) / (now - first.time), dy: (end.y - first.point.y) / (now - first.time))
            let horizontal = abs(v.dx) >= abs(v.dy)
            let speed = horizontal ? abs(v.dx) : abs(v.dy)
            guard speed > 800 else { return }
            let d: RemoteDirection = horizontal ? (v.dx > 0 ? .right : .left) : (v.dy > 0 ? .down : .up)
            // A long swipe has already stepped most of the way: the flick adds what's left, not six more.
            let taken = Int(abs(horizontal ? stepsTaken.width : stepsTaken.height))
            let extra = min(6, Int(speed / 700)) - max(taken - 1, 0)
            if extra > 0 { actions.jump(d, extra); feedback(.step) }
        }
    }

    // MARK: Holding

    private func holdFired() {
        guard start != nil, !moved, !twoFingers else { return }
        held = true
        actions.hold()
        feedback(.hold)
    }

    /// After a swipe, holding the finger at the pad's edge that way keeps stepping, until it lifts or moves off.
    private func updateEdgeRepeat(at p: CGPoint) {
        let atEdge: Bool = switch lastDirection {
        case .right: p.x > bounds.width - Self.edgeBand
        case .left: p.x < Self.edgeBand
        case .down: p.y > bounds.height - Self.edgeBand
        case .up: p.y < Self.edgeBand
        case nil: false
        }
        if atEdge, repeatTimer == nil, let d = lastDirection {
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.actions.step(d)
                    self?.feedback(.step)
                }
            }
        } else if !atEdge {
            repeatTimer?.invalidate(); repeatTimer = nil
        }
    }

    // MARK: Two fingers

    private func centroid(_ touches: Set<UITouch>) -> CGPoint {
        let live = touches.filter { $0.phase != .ended && $0.phase != .cancelled }
        let ps = (live.isEmpty ? touches : live).map { $0.location(in: self) }
        return CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(max(ps.count, 1)), y: ps.map(\.y).reduce(0, +) / CGFloat(max(ps.count, 1)))
    }

    private func beginTwoFingers(_ touches: Set<UITouch>) {
        holdTimer?.invalidate(); repeatTimer?.invalidate(); repeatTimer = nil
        guard !twoFingers else { return }
        twoFingers = true
        let c = centroid(touches), now = touches.first?.timestamp ?? 0
        twoStart = (c, start?.time ?? now); twoLast = c; twoTrail = [(c, now)]; twoMoved = false
        pendingScroll = .zero
        onFinger(c)
    }

    private func moveTwoFingers(_ touches: Set<UITouch>) {
        guard let twoStart, let twoLast else { return }
        let c = centroid(touches), now = touches.first?.timestamp ?? 0
        if hypot(c.x - twoStart.point.x, c.y - twoStart.point.y) > 10 { twoMoved = true }
        // Natural scrolling: fingers up shows what's further down.
        pendingScroll.dx -= (c.x - twoLast.x) * Self.scrollScale
        pendingScroll.dy -= (c.y - twoLast.y) * Self.scrollScale
        self.twoLast = c
        twoTrail.append((c, now)); twoTrail.removeAll { now - $0.time > 0.12 }
        onFinger(c)
        if twoMoved, now - lastScrollSent > 1.0 / 12 {
            lastScrollSent = now
            actions.scroll(pendingScroll, nil)
            pendingScroll = .zero
        }
    }

    private func endTwoFingers(at now: TimeInterval) {
        defer {
            twoFingers = false; twoStart = nil; twoLast = nil; twoTrail = []; pendingScroll = .zero
            start = nil; last = nil; trail = []; held = false
            onFinger(nil)
        }
        guard let twoStart else { return }
        if !twoMoved {
            if now - twoStart.time < 0.35 { actions.twoFingerTap(); feedback(.tap) }
            return
        }
        var v = CGVector.zero
        if let first = twoTrail.first, let lastPoint = twoTrail.last, lastPoint.time - first.time > 0.01 {
            let dt = lastPoint.time - first.time
            v = CGVector(dx: -(lastPoint.point.x - first.point.x) / dt * Self.scrollScale,
                         dy: -(lastPoint.point.y - first.point.y) / dt * Self.scrollScale)
        }
        actions.scroll(pendingScroll, v)
    }

    // MARK: Helpers

    private func flushPointer(_ now: TimeInterval) {
        guard pendingPointer != .zero else { return }
        lastPointerSent = now
        actions.pointer(pendingPointer)
        pendingPointer = .zero
    }

    private func inside(_ p: CGPoint) -> Bool {
        p.x > Self.edge && p.y > Self.edge && p.x < bounds.width - Self.edge && p.y < bounds.height - Self.edge
    }

    private func nearEdge(_ p: CGPoint) -> Bool {
        p.x < Self.edgeBand || p.y < Self.edgeBand || p.x > bounds.width - Self.edgeBand || p.y > bounds.height - Self.edgeBand
    }

    private func angle(of p: CGPoint) -> Double { atan2(Double(p.y - bounds.midY), Double(p.x - bounds.midX)) }
}
#endif

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
