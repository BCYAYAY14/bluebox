import DesignSystem
import Domain
import Downloads
import Playback
import SwiftUI
import VLCPlayback


struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case myList = "My List", lists = "Lists", watching = "Continue Watching", history = "History", onDevice = "My Sources"
        var id: String { rawValue }

        var identifier: String {
            switch self {
            case .myList: "myList"
            case .lists: "lists"
            case .watching: "watching"
            case .history: "history"
            case .onDevice: "sources"
            }
        }
    }

    @Environment(AppModel.self) private var app
    @State private var section: Section
    /// Shown alone (from a sidebar item) instead of with the section chips.
    let fixed: Bool
    /// Limits "My Sources" to one source (a sidebar source item).
    let sourceFilter: SourceID?
    var sourceName: String?

    init(section: Section = .myList, fixed: Bool = false, source: SourceID? = nil, sourceName: String? = nil) {
        _section = State(initialValue: source != nil ? .onDevice : section)
        self.fixed = fixed || source != nil
        self.sourceFilter = source
        self.sourceName = sourceName
    }
    @State private var watchlist: [Title] = []
    /// My List's hand-set order, for the Manual sort.
    @State private var manualOrder: [MediaKey] = []
    /// My List as shown: filtered and sorted in `rearrange()`, never in `body`.
    @State private var arranged: [Title] = []
    /// The Lists grid's tiles.
    @State private var summaries: [ListSummary] = []
    @State private var watching: [WatchEntry] = []
    @State private var history: [HistoryEntry] = []
    /// History under date headings, grouped once per load.
    @State private var historyGroups: [WatchHistory.Group] = []
    @State private var groups: [SourceGroup] = []
    @State private var loaded = false
    /// The library itself couldn't be read (the store on this device).
    @State private var libraryFailed = false
    /// Sources that couldn't be reached on the last load (their titles from before stay).
    @State private var unreachableSources: [String] = []
    @State private var listFilter: MyListFilter = .all
    @State private var listSort: MyListSort = .recentlyAdded
    @State private var scrolled = false
    /// Details from a Continue Watching card's menu.
    @Environment(\.pushRoute) private var pushRoute
    @Environment(\.selectTab) private var selectTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// "Add a Source" from the empty My Sources: Settings › Sources.
    @Environment(\.openSettingsPage) private var openSettingsPage

    struct SourceGroup: Identifiable {
        let id: SourceID
        let name: String
        let items: [SourceItem]
    }

    struct SourceItem: Identifiable {
        let variant: MediaVariant
        let title: Title?
        var id: String { variant.sourceID.rawValue + "/" + variant.id }
    }

    var body: some View {
        GeometryReader { geo in
            let inset = Spacing.pageInset(for: geo.size.width)
            let metrics = CardMetrics(containerWidth: geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    PageTitle(title: fixed ? (sourceName ?? section.rawValue) : "My Library", inset: inset)
                    if !fixed { sectionChips(inset: inset) }
                    if let name = app.debridLibraryName, !fixed || (section == .onDevice && sourceFilter == nil) {
                        DebridLibraryEntry(name: name).padding(.horizontal, inset)
                    }

                    switch section {
                    case .myList: myList(metrics: metrics, inset: inset, width: geo.size.width)
                    case .lists: lists(inset: inset, width: geo.size.width)
                    case .watching: continueWatching(metrics: metrics, inset: inset, width: geo.size.width)
                    case .history: historyList(inset: inset)
                    case .onDevice: sources(inset: inset)
                    }
                }
                .padding(.vertical, Spacing.l)
            }
            .reportsHeaderScroll()
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y + g.contentInsets.top > 4 } action: { _, now in
                scrolled = now
            }
        }
        .blueboxScreen()
        .navigationTitle(fixed ? (sourceName ?? section.rawValue) : "My Library")
        #if os(iOS)
        // Once the page scrolls, the bar turns solid black so posters don't show behind the title and profile button.
        .toolbarBackground(Palette.background, for: .navigationBar)
        .toolbarBackgroundVisibility(scrolled ? .visible : .hidden, for: .navigationBar)
        #endif
        .task(id: "\(app.libraryRevision)-\(app.sourcesRevision)") { await load() }
        .refreshable { await app.rescanSources() }
        .onChange(of: section) { _, s in if !fixed { ViewMemory.set(s.rawValue, "librarySection", profile: app.currentProfileID) } }
        .task(id: app.currentProfileID) {
            let profile = app.currentProfileID
            if !fixed, let saved = ViewMemory.string("librarySection", profile: profile),
               let s = Section(rawValue: saved) { section = s }
            listFilter = ViewMemory.string("myListFilter", profile: profile).flatMap(MyListFilter.init(rawValue:)) ?? .all
            listSort = ViewMemory.string("myListSort", profile: profile).flatMap(MyListSort.init(rawValue:)) ?? .recentlyAdded
            #if DEBUG
            // Screenshots: `-library-section History` opens on that section.
            let args = ProcessInfo.processInfo.arguments
            if !fixed, let i = args.firstIndex(of: "-library-section"), args.indices.contains(i + 1),
               let s = Section(rawValue: args[i + 1]) { section = s }
            #endif
        }
        .onChange(of: listFilter) { _, f in
            ViewMemory.set(f.rawValue, "myListFilter", profile: app.currentProfileID)
            rearrange()
        }
        .onChange(of: listSort) { _, s in
            ViewMemory.set(s.rawValue, "myListSort", profile: app.currentProfileID)
            rearrange()
        }
        .reloadsWhenBackOnline(!unreachableSources.isEmpty) { await load() }
    }

    /// My List, Continue Watching and My Sources as Bluebox chips, like New &
    /// Hot: each sized to its label (never truncated), scrolling sideways when
    /// they don't fit.
    private func sectionChips(inset: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.s) {
                ForEach(Section.allCases) { s in
                    CategoryChip(s.rawValue, selected: section == s) {
                        withAnimation(Motion.snappy(reduceMotion)) { section = s }
                    }
                    .accessibilityIdentifier("library.\(s.identifier)")
                }
            }
            .padding(.horizontal, inset)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .selectionHaptic(section)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library sections")
    }

    /// Reads My List, Continue Watching, History and your sources. What fails
    /// keeps what it showed: a store read leaves the list as it was (and says
    /// so if there's nothing), a source that can't be reached keeps its files
    /// from the last load and is named in a "Couldn't reach" notice.
    private func load() async {
        var failed = false
        do {
            watchlist = try await app.store.watchlist()
            manualOrder = try await app.store.watchlistEntries().map(\.key)
        } catch { failed = true }
        rearrange()
        do { summaries = try await app.librarySummaries() } catch { failed = true }
        // Titles looked up side by side (each may be a catalogue request).
        do {
            let progress = try await app.store.continueWatching(limit: 50)
            let titles = await app.titles(for: progress.map { $0.key.seriesKey ?? $0.key })
            watching = zip(progress, titles).compactMap { p, t in t.map { WatchEntry(progress: p, title: $0) } }
        } catch { failed = true }
        do {
            let finished = Array(WatchHistory.finished(try await app.store.recent(limit: 500)).prefix(200))
            let titles = await app.titles(for: finished.map { $0.key.seriesKey ?? $0.key })
            history = zip(finished, titles).compactMap { p, t in t.map { HistoryEntry(progress: p, title: $0) } }
            historyGroups = WatchHistory.grouped(history)
        } catch { failed = true }
        libraryFailed = failed

        var built: [SourceGroup] = []
        var unreachable: [String] = []
        // The debrid library has its own page (the entry above), not a list of raw
        // files here, and downloads have their own tab.
        for source in await app.registry.enabled(with: .browse)
        where (sourceFilter == nil && source.id != SidebarSource.debridLibraryID && source.kind != .downloads) || source.id == sourceFilter {
            let variants: [MediaVariant]
            do {
                variants = try await source.catalog()
            } catch {
                unreachable.append(source.displayName)
                if let old = groups.first(where: { $0.id == source.id }) { built.append(old) }
                continue
            }
            // Titles side by side (each may be a catalogue request); variants without a key get none.
            let keyed = variants.enumerated().compactMap { i, v in (v.mediaKey?.seriesKey ?? v.mediaKey).map { (i, $0) } }
            let found = await app.titles(for: keyed.map(\.1))
            var byIndex: [Int: Title] = [:]
            for ((i, _), t) in zip(keyed, found) { byIndex[i] = t }
            let items = variants.enumerated().map { i, v in SourceItem(variant: v, title: byIndex[i]) }
            built.append(SourceGroup(id: source.id, name: source.displayName, items: items))
        }
        groups = built
        unreachableSources = unreachable
        loaded = true
    }

    /// My List filtered and sorted. Runs on load and when the chips or sort
    /// change, so scrolling and other re-renders don't re-sort the list.
    private func rearrange() {
        let next = MyListArrangement.arrange(watchlist, filter: listFilter, sort: listSort, manual: manualOrder)
        if next != arranged { arranged = next }
    }

    /// Takes a title out of History (marks it unwatched, on every device), with Undo.
    private func removeFromHistory(_ entry: HistoryEntry) {
        let before = history
        Task {
            let removed = await app.optimistic("Couldn't remove from History", from: before,
                                               to: before.filter { $0.id != entry.id },
                                               apply: { list in withAnimation(Motion.standard(reduceMotion)) {
                                                   history = list
                                                   historyGroups = WatchHistory.grouped(list)
                                               } }) {
                try await app.setWatched(entry.progress.key, false)
            }
            guard removed else { return }
            app.showToast(AppToast(entry.title.name, message: "Removed from History", actionTitle: "Undo") { [app] in
                Task { await app.restoreToContinueWatching(entry.progress) }
            })
        }
    }

    /// A full-page message when the library couldn't be read and there's nothing to show.
    @ViewBuilder private func libraryFailure(hasContent: Bool) -> some View {
        let phase = LoadPhase.resolve(hasContent: hasContent, isLoading: !loaded, failed: libraryFailed,
                                      isOffline: false, needsNetwork: false)
        if phase == .failed {
            StateMessage(.failed, title: "Couldn't open your library",
                         message: "Bluebox couldn't read the library on this device. Try again; if it keeps happening, restart Bluebox.",
                         actionTitle: "Try Again") { Task { await load() } }
        }
    }

    // MARK: My List

    @ViewBuilder private func myList(metrics: CardMetrics, inset: CGFloat, width: CGFloat) -> some View {
        // Fixed columns that fill the width between the page insets, so the
        // grid lines up with the title and chips instead of floating.
        let grid = FittedGrid(width: width - inset * 2, minimum: metrics.posterWidth, gap: Spacing.cardGap)
        if !loaded {
            // The grid's shape while the list loads, not a flash of "empty".
            LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Spacing.cardGap) {
                ForEach(0..<(grid.count * 2), id: \.self) { _ in
                    SkeletonBlock(width: grid.itemWidth, height: grid.itemWidth * 1.5)
                }
            }
            // One sweep for the grid, not one masked animation per block.
            .shimmering()
            .padding(.horizontal, inset)
            .accessibilityElement()
            .accessibilityLabel("Loading")
        } else if watchlist.isEmpty {
            if libraryFailed {
                libraryFailure(hasContent: false)
            } else {
                StateMessage(systemImage: "plus.rectangle.on.rectangle", title: "Your list is empty",
                             message: "Tap My List on any movie or show to save it here for later.",
                             actionTitle: "Browse Popular", action: { selectTab(.home) })
            }
        } else {
            let shown = arranged
            VStack(alignment: .leading, spacing: Spacing.m) {
                myListControls(inset: inset)
                if shown.isEmpty {
                    StateMessage(systemImage: listFilter == .films ? "film" : "tv",
                                 title: listFilter == .films ? "No films on your list" : "No TV shows on your list",
                                 message: "Your list has \(watchlist.count) title\(watchlist.count == 1 ? "" : "s"), none of them \(listFilter == .films ? "films" : "TV shows").",
                                 actionTitle: "Show All") { listFilter = .all }
                } else {
                    LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Spacing.cardGap) {
                        ForEach(shown) { t in
                            TitleCardLink(t) {
                                PosterCard(title: t.name, url: app.imageURL(t.poster, width: grid.itemWidth), width: grid.itemWidth)
                            }
                            .accessibilityAction(named: "Remove from My List") { removeFromMyList(t) }
                        }
                    }
                    .padding(.horizontal, inset)
                    .animation(Motion.snappy(reduceMotion), value: shown.map(\.key))
                }
            }
        }
    }

    /// All / Films / TV chips, and the sort menu on the right.
    private func myListControls(inset: CGFloat) -> some View {
        HStack(spacing: Spacing.s) {
            ForEach(MyListFilter.allCases) { f in
                CategoryChip(f.title, selected: listFilter == f) {
                    withAnimation(Motion.snappy(reduceMotion)) { listFilter = f }
                }
                .accessibilityIdentifier("myList.filter.\(f.rawValue)")
            }
            Spacer(minLength: Spacing.s)
            BlueboxMenu("Sort") {
                BlueboxMenuSection("Sort By") {
                    for s in MyListSort.allCases {
                        BlueboxMenuButton(s.title, checked: listSort == s) {
                            withAnimation(Motion.snappy(reduceMotion)) { listSort = s }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(listSort.title).font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .foregroundStyle(Palette.textSecondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Sort: \(listSort.title)")
            .accessibilityIdentifier("myList.sort")
        }
        .padding(.horizontal, inset)
        .selectionHaptic(listFilter)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// Takes a title off My List at once, with Undo in a toast.
    private func removeFromMyList(_ t: Title) {
        let before = watchlist
        Task {
            let removed = await app.optimistic("Couldn't remove from My List", from: before,
                                               to: before.filter { $0.key != t.key },
                                               apply: { list in withAnimation(Motion.standard(reduceMotion)) {
                                                   watchlist = list
                                                   rearrange()
                                               } }) {
                try await app.setOnMyList(t, false)
            }
            guard removed else { return }
            app.showToast(AppToast(t.name, message: "Removed from My List", actionTitle: "Undo") { [app] in
                Task { await app.optimistic("Couldn't add back to My List", from: false, to: true, apply: { _ in }) {
                    try await app.setOnMyList(t, true)
                } }
            })
        }
    }

    // MARK: Lists

    /// My List, your lists and smart lists as mosaic tiles, with + for a new list.
    @ViewBuilder private func lists(inset: CGFloat, width: CGFloat) -> some View {
        if loaded && libraryFailed && summaries.isEmpty {
            libraryFailure(hasContent: false)
        } else {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack {
                    Text("Your lists sync to your other devices. Smart lists fill themselves.")
                        .font(.footnote).foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.s)
                    Button { app.listEditor = ListEditorRequest(list: nil, adding: nil) } label: {
                        Label("New List", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("lists.new")
                }
                .padding(.horizontal, inset)
                ListsGrid(summaries: summaries, loaded: loaded, inset: inset, width: width)
            }
        }
    }

    // MARK: Continue Watching

    @ViewBuilder private func continueWatching(metrics: CardMetrics, inset: CGFloat, width: CGFloat) -> some View {
        if watching.isEmpty && loaded && libraryFailed {
            libraryFailure(hasContent: false)
        } else if watching.isEmpty && loaded {
            StateMessage(systemImage: "play.rectangle", title: "Nothing in progress",
                         message: "Movies and episodes you start appear here, so you can pick up where you left off.",
                         actionTitle: "Browse Popular", action: { selectTab(.home) })
        } else if width < 500 {
            // iPhone: full-width rows, Netflix's downloads-style list.
            LazyVStack(spacing: 0) {
                ForEach(watching) { entry in
                    ContinueWatchingRow(entry: entry,
                                        imageURL: app.imageURL(entry.title.backdrop, width: ContinueWatchingRow.thumbnailWidth),
                                        play: { play(entry) }, details: { pushRoute(.title(entry.title)) },
                                        remove: { removeFromContinueWatching(entry) })
                }
            }
            .padding(.horizontal, inset)
        } else {
            let grid = FittedGrid(width: width - inset * 2, minimum: metrics.landscapeWidth, gap: Spacing.m)
            LazyVGrid(columns: grid.columns, alignment: .leading, spacing: Spacing.l) {
                ForEach(watching) { entry in
                    ResumeCardButton(entry, style: .plain, play: { play(entry) }, details: { pushRoute(.title(entry.title)) },
                                     remove: { removeFromContinueWatching(entry) }) {
                        LandscapeCard(title: entry.title.name, subtitle: entry.label,
                                      url: app.imageURL(entry.title.backdrop, width: grid.itemWidth),
                                      width: grid.itemWidth, progress: entry.progress.fraction, showsPlayGlyph: true)
                    }
                }
            }
            .padding(.horizontal, inset)
        }
    }

    private func play(_ entry: WatchEntry) {
        Task {
            await app.play(NowPlayingItem(key: entry.progress.key, title: entry.title.name,
                                          subtitle: entry.progress.key.episodeNumbers.map { "S\($0.season)·E\($0.episode)" }))
        }
    }

    /// Takes an item out of Continue Watching at once, with Undo in a toast.
    private func removeFromContinueWatching(_ entry: WatchEntry) {
        Task {
            await app.removeFromContinueWatching(entry.progress)
            await load()
            app.showToast(AppToast(entry.title.name, message: "Removed from Continue Watching", actionTitle: "Undo") { [app] in
                Task { await app.restoreToContinueWatching(entry.progress) }
            })
        }
    }

    // MARK: History

    /// What you finished, newest first, under date headings.
    @ViewBuilder private func historyList(inset: CGFloat) -> some View {
        if history.isEmpty && loaded {
            if libraryFailed {
                libraryFailure(hasContent: false)
            } else {
                StateMessage(systemImage: "clock.arrow.circlepath", title: "Nothing watched yet",
                             message: "Films and episodes you finish appear here, by date, so you can find them again.",
                             actionTitle: "Browse Popular", action: { selectTab(.home) })
            }
        } else if !loaded {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: Spacing.m) {
                        SkeletonBlock(width: HistoryRow.artWidth, height: HistoryRow.artWidth * 1.5, radius: Radius.thumbnail)
                        SkeletonBlock(width: 180, height: 14, radius: 4)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, inset)
        } else {
            // One lazy stack for headings and rows alike (grouped in `load`), so
            // a long History builds only the rows on screen.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(historyGroups) { group in
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .padding(.top, group.id == historyGroups.first?.id ? 0 : Spacing.l)
                        .padding(.bottom, Spacing.xs)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.entries) { entry in
                        if entry.id != group.entries.first?.id {
                            Rectangle().fill(Palette.separator).frame(height: 1)
                                .padding(.leading, HistoryRow.artWidth + Spacing.m)
                        }
                        HistoryRow(entry: entry, imageURL: app.imageURL(entry.title.poster, width: HistoryRow.artWidth),
                                   open: { pushRoute(entry.progress.key.episodeNumbers != nil
                                                     ? .episode(entry.title, entry.progress.key) : .title(entry.title)) },
                                   remove: { removeFromHistory(entry) })
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, inset)
        }
    }

    // MARK: My Sources

    @ViewBuilder private func sources(inset: CGFloat) -> some View {
        if !unreachableSources.isEmpty {
            InlineNotice(systemImage: "wifi.exclamationmark",
                         "Couldn't reach \(ListFormatter.localizedString(byJoining: unreachableSources))",
                         actionTitle: "Retry") { Task { await load() } }
                .padding(.horizontal, inset)
        }
        if groups.allSatisfy({ $0.items.isEmpty }) && loaded && unreachableSources.isEmpty {
            StateMessage(systemImage: "externaldrive.badge.plus", title: "No media sources",
                         message: "Add a folder of videos, a direct link or a Jellyfin server to watch what you already have.",
                         actionTitle: "Add a Source", action: openSourceSettings)
        }
        ForEach(groups.filter { !$0.items.isEmpty }) { group in
            VStack(alignment: .leading, spacing: Spacing.s) {
                if sourceFilter == nil {
                    Text(group.name).font(Typography.rowTitle).padding(.horizontal, inset).accessibilityAddTraits(.isHeader)
                }
                VStack(spacing: 0) {
                    ForEach(group.items) { item in
                        if item.id != group.items.first?.id {
                            // Inset to the text, past the poster, as in a grouped list.
                            Rectangle().fill(Palette.separator).frame(height: 1)
                                .padding(.leading, Spacing.l + SourceItemRow.artWidth + Spacing.m)
                        }
                        SourceItemRow(item: item, posterURL: item.title.flatMap { app.imageURL($0.poster, width: 80) }) {
                            Task {
                                let key = item.variant.mediaKey ?? MediaKey(rawValue: "url:\(item.variant.id)")
                                await app.play(NowPlayingItem(key: key, title: item.title?.name ?? item.variant.displayName,
                                                              subtitle: item.variant.mediaKey?.episodeNumbers.map { "S\($0.season)·E\($0.episode)" }),
                                               variant: item.variant)
                            }
                        }
                    }
                }
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .padding(.horizontal, inset)
            }
        }
    }

    /// The one Settings sheet (iOS) or window (Mac), at Sources.
    private func openSourceSettings() { openSettingsPage(.sources) }
}

/// Columns that exactly fill `width`: as many as fit at `minimum` wide, then
/// widened to share the leftover, so the outer cards sit on the page insets.
struct FittedGrid {
    let count: Int
    let itemWidth: CGFloat
    let gap: CGFloat

    init(width: CGFloat, minimum: CGFloat, gap: CGFloat) {
        let n = max(1, Int((width + gap) / (minimum + gap)))
        count = n
        itemWidth = max(minimum * 0.5, ((width - gap * CGFloat(n - 1)) / CGFloat(n)).rounded(.down))
        self.gap = gap
    }

    var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(itemWidth), spacing: gap, alignment: .top), count: count)
    }
}

