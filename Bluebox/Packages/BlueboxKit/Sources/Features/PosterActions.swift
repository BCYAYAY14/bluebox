import DesignSystem
import Domain
import Playback
import SwiftUI
#if os(macOS)
import AppKit
#endif

// Quick actions on any poster (GAPS B1, X8; decision Q3 A): touch and hold
// on iPhone and iPad, right-click (or Control-click) on Mac, opens the same
// solid Bluebox menu everywhere: Play, My List, Add to List…, Mark as
// Watched, Download, Details or Go to Show, Share. Continue Watching cards use it too, with
// Resume, Play Next Episode and Remove from Row, so there's one menu per thing.

/// What a quick-action menu offers for one card, worked out from what's
/// known about it. Pure, so the choice of entries is tested.
struct QuickActions: Equatable {
    enum Action: Equatable {
        case resume, play, playNext
        case addToList, removeFromList
        /// "Add to List…": the card of your lists (UI review decision 11).
        case addToLists
        case markWatched, markUnwatched
        case download, showDownloads
        case details, goToShow
        case share
        case notInterested
        case removeFromRow
    }

    /// Groups, separated in the menu.
    let groups: [[Action]]

    /// - Parameters:
    ///   - kind: the card's title kind.
    ///   - episode: the episode a Continue Watching or episode card stands for.
    ///   - inProgress: a saved position to resume.
    ///   - nearlyFinished: the episode is done or nearly (offers Play Next Episode).
    ///   - onList, watched, downloaded: current state, for the toggles.
    ///   - canShare: there's a public page to share (TMDB).
    ///   - removable: the card's row can drop it (Continue Watching).
    ///   - hideable: a poster, which "Not Interested" hides from Home's rows.
    static func build(kind: TitleKind, episode: MediaKey? = nil, inProgress: Bool = false, nearlyFinished: Bool = false,
                      onList: Bool, watched: Bool, downloaded: Bool, canShare: Bool, removable: Bool = false,
                      hideable: Bool = false) -> QuickActions {
        var play: [Action] = [inProgress ? .resume : .play]
        if episode != nil, nearlyFinished { play.append(.playNext) }

        var library: [Action] = [onList ? .removeFromList : .addToList, .addToLists]
        // Watched and Download need one playable thing: a movie, or the episode on the card.
        let single = kind == .movie || episode != nil
        if single {
            library.append(watched ? .markUnwatched : .markWatched)
            library.append(downloaded ? .showDownloads : .download)
        }

        var more: [Action] = [episode != nil ? .goToShow : .details]
        if canShare { more.append(.share) }
        if hideable { more.insert(.notInterested, at: 0) }

        var groups = [play, library, more]
        if removable { groups.append([.removeFromRow]) }
        return QuickActions(groups: groups)
    }
}

/// The card a menu is about.
struct QuickActionSubject {
    let title: Title
    /// Continue Watching and episode cards: the progress record they show.
    var entry: WatchEntry?
    /// Continue Watching's "Remove from Row".
    var remove: (@MainActor () -> Void)?

    var playKey: MediaKey { entry?.progress.key ?? title.key }
    var episodeKey: MediaKey? { entry?.progress.key.episodeNumbers != nil ? entry?.progress.key : nil }
}

extension View {
    /// Touch and hold (iOS) or right-click (Mac) opens `title`'s quick-action
    /// menu. Use `TitleCardLink` for tappable cards: it opens the title on a
    /// tap and keeps the hold from also opening it.
    ///
    /// - Parameter tapToOpen: a plain tap opens it too (a ⋯ button).
    func quickActions(_ subject: QuickActionSubject, opened: QuickActionGate? = nil, tapToOpen: Bool = false) -> some View {
        modifier(QuickActionsMenu(subject: subject, gate: opened, tapToOpen: tapToOpen))
    }
}

@MainActor final class QuickActionsHolder {
    var actions: QuickActions?
    /// Add to List… swaps the menu for the lists card, on the same anchor.
    var showsLists = false
    let lists = AddToListState()
}

