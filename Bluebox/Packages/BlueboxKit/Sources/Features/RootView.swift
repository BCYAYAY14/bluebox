import DesignSystem
import Domain
import Downloads
import Playback
import SwiftUI
import VLCPlayback

public enum Route: Hashable {
    case title(Title)
    /// A series page opened on one episode (its season, scrolled to it), e.g. from a new-episode alert.
    case episode(Title, MediaKey)
    case genre(Genre, TitleKind)
    /// One of an add-on's catalogs, from its Home row's See All.
    case addonCatalog(addonID: String, catalogID: String)
    /// A person's page (TMDB person ID).
    case person(Int)
    /// A film collection's page ("Part of …" on a film's page).
    case collection(CollectionRef)
    /// Everyone in a title's credits, by department.
    case castCrew(TitleCredits)
    /// Your debrid cloud (Real-Debrid, Premiumize, TorBox, AllDebrid or Debrid-Link).
    case debridLibrary
    /// A show's downloaded episodes, from Downloads' Shows shelf.
    case downloadedShow(seriesKey: MediaKey, title: String, artworkURL: URL?)
    /// "See All" from Home's rows (iPhone, where these aren't tabs).
    case continueWatching
    case myList
    /// A list's page: My List, one of yours, or a smart list.
    case list(LibraryListID)
}

extension EnvironmentValues {
    /// Pushes a page onto the current tab's navigation path, so the top bar's
    /// back button (iPad, Mac) knows about it. Use this or
    /// `NavigationLink(value:)`, not `navigationDestination(item:)`, which
    /// pushes outside the path.
    @Entry var pushRoute = PushRouteAction { _, _ in }
    /// Opens Settings, optionally at one page: the one Settings sheet on iOS,
    /// the Settings window on Mac. Every way into Settings goes through this.
    @Entry var openSettingsPage = OpenSettingsPageAction { _ in }
    /// iOS: the namespace title pages zoom out of (`TitleCardLink`); nil on Mac.
    @Entry var zoomNamespace: Namespace.ID?
    /// iPad and Mac: false on a tab kept alive behind the visible one, so
    /// it can stop what's only worth doing on screen (Home's preview).
    @Entry var isTabVisible = true
    /// Switches to a top-level tab (folded to its iPhone equivalent there),
    /// e.g. an empty state's "Browse" button opening Home.
    @Entry var selectTab = SelectTabAction { _ in }
    /// iPad and Mac: a page reports whether it has scrolled under the top
    /// bar, with its depth in the tab's navigation path.
    @Entry var reportTopBarScroll = TopBarScrollReport { _, _ in }
}

/// Always equal, so storing it doesn't invalidate readers.
struct OpenSettingsPageAction: Equatable {
    let action: @MainActor (SettingsRoute?) -> Void
    @MainActor func callAsFunction(_ page: SettingsPage? = nil) { action(page.map(SettingsRoute.page)) }
    /// A page below a category (a profile's editor).
    @MainActor func callAsFunction(route: SettingsRoute) { action(route) }
    static func == (a: Self, b: Self) -> Bool { true }
}

/// Always equal, so storing it doesn't invalidate readers.
struct SelectTabAction: Equatable {
    let action: @MainActor (AppTab) -> Void
    @MainActor func callAsFunction(_ tab: AppTab) { action(tab) }
    static func == (a: Self, b: Self) -> Bool { true }
}

/// Always equal, so storing it doesn't invalidate readers.
struct TopBarScrollReport: Equatable {
    let action: @MainActor (Int, Bool) -> Void
    @MainActor func callAsFunction(depth: Int, scrolled: Bool) { action(depth, scrolled) }
    static func == (a: Self, b: Self) -> Bool { true }
}

/// Appends to the visible tab's path. Always equal, so storing it doesn't invalidate readers.
struct PushRouteAction: Equatable {
    let action: @MainActor (Route, AnyHashable?) -> Void
    /// - Parameter zoomFrom: the `matchedTransitionSource` ID the page zooms
    ///   out of (iOS), from a card in `zoomNamespace`.
    @MainActor func callAsFunction(_ route: Route, zoomFrom: AnyHashable? = nil) { action(route, zoomFrom) }
    static func == (a: Self, b: Self) -> Bool { true }
}

/// The page for a route, shared by every navigation stack.
struct RouteDestination: View {
    let route: Route
    var body: some View {
        switch route {
        case .title(let t): TitleDetailView(title: t)
        case .episode(let t, let key): TitleDetailView(title: t, focus: key)
        case .genre(let g, let kind): GenreView(genre: g, kind: kind)
        case .addonCatalog(let addonID, let catalogID): AddonCatalogView(addonID: addonID, catalogID: catalogID)
        case .person(let id): PersonView(personID: id)
        case .collection(let ref): CollectionView(ref: ref)
        case .castCrew(let credits): CastCrewListView(credits: credits)
        case .debridLibrary: DebridLibraryView()
        case .downloadedShow(let key, let title, let art): DownloadedShowView(seriesKey: key, title: title, artworkURL: art)
        case .continueWatching: LibraryView(section: .watching, fixed: true)
        case .myList: LibraryView(section: .myList, fixed: true)
        case .list(let id): ListDetailView(id: id)
        }
    }
}

/// Everything the top bar (iPad, Mac) or tab bar (iPhone) can show.
public enum AppTab: Hashable {
    case home, shows, movies, newHot, search, library, myList, watching, downloads
    case source(SourceID)
}

/// A registered source, as listed in the Sources menu.
struct SidebarSource: Identifiable, Hashable {
    let id: SourceID
    let name: String
    let kind: SourceKind

    /// `DebridLibrarySource`'s ID: it gets its own entry, shown once it's set up.
    static let debridLibraryID = SourceID("debrid-library")

    var symbol: String {
        switch kind {
        case .localFolder: "folder"
        case .directURL: "link"
        case .jellyfin, .emby, .plex: "server.rack"
        case .webdav: "externaldrive.connected.to.line.below"
        case .publicCatalog: "film.stack"
        case .torrent: "arrow.down.to.line.circle"
        case .downloads: "arrow.down.circle"
        case .addons: "magnet"
        }
    }
}

