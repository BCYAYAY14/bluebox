import DesignSystem
import Domain
import SwiftUI

extension EnvironmentValues {
    /// True when navigation is the top bar (Mac, iPad) rather than a tab bar,
    /// so pages draw their own titles and search field.
    @Entry var usesTopNav = false
    /// Whether this page's content has scrolled under its bar. Every page
    /// owns its own value (`PageChrome` in RootView), so a page you come back
    /// to keeps its state instead of inheriting the last page's.
    @Entry var headerScrolled: Binding<Bool> = .constant(false)
}

extension View {
    /// Reports whether this scroll view has scrolled content under the top bar.
    func reportsHeaderScroll() -> some View { modifier(HeaderScrollReporter()) }

    /// A solid chrome navigation bar once the page scrolls, transparent at the
    /// top (so title-page art runs under it). Owns its page's scroll state:
    /// put `reportsHeaderScroll()` on the page's scroll view. For pages
    /// outside the app's tab stacks (sheets and covers); pages in the stacks
    /// get it from `RootView`.
    func solidNavigationBarOnScroll() -> some View { modifier(SolidNavigationBarOnScroll()) }
}

private struct SolidNavigationBarOnScroll: ViewModifier {
    @State private var scrolled = false
    func body(content: Content) -> some View {
        content
            .scrolledNavigationBar(scrolled)
            .environment(\.headerScrolled, $scrolled)
    }
}

extension View {
    /// The navigation bar's background for a page: hidden at the top,
    /// solid chrome once content runs under it.
    @ViewBuilder func scrolledNavigationBar(_ scrolled: Bool) -> some View {
        #if os(iOS)
        toolbarBackground(Palette.chrome, for: .navigationBar)
            .toolbarBackgroundVisibility(scrolled ? .visible : .hidden, for: .navigationBar)
            .animation(Motion.appear, value: scrolled)
        #else
        self
        #endif
    }
}

private struct HeaderScrollReporter: ViewModifier {
    @Environment(\.headerScrolled) private var scrolled

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Bool.self) { g in
            g.contentOffset.y + g.contentInsets.top > 12
        } action: { _, now in
            if scrolled.wrappedValue != now { scrolled.wrappedValue = now }
        }
    }
}

/// A large page title, shown only under the top bar (the tab bar layout uses
/// navigation-bar titles instead).
struct PageTitle: View {
    @Environment(\.usesTopNav) private var usesTopNav
    let title: String
    let inset: CGFloat