/// A Continue Watching row on iPhone: a 16:9 still with the progress along
/// its bottom, the title and what's left, and a ⋯ menu. Tap to resume.
struct ContinueWatchingRow: View {
    @Environment(AppModel.self) private var app
    let entry: WatchEntry
    let imageURL: URL?
    let play: () -> Void
    let details: @MainActor () -> Void
    let remove: @MainActor () -> Void
    @State private var gate = QuickActionGate()

    static let thumbnailWidth: CGFloat = 144

    private var offersNext: Bool { entry.progress.key.episodeNumbers != nil && entry.progress.isNearlyFinished }
    private var subject: QuickActionSubject { QuickActionSubject(title: entry.title, entry: entry, remove: remove) }

    var body: some View {
        HStack(spacing: Spacing.m) {
            Button { if !gate.consumeHold() { play() } } label: {
                HStack(spacing: Spacing.m) {
                    ZStack(alignment: .bottom) {
                        ArtworkView(url: imageURL, fallbackTitle: entry.title.name, kind: .backdrop,
                                    pixelWidth: Int(Self.thumbnailWidth * 2), showsFallbackTitle: false)
                            .frame(width: Self.thumbnailWidth, height: Self.thumbnailWidth * 9 / 16)
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.5), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let fraction = entry.progress.fraction { ProgressStrip(fraction: fraction) }
                    }
                    .frame(width: Self.thumbnailWidth, height: Self.thumbnailWidth * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous).strokeBorder(.white.opacity(0.06)))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title.name)
                            .font(Typography.cardTitle)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if !entry.label.isEmpty {
                            Text(entry.label).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            // Touch and hold: the same menu as the ⋯ (and every poster).
            .quickActions(subject, opened: gate)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resume \(entry.title.name)")
            .accessibilityValue(entry.label)

            QuickActionsMoreButton(subject: subject, size: 44, filled: false)
        }
        .padding(.vertical, Spacing.s)
        .accessibilityAction(named: "Details", details)
        .accessibilityAction(named: "Remove from Row", remove)
    }