/// Top-level navigation. On iPhone, a tab bar (Home, Library, Downloads, with
/// search split off) and the profile button at the top of Home. On iPad and
/// Mac, a Netflix-style top bar over the content, with every visited tab kept
/// alive underneath. Settings opens from the profile menu: one sheet on iOS,
/// the Settings window on Mac. The player is presented over everything.
public struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .home
    @State private var sources: [SidebarSource] = []
    @State private var paths: [AppTab: [Route]] = [:]
    /// Bumped to make Search focus its field (see `tabChosen`).
    @State private var searchFocusRequest = 0
    /// iPad and Mac: whether each page (by tab, then depth in its path) has
    /// scrolled under the top bar. Kept per page, so going back to a
    /// scrolled page or tab keeps the bar solid; hidden tabs write only their own.
    @State private var topBarScrolled: [AppTab: [Int: Bool]] = [:]
    /// iPad and Mac: the tabs opened so far, kept alive (with their scroll
    /// position and loaded rows) behind the visible one.
    @State private var visitedTabs: [AppTab] = []
    /// iOS: the card each pushed page zoomed out of, by tab and depth.
    @State private var zoomSources: [AppTab: [Int: AnyHashable]] = [:]
    @Namespace private var zoomNamespace
    /// iOS: the one Settings sheet and where it should be.
    @State private var settingsTarget: SettingsTarget?
    /// Where Play was last pressed, and the launch surface growing from it.
    @State private var pendingPlayOrigin: PlayOrigin?
    @State private var playLaunch: PlayOrigin?
    /// iPhone Home's TV Shows / Movies chips.
    @State private var homeCategory: HomeCategory = .all
    /// "Who's watching?" over everything: at launch with several profiles, or from the profile menu.
    @State private var showsProfilePicker = false
    /// The launch gate has no close button: someone has to pick.
    @State private var profilePickerIsGate = false
    @State private var checkedProfilesAtLaunch = false
    /// The picker opened for a locked profile's PIN (a shortcut or the menu chose it).
    @State private var pickerPIN: String?
    /// The avatar flying into the top bar, and Home fading back in, after a switch.
    @State private var flight = ProfileSwitchFlight()
    /// iPhone: the profile menu opened by long-pressing My Library.
    @State private var libraryProfileMenu = false
    #if DEBUG
    /// Screenshots: `-edit-profile <name>` opens that profile's editor.
    @State private var reviewEditor: Profile?
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(\.openSettings) private var openSettingsWindow
    @AppStorage("bluebox.settingsPage") private var settingsPage: SettingsPage = .account
    #endif

    public init() {}

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    public var body: some View {
        @Bindable var app = app
        Group {
            #if os(iOS)
            if sizeClass == .compact { compactTabs } else { topNavLayout }
            #else
            topNavLayout
            #endif
        }
        .tint(Palette.brand)
        .listEditorHost()
        .blueboxMenuHost()
        .environment(\.profileSwitchFlight, flight)
        .environment(\.isDownloaded, DownloadedLookup(revision: app.completedDownloadKeys.hashValue) { [app] key in app.hasFinishedDownload(key) })
        .environment(\.showProfilePicker, ProfilePickerAction {
            profilePickerIsGate = false
            pickerPIN = nil
            withAnimation(Motion.standard(reduceMotion)) { showsProfilePicker = true }
        })
        .environment(\.openSettingsPage, OpenSettingsPageAction { route in openSettings(route: route) })
        .environment(\.notePlayOrigin, NotePlayOriginAction { pendingPlayOrigin = $0 })
        .environment(\.searchFocusRequest, searchFocusRequest)
        .environment(\.selectTab, SelectTabAction { new in
            tab = new
            normalizeTab(compact: isCompact)
        })
        .overlay {
            if showsProfilePicker {
                ProfilePickerView(canClose: !profilePickerIsGate, pinFor: pickerPIN,
                                  onDone: {
                                      withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .easeOut(duration: 0.28)) {
                                          showsProfilePicker = false
                                      }
                                  },
                                  manage: manageProfiles, addProfile: addProfileFromPicker)
                    .environment(\.profileSwitchFlight, flight)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .overlay { ProfileFlightLayer(flight: flight).zIndex(3) }
        .onChange(of: app.profilePickerRequest) {
            profilePickerIsGate = false
            pickerPIN = nil
            withAnimation(Motion.standard(reduceMotion)) { showsProfilePicker = true }
        }
        // ⌃⌘1–4, the Profiles menu and the profile menu's avatars: locked
        // profiles ask for their PIN in the picker; the rest switch in place.
        .onChange(of: app.profileSwitchRequest) { _, request in
            guard let request else { return }
            app.profileSwitchRequest = nil
            if app.isLocked(request.profileID) {
                profilePickerIsGate = false
                pickerPIN = request.profileID
                withAnimation(Motion.standard(reduceMotion)) { showsProfilePicker = true }
            } else {
                Task { await flight.rebuild(reduceMotion: reduceMotion) { await app.switchProfile(to: request.profileID) } }
            }
        }
        .task {
            // Like Netflix, ask who's watching at launch, but only when there's a choice.
            guard !checkedProfilesAtLaunch else { return }
            checkedProfilesAtLaunch = true
            let args = ProcessInfo.processInfo.arguments
            let several = app.profiles.filter { !$0.isRemoved }.count > 1
            if (several && !args.contains("-ui-testing")) || args.contains("-profile-picker") {
                profilePickerIsGate = true
                #if DEBUG
                // Screenshots: `-review-pin Sam` opens on Sam's PIN.
                if let name = AppModel.reviewValue("-review-pin") { pickerPIN = app.profiles.first { $0.name == name }?.id }
                #endif
                showsProfilePicker = true
            }
        }
        #if os(iOS)
        .overlay { launchLayer }
        #endif
        .onChange(of: app.preparingItem?.key) { _, key in preparingChanged(key) }
        .onChange(of: app.activePlayer == nil) { _, closed in if !closed { playerArrived() } }
        .task(id: app.sourcesRevision) { await loadSources() }
        .task(id: app.currentProfileID) { restoreTab() }
        #if DEBUG
        .task { await openForReview() }
        #endif
        .onChange(of: tab) { _, t in ViewMemory.set(t.memoryValue, "tab", profile: app.currentProfileID) }
        .task { PlaybackEngines.prewarm() }  // libVLC's first setup is slow; do it before Play
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await app.syncAll() } }
            if phase == .background { app.lockSettings() }  // a restricted profile's Settings asks for the PIN again
            app.account.setInForeground(phase == .active)
        }
        .task { app.account.setInForeground(scenePhase == .active) }
        #if os(macOS)
        // The Mac's "background": another app in front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in app.lockSettings() }
        #endif
        // MARK: Remote and menu bar hooks (RemoteControlViews.swift, MenuBarDownloads.swift)
        .modifier(RemoteControlHost())
        .onChange(of: app.downloadsOpenRequest) { tab = .downloads }
        // MARK: end
        .preferredColorScheme(.dark)
        // A tapped new-episode alert: show that title (and episode) on the current tab.
        .task(id: app.features.openRequest?.id) { openRequested() }
        // The remote asked to go somewhere (Home, Search, a title, back).
        .task(id: app.remoteNavigation?.id) { await remoteNavigated() }
        // What the remote's touch pad shows as this Mac's page.
        .onChange(of: remotePageTitle, initial: true) { _, title in app.remoteFocus.screenTitle = title }
        // My List or Search from a widget, Spotlight or Siri.
        .task(id: app.features.tabRequest?.id) { tabRequested() }
        // A connect link from another device: Settings › Account, to sign in.
        .task(id: app.account.openRequest) {
            guard app.account.openRequest != nil else { return }
            app.account.openRequest = nil
            openSettings(.account)
        }
        #if os(iOS)
        .sheet(isPresented: settingsPresented) { SettingsView(target: settingsTarget) }
        .fullScreenCover(isPresented: playerPresented) {
            if let session = app.activePlayer {
                // Through the launch surface: the video fades in over its darkened art.
                PlayerView(session: session)
                    .modifier(PlayerLaunchFadeIn(launchArtwork: playLaunch.map(\.artwork)))
            }
        }
        #else
        // The library stays alive underneath (keeping navigation state) but is
        // hidden from input and VoiceOver while the player replaces it.
        .opacity(app.activePlayer == nil ? 1 : 0)
        .allowsHitTesting(app.activePlayer == nil)
        .accessibilityHidden(app.activePlayer != nil)
        .modifier(UnifiedTitlebar(hidden: app.activePlayer != nil))
        .modifier(MacPlayerHost(session: app.activePlayer) { launchLayer })
        #endif
        // Releases… from an alert (a debrid link that led to a notice clip).
        .sheet(item: $app.releasePickerRequest) { request in ReleasePickerSheet(item: request.item, canOpenSettings: true) }
        // A magnet, .torrent or video opened from outside: one sheet with Play.
        .modifier(ExternalOpenPresenter())
        // Join a Party…, and a party being joined before its player opens (WatchPartyViews.swift).
        .modifier(PartyHost())
        #if os(macOS)
        // Drop a magnet, .torrent, video or folder anywhere on the window.
        .modifier(ExternalDropTarget())
        #endif
        // File › Open… (⌘O) and My Sources' Open Files…: videos, folders and .torrent files.
        .openFilesImporter(isPresented: Bindable(app).pickingFiles)
        // Last, so on Mac the dialog draws over the player too.
        .modifier(AppAlertPresenter(isFrontmost: alertsShowHere))
        #if DEBUG
        .task { applyDebugLaunchStates() }
        .task {
            guard let name = AppModel.reviewValue("-edit-profile") else { return }
            try? await Task.sleep(for: .seconds(1.5))
            reviewEditor = app.profiles.first { $0.name == name }
        }
        .sheet(item: $reviewEditor) { p in ProfileEditorSheet(profile: p).environment(app) }
        #endif
    }

    #if DEBUG
    /// Screenshots and design review: `-simulate-offline` shows every offline
    /// state; `-open-external-sample` shows the sheet a dropped magnet opens.
    private func applyDebugLaunchStates() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-ui-testing") else { return }
        if args.contains("-simulate-offline") { app.settings.simulateNetwork(.init(isOnline: false)) }
        if args.contains("-open-external-sample") {
            let variant = MediaVariant(id: "sample:0", sourceID: SourceID("torrents"), mediaKey: .movie(tmdbID: 133701),
                                       displayName: "Tears.of.Steel.2012.1080p.mkv", container: "mkv", resolution: "1080p",
                                       sizeBytes: 1_288_490_189, location: .remote)
            Task {
                let title = await app.title(for: .movie(tmdbID: 133701))
                app.externalOpen = ExternalOpenState(source: "Opened from a magnet link", phase: .ready(title: title, variant: variant))
            }
        }
    }
    #endif

    /// Opens `app.features.openRequest` (set when a notification is tapped) on
    /// the current tab, then clears it. Closes the player, which covers the library.
    private func openRequested() {
        guard let request = app.features.openRequest else { return }
        app.features.openRequest = nil
        if tab == .search || tab == .downloads { tab = .home }
        let route: Route = request.episode.map { .episode(request.title, $0) } ?? .title(request.title)
        paths[tab, default: []].append(route)
        if app.activePlayer != nil { Task { await app.closePlayer() } }
    }

    /// Goes to `app.features.tabRequest`'s tab, at its first page; Search
    /// takes the query along (`SearchView` reads `searchRequest`).
    private func tabRequested() {
        guard let request = app.features.tabRequest else { return }
        app.features.tabRequest = nil
        if let query = request.search { app.features.searchRequest = query }
        tab = request.tab
        normalizeTab(compact: isCompact)
        paths[tab] = []
    }

    /// Carries out `app.remoteNavigation`, then clears it. Going anywhere but
    /// back closes the player, as a tapped alert does; back closes it too, or
    /// leaves the current page.
    private func remoteNavigated() async {
        guard let request = app.remoteNavigation else { return }
        app.remoteNavigation = nil
        if app.activePlayer != nil {
            await app.closePlayer()
            if request.destination == .back { return }
        }
        switch request.destination {
        case .home:
            tab = .home
            paths[.home] = []
        case .search(let query):
            tab = .search
            paths[.search] = []
            app.remoteSearchText = query
        case .title(let key):
            guard let title = await app.title(for: key) else { return }
            if tab == .search || tab == .downloads { tab = .home }
            if case .title(let shown) = paths[tab]?.last, shown.key == title.key { return }
            paths[tab, default: []].append(.title(title))
        case .back:
            if !(paths[tab] ?? []).isEmpty { paths[tab]?.removeLast() }
        }
    }

    /// "Home", "Search", or the title open on the current tab.
    private var remotePageTitle: String {
        if case .title(let t) = paths[tab]?.last { return t.name }
        if case .episode(let t, _) = paths[tab]?.last { return t.name }
        return switch tab {
        case .search: String(localized: "Search")
        case .downloads: String(localized: "Downloads")
        case .home: String(localized: "Home")
        default: String(localized: "Library")
        }
    }

    /// Shows the debrid library on the current tab (from Search or Downloads, on My List).
    private func openDebridLibrary() {
        if tab == .search || tab == .downloads { tab = .myList }
        if paths[tab]?.last != .debridLibrary { paths[tab, default: []].append(.debridLibrary) }
    }

    /// iOS: alerts go on Settings while its sheet is up (a covered view can't
    /// present). Mac: each window shows them only while it's key (see `AppAlertPresenter`).
    private var alertsShowHere: Bool {
        #if os(iOS)
        settingsTarget == nil
        #else
        true
        #endif
    }

    /// From "Who's watching?": Settings › Profiles over the picker; closing
    /// Settings returns to the picker.
    private func manageProfiles() { openSettings(.profiles) }

    /// iPhone and iPad: the picker's Add Profile pushes inside Settings, like
    /// every other profile edit. The Mac keeps its sheet over the picker.
    private var addProfileFromPicker: (() -> Void)? {
        #if os(iOS)
        { openSettings(route: .newProfile) }
        #else
        nil
        #endif
    }

    private func openSettings(_ page: SettingsPage?) { openSettings(route: page.map(SettingsRoute.page)) }

    /// The one way into Settings. iOS: one sheet; asked again while it's up,
    /// it moves to the route in place. Mac: the Settings window at the category.
    private func openSettings(route: SettingsRoute?) {
        #if os(macOS)
        if let route { settingsPage = route.category }
        openSettingsWindow()
        #else
        if settingsTarget != nil, route == nil { return }  // already open; stay where it is
        settingsTarget = SettingsTarget(route: route)
        #endif
    }

    #if os(iOS)
    private var settingsPresented: Binding<Bool> {
        Binding(get: { settingsTarget != nil }, set: { if !$0 { settingsTarget = nil } })
    }
    #endif

    // MARK: Play → player

    /// The artwork growing into the player, and the add-on overlay over it.
    /// iOS: over the window. Mac: between the library and the player, so the
    /// player fades in over it while the library is hidden.
    @ViewBuilder private var launchLayer: some View {
        ZStack {
            if let origin = playLaunch {
                PlayLaunchSurface(origin: origin, title: app.preparingItem?.title,
                                  showsStatus: app.addonStatus == nil, cancel: { app.cancelPreparing() })
                    .transition(.asymmetric(insertion: reduceMotion ? .opacity : .identity, removal: .opacity))
            }
            if let status = app.addonStatus, app.activePlayer == nil {
                StreamPreparingOverlay(status: status) { app.cancelPreparing() }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.addonStatus == nil)
    }

    /// Play reached the preparing step: if it was pressed on artwork a moment
    /// ago, that artwork becomes the surface. Back to nil without a player
    /// (failed, cancelled): the surface fades away and the page is as it was.
    private func preparingChanged(_ key: MediaKey?) {
        if let key {
            guard let origin = pendingPlayOrigin, origin.key == key, origin.isFresh, app.activePlayer == nil else { return }
            pendingPlayOrigin = nil
            PlayerPresentation.launchSurfaceIsUp = true
            withAnimation(.easeInOut(duration: 0.2)) { playLaunch = origin }
        } else if playLaunch != nil, app.activePlayer == nil {
            endPlayLaunch()
        }
    }

    /// The player is up (over the surface on iOS, fading in over it on Mac):
    /// the surface goes once it's covered.
    private func playerArrived() {
        pendingPlayOrigin = nil
        guard playLaunch != nil else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            endPlayLaunch()
        }
    }

    private func endPlayLaunch() {
        PlayerPresentation.launchSurfaceIsUp = false
        withAnimation(.easeOut(duration: 0.25)) { playLaunch = nil }
    }

    /// iPhone: three tabs plus search, which iOS draws as its own button.
    private var compactTabs: some View {
        TabView(selection: tabBarSelection) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                stack(.home) {
                    HomeView(category: homeCategory)
                        .safeAreaInset(edge: .top, spacing: 0) {
                            CompactHomeHeader(category: $homeCategory, openSettings: openSettings)
                        }
                }
                .modifier(TabBarScrim())
            }
            Tab("New & Hot", systemImage: "play.rectangle.on.rectangle.fill", value: AppTab.newHot) {
                stack(.newHot) { NewHotView() }.modifier(TabBarScrim())
            }
            Tab("My Library", systemImage: "rectangle.stack.fill", value: AppTab.library) {
                stack(.library) { LibraryView() }.modifier(TabBarScrim())
            }
            Tab("Downloads", systemImage: "arrow.down.circle.fill", value: AppTab.downloads) {
                stack(.downloads) { DownloadsView() }.modifier(TabBarScrim())
            }
            .badge(activeDownloads)
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                stack(.search) { SearchView() }.modifier(TabBarScrim())
            }
        }
        .onAppear { normalizeTab(compact: true) }
        #if os(iOS)
        // Long-press My Library: the profile menu, from any tab.
        .background(TabBarLongPress(tabIndex: 2) { libraryProfileMenu = true })
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                // An anchor just above the tab bar's My Library item, for the menu to open from.
                Color.clear
                    .frame(width: 1, height: 1)
                    .position(x: geo.size.width * 0.62, y: geo.size.height - 4)
                    .profileMenu(isPresented: $libraryProfileMenu, openSettings: openSettings)
            }
            .allowsHitTesting(false)
        }
        #endif
    }

    /// iPad and Mac: one page at a time under the top bar. Every tab opened
    /// so far stays alive underneath (its path, scroll position and loaded
    /// rows), as iPhone's tab bar keeps them, and switching is a 0.12 s fade.
    /// Hidden tabs take no input or keyboard shortcuts, are hidden from
    /// VoiceOver, and are told they're hidden (`isTabVisible`).
    private var topNavLayout: some View {
        ZStack {
            ForEach(visitedTabs, id: \.self) { t in
                let visible = t == tab
                stack(t) { page(for: t) }
                    // Only the fade is animated, not whatever else the switch changes inside.
                    .animation(.easeInOut(duration: 0.12)) { $0.opacity(visible ? 1 : 0) }
                    .allowsHitTesting(visible)
                    .disabled(!visible)  // its keyboard shortcuts (⌘L, Return to play) too
                    .accessibilityHidden(!visible)
                    .environment(\.isTabVisible, visible)
                    .zIndex(visible ? 1 : 0)
                    .transition(.opacity)
            }
        }
        #if os(iOS)
        // iPad: a safe-area inset outside the NavigationStack doesn't reach
        // its pages reliably (they started under the bar, or 40 pt below
        // it), so the bar floats over the stack and each page reserves its
        // height itself (`TopNavPageChrome`).
        .overlay(alignment: .top) { topNavBar }
        #else
        .safeAreaInset(edge: .top, spacing: 0) { topNavBar }
        #endif
        .environment(\.usesTopNav, true)
        .onChange(of: tab, initial: true) { _, t in
            if !visitedTabs.contains(t) {
                withAnimation(.easeInOut(duration: 0.12)) { visitedTabs.append(t) }
            }
            // Focus would stay behind in the hidden tab (typing would go to its search field).
            if t != .search { resignFocus() }
        }
        .onAppear { normalizeTab(compact: false) }
        #if os(macOS)
        .ignoresSafeArea(edges: .top)
        #endif
    }

    private var topNavBar: some View {
        TopNavBar(tab: $tab, scrolled: topBarScrolled[tab]?[paths[tab]?.count ?? 0] ?? false,
                  sources: sources, downloads: activeDownloads,
                  canGoBack: !(paths[tab] ?? []).isEmpty,
                  back: { paths[tab]?.removeLast() },
                  debridLibraryName: app.debridLibraryName,
                  openDebridLibrary: openDebridLibrary,
                  openSettings: openSettings,
                  chose: { t, again in tabChosen(t, again: again) })
    }

    /// iPhone's tab bar. Its setter also runs when the selected tab is tapped
    /// again, which a plain `$tab` binding can't tell apart.
    private var tabBarSelection: Binding<AppTab> {
        Binding(get: { tab }, set: { new in
            let again = new == tab
            if !again { tab = new }
            tabChosen(new, again: again)
        })
    }

    /// A tab chosen from the tab bar, the top bar or ⌘F. As in iOS, choosing
    /// the tab you're on goes back to its first page. Search always opens on
    /// its field: coming back to it doesn't leave you on a title you opened
    /// from the results (the query and results are kept), and choosing it
    /// again focuses the field.
    private func tabChosen(_ chosen: AppTab, again: Bool) {
        if chosen == .search {
            if !(paths[.search] ?? []).isEmpty { paths[.search] = [] }
            if again || !isCompact { searchFocusRequest += 1 }
        } else if again, !(paths[chosen] ?? []).isEmpty {
            paths[chosen] = []
        }
    }

    /// Maps a tab to its nearest equivalent in the other layout: items that
    /// only exist in the top bar fold into My Library on iPhone, and back.
    private func normalizeTab(compact: Bool) {
        if compact {
            switch tab {
            case .myList, .watching, .source: tab = .library
            case .shows: tab = .home; homeCategory = .series
            case .movies: tab = .home; homeCategory = .movies
            default: break
            }
        } else {
            if tab == .library { tab = .myList }
            if tab == .home && homeCategory != .all {
                tab = homeCategory == .series ? .shows : .movies
                homeCategory = .all
            }
        }
    }

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    #if DEBUG
    /// Screenshots: `-open-tab <tab>` (downloads, home…) and `-open-title <media key>`
    /// (e.g. tmdb:tv:9100001) land on a page at launch. Debug builds only.
    private func openForReview() async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        try? await Task.sleep(for: .milliseconds(300))
        if let t = value("-open-tab").flatMap(AppTab.init(memoryValue:)) { tab = t }
        if let raw = value("-open-title"), let title = await app.title(for: MediaKey(rawValue: raw)) {
            paths[tab, default: []].append(.title(title))
        }
        if args.contains("-demo-debrid"), app.debridLibraryName == nil {
            // Screenshots: a placeholder Real-Debrid setup, so the library's entries show.
            var settings = app.addonSettings
            settings.debrid = .realDebrid
            app.setAddonSettings(settings)
            app.setDebridKey("demo-key-for-screenshots")
        }
        if args.contains("-open-debrid-library") { openDebridLibrary() }
        if let raw = value("-open-settings") { openSettings(SettingsPage(rawValue: raw)) }
        if args.contains("-show-alert") {
            // Screenshots: the Bluebox alert, with Try Again.
            try? await Task.sleep(for: .seconds(1))
            app.alert = AppAlert(title: "Not available to play",
                                 message: "None of your sources has “Inception”. Add a folder, a direct link, or a media server in Settings.",
                                 retry: {})
        }
    }
    #endif

    /// Returns each profile to the tab it was last on.
    private func restoreTab() {
        guard let saved = ViewMemory.string("tab", profile: app.currentProfileID),
              let restored = AppTab(memoryValue: saved), restored != tab else { return }
        tab = restored
        normalizeTab(compact: isCompact)
    }

    @ViewBuilder private func page(for tab: AppTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .shows: HomeView(category: .series)
        case .movies: HomeView(category: .movies)
        case .newHot: NewHotView()
        case .search: SearchView()
        case .library, .myList: LibraryView(section: .myList, fixed: true)
        case .watching: LibraryView(section: .watching, fixed: true)
        case .downloads: DownloadsView()
        case .source(let id): LibraryView(source: id, sourceName: sources.first { $0.id == id }?.name)
        }
    }

    private var activeDownloads: Int { app.activeDownloadCount }

    private func loadSources() async {
        var out: [SidebarSource] = []
        for s in await app.registry.all()
        where s.kind != .downloads && s.capabilities.contains(.browse) && s.id != SidebarSource.debridLibraryID {
            out.append(SidebarSource(id: s.id, name: s.displayName, kind: s.kind))
        }
        sources = out
        if case .source(let id) = tab, !out.contains(where: { $0.id == id }) { tab = .home }
        // A removed source's page goes with it.
        visitedTabs.removeAll { if case .source(let id) = $0 { !out.contains { $0.id == id } } else { false } }
    }

    /// Ends editing in whatever has focus (a hidden tab's search field).
    private func resignFocus() {
        #if os(macOS)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #else
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private var playerPresented: Binding<Bool> {
        Binding(get: { app.activePlayer != nil }, set: { presented in
            if !presented { Task { await app.closePlayer() } }
        })
    }

    private func path(_ tab: AppTab) -> Binding<[Route]> {
        Binding(get: { paths[tab] ?? [] }, set: { paths[tab] = $0 })
    }

    private func stack<Content: View>(_ tab: AppTab, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack(path: path(tab)) {
            content()
                // Home rebuilds under a switch: the page fades out and back in.
                .opacity(flight.contentHidden ? 0 : 1)
                .modifier(CompactProfileButton(enabled: tab != .home, openSettings: openSettings))
                .modifier(PageChrome(depth: 0))
                .navigationDestination(for: Route.self) { route in
                    let depth = (paths[tab]?.lastIndex(of: route) ?? 0) + 1
                    RouteDestination(route: route)
                        .modifier(PageChrome(depth: depth))
                        .modifier(PushTransition(sourceID: zoomSources[tab]?[depth], namespace: zoomNamespace))
                }
        }
        .environment(\.pushRoute, PushRouteAction { route, zoomFrom in
            paths[tab, default: []].append(route)
            zoomSources[tab, default: [:]][paths[tab]?.count ?? 0] = zoomFrom
        })
        .environment(\.reportTopBarScroll, TopBarScrollReport { depth, scrolled in
            if topBarScrolled[tab]?[depth] != scrolled { topBarScrolled[tab, default: [:]][depth] = scrolled }
        })
        .onChange(of: paths[tab]?.count ?? 0) { _, depth in
            // Pages popped off the path take their state with them.
            topBarScrolled[tab] = topBarScrolled[tab]?.filter { $0.key <= depth }
            zoomSources[tab] = zoomSources[tab]?.filter { $0.key <= depth }
        }
        #if os(iOS)
        .environment(\.zoomNamespace, zoomNamespace)
        #endif
    }
}

