import DesignSystem
import Sync
import SwiftUI

/// Joins the remote channel when this device should (RemoteControl.swift) and,
/// on iPhone and iPad, draws "Playing on Mac" over the tabs and opens the
/// remote from it. RootView applies it once; everything else lives here.
struct RemoteControlHost: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsRemote = false
    #endif

    private struct Want: Hashable {
        let wanted: Bool
        let player: ObjectIdentifier?
    }

    private var want: Want {
        #if os(macOS)
        let player = app.activePlayer
        return Want(wanted: app.featureSwitches.allowRemoteControl && app.account.isSignedIn && player != nil,
                    player: player.map(ObjectIdentifier.init))
        #else
        return Want(wanted: app.featureSwitches.useAsRemote && app.account.isSignedIn && scenePhase == .active, player: nil)
        #endif
    }

    func body(content: Content) -> some View {
        content
            .task(id: want) {
                #if os(macOS)
                app.remote.update(wanted: want.wanted, account: app.account, player: app.activePlayer)
                #else
                app.remote.update(wanted: want.wanted, account: app.account, player: nil)
                #endif
            }
            #if os(iOS)
            .overlay(alignment: .bottom) {
                if let state = app.remote.nowPlaying, app.activePlayer == nil {
                    PlayingOnMacBar(state: state, togglePlay: { app.remote.send(.setPaused(!state.paused)) },
                                    open: { showsRemote = true })
                        // Above the tab bar on iPhone; iPad has no bar at the bottom.
                        .padding(.horizontal, Spacing.m)
                        .padding(.bottom, sizeClass == .compact ? 58 : Spacing.l)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: app.remote.nowPlaying == nil)
            .sheet(isPresented: $showsRemote) {
                RemoteControlScreen().environment(app)
            }
            .onChange(of: showsRemote) { _, open in app.remote.screenOpen = open }
            #endif
    }
}

#if os(iOS)
/// "Playing on Mac": the title, a thin blue line for where it is, and play/pause. Tap for the remote.
struct PlayingOnMacBar: View {
    let state: RemoteNowPlaying
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Playing on Mac")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Palette.textSecondary)
                        Text(state.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 1))
            .accessibilityLabel("Playing on Mac: \(state.title)")
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
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .overlay(alignment: .bottom) {
            // Blue for state: how far through it is.
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

/// The remote: transport, ±10 s, scrub, next episode, audio and subtitle
/// tracks, and the Mac's volume. Every control answers at once
/// (`RemoteControl.send`); the Mac's next state settles it.
struct RemoteControlScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// While dragging the timeline: where the thumb is (sent on release).
    @State private var scrubbing: TimeInterval?
    @State private var volume: Float?
    @State private var lastVolumeSend = Date.distantPast

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Playing on \(app.remote.nowPlaying?.deviceName ?? "Mac")", systemImage: "laptopcomputer")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
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

            if let s = app.remote.nowPlaying {
                controls(s)
            } else {
                Spacer()
                ContentUnavailableView("Nothing Playing on Your Mac", systemImage: "laptopcomputer",
                                       description: Text("Play something in Bluebox on your Mac to control it from here."))
                Spacer()
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationBackground(Palette.background)
    }

    @ViewBuilder
    private func controls(_ s: RemoteNowPlaying) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(s.title)
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
            if let subtitle = s.subtitle {
                Text(subtitle).font(Typography.meta).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xl).padding(.top, Spacing.xxl)

        Spacer(minLength: Spacing.xl)

        timeline(s).padding(.horizontal, Spacing.xl)

        HStack(spacing: Spacing.xxxl) {
            transportButton("gobackward.10", label: "Back 10 Seconds", size: 30) { app.remote.skip(by: -10) }
            Button { app.remote.send(.setPaused(!s.paused)) } label: {
                Image(systemName: s.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 76, height: 76)
                    .background(Color.white, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(haptic: true))
            .accessibilityLabel(s.paused ? "Play" : "Pause")
            transportButton("goforward.10", label: "Forward 10 Seconds", size: 30) { app.remote.skip(by: 10) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xl)

        HStack(spacing: Spacing.s) {
            trackMenu("Audio", systemImage: "waveform", tracks: s.audioTracks, selected: s.audioID, allowsOff: false) { id in
                if let id { app.remote.send(.audio(id)) }
            }
            trackMenu("Subtitles", systemImage: "captions.bubble", tracks: s.subtitleTracks, selected: s.subtitleID, allowsOff: true) { id in
                app.remote.send(.subtitle(id))
            }
            if s.hasNext {
                Button { app.remote.send(.nextEpisode) } label: {
                    Label("Next", systemImage: "forward.end.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Next Episode")
            }
        }
        .padding(.horizontal, Spacing.xl).padding(.top, Spacing.xxl)

        volumeRow(s).padding(.horizontal, Spacing.xl).padding(.top, Spacing.xl)

        Spacer(minLength: Spacing.xl)
    }

    private func timeline(_ s: RemoteNowPlaying) -> some View {
        let duration = max(s.duration ?? 0, 1)
        let position = scrubbing ?? s.position
        return VStack(spacing: Spacing.xs) {
            Slider(value: Binding(get: { min(position, duration) }, set: { scrubbing = $0 }), in: 0...duration) { editing in
                if !editing, let target = scrubbing {
                    app.remote.send(.seek(target))
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

    private func transportButton(_ symbol: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(haptic: true))
        .accessibilityLabel(label)
    }

    private func trackMenu(_ title: String, systemImage: String, tracks: [RemoteTrack], selected: String?, allowsOff: Bool,
                           choose: @escaping (String?) -> Void) -> some View {
        Menu {
            Picker(title, selection: Binding(get: { selected }, set: choose)) {
                if allowsOff { Text("Off").tag(String?.none) }
                ForEach(tracks) { t in Text(t.label).tag(String?.some(t.id)) }
            }
        } label: {
            SecondaryButtonLabel { Label(title, systemImage: systemImage) }
        }
        .disabled(tracks.isEmpty)
        .accessibilityValue(tracks.first { $0.id == selected }?.label ?? "Off")
    }
}
#endif