    var body: some View {
        if usesTopNav {
            Text(ui: title)
                .font(Typography.pageTitle)
                .padding(.horizontal, inset)
                .padding(.top, Spacing.s)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// Netflix-style top navigation for Mac and iPad: wordmark, text tabs, a
/// Sources menu, then search and the profile menu. Transparent over artwork
/// until the page scrolls, then solid chrome grey with a hairline.
struct TopNavBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underline
    @Binding var tab: AppTab
    /// Whether the visible page has scrolled under the bar.
    var scrolled = false
    let sources: [SidebarSource]
    let downloads: Int
    let canGoBack: Bool
    let back: () -> Void
    /// "Real-Debrid" etc. once a debrid library is set up; nil hides its entry.
    var debridLibraryName: String?
    var openDebridLibrary: () -> Void = {}
    let openSettings: (SettingsPage?) -> Void
    /// A tab was chosen; `again` when it was already showing (back to its first page).
    var chose: (AppTab, _ again: Bool) -> Void = { _, _ in }

    /// The bar's height below the status bar (iPad pages reserve this much).
    #if os(macOS)
    static let barHeight: CGFloat = 52
    #else
    static let barHeight: CGFloat = 60
    #endif

    #if os(macOS)
    /// Clears the window's close/minimize/zoom buttons (they end 80 pt in;
    /// with the bar's 24 pt inset, content starts 12 pt after them). Full
    /// screen hides the buttons, so the bar starts at its usual inset.
    @Environment(\.windowIsFullScreen) private var isFullScreen
    @Environment(\.fullScreenToolbarInset) private var fullScreenInset
    private var leadingChrome: CGFloat { isFullScreen ? 0 : 68 }
    #else
    private let leadingChrome: CGFloat = 0
    private let fullScreenInset: CGFloat = 0
    #endif
    private var height: CGFloat { Self.barHeight }

    var body: some View {
        HStack(spacing: Spacing.l) {
            if canGoBack {
                TopBarBackButton(action: back)
                    .transition(Motion.pop(reduceMotion, scale: 0.8))
            }
            Button { select(.home) } label: { BlueboxWordmark(size: 24) }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Bluebox, Home")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.l + 2) { navItems }
                browseMenu
            }
            Spacer(minLength: Spacing.l)
            HStack(spacing: Spacing.l + 2) {
                NavIcon(symbol: "magnifyingglass", label: "Search", selected: tab == .search) { select(.search) }
                    .keyboardShortcut("f", modifiers: .command)
                PlayOnButton()
                ProfileMenu(size: 28, showsChevron: true, openSettings: openSettings)
            }
        }
        .padding(.leading, leadingChrome)
        .padding(.horizontal, Spacing.xl)
        .frame(height: height)
        .padding(.top, fullScreenInset)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { background }
        .animation(Motion.appear, value: scrolled)
        .animation(Motion.snappy(reduceMotion), value: canGoBack)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: height * 1.6)
                .frame(maxHeight: .infinity, alignment: .top)
            Palette.chrome.opacity(scrolled ? 1 : 0)
            VStack { Spacer(); Palette.separator.frame(height: 1).opacity(scrolled ? 1 : 0) }
        }
        .ignoresSafeArea(edges: .top)
        #if os(macOS)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        #endif
    }

    /// Switches tabs with the underline sliding across and the page crossfading.
    private func select(_ new: AppTab) {
        guard new != tab else { chose(new, true); return }
        chose(new, false)
        withAnimation(Motion.snappy(reduceMotion)) { tab = new }
    }

    @ViewBuilder private var navItems: some View {
        NavText("Home", selected: tab == .home, underline: underline) { select(.home) }
            .keyboardShortcut("1", modifiers: .command)
        NavText("TV Shows", selected: tab == .shows, underline: underline) { select(.shows) }
            .keyboardShortcut("2", modifiers: .command)
        NavText("Movies", selected: tab == .movies, underline: underline) { select(.movies) }
            .keyboardShortcut("3", modifiers: .command)
        NavText("New & Hot", selected: tab == .newHot, underline: underline) { select(.newHot) }
            .keyboardShortcut("4", modifiers: .command)
        NavText("My List", selected: tab == .myList || tab == .watching, underline: underline) { select(.myList) }
            .keyboardShortcut("5", modifiers: .command)
        NavText("Downloads", badge: downloads, selected: tab == .downloads, underline: underline) { select(.downloads) }
            .keyboardShortcut("6", modifiers: .command)
        sourcesMenu
    }

    private var isSource: Bool { if case .source = tab { true } else { false } }

    private var sourcesMenu: some View {
        BlueboxMenu("Sources") {
            BlueboxMenuSection {
                for s in sources {
                    BlueboxMenuButton(s.name, systemImage: s.symbol, checked: tab == .source(s.id)) { select(.source(s.id)) }
                }
                if let debridLibraryName {
                    BlueboxMenuButton("\(debridLibraryName) Library", systemImage: "externaldrive.badge.icloud") {
                        openDebridLibrary()
                    }
                }
            }
            BlueboxMenuSection {
                BlueboxMenuButton("Add Source…", systemImage: "plus") { openSettings(.sources) }
            }
        } label: {
            NavLabel(title: "Sources", selected: isSource, showsChevron: true, underline: underline)
        }
        .fixedSize()
        .accessibilityIdentifier("topNavSources")
    }

    /// Narrow windows: the tabs fold into one menu.
    private var browseMenu: some View {
        BlueboxMenu("Browse") {
            BlueboxMenuSection {
                BlueboxMenuButton("Home", systemImage: "house", checked: tab == .home, shortcut: shortcut(1)) { select(.home) }
                BlueboxMenuButton("TV Shows", systemImage: "tv", checked: tab == .shows, shortcut: shortcut(2)) { select(.shows) }
                BlueboxMenuButton("Movies", systemImage: "film", checked: tab == .movies, shortcut: shortcut(3)) { select(.movies) }
                BlueboxMenuButton("New & Hot", systemImage: "flame", checked: tab == .newHot, shortcut: shortcut(4)) { select(.newHot) }
                BlueboxMenuButton("My List", systemImage: "plus.rectangle.on.rectangle", checked: tab == .myList || tab == .library,
                                  shortcut: shortcut(5)) { select(.myList) }
                BlueboxMenuButton("Continue Watching", systemImage: "play.circle", checked: tab == .watching) { select(.watching) }
                BlueboxMenuButton(downloads > 0 ? "Downloads (\(downloads))" : "Downloads", systemImage: "arrow.down.circle",
                                  checked: tab == .downloads, shortcut: shortcut(6)) { select(.downloads) }
            }
            if !sources.isEmpty || debridLibraryName != nil {
                BlueboxMenuSection("Sources") {
                    for s in sources {
                        BlueboxMenuButton(s.name, systemImage: s.symbol, checked: tab == .source(s.id)) { select(.source(s.id)) }
                    }
                    if let debridLibraryName {
                        BlueboxMenuButton("\(debridLibraryName) Library", systemImage: "externaldrive.badge.icloud") {
                            openDebridLibrary()
                        }
                    }
                }
            }
        } label: {
            NavLabel(title: currentTitle, selected: true, showsChevron: true)
        }
        .fixedSize()
        .accessibilityIdentifier("topNavBrowse")
    }

    private func shortcut(_ n: Int) -> String? {
        #if os(macOS)
        "⌘\(n)"
        #else
        nil
        #endif
    }

    private var currentTitle: String {
        switch tab {
        case .home: "Home"
        case .shows: "TV Shows"
        case .movies: "Movies"
        case .newHot: "New & Hot"
        case .search: "Search"
        case .myList, .library: "My List"
        case .watching: "Continue Watching"
        case .downloads: "Downloads"
        case .source(let id): sources.first { $0.id == id }?.name ?? "Sources"
        }
    }
}