/// Every page in a tab's stack. Owns the page's "scrolled under the bar"
/// state (`headerScrolled`), so each page keeps its own: coming back to a
/// scrolled Home keeps its header solid.
///
/// iPhone: the navigation bar is transparent at the top and solid chrome once
/// the page scrolls. Under the top bar (iPad, Mac) the navigation bar is
/// hidden and the top bar, which has the back button, follows the visible
/// page. On Mac the stack would otherwise put its own glass back button in
/// the window toolbar, beside the traffic lights and under Bluebox's.
private struct PageChrome: ViewModifier {
    /// Position in the tab's navigation path (0 is the tab's root page).
    let depth: Int
    @Environment(\.usesTopNav) private var usesTopNav
    @Environment(\.reportTopBarScroll) private var reportTopBarScroll
    @State private var scrolled = false

    func body(content: Content) -> some View {
        chrome(content)
            .environment(\.headerScrolled, $scrolled)
            .onChange(of: scrolled) { _, now in if usesTopNav { reportTopBarScroll(depth: depth, scrolled: now) } }
            .onAppear { if usesTopNav { reportTopBarScroll(depth: depth, scrolled: scrolled) } }
    }

    @ViewBuilder private func chrome(_ content: Content) -> some View {
        #if os(iOS)
        if usesTopNav {
            // Room for the floating top bar (see `RootView.topNavLayout`). Pages
            // that ignore the top safe area (Home, title pages) still run under it.
            content
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: TopNavBar.barHeight).allowsHitTesting(false) }
        } else {
            content.scrolledNavigationBar(scrolled)
        }
        #else
        content
            .navigationBarBackButtonHidden(true)
            .toolbar(removing: .title)
        #endif
    }
}

