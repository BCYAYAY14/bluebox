import Addons
import DesignSystem
import Domain
import SwiftUI
import Sync
#if os(iOS)
import UIKit
#endif

/// The settings pages. Raw values are stored (`bluebox.settingsPage`), so
/// existing cases keep their names.
public enum SettingsPage: String, CaseIterable, Identifiable, Hashable, Sendable {
    case account, profiles
    /// The profile group: the current profile's own settings.
    case languages, myPlayback, hiddenTitles
    case playback, subtitles, picture
    case torrents, downloads, sources, catalog
    case mobileData
    case notifications
    /// Privacy & Features (PrivacySettingsPage); My Bluebox (StatisticsPage,
    /// reached from the profile menu and Profiles, not the sidebar).
    case privacy, statistics
    case storage, advanced
    case about
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .account: "Account & Sync"
        case .profiles: "Profiles"
        case .languages: "Languages"
        case .myPlayback: "Playback"
        case .hiddenTitles: "Hidden Titles"
        // The shared player settings; "Playback" is the profile's own page.
        case .playback: "Player"
        case .subtitles: "Subtitles"
        case .picture: "Picture"
        case .torrents: "Torrents & Debrid"
        case .downloads: "Downloads"
        case .sources: "Sources"
        case .catalog: "Catalog & Ratings"
        case .mobileData: "Mobile Data"
        case .notifications: "Notifications"
        case .privacy: "Privacy & Features"
        case .statistics: "My Bluebox"
        case .storage: "Storage"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    /// A small monochrome glyph for the sidebar (no coloured tiles).
    var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .profiles: "person.2"
        case .languages: "globe"
        case .myPlayback: "play.circle"
        case .hiddenTitles: "eye.slash"
        case .playback: "play.rectangle"
        case .subtitles: "captions.bubble"
        case .picture: "slider.horizontal.3"
        case .torrents: "point.3.connected.trianglepath.dotted"
        case .downloads: "arrow.down.circle"
        case .sources: "externaldrive"
        case .catalog: "film.stack"
        case .mobileData: "antenna.radiowaves.left.and.right"
        case .notifications: "bell"
        case .privacy: "hand.raised"
        case .statistics: "chart.bar"
        case .storage: "internaldrive"
        case .advanced: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }

    /// Mobile Data is iPhone and iPad only.
    static var available: [SettingsPage] {
        #if os(iOS)
        allCases
        #else
        allCases.filter { $0 != .mobileData }
        #endif
    }

    /// The current profile's own pages, at the top of Settings under its avatar and name.
    static let profileGroup: [SettingsPage] = [.profiles, .languages, .myPlayback, .subtitles, .hiddenTitles]

    /// Pages that are the same for every profile, under "Everyone on this Mac".
    @MainActor static var groups: [(title: String, pages: [SettingsPage])] {
        [
            (everyoneTitle, [.account, .playback, .picture]),
            ("Finding Things to Watch", [.torrents, .sources, .catalog]),
            ("Data & Storage", [.mobileData, .downloads, .storage]),
            ("More", [.notifications, .privacy, .advanced, .about]),
        ].map { ($0.0, $0.1.filter(available.contains)) }
    }

    /// "Everyone on this Mac" (iPhone, iPad).
    @MainActor static var everyoneTitle: String {
        #if os(macOS)
        "Everyone on this Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "Everyone on this iPad" : "Everyone on this iPhone"
        #endif
    }

    /// True for the pages that belong to the current profile.
    var isPersonal: Bool { Self.profileGroup.contains(self) }
}

/// A page inside Settings' navigation stack. Categories, and the pages
/// below them that something outside Settings can open directly.
public enum SettingsRoute: Hashable, Sendable {
    case page(SettingsPage)
    /// Profiles › Add Profile ("Who's watching?" and the profile menu).
    case newProfile
    /// Profiles › Edit Profile, by profile ID.
    case editProfile(String)

    /// The category the route lives under (the sidebar's selection).
    var category: SettingsPage {
        switch self {
        case .page(let p): p
        case .newProfile, .editProfile: .profiles
        }
    }

    /// iPhone: the stack from the category list down to this route, so ‹ walks back up.
    var phonePath: [SettingsRoute] {
        switch self {
        case .page: [self]
        case .newProfile, .editProfile: [.page(.profiles), self]
        }
    }

    /// iPad and Mac: what's pushed inside the selected category.
    var detailPath: [SettingsRoute] {
        if case .page = self { return [] }
        return [self]
    }
}

/// One request to show Settings at a route. A fresh ID each time, so asking
/// for the page that's already showing still navigates to it.
struct SettingsTarget: Identifiable, Equatable {
    let id = UUID()
    let route: SettingsRoute?
}