/// One text tab. Selected is bold white with a short blue underline.
private struct NavText: View {
    let title: String
    var badge = 0
    let selected: Bool
    let underline: Namespace.ID
    let action: () -> Void

    init(_ title: String, badge: Int = 0, selected: Bool, underline: Namespace.ID, action: @escaping () -> Void) {
        self.title = title; self.badge = badge; self.selected = selected; self.underline = underline; self.action = action
    }

    var body: some View {
        Button(action: action) {
            NavLabel(title: title, selected: selected, badge: badge, underline: underline)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("topNav.\(title)")
    }
}

/// A tab label. One blue underline is shared by all labels (matched geometry),
/// so it slides from the old tab to the new one.
private struct NavLabel: View {
    let title: String
    let selected: Bool
    var showsChevron = false
    var badge = 0
    var underline: Namespace.ID?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            content
            ZStack {
                if selected, let underline {
                    Capsule().fill(Palette.brand)
                        .matchedGeometryEffect(id: "underline", in: underline)
                }
            }
            .frame(width: 18, height: 2.5)
        }
        .padding(.top, 8.5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }

    private var content: some View {
        HStack(spacing: 5) {
            Text(ui: title)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected || hovering ? Palette.textPrimary : Palette.textSecondary)
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                    .background(Palette.brand, in: Capsule())
                    .foregroundStyle(.white)
            }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Bluebox's back button, just after the window's traffic lights (Mac) or at
/// the leading edge (iPad). The only back button: the stack's own is hidden.
private struct TopBarBackButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(hovering ? 0.22 : 0.12)))
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back")
        .accessibilityLabel("Back")
        .accessibilityIdentifier("topNavBack")
    }
}

private struct NavIcon: View {
    let symbol: String
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(selected || hovering ? Palette.textPrimary : Palette.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityIdentifier("topNav.\(label)")
    }
}