/// iPhone: a black fade behind the floating tab bar (iOS 26 and later), so
/// artwork scrolling under it doesn't show through its glass. The floating
/// bar doesn't count as safe area, so the fade reaches above the home
/// indicator by the bar's height. Earlier systems draw their own bar background.
private struct TabBarScrim: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.overlay(alignment: .bottom) {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.7), location: 0.35),
                                       .init(color: .black.opacity(0.95), location: 0.6), .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 84)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}

/// A pushed page's entrance. iOS: the zoom out of the card that was tapped
/// (`TitleCardLink`), shrinking back into it on the way out; the standard
/// push otherwise. Mac, which has no zoom transition: a quick fade and scale
/// up (Reduce Motion: the fade alone).
private struct PushTransition: ViewModifier {
    let sourceID: AnyHashable?
    let namespace: Namespace.ID
    #if os(macOS)
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        if let sourceID {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
        #else
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.97)
            .onAppear {
                guard !shown else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.25)) { shown = true }
            }
        #endif
    }
}

#if os(macOS)
/// Puts the player beside (not on top of) the library in a ZStack, with the
/// launch surface between them.
private struct MacPlayerHost<Launch: View>: ViewModifier {
    let session: PlayerSession?
    @ViewBuilder let launch: () -> Launch
    func body(content: Content) -> some View {
        ZStack {
            content
            launch().zIndex(0.5)
            if let session {
                PlayerView(session: session)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session != nil)
    }
}
#endif

/// Who's watching, plus Settings. Switch profiles from any screen: a row of
/// avatars at the top (one click switches; ⌃⌘1–4 on Mac), then Manage
/// Profiles and Settings, and any sync problem with its fix.
struct ProfileMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.profileSwitchFlight) private var flight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat = 26
    var showsChevron = false
    let openSettings: (SettingsPage?) -> Void
    @State private var isPresented = false
    private var updater: AppUpdater { .shared }

    var body: some View {
        let current = app.currentProfile
        let issues = app.syncIssues
        Button { isPresented.toggle() } label: {
            HStack(spacing: 6) {
                // Rounded square, like Netflix's profile icons (the picker uses the same shape).
                ProfileBadge(symbol: current.symbol, color: current.color, size: size)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).strokeBorder(.white.opacity(0.15)))
                    // Where the switch animation's avatar lands. Hidden while it flies in.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        if frame.width > 0 { flight?.slot = frame }
                    }
                    .opacity(flight?.flight == nil ? 1 : 0)
                    .overlay(alignment: .topTrailing) {
                        if !issues.isEmpty {
                            // Amber: sync has stopped. The menu says why.
                            Circle().fill(Palette.caution)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(Palette.chrome, lineWidth: 2).padding(-2))
                                .offset(x: 3, y: -3)
                                .transition(Motion.pop(reduceMotion, scale: 0.3))
                                .accessibilityIdentifier("syncDot")
                        } else if updater.hasUnseenUpdate {
                            // Blue: a new Bluebox the daily check found. The menu says which.
                            Circle().fill(Palette.brand)
                                .frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(Palette.chrome, lineWidth: 2).padding(-2))
                                .offset(x: 3, y: -3)
                                .transition(Motion.pop(reduceMotion, scale: 0.3))
                                .accessibilityIdentifier("updateDot")
                        }
                    }
                    // The dot pops in when sync stops or an update turns up, rather than appearing mid-frame.
                    .animation(Motion.snappy(reduceMotion), value: issues.isEmpty)
                    .animation(Motion.snappy(reduceMotion), value: updater.hasUnseenUpdate)
                if showsChevron {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(ProfileMenuTriggerStyle(isOpen: isPresented))
        .profileMenu(isPresented: $isPresented, openSettings: openSettings)
        .fixedSize()
        .accessibilityLabel(!issues.isEmpty ? "Profile: \(current.name), sync has stopped"
                            : updater.hasUnseenUpdate ? "Profile: \(current.name), an update is available" : "Profile: \(current.name)")
        .accessibilityHint("Switch who's watching or open Settings")
        .accessibilityIdentifier("profileMenu")
        #if DEBUG
        .task {
            // Screenshots: `-open-profile-menu` opens it once Home has loaded.
            guard AppModel.reviewArguments.contains("-open-profile-menu") else { return }
            try? await Task.sleep(for: .seconds(2))
            isPresented = true
        }
        #endif
    }
}