#if DEBUG
@MainActor enum DebugFlags {
    static var posterMenuOpened = false
}
#endif

/// Set when a hold opened the menu, so the tap that ends the hold doesn't
/// also open the title.
@MainActor
final class QuickActionGate {
    private var heldAt: Date?
    func held() { heldAt = .now }
    /// True (once) when the tap that just ended was the hold.
    func consumeHold() -> Bool {
        defer { heldAt = nil }
        guard let heldAt else { return false }
        return Date().timeIntervalSince(heldAt) < 2
    }
}

/// A poster or card that opens its title on a tap and has the quick-action
/// menu on a hold or right-click. Drop-in for `NavigationLink(value: .title(t))`.
/// On iOS the title page zooms out of the card (and back into it), the card
/// being its own `matchedTransitionSource` under a per-card ID: the same title
/// can sit in several rows at once.
struct TitleCardLink<Label: View>: View {
    @Environment(\.pushRoute) private var pushRoute
    @Environment(\.zoomNamespace) private var zoomNamespace
    let subject: QuickActionSubject
    var route: Route?
    var onOpen: () -> Void = {}
    let label: Label
    @State private var gate = QuickActionGate()
    @State private var zoomID = UUID()

    init(_ title: Title, route: Route? = nil, onOpen: @escaping () -> Void = {}, @ViewBuilder label: () -> Label) {
        self.subject = QuickActionSubject(title: title)
        self.route = route; self.onOpen = onOpen; self.label = label()
    }

    init(_ subject: QuickActionSubject, route: Route? = nil, onOpen: @escaping () -> Void = {}, @ViewBuilder label: () -> Label) {
        self.subject = subject; self.route = route; self.onOpen = onOpen; self.label = label()
    }

    var body: some View {
        Button {
            guard !gate.consumeHold() else { return }
            onOpen()
            pushRoute(route ?? .title(subject.title), zoomFrom: zoomNamespace == nil ? nil : zoomID)
        } label: { label.modifier(ZoomSource(id: zoomID, namespace: zoomNamespace)) }
        .buttonStyle(PressableStyle())
        .quickActions(subject, opened: gate)
    }
}

