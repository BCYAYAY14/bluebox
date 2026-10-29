import DesignSystem
import Domain
import SwiftUI

/// How the player comes on screen.
@MainActor
enum PlayerPresentation {
    /// True while `PlayLaunchSurface` covers the window: the player then
    /// takes its place at once, with no sliding cover on top of it.
    static var launchSurfaceIsUp = false

    /// Runs `change` (setting `activePlayer`) with presentation animations off
    /// when `instantly`, or when the launch surface is up: after the preparing
    /// overlay or the surface, both already full screen, the player takes its
    /// place in one step instead of sliding up over it.
    static func change(instantly: Bool, _ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = instantly || launchSurfaceIsUp
        withTransaction(transaction, change)
    }
}

// MARK: - Play → player (DECISIONS.md, UI review 13)

/// What Play was pressed on: the artwork that grows into the player.
struct PlayOrigin: Equatable {
    let key: MediaKey
    /// In global coordinates.
    let frame: CGRect
    let artwork: URL?
    var pressedAt = Date()

    /// A press that never got as far as preparing (a prompt, a maturity
    /// block, nothing to play) mustn't animate a later, unrelated Play.
    var isFresh: Bool { Date().timeIntervalSince(pressedAt) < 30 }
}

extension EnvironmentValues {
    /// Says where Play was pressed, just before calling `AppModel.play`.
    @Entry var notePlayOrigin = NotePlayOriginAction { _ in }
}

/// Always equal, so storing it doesn't invalidate readers.
struct NotePlayOriginAction: Equatable {
    let action: @MainActor (PlayOrigin) -> Void
    @MainActor func callAsFunction(_ origin: PlayOrigin) { action(origin) }
    static func == (a: Self, b: Self) -> Bool { true }
}

/// Where a view is on screen, for `PlayOrigin`, kept in a box rather than
/// state: it changes on every scroll frame, and nothing redraws from it.
@MainActor final class PlayOriginAnchor {
    var frame: CGRect = .zero
}

/// Records the artwork's global frame into `anchor`.
struct PlayOriginReporter: ViewModifier {
    let anchor: PlayOriginAnchor
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor.frame = $0 }
    }
}

/// The artwork Play was pressed on, growing from its place to fill the
/// window and darkening as it goes, with "Preparing" over it. The add-on
/// overlay (`StreamPreparingOverlay`, which looks the same once grown) fades
/// in over it with the real numbers; the player fades in over it at the end.
/// Reduce Motion: it fades in already full size.
struct PlayLaunchSurface: View {
    let origin: PlayOrigin
    let title: String?
    /// Off while the add-on overlay, which says more, is on top.
    let showsStatus: Bool
    let cancel: () -> Void
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let container = geo.frame(in: .global)
            let full = CGRect(origin: .zero, size: geo.size)
            let start = origin.frame.offsetBy(dx: -container.minX, dy: -container.minY)
            let rect = expanded ? full : start
            ZStack(alignment: .topLeading) {
                Color.black.opacity(expanded ? 1 : 0)
                ArtworkView(url: origin.artwork, fallbackTitle: title ?? "", kind: .backdrop,
                            pixelWidth: Int(geo.size.width * 2), showsFallbackTitle: false)
                    .frame(width: rect.width, height: rect.height)
                    .clipped()
                    .opacity(expanded ? LaunchBackdrop.artOpacity : 1)
                    .overlay { LaunchBackdrop.vignette(geo.size).opacity(expanded ? 1 : 0) }
                    .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : Radius.card, style: .continuous))
                    .offset(x: rect.minX, y: rect.minY)
                    .accessibilityHidden(true)
                status
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(expanded && showsStatus ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: showsStatus)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {}  // the page underneath is out of reach until the player is up
        .onAppear {
            if reduceMotion {
                expanded = true
            } else {
                withAnimation(Motion.spatial(false)) { expanded = true }
            }
        }
        .accessibilityIdentifier("playLaunchSurface")
    }

    /// Like the add-on overlay's top half, so one hands over to the other unseen.
    private var status: some View {
        VStack(spacing: Spacing.l) {
            if let title {
                Text(title)
                    .font(.title2.weight(.heavy))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            ProgressView().tint(.white).controlSize(.large).frame(height: 36)
            Text("Preparing").font(.headline)
            Button("Cancel", action: cancel)
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cancelPreparing")
        }
        .foregroundStyle(Palette.textPrimary)
        .padding(Spacing.xl)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title.map { "Preparing \($0)" } ?? "Preparing")
    }
}

/// The grown surface's look (the darkened art), shared by the surface and
/// the backdrop the player fades in over.
struct LaunchBackdrop: View {
    static let artOpacity = 0.32
    let artwork: URL?

    static func vignette(_ size: CGSize) -> some View {
        RadialGradient(colors: [.black.opacity(0.2), .black.opacity(0.85)], center: .center,
                       startRadius: 0, endRadius: max(size.width, size.height) * 0.6)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                ArtworkView(url: artwork, fallbackTitle: "", kind: .backdrop,
                            pixelWidth: Int(geo.size.width * 2), showsFallbackTitle: false)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .opacity(Self.artOpacity)
                Self.vignette(geo.size)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// iOS: the player's cover fades the video in over the darkened art when
/// Play came through the launch surface; otherwise it's shown as before.
struct PlayerLaunchFadeIn: ViewModifier {
    /// Captured when the player appears: the surface goes soon after.
    @State private var backdrop: URL??
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(launchArtwork: URL??) {
        _backdrop = State(initialValue: launchArtwork)
        _shown = State(initialValue: launchArtwork == nil)
    }

    func body(content: Content) -> some View {
        ZStack {
            if let backdrop { LaunchBackdrop(artwork: backdrop) }
            content.opacity(shown ? 1 : 0)
        }
        .onAppear {
            guard !shown else { return }
            withAnimation(.easeIn(duration: reduceMotion ? 0.2 : 0.35)) { shown = true }
        }
    }
}