/// Dims the avatar while pressed or while its menu is open (as `BlueboxMenu` does).
private struct ProfileMenuTriggerStyle: ButtonStyle {
    let isOpen: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : isOpen ? 0.8 : 1)
            #if os(iOS)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            #endif
            .animation(Motion.press, value: configuration.isPressed)
    }
}

extension View {
    /// The profile menu's panel, anchored to this view.
    func profileMenu(isPresented: Binding<Bool>, openSettings: @escaping (SettingsPage?) -> Void) -> some View {
        modifier(ProfileMenuPanel(isPresented: isPresented, openSettings: openSettings))
    }
}

private struct ProfileMenuPanel: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.showProfilePicker) private var showProfilePicker
    @Binding var isPresented: Bool
    let openSettings: (SettingsPage?) -> Void

    func body(content: Content) -> some View {
        content.blueboxMenu(isPresented: $isPresented, title: "Profile") { [app] in
            let current = app.currentProfile
            let profiles = app.profiles.filter { !$0.isRemoved }
            // Sync that stopped: what's wrong, since when, and the one fix.
            for issue in app.syncIssues {
                BlueboxMenuAlertBlock(BlueboxMenuAlert(
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath", title: issue.title, message: issue.message,
                    actionTitle: issue.fixTitle, action: { app.fix(issue, openSettings: openSettings) }))
            }
            // A new Bluebox the daily check found, until About has shown it.
            if let update = AppUpdater.shared.update, AppUpdater.shared.hasUnseenUpdate {
                BlueboxMenuSection {
                    BlueboxMenuButton("Bluebox \(update.version) Is Available", systemImage: "arrow.down.circle") { openSettings(.about) }
                }
            }
            if profiles.count > 1 {
                BlueboxMenuAvatarRow(profiles.prefix(5).map { p in
                    BlueboxMenuAvatar(id: p.id, title: p.name, symbol: p.symbol, color: Palette.profileColor(p.color),
                                      isCurrent: p.id == current.id, isLocked: app.isLocked(p.id),
                                      shortcut: ProfileShortcuts.digit(for: p.id, in: profiles).map { "⌃⌘\($0)" }) {
                        app.requestProfileSwitch(to: p.id)
                    }
                })
            }
            BlueboxMenuSection {
                if app.party != nil {
                    BlueboxMenuButton("Leave Party", systemImage: "rectangle.portrait.and.arrow.right") { Task { await app.leaveParty() } }
                } else {
                    #if os(macOS)
                    BlueboxMenuButton("Join a Party…", systemImage: "person.2.fill", shortcut: "⇧⌘J") { app.partyJoin = PartyJoinRequest() }
                    #else
                    BlueboxMenuButton("Join a Party", systemImage: "person.2.fill") { app.partyJoin = PartyJoinRequest() }
                    #endif
                }
            }
            BlueboxMenuSection {
                if profiles.count > 1 {
                    BlueboxMenuButton("Who's Watching?", systemImage: "person.2.crop.square.stack") { showProfilePicker() }
                }
                // Mac: the ellipsis says it opens a window. iOS: it only navigates.
                #if os(macOS)
                BlueboxMenuButton("Manage Profiles…", systemImage: "pencil") { openSettings(.profiles) }
                if app.featureSwitches.statistics {
                    BlueboxMenuButton("My Bluebox…", systemImage: "chart.bar") { openSettings(.statistics) }
                }
                BlueboxMenuButton("Account", systemImage: "person.crop.circle") { openSettings(.account) }
                BlueboxMenuButton("Settings…", systemImage: "gearshape", shortcut: "⌘,") { openSettings(nil) }
                #else
                BlueboxMenuButton("Manage Profiles", systemImage: "pencil") { openSettings(.profiles) }
                if app.featureSwitches.statistics {
                    BlueboxMenuButton("My Bluebox", systemImage: "chart.bar") { openSettings(.statistics) }
                }
                BlueboxMenuButton("Account", systemImage: "person.crop.circle") { openSettings(.account) }
                BlueboxMenuButton("Settings", systemImage: "gearshape") { openSettings(nil) }
                #endif
            }
            BlueboxMenuNote(Self.syncStatus(app, profiles: profiles.count))
        }
    }

    static func syncStatus(_ app: AppModel, profiles: Int) -> String {
        let status: String
        if !app.account.isSignedIn {
            status = "Library on this device"
        } else {
            switch app.account.status {
            case .syncing: status = "Syncing…"
            case .synced(let d): status = "Synced \(d.formatted(.relative(presentation: .named)))"
            case .failed: status = "Sync paused"
            case .idle: status = "Signed in"
            }
        }
        #if os(macOS)
        if profiles > 1 { return status + " · ⌃⌘1–\(min(profiles, ProfileShortcuts.count)) to switch" }
        #endif
        return status
    }
}