/// The card a title page zooms out of (iOS), clipped to the card's corners.
struct ZoomSource: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace) { source in
                source.clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct QuickActionsMenu: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.pushRoute) private var pushRoute
    @Environment(\.selectTab) private var selectTab
    let subject: QuickActionSubject
    let gate: QuickActionGate?
    var tapToOpen = false
    @State private var open = false
    // A reference, so the menu (built when it opens, outside this body) reads the current entries.
    @State private var holder = QuickActionsHolder()

    func body(content: Content) -> some View {
        if tapToOpen {
            content
                .contentShape(Rectangle())
                .onTapGesture { present() }
                .blueboxMenu(isPresented: $open, title: subject.title.name) { entries }
        } else {
            content
                .blueboxMenu(isPresented: $open, title: subject.title.name) { entries }
                #if os(iOS)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    gate?.held()
                    present()
                })
                #else
                .overlay { SecondaryClickCatcher { present() } }
                #endif
                .accessibilityAction(named: "More Actions") { present() }
                #if DEBUG
                .task {
                    // Screenshots: `-open-poster-menu` opens the first poster's menu once.
                    guard ProcessInfo.processInfo.arguments.contains("-open-poster-menu"), !DebugFlags.posterMenuOpened else { return }
                    DebugFlags.posterMenuOpened = true
                    try? await Task.sleep(for: .seconds(2))
                    present()
                }
                #endif
        }
    }

    /// Reads the card's state (all local), then opens the menu.
    private func present() {
        Task {
            let t = subject.title
            let onList = (try? await app.store.isOnWatchlist(t.key)) ?? false
            let key = subject.playKey
            let single = t.kind == .movie || subject.episodeKey != nil
            let watched = single ? ((try? await app.store.progress(for: key))?.isCompleted ?? false) : false
            holder.showsLists = false
            holder.actions = QuickActions.build(
                kind: t.kind, episode: subject.episodeKey,
                inProgress: subject.entry.map { !$0.progress.isCompleted && $0.progress.position > 0 } ?? false,
                nearlyFinished: subject.entry?.progress.isNearlyFinished ?? false,
                onList: onList, watched: watched, downloaded: single && app.isDownloaded(key),
                canShare: shareURL != nil, removable: subject.remove != nil, hideable: subject.entry == nil && subject.remove == nil)
            open = true
        }
    }

    private var shareURL: URL? {
        guard app.catalogMode == .live, let id = subject.title.key.tmdbID else { return nil }
        return URL(string: "https://www.themoviedb.org/\(subject.title.kind == .movie ? "movie" : "tv")/\(id)")
    }

    private var subtitle: String {
        let t = subject.title
        if let entry = subject.entry, !entry.label.isEmpty { return entry.label }
        return [t.year.map(String.init), t.kind == .movie ? "Film" : "Series"].compactMap { $0 }.joined(separator: " · ")
    }

    @BlueboxMenuBuilder private var entries: [BlueboxMenuEntry] {
        if holder.showsLists {
            holder.lists.entries(app, subject.title)
        } else {
            BlueboxMenuTitle(subject.title.name, subtitle: subtitle)
            for group in holder.actions?.groups ?? [] {
                BlueboxMenuSection {
                    for action in group { button(action) }
                }
            }
        }
    }

    /// Add to List…: the menu closes, then reopens in place as the lists card.
    private func presentLists() {
        Task {
            await holder.lists.load(app, subject.title)
            holder.showsLists = true
            open = true
        }
    }

    private func button(_ action: QuickActions.Action) -> BlueboxMenuButton {
        let t = subject.title
        let key = subject.playKey
        switch action {
        case .resume:
            return BlueboxMenuButton("Resume", systemImage: "play.fill") { Task { await app.playQuick(subject) } }
        case .play:
            return BlueboxMenuButton("Play", systemImage: "play.fill") { Task { await app.playQuick(subject) } }
        case .playNext:
            return BlueboxMenuButton("Play Next Episode", systemImage: "forward.end") {
                Task { await app.playNextEpisode(after: key, seriesName: t.name) }
            }
        case .addToList:
            return BlueboxMenuButton("Add to My List", systemImage: "plus") { Task { await app.toggleWatchlistWithToast(t, adding: true) } }
        case .removeFromList:
            return BlueboxMenuButton("Remove from My List", systemImage: "checkmark") {
                Task { await app.toggleWatchlistWithToast(t, adding: false) }
            }
        case .addToLists:
            return BlueboxMenuButton("Add to List…", systemImage: "text.badge.plus") { presentLists() }
        case .markWatched:
            return BlueboxMenuButton("Mark as Watched", systemImage: "eye") { Task { await app.setWatchedWithToast(key, name: t.name, true) } }
        case .markUnwatched:
            return BlueboxMenuButton("Mark as Unwatched", systemImage: "eye.slash") {
                Task { await app.setWatchedWithToast(key, name: t.name, false) }
            }
        case .download:
            return BlueboxMenuButton("Download", systemImage: "arrow.down.circle") {
                let subtitle = key.episodeNumbers.map { "S\($0.season)·E\($0.episode)" }
                Task { await app.startDownload(key: key, title: t.name, subtitle: subtitle) }
            }
        case .showDownloads:
            return BlueboxMenuButton("Show in Downloads", systemImage: "arrow.down.circle.fill") { selectTab(.downloads) }
        case .details:
            return BlueboxMenuButton("Details", systemImage: "info.circle") { pushRoute(.title(t)) }
        case .goToShow:
            return BlueboxMenuButton("Go to Show", systemImage: "info.circle") {
                pushRoute(subject.episodeKey.map { .episode(t, $0) } ?? .title(t))
            }
        case .share:
            return BlueboxMenuButton("Share…", systemImage: "square.and.arrow.up") { if let url = shareURL { ShareSheet.present(url) } }
        case .notInterested:
            return BlueboxMenuButton("Not Interested", systemImage: "nosign") { app.hideTitle(t) }
        case .removeFromRow:
            return BlueboxMenuButton("Remove from Row", systemImage: "minus.circle", role: .destructive) { subject.remove?() }
        }
    }
}