/// Settings, styled after Netflix's account pages.
/// iPhone: one sheet holding one navigation stack. The category list pushes
/// a page per category, and everything below (Account, a profile's editor,
/// Downloads) pushes inside the same stack: ‹ goes back, × closes it.
/// iPad and Mac: a sidebar with search beside the selected page.
public struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var reveal = SettingsReveal()
    /// iPad and Mac: pages pushed inside the selected category (a profile's editor).
    @State private var detailPath: [SettingsRoute] = []
    #if os(macOS)
    @AppStorage("bluebox.settingsPage") private var selection: SettingsPage = .account
    public init() {}
    #else
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path: [SettingsRoute]
    @State private var selection: SettingsPage
    /// Where to open, and later requests while the sheet is up (RootView's `openSettingsPage`).
    private let target: SettingsTarget?

    public init(page: SettingsPage? = nil) {
        self.init(target: SettingsTarget(route: page.map(SettingsRoute.page)))
    }

    init(target: SettingsTarget?) {
        self.target = target
        let route = target?.route
        _path = State(initialValue: route?.phonePath ?? [])
        _selection = State(initialValue: route?.category ?? .account)
        _detailPath = State(initialValue: route?.detailPath ?? [])
    }
    #endif

    public var body: some View {
        Group {
            #if os(macOS)
            split(selection: $selection)
                .frame(minWidth: 860, minHeight: 580)
            #else
            if sizeClass == .regular {
                split(selection: $selection)
            } else {
                phoneList
            }
            #endif
        }
        .environment(\.settingsReveal, reveal)
        .preferredColorScheme(.dark)
        .tint(Palette.brand)
        .accountLinkBanner()  // a sheet or its own window: the app's banner would sit underneath
        .blueboxMenuHost()  // its own window (Mac) or sheet (iOS): menus draw here, not under it
        .modifier(ToastHost(model: app))  // Undo after removing a source or add-on, over the sheet
        .modifier(AppAlertPresenter())
        #if os(iOS)
        .presentationSizing(.page)
        // Asked again while open (a connect link, the picker's Add Profile): go there in place.
        .onChange(of: target) { _, new in
            guard let route = new?.route else { return }
            path = route.phonePath
            selection = route.category
            detailPath = route.detailPath
        }
        #endif
        #if DEBUG
        .task {
            // Screenshots: `-preview-account <state>` (AccountPreviews.swift).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-preview-account"), args.indices.contains(i + 1) {
                app.previewAccountForReview(args[i + 1])
            }
        }
        #endif
    }

    // MARK: iPad and Mac

    private func split(selection: Binding<SettingsPage>) -> some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: selection.wrappedValue, query: $query) { page, hit in
                if page != selection.wrappedValue { detailPath = [] }
                selection.wrappedValue = page
                reveal.target = hit
            } done: {
                #if os(iOS)
                dismiss()
                #endif
            }
            #if os(macOS)
            .frame(width: 250)
            #else
            .frame(width: 300)
            #endif
            Rectangle().fill(SettingsMetrics.hairline).frame(width: 1).ignoresSafeArea()
            NavigationStack(path: $detailPath) {
                SettingsPageView(page: selection.wrappedValue)
                    .settingsDestinations()
            }
            .id(selection.wrappedValue)  // each page starts at its root
        }
        .background(Palette.background.ignoresSafeArea())
    }

    // MARK: iPhone

    #if os(iOS)
    private var phoneList: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Settings")
                        .font(SettingsMetrics.titleFont)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, Spacing.s)
                        .padding(.bottom, Spacing.l)
                    SettingsSearchField(text: $query)
                        .padding(.bottom, Spacing.xl)
                    if query.isEmpty {
                        SettingsProfileCard()
                            .padding(.bottom, Spacing.xl)
                        SettingsSections {
                            Section {
                                ForEach(SettingsPage.profileGroup) { page in
                                    NavigationLink(value: SettingsRoute.page(page)) { SettingsCategoryRow(page: page) }
                                        .buttonStyle(SettingsRowPressStyle())
                                        .accessibilityIdentifier("settings.\(page.rawValue)")
                                }
                            } header: {
                                Text("Only for \(app.currentProfile.name)")
                            }
                            ForEach(SettingsPage.groups, id: \.title) { group in
                                Section {
                                    ForEach(group.pages) { page in
                                        NavigationLink(value: SettingsRoute.page(page)) { SettingsCategoryRow(page: page) }
                                            .buttonStyle(SettingsRowPressStyle())
                                            .accessibilityIdentifier("settings.\(page.rawValue)")
                                    }
                                } header: {
                                    Text(group.title)
                                }
                            }
                        }
                    } else {
                        SettingsSearchResults(query: query) { page, hit in
                            reveal.target = hit
                            path = [.page(page)]
                        }
                    }
                }
                .padding(.horizontal, SettingsMetrics.pageInset)
                .padding(.bottom, Spacing.xxxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background.ignoresSafeArea())
            .foregroundStyle(Palette.textPrimary)
            .navigationTitle("Settings")
            .toolbar(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Text("") }
            }
            .modifier(SettingsCloseButton { dismiss() })
            .toolbarBackground(Palette.background, for: .navigationBar)
            .settingsDestinations(close: { dismiss() })
        }
    }
    #endif
}