/// On iPhone pages other than Home, the profile button sits in the navigation bar.
private struct CompactProfileButton: ViewModifier {
    /// Off for Home, whose header has its own profile button.
    let enabled: Bool
    let openSettings: (SettingsPage?) -> Void
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        if sizeClass == .compact && enabled {
            content.toolbar {
                // Its own item, not merged into one glass capsule with the
                // page's buttons (Downloads' ⋯): the avatar is its own background.
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .primaryAction) { ProfileMenu(openSettings: openSettings) }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) { ProfileMenu(openSettings: openSettings) }
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Shows `AppModel.alert`, with Try Again when the alert has a retry. Both the
/// main window and Settings carry one; only the frontmost shows it: on Mac the
/// key window (so an alert raised while Settings is in front appears there,
/// not behind it), on iOS whichever is on top.
struct AppAlertPresenter: ViewModifier {
    @Environment(AppModel.self) private var app
    var isFrontmost = true
    #if os(macOS)
    @Environment(\.controlActiveState) private var activeState
    private var shows: Bool { isFrontmost && activeState == .key }
    #else
    private var shows: Bool { isFrontmost }
    #endif

    func body(content: Content) -> some View {
        let shown = shows ? app.alert : nil
        content
            .overlay {
                if let shown {
                    AppAlertDialog(alert: shown) { app.alert = nil }
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .animation(Motion.appear, value: shown)
    }
}

/// Bluebox's own alert: a solid black card over a dimmed page, a heavy
/// title, the message in grey, and OK (with Try Again, in white, when the
/// alert can retry), or the alert's own buttons, stacked. Return picks the
/// white button, Esc is OK (or Cancel).
struct AppAlertDialog: View {
    let alert: AppAlert
    let dismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.66)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}  // blocks the page underneath
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xl) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(ui: alert.title)
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(ui: alert.message)
                        .font(.callout)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous).strokeBorder(Palette.edge))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
            .padding(Spacing.xl)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("appAlert")
    }

    @ViewBuilder private var buttons: some View {
        if alert.actions.contains(where: { $0.role != nil }) {
            // A decision: only its own buttons.
            VStack(spacing: Spacing.s) {
                ForEach(alert.actions.indices, id: \.self) { i in
                    decisionButton(alert.actions[i])
                }
            }
            .accessibilityIdentifier("appAlertButtons")
        } else if !alert.actions.isEmpty {
            VStack(spacing: Spacing.s) {
                ForEach(alert.actions.indices, id: \.self) { i in
                    let action = alert.actions[i]
                    if i == 0 {
                        Button { dismiss(); action.perform() } label: { Text(ui: action.title) }
                            .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button { dismiss(); action.perform() } label: { Text(ui: action.title) }
                            .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    }
                }
                Button("OK") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    .keyboardShortcut(.cancelAction)
            }
            .accessibilityIdentifier("appAlertButtons")
        } else {
            plainButtons
        }
    }

    @ViewBuilder private func decisionButton(_ action: AppAlert.Action) -> some View {
        switch action.role {
        case .primary:
            Button { dismiss(); action.perform() } label: { Text(ui: action.title) }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .keyboardShortcut(.defaultAction)
        case .cancel:
            Button { dismiss(); action.perform() } label: { Text(ui: action.title) }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                .keyboardShortcut(.cancelAction)
        case .secondary, nil:
            Button { dismiss(); action.perform() } label: { Text(ui: action.title) }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))
        }
    }

    @ViewBuilder private var plainButtons: some View {
        HStack(spacing: Spacing.s) {
            if let retry = alert.retry {
                Button("OK") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { dismiss(); retry() }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("appAlertRetry")
            } else {
                Button("OK") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                    .keyboardShortcut(.defaultAction)
                    .background {
                        Button("Close") { dismiss() }  // Esc closes it too
                            .keyboardShortcut(.cancelAction)
                            .opacity(0).accessibilityHidden(true)
                    }
            }
        }
        .accessibilityIdentifier("appAlertButtons")
    }
}