extension AppModel {
    /// Play from a quick-action menu: the movie, the card's episode, or a
    /// series' next episode (the one the title page would play).
    func playQuick(_ subject: QuickActionSubject) async {
        let t = subject.title
        if let entry = subject.entry {
            let p = entry.progress
            await play(NowPlayingItem(key: p.key, title: t.name, subtitle: p.key.episodeNumbers.map { "S\($0.season)·E\($0.episode)" },
                                      artworkURL: imageURL(t.backdrop, width: 640)))
            return
        }
        guard t.kind == .series else {
            await play(NowPlayingItem(key: t.key, title: t.name, subtitle: t.year.map(String.init),
                                      artworkURL: imageURL(t.backdrop, width: 640)))
            return
        }
        do {
            let progress = (try? await store.progress(forSeries: t.key)) ?? []
            let detail = try await metadata.detail(for: t.key)
            guard let target = SeriesCursor.target(series: t.key, progress: progress, seasons: detail.seasons) else {
                alert = AppAlert(title: "Nothing to play yet", message: "“\(t.name)” has no episodes listed.")
                return
            }
            await play(NowPlayingItem(key: target.key, title: t.name, subtitle: "S\(target.season)·E\(target.episode)",
                                      artworkURL: imageURL(t.backdrop, width: 640)))
        } catch {
            report(error, title: "Couldn't play “\(t.name)”", context: .catalog) { [weak self] in await self?.playQuick(subject) }
        }
    }

    /// My List from a menu, with Undo in a toast.
    /// A failed save says so, with Try Again (as the optimistic toggles do).
    func toggleWatchlistWithToast(_ t: Title, adding: Bool) async {
        do {
            try await setOnMyList(t, adding)
        } catch {
            report(error, title: "Couldn't update My List") { [weak self] in await self?.toggleWatchlistWithToast(t, adding: adding) }
            return
        }
        showToast(AppToast(t.name, message: adding ? "Added to My List" : "Removed from My List", actionTitle: "Undo") { [weak self] in
            Task { try? await self?.setOnMyList(t, !adding) }
        })
    }

    /// Watched from a menu, with Undo in a toast. A failed save says so, with Try Again.
    func setWatchedWithToast(_ key: MediaKey, name: String, _ watched: Bool) async {
        let before = try? await store.progress(for: key)
        do {
            try await setWatched(key, watched)
        } catch {
            report(error, title: "Couldn't mark “\(name)”") { [weak self] in await self?.setWatchedWithToast(key, name: name, watched) }
            return
        }
        showToast(AppToast(name, message: watched ? "Marked as watched" : "Marked as unwatched", actionTitle: "Undo") { [weak self] in
            Task {
                guard let self else { return }
                if var restored = before {
                    restored.updatedAt = .now
                    restored.deviceID = self.prefs.deviceID
                    _ = try? await self.store.save(restored)
                    self.noteLibraryChanged()
                } else {
                    try? await self.setWatched(key, !watched)
                }
            }
        })
    }
}

#if os(macOS)
/// Catches right-clicks (and Control-clicks) over a card and lets every
/// other event through, since SwiftUI has no secondary-click gesture.
struct SecondaryClickCatcher: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.action = action
        return v
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (@MainActor () -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown || event.type == .rightMouseUp
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { action?() }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { action?() } else { super.mouseDown(with: event) }
        }
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }
}
#endif