// MARK: - Sidebar

/// iPad and Mac: search, who's watching, and the categories.
struct SettingsSidebar: View {
    let selection: SettingsPage
    @Binding var query: String
    let select: (SettingsPage, SettingsSearchIndex.Entry?) -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(iOS)
            HStack(alignment: .firstTextBaseline) {
                Text("Settings").font(.title.weight(.heavy))
                Spacer()
                Button("Done", action: done).fontWeight(.semibold).foregroundStyle(Palette.textPrimary)
                    .buttonStyle(PressableStyle(scale: 1))
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.l)
            .padding(.bottom, Spacing.m)
            #endif
            SettingsSearchField(text: $query, prompt: "Search")
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.m)
                .padding(.bottom, Spacing.m)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        SettingsProfileCard(compact: true)
                            .padding(.horizontal, Spacing.m)
                            .padding(.bottom, Spacing.s)
                        VStack(spacing: 2) {
                            ForEach(SettingsPage.profileGroup) { page in
                                SidebarRow(page: page, selected: page == selection) { select(page, nil) }
                            }
                        }
                        .padding(.bottom, Spacing.m)
                        Text(SettingsPage.everyoneTitle)
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, Spacing.s)
                            .padding(.bottom, Spacing.xs)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(SettingsPage.groups, id: \.title) { group in
                            VStack(spacing: 2) {
                                ForEach(group.pages) { page in
                                    SidebarRow(page: page, selected: page == selection) { select(page, nil) }
                                }
                            }
                            .padding(.bottom, Spacing.m)
                        }
                    } else {
                        SettingsSearchResults(query: query, compact: true) { page, hit in select(page, hit) }
                            .padding(.horizontal, Spacing.m)
                    }
                }
                .padding(.horizontal, Spacing.s)
                .padding(.bottom, Spacing.l)
            }
            .scrollIndicators(.never)
        }
        .foregroundStyle(Palette.textPrimary)
        .background(Palette.chrome.ignoresSafeArea())
    }
}

private struct SidebarRow: View {
    let page: SettingsPage
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(page.title)
                    .font(SettingsMetrics.rowFont.weight(selected ? .bold : .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                if page == .about && AppUpdater.shared.hasUnseenUpdate {
                    Circle().fill(Palette.brand).frame(width: 7, height: 7)
                        .accessibilityLabel("Update available")
                }
            }
            .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
            .padding(.horizontal, 10)
            #if os(macOS)
            .frame(height: 32)
            #else
            .frame(height: 44)
            #endif
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Palette.elevated : hovering ? Palette.surface : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 1))
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.\(page.rawValue)")
    }
}

/// Search hits, grouped by page.
struct SettingsSearchResults: View {
    let query: String
    var compact = false
    let open: (SettingsPage, SettingsSearchIndex.Entry) -> Void

    var body: some View {
        let hits = SettingsSearchIndex.search(query)
        if hits.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("No Results").font(.headline)
                Text("Nothing in Settings matches “\(query)”.").font(.subheadline).foregroundStyle(Palette.textSecondary)
            }
            .padding(.top, Spacing.l)
        } else {
            SettingsSections {
                ForEach(SettingsPage.available) { page in
                    let pageHits = hits.filter { $0.page == page }
                    if !pageHits.isEmpty {
                        Section {
                            ForEach(pageHits) { hit in
                                Button { open(hit.page, hit) } label: { SettingsSearchRow(entry: hit) }
                                    .buttonStyle(SettingsRowPressStyle())
                            }
                        } header: {
                            Text(page.title)
                        }
                    }
                }
            }
        }
    }
}

/// Who's watching, at the top of the category list.
struct SettingsProfileCard: View {
    @Environment(AppModel.self) private var app
    var compact = false