extension EnvironmentValues {
    /// Shows the full-screen "Who's watching?" picker.
    @Entry var showProfilePicker = ProfilePickerAction {}
}

/// Opens "Who's watching?". Always equal, so storing it doesn't invalidate readers.
struct ProfilePickerAction: Equatable {
    let action: @MainActor () -> Void
    @MainActor func callAsFunction() { action() }
    static func == (a: Self, b: Self) -> Bool { true }
}

#if os(iOS)
import UIKit

/// iPhone: a long press on one of the tab bar's items (My Library opens the
/// profile menu). SwiftUI's `Tab` takes no gestures, so this finds the
/// hosting tab bar controller and adds a recogniser to its bar.
private struct TabBarLongPress: UIViewRepresentable {
    /// Which item, counting from the leading edge (Search, drawn apart on iOS 26, isn't counted).
    let tabIndex: Int
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.tabIndex = tabIndex
        context.coordinator.action = action
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
    }

    @MainActor final class Coordinator: NSObject {
        var tabIndex = 0
        var action: (@MainActor () -> Void)?
        private weak var bar: UITabBar?

        func attach(from view: UIView) {
            guard bar == nil, let root = view.window?.rootViewController,
                  let controller = Self.tabBarController(in: root) else { return }
            let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.minimumPressDuration = 0.45
            press.cancelsTouchesInView = true
            controller.tabBar.addGestureRecognizer(press)
            bar = controller.tabBar
        }

        @objc func pressed(_ press: UILongPressGestureRecognizer) {
            guard press.state == .began, let bar else { return }
            // The item buttons, left to right; the Search button stands apart on iOS 26.
            var views: [UIView] = []
            for v in bar.subviews { views.append(v); views.append(contentsOf: v.subviews) }
            let half = bar.bounds.width / 2
            var items: [CGRect] = []
            for v in views where v is UIControl && v.bounds.width > 20 && v.bounds.width < half {
                items.append(v.convert(v.bounds, to: bar))
            }
            items.sort { $0.minX < $1.minX }
            let x = press.location(in: bar).x
            let hit: Bool
            if items.count > tabIndex {
                hit = items[tabIndex].insetBy(dx: -8, dy: -20).contains(CGPoint(x: x, y: items[tabIndex].midY))
            } else {
                // Couldn't find the buttons: share the bar evenly between the four tabs.
                let width = bar.bounds.width / 4
                hit = x >= width * CGFloat(tabIndex) && x < width * CGFloat(tabIndex + 1)
            }
            if hit {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                action?()
            }
        }

        static func tabBarController(in vc: UIViewController) -> UITabBarController? {
            if let tab = vc as? UITabBarController { return tab }
            for child in vc.children { if let found = tabBarController(in: child) { return found } }
            if let presented = vc.presentedViewController, presented.isBeingDismissed == false {
                return tabBarController(in: presented)
            }
            return nil
        }
    }
}
#endif