/// iPhone Home: wordmark, profile and filter chips over the hero, like the top of Netflix.
struct CompactHomeHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.headerScrolled) private var scrolled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pushRoute) private var pushRoute
    @Binding var category: HomeCategory
    let openSettings: (SettingsPage?) -> Void
    @State private var genres = GenreMenuModel()
    @State private var categoriesOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Button { setCategory(.all) } label: { BlueboxWordmark(size: 26) }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Bluebox, Home")
                Spacer()
                PlayOnButton()
                ProfileMenu(size: 28, openSettings: openSettings)
            }
            .frame(height: 44)
            .padding(.horizontal, Spacing.l)
            chips
        }
        .padding(.bottom, Spacing.s)
        // Chrome text: past this size the chips no longer fit across the screen.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .background(alignment: .top) {
            ZStack {
                LinearGradient(colors: [Palette.background.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                // Fully opaque: at 97% the hero's buttons still ghosted through.
                Palette.chrome.opacity(scrolled.wrappedValue ? 1 : 0)
            }
            .ignoresSafeArea(edges: .top)
        }
        .animation(Motion.appear, value: scrolled.wrappedValue)
        .selectionHaptic(category)
        .task(id: app.catalogMode) { await genres.load(app) }
    }

    /// Netflix's filter chips: tap one to narrow Home, then an ✕ appears to clear it.
    /// Scrolls sideways rather than truncating if the chips don't fit.
    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.s) {
                if category != .all {
                    Button { setCategory(.all) } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Show Everything")
                    .transition(Motion.pop(reduceMotion, scale: 0.5))
                }
                ForEach([HomeCategory.series, .movies], id: \.self) { c in
                    if category == .all || category == c {
                        CategoryChip(c.title, selected: category == c) { setCategory(category == c ? .all : c) }
                            .fixedSize()
                            .transition(.opacity)
                    }
                }
                if genres.hasGenres != false { categoriesMenu }
            }
            .padding(.horizontal, Spacing.l)
            .frame(height: 40)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    /// Genres for the current chip. Loads when Home appears, again whenever
    /// it opens empty, and retries a failed load by itself.
    private var categoriesMenu: some View {
        Button { categoriesOpen.toggle() } label: {
            HStack(spacing: 5) {
                Text("Categories")
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(categoriesOpen ? 0.8 : 1)
        }
        .buttonStyle(PressableStyle())
        .fixedSize()
        .accessibilityHint("Opens a menu")
        .accessibilityIdentifier("homeCategories")
        .blueboxMenu(isPresented: $categoriesOpen, title: "Categories") { [genres, category] in
            // `genres` is observed here, so the open menu fills in when the load finishes.
            BlueboxMenuSection(category == .series ? "TV Show Genres" : "Genres") {
                for g in genres.genres {
                    BlueboxMenuButton(g.name) { pushRoute(.genre(g, category == .series ? .series : .movie)) }
                }
            }
            if genres.phase == .failed {
                BlueboxMenuNote("Couldn't load genres. Check your connection and try again.")
                BlueboxMenuSection {
                    BlueboxMenuButton("Try Again", systemImage: "arrow.clockwise") { Task { await genres.load(app, force: true) } }
                }
            } else if genres.phase != .loaded {
                BlueboxMenuNote("Loading genres…")
            }
        }
        .onChange(of: categoriesOpen) { _, open in
            if open, genres.genres.isEmpty { Task { await genres.load(app, force: true) } }
        }
    }

    private func setCategory(_ c: HomeCategory) {
        withAnimation(Motion.snappy(reduceMotion)) { category = c }
    }
}

/// The Categories menu's genres. A reference the menu reads while it's open,
/// so a load that finishes then shows up at once.
@Observable
@MainActor
final class GenreMenuModel {
    enum Phase { case idle, loading, loaded, failed }
    private(set) var genres: [Genre] = []
    private(set) var phase: Phase = .idle
    private var mode: AppModel.CatalogMode?

    /// False only when the catalog answered with no genres at all (the chip hides).
    var hasGenres: Bool? { phase == .loaded ? !genres.isEmpty : nil }

    /// Three tries, a second or two apart; `force` loads again after a failure.
    func load(_ app: AppModel, force: Bool = false) async {
        if mode != app.catalogMode { mode = app.catalogMode; genres = []; phase = .idle }
        guard phase != .loading, phase == .idle || (force && phase == .failed) else { return }
        phase = .loading
        for attempt in 1...3 {
            if let loaded = try? await app.metadata.genres() {
                genres = loaded
                phase = .loaded
                return
            }
            if Task.isCancelled { phase = .idle; return }
            if attempt < 3 { try? await Task.sleep(for: .seconds(Double(attempt))) }
        }
        phase = Task.isCancelled ? .idle : .failed
    }
}

#if os(macOS)
extension EnvironmentValues {
    /// Whether this window is in full screen, where the window buttons are hidden.
    @Entry var windowIsFullScreen = false
    /// In full screen, the height of the strip AppKit keeps for the toolbar
    /// at the top of the window (0 otherwise).
    @Entry var fullScreenToolbarInset: CGFloat = 0
}

/// Gives the window an empty, invisible unified toolbar (owned by SwiftUI) so
/// the close, minimize and zoom buttons sit vertically centred in the top bar
/// instead of above it. While the player is up the toolbar, and with it the
/// buttons, is hidden: the player has its own chrome.
///
/// In full screen AppKit moves the toolbar into its own strip window across
/// the top of the window, drawn grey over the top bar. So in full screen the
/// toolbar is hidden (the strip then draws nothing), but the empty strip still
/// takes clicks: the top bar moves down below it (`fullScreenToolbarInset`)
/// and paints its background up behind it.
struct UnifiedTitlebar: ViewModifier {
    var hidden = false
    @State private var state = FullScreenState()