    private func playNext() {
        Task { await app.playNextEpisode(after: entry.progress.key, seriesName: entry.title.name) }
    }
}

extension AppModel {
    /// Undo for "Remove from Row": puts the progress back as a newer record, so it syncs.
    func restoreToContinueWatching(_ progress: WatchProgress) async {
        var restored = progress
        restored.updatedAt = .now
        restored.deviceID = prefs.deviceID
        _ = try? await store.save(restored)
        noteLibraryChanged()
    }
}

/// A file in My Sources: the title's poster when it's matched to the catalogue
/// (a folder or link glyph when it isn't), the name, its details, and Play.
struct SourceItemRow: View {
    let item: LibraryView.SourceItem
    let posterURL: URL?
    let play: () -> Void
    @State private var hovering = false

    static let artWidth: CGFloat = 32

    var body: some View {
        let v = item.variant
        let supported = PlaybackEngines.canAttempt(container: v.container)
        HStack(spacing: Spacing.m) {
            Group {
                if let title = item.title {
                    ArtworkView(url: posterURL, fallbackTitle: title.name, kind: .poster, pixelWidth: 80, showsFallbackTitle: false)
                        .frame(width: Self.artWidth, height: Self.artWidth * 1.5)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous))
                } else {
                    Image(systemName: v.location == .remote ? "link" : "folder")
                        .font(.system(size: 17))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: Self.artWidth, height: Self.artWidth * 1.5)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title?.name ?? v.displayName).font(.body.weight(.medium)).lineLimit(2)
                Text([v.mediaKey?.episodeNumbers.map { "S\($0.season)·E\($0.episode)" }, v.resolution, v.container?.uppercased(),
                      v.sizeBytes.map(Formatters.bytes)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !supported {
                Text("Can't Play").font(.caption).foregroundStyle(Palette.textTertiary)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
        .background(hovering ? Palette.elevated : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if supported { play() } }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(supported ? .isButton : [])
        .accessibilityHint(supported ? "Plays it" : "This format can't play on this device")
        .accessibilityAction { if supported { play() } }
    }
}

/// A History row: the poster, the title and episode, when it was finished,
/// and a ⋯ with Remove from History. Tap opens the title (on the episode).
struct HistoryRow: View {
    let entry: HistoryEntry
    let imageURL: URL?
    let open: () -> Void
    let remove: @MainActor () -> Void
    @State private var hovering = false

    static let artWidth: CGFloat = 34

    var body: some View {
        HStack(spacing: Spacing.m) {
            Button(action: open) {
                HStack(spacing: Spacing.m) {
                    ArtworkView(url: imageURL, fallbackTitle: entry.title.name, kind: .poster,
                                pixelWidth: Int(Self.artWidth * 2), showsFallbackTitle: false)
                        .frame(width: Self.artWidth, height: Self.artWidth * 1.5)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title.name).font(Typography.cardTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Text(entry.detail).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: Spacing.s)
                    Text(WatchHistory.shortDate(entry.finishedAt))
                        .font(.caption).foregroundStyle(Palette.textTertiary)
                }
                .padding(.vertical, Spacing.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.title.name), \(entry.detail)")
            .accessibilityValue("Finished \(entry.finishedAt.formatted(date: .abbreviated, time: .omitted))")

            BlueboxMenu(entry.title.name) {
                BlueboxMenuButton("Remove from History", systemImage: "minus.circle", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More for \(entry.title.name)")
        }
        .background(hovering ? Palette.surface.opacity(0.6) : .clear)
        .onHover { hovering = $0 }
        .accessibilityAction(named: "Remove from History", remove)
    }
}

/// "Real-Debrid Library ›": opens `DebridLibraryView`. Shown once a debrid
/// service with a browsable library is set up.
struct DebridLibraryEntry: View {
    let name: String
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: Route.debridLibrary) {
            HStack(spacing: Spacing.m) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(name) Library").font(Typography.cardTitle).foregroundStyle(Palette.textPrimary)
                    Text("Everything in your cloud").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.m)
            .frame(maxWidth: 520)
            .background(hovering ? Palette.elevated : Palette.surface,
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 1))
        .onHover { hovering = $0 }
        .accessibilityIdentifier("debridLibraryEntry")
    }
}

// DownloadsView, DownloadRow and DownloadButton live in DownloadsView.swift.