    var body: some View {
        let current = app.currentProfile
        HStack(spacing: Spacing.m) {
            ProfileAvatar(symbol: current.symbol, color: current.color, size: compact ? 34 : 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(current.name).font(compact ? .subheadline.weight(.semibold) : .title3.weight(.bold)).lineLimit(1)
                Text(subtitle).font(compact ? .caption : .subheadline).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let name = app.account.accountName { return name }
        return app.account.isConfigured ? "Not signed in" : "On this device"
    }
}

/// A category row (iPhone): title, a short status in grey, and a chevron.
struct SettingsCategoryRow: View {
    @Environment(AppModel.self) private var app
    let page: SettingsPage

    var body: some View {
        HStack(spacing: Spacing.l) {
            Text(page.title).foregroundStyle(Palette.textPrimary).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 0)
            if let status { Text(status).foregroundStyle(Palette.textSecondary).lineLimit(1) }
            SettingsChevron()
        }
        .font(SettingsMetrics.rowFont)
    }

    private var status: String? {
        switch page {
        case .account: app.account.isSignedIn ? "Signed In" : "Off"
        case .profiles: "\(app.profiles.count)"
        case .languages: app.settings.preferredAudioLanguage.map(SettingsLanguages.name) ?? "Original"
        case .myPlayback: app.settings.autoplayNextEpisode ? "Autoplay On" : "Autoplay Off"
        case .hiddenTitles: nil
        case .catalog: switch app.catalogMode {
            case .live: "TMDB"
            case .cinemeta: "Cinemeta"
            case .sample: "Sample"
            }
        case .subtitles: app.subtitleStyle.preferredLanguage.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? "Off"
        case .playback: app.settings.enginePreference == .automatic ? nil : app.settings.enginePreference.title
        case .picture: app.settings.pictureDefaults.isDefault ? "Original" : "Adjusted"
        case .torrents:
            !app.addonSettings.isEnabled ? "Off" : app.addonSettings.debrid == .none ? "P2P" : app.addonSettings.debrid.title
        case .mobileData: app.settings.mobileData.streaming.title
        case .notifications: app.newEpisodeSettings.notify ? "On" : "Off"
        case .privacy, .statistics: nil
        case .downloads: app.downloadSettings.wifiOnly ? "Wi‑Fi Only" : nil
        case .about: AppUpdater.shared.hasUnseenUpdate ? "Update Available" : nil
        case .sources, .storage, .advanced: nil
        }
    }
}

extension View {
    /// The pages a Settings stack can push (`SettingsRoute`). With `close`
    /// (iPhone), each carries the × that closes the sheet; `dismiss` inside a
    /// pushed page would only go back.
    func settingsDestinations(close: (() -> Void)? = nil) -> some View {
        navigationDestination(for: SettingsRoute.self) { route in
            SettingsRouteView(route: route)
                .modifier(SettingsCloseButton(close: close))
        }
    }
}

/// The page for a route.
struct SettingsRouteView: View {
    @Environment(AppModel.self) private var app
    let route: SettingsRoute

    var body: some View {
        switch route {
        case .page(let page): SettingsPageView(page: page)
        case .newProfile: ProfileEditorPage(profile: nil)
        case .editProfile(let id):
            if let profile = app.profiles.first(where: { $0.id == id }) {
                ProfileEditorPage(profile: profile)
            } else {
                StateMessage(.empty, title: "Profile removed", message: "This profile is no longer on this device.")
            }
        }
    }
}

/// iPhone Settings' × (every page of its stack): Bluebox's own dark circle
/// with a hairline, like Downloads' ⋯, with no system glass behind it.
private struct SettingsCloseButton: ViewModifier {
    var close: (() -> Void)?

    func body(content: Content) -> some View {
        #if os(iOS)
        if let close {
            content.toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .confirmationAction) { button(close) }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .confirmationAction) { button(close) }
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }

    private func button(_ close: @escaping () -> Void) -> some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.glassFill))
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Close Settings")
        .accessibilityIdentifier("settingsClose")
    }
}

struct SettingsPageView: View {
    let page: SettingsPage
    var body: some View {
        switch page {
        case .account: AccountSettingsPage()
        case .profiles: SettingsForm(.profiles) { ProfilesSection(); StatisticsLinkSection() }
        case .languages: ProfileLanguagesPage()
        case .myPlayback: ProfilePlaybackPage()
        case .hiddenTitles: HiddenTitlesSettingsPage()
        case .playback: PlaybackSettingsPage()
        case .subtitles: SubtitlesSettingsPage()
        case .picture: PictureSettingsPage()
        case .torrents: TorrentsSettingsPage()
        case .downloads: DownloadsSettingsPage()
        case .sources: SourcesSettingsPage()
        case .catalog: CatalogSettingsPage()
        case .mobileData: MobileDataSettingsPage()
        case .notifications: NotificationsSettingsPage()
        case .privacy: PrivacySettingsPage()
        case .statistics: StatisticsPage()
        case .storage: StorageSettingsPage()
        case .advanced: AdvancedSettingsPage()
        case .about: AboutSettingsPage()
        }
    }
}