    func body(content: Content) -> some View {
        content
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .principal) { spacer }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) { spacer }
                }
            }
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(hidden || state.isFullScreen ? .hidden : .automatic, for: .windowToolbar)
            .windowToolbarFullScreenVisibility(.onHover)
            .environment(\.windowIsFullScreen, state.isFullScreen)
            .environment(\.fullScreenToolbarInset, state.isFullScreen && !hidden ? state.toolbarInset : 0)
            .background(FullScreenObserver(state: $state))
    }

    private var spacer: some View {
        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
    }
}

struct FullScreenState: Equatable {
    var isFullScreen = false
    var toolbarInset: CGFloat = 0
}

/// Reports whether the hosting window is in full screen, and how much of its
/// top the toolbar strip covers there.
private struct FullScreenObserver: NSViewRepresentable {
    @Binding var state: FullScreenState

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = { new in if state != new { state = new } }
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = { new in if state != new { state = new } }
    }

    final class ObserverView: NSView {
        var onChange: ((FullScreenState) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        private var layoutObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            layoutObservation = nil
            guard let window else { return }
            onChange?(Self.measure(window))
            // The strip is laid out after the enter notifications, and a window
            // restored into full screen at launch posts none: follow the layout rect.
            layoutObservation = window.observe(\.contentLayoutRect) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.styleMask.contains(.fullScreen) else { return }
                    self.onChange?(Self.measure(window))
                }
            }
            let names = [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification]
            for name in names {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let name = note.name
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        switch name {
                        // Before the animation: the strip isn't laid out yet, so assume the toolbar's height.
                        case NSWindow.willEnterFullScreenNotification: self.onChange?(.init(isFullScreen: true, toolbarInset: 52))
                        case NSWindow.willExitFullScreenNotification: self.onChange?(.init())
                        default: self.onChange?(Self.measure(window))
                        }
                    }
                })
            }
        }

        static func measure(_ window: NSWindow) -> FullScreenState {
            guard window.styleMask.contains(.fullScreen) else { return .init() }
            let inset = max(0, window.frame.height - window.contentLayoutRect.maxY)
            return .init(isFullScreen: true, toolbarInset: inset)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif

/// Plays the launch ident over the app once per launch. UI tests skip it
/// unless launched with `-intro`.
///
/// `holdingContent` is true while the caller should keep heavy views (Home)
/// out of the window. Building them takes the main thread for up to a second
/// on a cold launch, which froze the ident and swallowed its sweep. They're
/// released once the sweep is over, while the wordmark holds still and a
/// stall can't be seen. `contentReady` says the library has opened; until it
/// has, the wordmark holds instead of fading to an empty black window.
public struct LaunchIntroOverlay: ViewModifier {
    /// Whether a window opening now plays the ident.
    @MainActor public static var playsOnLaunch: Bool {
        let args = ProcessInfo.processInfo.arguments
        return (!args.contains("-ui-testing") && AppSettings.launchIntroEnabled) || args.contains("-intro")
    }

    @State private var showing = LaunchIntroOverlay.playsOnLaunch
    @Binding private var holdingContent: Bool
    private let contentReady: Bool

    public init(holdingContent: Binding<Bool> = .constant(false), contentReady: Bool = true) {
        self.contentReady = contentReady
        _holdingContent = holdingContent
    }

    /// Faded explicitly, then removed: a removal transition on the overlay
    /// cut straight to the app instead of crossfading.
    @State private var opacity = 1.0

    public func body(content: Content) -> some View {
        content
            .onAppear { if !showing { holdingContent = false } }
            .overlay {
                if showing {
                    BlueboxIntro(contentReady: contentReady, onSweepFinished: { holdingContent = false }) {
                        holdingContent = false
                        withAnimation(.easeIn(duration: 0.45)) { opacity = 0 }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(500))
                            showing = false
                        }
                    }
                    .opacity(opacity)
                    .allowsHitTesting(opacity > 0.5)
                }
            }
            #if os(macOS)
            // The window itself is black from its first frame, so nothing grey
            // shows before SwiftUI draws (iOS gets this from the dark launch screen).
            .containerBackground(Color.black, for: .window)
            #endif
    }
}
