import DesignSystem
import Domain
import Observation
import Playback
import SwiftUI

@Observable
@MainActor
final class TitleDetailModel {
    let title: Title
    var detail: TitleDetail?
    var ratings: ExternalRatings?
    var error: Error?
    var onList = false

    // Movie
    var movieProgress: WatchProgress?
    var movieAvailability: Availability?

    // Series
    var seriesProgress: [MediaKey: WatchProgress] = [:]
    var target: SeriesCursor.Target?
    var targetAvailability: Availability?
    var targetAvailable: Bool { targetAvailability?.isPlayable ?? false }
    var selectedSeason: Int?
    var season: Season?
    var seasonError: Error?
    var playableEpisodes: Set<MediaKey> = []
    /// Episodes a source would let you download (the round ↓ shows for these).
    var downloadableEpisodes: Set<MediaKey> = []
    /// Rates for the season menu's "about" sizes.
    var sizeEstimate = SeasonSizeEstimate(bytesPerMinute: nil, fallbackBytesPerMinute: SeasonSizeEstimate.typicalBytesPerMinute(resolution: nil))
    /// Set once the page has scrolled to the episode you're up to.
    var didScrollToNext = false
    /// An episode to open on (its season, scrolled to it), e.g. from a new-episode alert.
    let focus: MediaKey?

    // Trailers & More
    /// True once the title (or the season shown) has trailers or extras.
    var hasExtras = false
    /// The season whose videos Trailers & More shows; nil for the title's own.
    var extrasSeason: Int?
    /// The title's own trailer, for the Trailer tile.
    var trailer: TitleVideo?

    init(title: Title, focus: MediaKey? = nil) { self.title = title; self.focus = focus }

    /// True once any episode of the show has been started or finished.
    var hasSeriesProgress: Bool { seriesProgress.values.contains { $0.isCompleted || $0.position > 0 } }

    var seasonMemoryKey: String { "season." + title.key.rawValue }

    var display: Title { detail?.title ?? title }

    func load(_ app: AppModel) async {
        onList = (try? await app.store.isOnWatchlist(title.key)) ?? false
        do {
            let d = try await app.metadata.detail(for: title.key)
            detail = d
            error = nil
            try? await app.store.store([d.title])
            ratings = await app.externalRatings(for: d)
        } catch {
            self.error = error
        }
        await refreshProgress(app)
        // A Jellyfin or Emby server may know of watching since its library last
        // loaded; anything newer bumps libraryRevision, which redraws the page.
        Task { [key = title.key] in await app.refreshServerProgress(for: key) }
        sizeEstimate.fallbackBytesPerMinute = SeasonSizeEstimate.typicalBytesPerMinute(resolution: app.addonSettings.preferredResolution)
        if title.kind == .series, selectedSeason == nil {
            // Once you've started the show, the page opens on the episode you're
            // up to, in its season. Before that, the season this profile last
            // picked here (if it still exists), else the first.
            let remembered = ViewMemory.int(seasonMemoryKey, profile: app.currentProfileID)
                .flatMap { n in detail?.seasons.contains { $0.number == n } == true ? n : nil }
            let upTo = focus?.episodeNumbers?.season ?? (hasSeriesProgress ? target?.season : nil)
            selectedSeason = upTo ?? remembered ?? target?.season ?? detail?.seasons.first { $0.number > 0 }?.number ?? detail?.seasons.first?.number
        }
        async let extras: Void = loadExtras(app)
        if let s = selectedSeason { await loadSeason(s, app) }
        await extras
    }

    /// Trailers & More: the season's videos when it has its own, else the title's.
    func loadExtras(_ app: AppModel) async {
        let own = await app.videos(for: title.key)
        trailer = VideoRanking.heroTrailer(own, language: AppModel.preferredLanguage)
        if title.kind == .series, let s = selectedSeason, !(await app.videos(for: title.key, season: s)).isEmpty {
            extrasSeason = s
            hasExtras = true
            return
        }
        extrasSeason = nil
        hasExtras = !own.isEmpty
    }

    /// Films not out yet, and shows (whose next episodes can be announced), get Remind Me.
    var offersReminder: Bool {
        let t = display
        if t.kind == .series { return true }
        guard let date = t.releaseDate else { return false }
        return date > Calendar.current.startOfDay(for: .now)
    }

    func refreshProgress(_ app: AppModel) async {
        if title.kind == .movie {
            movieProgress = try? await app.store.progress(for: title.key)
            movieAvailability = await app.availability(for: title.key)
        } else if title.key.isSeries {
            let all = (try? await app.store.progress(forSeries: title.key)) ?? []
            seriesProgress = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            target = SeriesCursor.target(series: title.key, progress: all, seasons: detail?.seasons ?? [])
            if let t = target { targetAvailability = await app.availability(for: t.key) } else { targetAvailability = Availability.none }
        }
    }

    func loadSeason(_ number: Int, _ app: AppModel) async {
        seasonError = nil
        do {
            let s = try await app.metadata.season(number, of: title.key)
            guard selectedSeason == number else { return }
            season = s
            let keys = s.episodes.map(\.key)
            var playable = Set<MediaKey>(), downloadable = Set<MediaKey>()
            await withTaskGroup(of: (MediaKey, Bool, Bool).self) { group in
                for k in keys {
                    group.addTask {
                        let a = await app.availability(for: k)
                        return (k, a.isPlayable, a.variants.contains { $0.isDownloadable && $0.location == .remote })
                    }
                }
                for await (k, ok, canDownload) in group {
                    if ok { playable.insert(k) }
                    if canDownload { downloadable.insert(k) }
                }
            }
            #if DEBUG
            // Screenshots: `-demo-downloadable` treats every episode as downloadable (the season's ↓ menu shows).
            if ProcessInfo.processInfo.arguments.contains("-demo-downloadable") { downloadable = Set(keys) }
            #endif
            playableEpisodes = playable
            downloadableEpisodes = downloadable
            await estimateSizes(for: s, app)
        } catch {
            seasonError = error
        }
    }

    /// Looks up the best release of one episode (the one you're up to, else
    /// the first unwatched) to size the season's downloads by.
    private func estimateSizes(for season: Season, _ app: AppModel) async {
        guard sizeEstimate.bytesPerMinute == nil else { return }
        let probe = season.episodes.first { $0.key == target?.key }
            ?? season.episodes.first { seriesProgress[$0.key]?.isCompleted != true && downloadableEpisodes.contains($0.key) }
        guard let probe, downloadableEpisodes.contains(probe.key) else { return }
        if let rate = SeasonSizeEstimate.rate(releaseBytes: await app.bestReleaseBytes(for: probe.key),
                                              runtimeMinutes: probe.runtimeMinutes) {
            sizeEstimate.bytesPerMinute = rate
        }
    }

    func selectSeason(_ number: Int, _ app: AppModel) {
        guard number != selectedSeason else { return }
        selectedSeason = number
        ViewMemory.set(number, seasonMemoryKey, profile: app.currentProfileID)
        season = nil
        Task {
            await loadSeason(number, app)
            await loadExtras(app)
        }
    }
}

struct TitleDetailView: View {
    /// The tabs under the header. Trailers & More shows once the title (or
    /// season) has videos; Cast & Crew opens person pages with TMDB.
    enum Tab: String, CaseIterable, Identifiable {
        case episodes = "Episodes", related = "More Like This", trailers = "Trailers & More", cast = "Cast & Crew"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isDownloaded) private var isDownloaded
    @State private var model: TitleDetailModel
    @State private var releaseItem: ReleaseRequest?
    /// Play's ▾ (or a right-click on Play): Start a Party, Releases….
    @State private var playMenuOpen = false
    @State private var tab: Tab
    @State private var overviewExpanded = false
    @State private var showingSeasons = false
    @State private var seasonMenuOpen = false
    /// The show's Download Rules sheet, from the season's ↓ menu.
    @State private var editingRules = false
    /// Delete Season Downloads asks first (it's many files at once).
    @State private var confirmSeasonDelete: Season?
    /// Download Season waiting on "Download on mobile data?" or a big size.
    @State private var seasonRequest: SeasonDownloadRequest?
    @State private var playingTrailer: TitleVideo?
    @Environment(\.openSettingsPage) private var openSettingsPage
    @Environment(\.notePlayOrigin) private var notePlayOrigin
    /// Where the header's artwork is: Play's launch surface grows from it.
    @State private var artworkAnchor = PlayOriginAnchor()
    @Namespace private var tabIndicator

    struct ReleaseRequest: Identifiable {
        let item: NowPlayingItem
        var id: String { item.key.rawValue }
    }

    @Environment(\.pushRoute) private var pushRoute

    init(title: Title, focus: MediaKey? = nil) {
        _model = State(initialValue: TitleDetailModel(title: title, focus: focus))
        _tab = State(initialValue: title.kind == .series ? .episodes : .related)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let compact = width < 600
            let inset = Spacing.pageInset(for: width)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        if compact {
                            compactHeader(width: width, inset: inset, topInset: geo.safeAreaInsets.top)
                        } else {
                            wideHeader(width: width, inset: inset)
                        }
                        if let error = model.error, model.detail == nil {
                            // The title, art and Play stay above; what needed the catalog says why it's missing.
                            detailFailure(error)
                        } else {
                            tabs(inset: inset, width: width)
                        }
                        if app.catalogMode == .live {
                            CatalogFooter(mode: .live).padding(.horizontal, inset)
                        }
                    }
                    .padding(.bottom, Spacing.xxxl)
                }
                .scrollIndicators(.hidden)
                .reportsHeaderScroll()
                .ignoresSafeArea(edges: .top)
                // Pull to refresh keeps the page as it is while it reloads.
                .refreshable { await model.load(app) }
                .refreshShortcut { await model.load(app) }
                .onChange(of: model.season?.number) { scrollToNextEpisode(proxy) }
            }
        }
        .blueboxScreen()
        #if os(iOS)
        // "Play on" a Mac: the page opens there too, so the room sees what you're looking at.
        .onAppear { app.remote.follow(.title(model.title.key)) }
        .fullScreenCover(isPresented: $showingSeasons) {
            seasonList.presentationBackground(.clear)
        }
        #else
        .overlay {
            if showingSeasons { seasonList.transition(.opacity) }
        }
        .animation(Motion.standard(reduceMotion), value: showingSeasons)
        #endif
        .navigationTitle(model.display.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // The bar's background (clear over the art, solid once scrolled) comes from RootView's `PageChrome`.
        #endif
        .task(id: app.sourcesRevision) { await model.load(app) }
        .reloadsWhenBackOnline(model.error != nil && model.detail == nil) { await model.load(app) }
        .onChange(of: app.libraryRevision) { Task { await model.refreshProgress(app) } }
        .sheet(item: $releaseItem) { request in ReleasePickerSheet(item: request.item, canOpenSettings: true) }
        .sheet(isPresented: $editingRules) {
            ShowDownloadRulesSheet(series: model.title.key, showName: model.display.name).environment(app)
        }
        #if DEBUG
        .task {
            // Screenshots: `-title-tab "Cast & Crew"` opens on that tab.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-title-tab"), args.indices.contains(i + 1), let t = Tab(rawValue: args[i + 1]) { tab = t }
        }
        .task(id: model.detail == nil) {
            // Screenshots: `-open-releases` opens the release list once the page has loaded.
            guard model.detail != nil, ProcessInfo.processInfo.arguments.contains("-open-releases"), releaseItem == nil,
                  let key = primaryKey ?? (model.title.kind == .movie ? model.title.key : nil) else { return }
            releaseItem = ReleaseRequest(item: nowPlayingItem(for: key))
        }
        .task(id: model.target?.key) {
            // Screenshots: `-show-preparing` shows the overlay Play puts up while it opens a release.
            guard ProcessInfo.processInfo.arguments.contains("-show-preparing"), model.detail != nil,
                  let key = primaryKey else { return }
            try? await Task.sleep(for: .seconds(1))
            app.debugShowPreparing(nowPlayingItem(for: key))
        }
        .task(id: model.season?.number) {
            // Screenshots: `-open-seasons` / `-open-season-menu` once a season has loaded.
            guard model.season != nil else { return }
            let args = ProcessInfo.processInfo.arguments
            try? await Task.sleep(for: .milliseconds(900))
            if args.contains("-open-seasons"), !showingSeasons { openSeasons() }
            if args.contains("-open-season-menu"), !seasonMenuOpen { seasonMenuOpen = true }
            if args.contains("-open-download-rules") { editingRules = true }
        }
        #endif
        .successHaptic(model.onList)
        .confirmationDialog(seasonDeleteTitle, isPresented: Binding(get: { confirmSeasonDelete != nil },
                                                                    set: { if !$0 { confirmSeasonDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmSeasonDelete) { season in
            let downloads = seasonPlan(season).downloads
            Button("Delete \(downloads.count) Episode\(downloads.count == 1 ? "" : "s")", role: .destructive) {
                app.deleteDownloads(downloads)
            }
            Button("Cancel", role: .cancel) {}
        } message: { season in
            let plan = seasonPlan(season)
            Text("Frees \(Formatters.bytes(plan.downloadedBytes)) on this device.")
        }
        .confirmationDialog(seasonRequest?.title ?? "", isPresented: Binding(get: { seasonRequest != nil },
                                                                             set: { if !$0 { seasonRequest = nil } }),
                            titleVisibility: .visible, presenting: seasonRequest) { request in
            let n = request.episodes.count
            switch request.check {
            case .mobileData(_, _, let wifiOnly):
                Button("Download on Wi‑Fi") { startSeason(request, mobileData: false) }
                Button(wifiOnly ? "Download Now on Mobile Data" : "Download Now") { startSeason(request, mobileData: true) }
            default:
                Button(n == 1 ? "Download 1 Episode" : "Download \(n) Episodes") { startSeason(request, mobileData: nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        // On its own view, apart from the release sheet above.
        .background { Color.clear.sheet(item: $playingTrailer) { TrailerSheet(video: $0) } }
    }

    // MARK: Headers

    /// iPhone: backdrop on top, then the title block and full-width buttons below it.
    private func compactHeader(width: CGFloat, inset: CGFloat, topInset: CGFloat) -> some View {
        let height = width * 9 / 16 + topInset
        let t = model.display
        return VStack(alignment: .leading, spacing: Spacing.m) {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(url: app.imageURL(t.backdrop ?? t.poster, width: width), fallbackTitle: t.name, kind: .backdrop,
                            pixelWidth: Int(width * 2), showsFallbackTitle: false)
                    .frame(width: width, height: height)
                    .modifier(PlayOriginReporter(anchor: artworkAnchor))
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.35),
                                       .init(color: .clear, location: 0.6), .init(color: Palette.background, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: width, height: height)
            .clipped()

            VStack(alignment: .leading, spacing: Spacing.m) {
                titleBlock(width: width, compact: true)
                // The primary button alone at full width; the secondary ones
                // (Download, Start Over) share the row under it, or stack when
                // their labels don't fit side by side.
                VStack(spacing: Spacing.s) {
                    primaryButton(fullWidth: true)
                    HeroButtonRow(spacing: Spacing.s) {
                        downloadButton(fullWidth: true)
                        if resumeKey != nil { startOverButton.buttonStyle(SecondaryButtonStyle(fullWidth: true)) }
                    }
                }
                progressAndHint
                overview(compact: true)
                creditsSummary
                genresLine
                collectionRow
                // Four columns across a phone; past that the last ones fold into More.
                actionTiles(columns: 4)
                    .padding(.top, Spacing.xs)
            }
            .padding(.horizontal, inset)
            // Tuck the title into the backdrop's fade.
            .padding(.top, -Spacing.xxl)
        }
    }

    /// iPad and Mac: full-bleed backdrop with the title and buttons over it,
    /// then the overview beside the credits.
    private func wideHeader(width: CGFloat, inset: CGFloat) -> some View {
        let height = min(max(width * 0.48, 420), 620)
        let t = model.display
        return VStack(alignment: .leading, spacing: Spacing.xl) {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(url: app.imageURL(t.backdrop ?? t.poster, width: width), fallbackTitle: t.name, kind: .backdrop,
                            pixelWidth: Int(width * 2), showsFallbackTitle: false)
                    .frame(width: width, height: height)
                    .modifier(PlayOriginReporter(anchor: artworkAnchor))
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: Palette.background.opacity(0.75), location: 0.78),
                                       .init(color: Palette.background, location: 1)], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [Palette.background.opacity(0.8), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.6, y: 0.5))
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
                VStack(alignment: .leading, spacing: Spacing.m) {
                    titleBlock(width: width, compact: false)
                    HStack(spacing: Spacing.m) {
                        primaryButton(fullWidth: false)
                        downloadButton(fullWidth: false)
                        if resumeKey != nil { startOverButton.buttonStyle(SecondaryButtonStyle()).fixedSize() }
                    }
                    .padding(.top, Spacing.xs)
                    progressAndHint
                }
                .padding(.horizontal, inset)
                .padding(.bottom, Spacing.l)
            }
            .frame(width: width, height: height)
            .clipped()

            HStack(alignment: .top, spacing: Spacing.xxl) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    overview(compact: false)
                    creditsSummary
                    actionTiles(columns: 5)
                }
                .frame(maxWidth: 640, alignment: .leading)
                VStack(alignment: .leading, spacing: Spacing.m) {
                    genresLine
                    collectionRow
                }
                .frame(maxWidth: 320, alignment: .leading)
            }
            .padding(.horizontal, inset)
        }
    }

    private func titleBlock(width: CGFloat, compact: Bool) -> some View {
        let t = model.display
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: 6) {
                // Grey, not blue: blue marks state only.
                Image(systemName: t.kind == .series ? "tv" : "film").font(.caption.weight(.bold)).foregroundStyle(Palette.textSecondary)
                Text(t.kind == .series ? "SERIES" : "FILM").font(.caption.weight(.heavy)).tracking(2.4)
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityHidden(true)
            if let logo = model.detail?.logo, let url = app.imageURL(logo, width: 400) {
                ArtworkView(url: url, fallbackTitle: t.name, kind: .logo, pixelWidth: 800)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(width * 0.6, 420), maxHeight: compact ? 90 : 140, alignment: .bottomLeading)
                    .accessibilityLabel(t.name)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Text(t.name)
                    .font(compact ? Typography.titleHero : Typography.display(compact: false))
                    .lineLimit(3).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(compact ? 0 : 0.5), radius: 10)
                    .accessibilityAddTraits(.isHeader)
            }
            metaLine
            if let ratings = model.ratings { RatingsRow(ratings: ratings) }
        }
    }

    /// Year, match score, certification, runtime or seasons, and quality.
    private var metaLine: some View {
        let t = model.display
        let quality = app.qualityLabel(t.kind == .movie ? model.movieAvailability : model.targetAvailability)
        return ViewThatFits(in: .horizontal) {
            metaRow(t, quality: quality)
            VStack(alignment: .leading, spacing: 4) { metaRow(t, quality: quality) }
        }
        .accessibilityElement(children: .combine)
    }

    private func metaRow(_ t: Title, quality: String?) -> some View {
        HStack(spacing: Spacing.s) {
            if let v = t.voteAverage, v > 0 {
                // White and bold, not blue: a score isn't state.
                Text("\(Int((v * 10).rounded()))% Match")
                    .foregroundStyle(Palette.textPrimary).fontWeight(.bold)
                    .accessibilityLabel("Rated \(String(format: "%.1f", v)) out of 10")
            }
            if let y = t.year { Text(String(y)) }
            if let c = model.detail?.certification, !c.isEmpty { OutlineTag(c) }
            if t.kind == .movie, let r = model.detail?.runtimeMinutes, r > 0 { Text(Formatters.runtime(minutes: r)) }
            if t.kind == .series, let n = model.detail?.seasons.filter({ $0.number > 0 }).count, n > 0 {
                Text(n == 1 ? "1 Season" : "\(n) Seasons")
            }
            if let quality { OutlineTag(quality) }
            if isDownloaded(primaryKey ?? t.key) { DownloadedBadge() }
        }
        .font(Typography.meta)
        .foregroundStyle(Palette.textSecondary)
        .lineLimit(1)
    }

    // MARK: Actions

    @ViewBuilder private func downloadButton(fullWidth: Bool) -> some View {
        if model.title.kind == .movie {
            DownloadButton(key: model.title.key, title: model.display.name, fullWidth: fullWidth)
        } else if let target = model.target {
            DownloadButton(key: target.key, title: model.display.name, subtitle: "S\(target.season)·E\(target.episode)",
                           fullWidth: fullWidth)
        }
    }

    /// The action tiles, always in the order My List, Rate, Trailer, Share,
    /// More (DECISIONS.md, UI review 2). Remind Me, Mark Watched and Releases
    /// live under More.
    private enum ActionTile: Hashable { case myList, rate, trailer, share, remind, watched, releases, openIn }

    /// The tiles that get a column of their own when there's room, in order.
    private var leadingTiles: [ActionTile] {
        var tiles: [ActionTile] = [.myList, .rate]
        if model.trailer != nil { tiles.append(.trailer) }
        if shareURL != nil { tiles.append(.share) }
        return tiles
    }

    /// What More holds when nothing had to fold into it.
    private var moreTiles: [ActionTile] {
        var tiles: [ActionTile] = []
        if model.offersReminder { tiles.append(.remind) }
        if model.title.kind == .movie { tiles.append(.watched) }
        if app.addonSettings.isEnabled, primaryKey != nil { tiles.append(.releases) }
        if isPlayable, primaryKey != nil, !ExternalPlayer.installed.isEmpty { tiles.append(.openIn) }
        return tiles
    }

    /// The tile row in `columns` columns: the leading tiles, then More. When
    /// they don't all fit, the last leading tiles fold into More, ahead of its own.
    private func actionTiles(columns: Int) -> some View {
        let leading = leadingTiles, extra = moreTiles
        let needsMore = !extra.isEmpty || leading.count > columns
        let shown = needsMore ? Array(leading.prefix(columns - 1)) : leading
        let folded = Array(leading.dropFirst(shown.count)) + extra
        let used = shown.count + (folded.isEmpty ? 0 : 1)
        return HStack(alignment: .top, spacing: 0) {
            ForEach(shown, id: \.self) { tile in
                actionTile(tile).frame(maxWidth: .infinity)
            }
            if !folded.isEmpty { moreTile(folded).frame(maxWidth: .infinity) }
            // Fewer tiles than columns: each column keeps its width, from the leading edge.
            ForEach(0..<max(0, columns - used), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        }
        // Wide screens: five even columns, not spread across the page.
        .frame(maxWidth: columns >= 5 ? 480 : .infinity, alignment: .leading)
        .buttonStyle(ActionTileStyle())
    }

    @ViewBuilder private func actionTile(_ tile: ActionTile) -> some View {
        switch tile {
        case .myList: myListTile
        case .rate: rateTile
        case .trailer:
            if let trailer = model.trailer {
                Button { playingTrailer = trailer } label: { Label("Trailer", systemImage: "play.rectangle") }
                    .accessibilityIdentifier("trailerButton")
            }
        case .share:
            if let url = shareURL {
                ShareLink(item: url, subject: Text(model.display.name)) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        case .remind: RemindMeButton(title: model.display, tile: true).modifier(TileFrame())
        case .watched: watchedTile
        case .releases: releasesTile
        case .openIn: EmptyView()  // only ever under More
        }
    }

    /// "More": the tiles that didn't get a column, in a Bluebox menu.
    private func moreTile(_ tiles: [ActionTile]) -> some View {
        BlueboxMenu("More") {
            moreEntries(tiles)
        } label: {
            TileLabel(title: "More", symbol: "ellipsis")
        }
        .accessibilityLabel("More Actions")
        .accessibilityIdentifier("moreActions")
    }

    private func moreEntries(_ tiles: [ActionTile]) -> [BlueboxMenuEntry] {
        let key = model.title.key
        let display = model.display
        let watched = model.movieProgress?.isCompleted == true
        let reminder = app.isReminderSet(key)
        var entries: [BlueboxMenuEntry] = []
        for tile in tiles {
            switch tile {
            case .releases:
                guard let k = primaryKey else { continue }
                entries += BlueboxMenuButton("Releases…", systemImage: "list.bullet.rectangle") {
                    releaseItem = ReleaseRequest(item: nowPlayingItem(for: k))
                }.entries
            case .watched:
                entries += BlueboxMenuButton(watched ? "Mark as Unwatched" : "Mark as Watched",
                                             systemImage: watched ? "circle" : "checkmark.circle") {
                    markMovie(!watched)
                }.entries
            case .remind:
                entries += BlueboxMenuButton("Remind Me", systemImage: reminder ? "bell.fill" : "bell", checked: reminder) {
                    Task {
                        let granted = await app.setReminder(!reminder, for: display)
                        if !granted {
                            app.alert = AppAlert(title: "Notifications are off",
                                                 message: "Bluebox will list \(display.name) in Coming Soon. To get an alert, allow notifications for Bluebox in System Settings.")
                        }
                    }
                }.entries
            case .share:
                entries += BlueboxMenuButton("Share…", systemImage: "square.and.arrow.up") { shareTitle() }.entries
            case .trailer:
                guard let trailer = model.trailer else { continue }
                entries += BlueboxMenuButton("Trailer", systemImage: "play.rectangle") { playingTrailer = trailer }.entries
            case .openIn:
                guard let k = primaryKey else { continue }
                entries += ExternalPlayerMenuSection(players: ExternalPlayer.installed) { player in
                    Task { await app.play(nowPlayingItem(for: k), in: player) }
                }.entries
            case .myList, .rate:
                continue
            }
        }
        return entries
    }

    /// The system share sheet for the title's TMDB page (from the More menu).
    private func shareTitle() {
        if let url = shareURL { ShareSheet.present(url) }
    }

    /// Netflix's thumbs, kept as a 1–10 rating (2, 7 or 10) that syncs to Trakt.
    private var rateTile: some View {
        let key = model.title.key
        let rating = app.trakt.rating(for: key)
        let thumb = RatingThumb(rating)
        let name = model.display.name
        return BlueboxMenu("Rate \(name)") {
            BlueboxMenuSection("Rate \(name)") {
                BlueboxMenuButton("Not for Me", systemImage: "hand.thumbsdown", checked: thumb == .down) {
                    app.trakt.setRating(RatingThumb.down.rating, for: key)
                }
                BlueboxMenuButton("I Like This", systemImage: "hand.thumbsup", checked: thumb == .up) {
                    app.trakt.setRating(RatingThumb.up.rating, for: key)
                }
                BlueboxMenuButton("Love This!", systemImage: "heart", checked: thumb == .love) {
                    app.trakt.setRating(RatingThumb.love.rating, for: key)
                }
            }
            if rating != nil {
                BlueboxMenuSection {
                    BlueboxMenuButton("Clear Rating", systemImage: "xmark.circle") { app.trakt.setRating(nil, for: key) }
                }
            }
            BlueboxMenuNote(rating.map { "Your rating: \($0)/10" + (app.trakt.isConnected ? " · synced to Trakt" : "") }
                            ?? (app.trakt.isConnected ? "Ratings sync to Trakt" : "Kept on this device"))
        } label: {
            TileLabel(title: thumb?.label ?? "Rate", symbol: thumb?.symbol ?? "hand.thumbsup", highlighted: thumb != nil)
        }
        .fixedSize()
        .selectionHaptic(rating)
        .accessibilityLabel(thumb.map { "Rated: \($0.label)" } ?? "Rate")
        .accessibilityIdentifier("rateButton")
    }

    /// Marks the film watched or unwatched on screen at once; the save follows
    /// and is undone, with a toast, if it fails.
    private func markMovie(_ watched: Bool) {
        let key = model.title.key, old = model.movieProgress
        let new = WatchProgress(key: key, position: watched ? (old?.duration ?? 1) : 0, duration: old?.duration,
                                isCompleted: watched, updatedAt: .now, deviceID: app.prefs.deviceID)
        Task {
            await app.optimistic(watched ? "Couldn't mark as watched" : "Couldn't mark as unwatched",
                                 from: old, to: new, apply: { model.movieProgress = $0 }) { try await app.setWatched(key, watched) }
        }
    }

    /// Episodes (one, or a season) marked watched or unwatched, the same way.
    private func markEpisodes(_ episodes: [Episode], watched: Bool) {
        let old = model.seriesProgress
        let new = AppModel.progressAfterMarking(episodes, watched: watched, current: old, deviceID: app.prefs.deviceID)
        Task {
            await app.optimistic(watched ? "Couldn't mark as watched" : "Couldn't mark as unwatched",
                                 from: old, to: new, apply: { p in withAnimation(Motion.snappy(reduceMotion)) { model.seriesProgress = p } }) {
                try await app.setWatched(episodes, watched: watched, current: old)
            }
        }
    }

    /// Mark a film watched or unwatched (episodes have it in their rows and the season menu).
    @ViewBuilder private var watchedTile: some View {
        if model.title.kind == .movie {
            let watched = model.movieProgress?.isCompleted == true
            Button { markMovie(!watched) } label: {
                Label(watched ? "Watched" : "Mark Watched", systemImage: watched ? "checkmark.circle.fill" : "checkmark.circle")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityValue(watched ? "Watched" : "Not watched")
            .accessibilityIdentifier("watchedButton")
        }
    }

    /// Tap toggles My List; press and hold (or right-click on Mac) opens Add to List.
    private var myListTile: some View { MyListTile(model: model) }

    @ViewBuilder private var releasesTile: some View {
        if app.addonSettings.isEnabled, let key = primaryKey {
            Button { releaseItem = ReleaseRequest(item: nowPlayingItem(for: key)) } label: {
                Label("Releases", systemImage: "list.bullet.rectangle")
            }
            .accessibilityIdentifier("releasesButton")
        }
    }

    private var startOverButton: some View {
        Button { Task { if let k = resumeKey { await play(key: k, resume: false, fromHeader: true) } } } label: {
            Label("Start Over", systemImage: "arrow.counterclockwise")
        }
    }

    private var shareURL: URL? {
        guard app.catalogMode == .live, let id = model.title.key.tmdbID else { return nil }
        return URL(string: "https://www.themoviedb.org/\(model.title.kind == .movie ? "movie" : "tv")/\(id)")
    }

    @ViewBuilder private var progressAndHint: some View {
        if let p = progressForPrimary, let f = p.fraction, !p.isCompleted {
            HStack(spacing: Spacing.s) {
                ProgressStrip(fraction: f).frame(maxWidth: 220).clipShape(Capsule())
                if let r = p.remaining { Text(Formatters.remaining(r)).font(.caption).foregroundStyle(Palette.textSecondary) }
            }
        }
        if !isPlayable && !isCheckingAvailability {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label(app.addonSettings.isEnabled
                      ? "None of your sources has this yet. Your add-ons may still find a release."
                      : "None of your sources has this yet. Add a folder, link, media server or add-on.",
                      systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(Palette.textSecondary)
                // A next step, not just an explanation.
                if app.addonSettings.isEnabled, let key = primaryKey {
                    Button { releaseItem = ReleaseRequest(item: nowPlayingItem(for: key)) } label: {
                        Label("Search Releases", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("searchReleases")
                } else {
                    Button { openSourcesSettings() } label: { Label("Set Up Sources", systemImage: "plus") }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("setUpSources")
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    /// Settings › Sources: the Settings sheet on iPhone and iPad, the Settings window on the Mac.
    private func openSourcesSettings() { openSettingsPage(.sources) }

    private var isCheckingAvailability: Bool {
        model.title.kind == .movie ? model.movieAvailability == nil : model.targetAvailability == nil && model.error == nil
    }

    private var isPlayable: Bool {
        model.title.kind == .movie ? (model.movieAvailability?.isPlayable ?? false) : model.targetAvailable
    }

    private var progressForPrimary: WatchProgress? {
        model.title.kind == .movie ? model.movieProgress : model.target.flatMap { model.seriesProgress[$0.key] }
    }

    /// Key that would be resumed, for showing "Start Over".
    private var resumeKey: MediaKey? {
        guard isPlayable else { return nil }
        if model.title.kind == .movie {
            return ProgressPolicy.standard.resumePosition(for: model.movieProgress) != nil ? model.title.key : nil
        }
        return model.target?.isResume == true ? model.target?.key : nil
    }

    /// Play, with its ▾ beside it: Start a Party (or, hosting one, Add to
    /// Party Queue) and Releases… — the same things a right-click on Play offers.
    private func primaryButton(fullWidth: Bool) -> some View {
        let blocked = model.detail != nil && !app.allowsCertification(model.detail?.certification)
        let enabled = isPlayable && !blocked
        return HStack(spacing: 2) {
            playButton(fullWidth: fullWidth)
                .blueboxMenu(isPresented: $playMenuOpen, title: "Play Options") { playMenuEntries }
                #if os(macOS)
                .overlay { SecondaryClickCatcher { if enabled { playMenuOpen = true } } }
                #else
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in if enabled { playMenuOpen = true } })
                #endif
            BlueboxMenu("Play Options") {
                playMenuEntries
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(enabled ? Color.black : Palette.textTertiary)
                    .frame(width: 38, height: 44)
                    .background(enabled ? Color.white : Palette.elevated,
                                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
            .disabled(!enabled)
            .redacted(reason: isCheckingAvailability ? .placeholder : [])
            .accessibilityLabel("Play Options")
            .accessibilityIdentifier("playOptions")
        }
    }

    @BlueboxMenuBuilder private var playMenuEntries: [BlueboxMenuEntry] {
        if let key = primaryKey {
            if app.party?.isHost == true {
                BlueboxMenuButton("Add to Party Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    app.addToParty(nowPlayingItem(for: key))
                }
            } else {
                BlueboxMenuButton("Start a Party", systemImage: "person.2.fill",
                                  subtitle: "Watch in step with friends, with a chat") {
                    Task { await app.startParty(nowPlayingItem(for: key)) }
                }
            }
            if app.addonSettings.isEnabled {
                BlueboxMenuButton("Releases…", systemImage: "list.bullet.rectangle") {
                    releaseItem = ReleaseRequest(item: nowPlayingItem(for: key))
                }
            }
        }
    }

    private func playButton(fullWidth: Bool) -> some View {
        // Above the profile's maturity limit (or unrated on Kids): say so instead of Play.
        let blocked = model.detail != nil && !app.allowsCertification(model.detail?.certification)
        let label: String = {
            if blocked { return "Not on \(app.currentProfile.name)\u{2019}s Profile" }
            if isCheckingAvailability { return "Play" }
            if !isPlayable { return "Unavailable" }
            if model.title.kind == .movie { return resumeKey != nil ? "Resume" : "Play" }
            guard let t = model.target else { return "Play" }
            return (t.isResume ? "Resume " : "Play ") + "S\(t.season)·E\(t.episode)"
        }()
        return Button {
            if model.title.kind == .movie { Task { await play(key: model.title.key, resume: true, fromHeader: true) } }
            else if let t = model.target { Task { await play(key: t.key, resume: true, fromHeader: true) } }
        } label: {
            Label(label, systemImage: blocked ? "lock.fill" : isPlayable || isCheckingAvailability ? "play.fill" : "nosign")
                .frame(minWidth: 120)
        }
        .buttonStyle(PrimaryButtonStyle(fullWidth: fullWidth))
        .disabled(!isPlayable || blocked)
        .redacted(reason: isCheckingAvailability ? .placeholder : [])
        .accessibilityIdentifier("playButton")
        .keyboardShortcut(.defaultAction)
        .remoteFocusable("play", label: label, cornerRadius: Radius.control) {
            guard isPlayable, !blocked else { return }
            if model.title.kind == .movie { Task { await play(key: model.title.key, resume: true, fromHeader: true) } }
            else if let t = model.target { Task { await play(key: t.key, resume: true, fromHeader: true) } }
        }
    }

    /// - Parameter fromHeader: Play or Start Over in the header: the header's
    ///   artwork grows into the player (`PlayLaunchSurface`).
    private func play(key: MediaKey, resume: Bool, fromHeader: Bool = false) async {
        let frame = artworkAnchor.frame
        if fromHeader, frame.width > 0 {
            let t = model.display
            notePlayOrigin(PlayOrigin(key: key, frame: frame, artwork: app.imageURL(t.backdrop ?? t.poster, width: frame.width)))
        }
        await app.play(nowPlayingItem(for: key), resume: resume)
    }

    private func nowPlayingItem(for key: MediaKey) -> NowPlayingItem {
        let t = model.display
        var subtitle: String? = t.year.map(String.init)
        var art = app.imageURL(t.backdrop, width: 640)
        if let (s, e) = key.episodeNumbers {
            let ep = model.season?.episodes.first { $0.key == key }
            subtitle = "S\(s)·E\(e)" + (ep.map { " · \($0.name)" } ?? "")
            if let still = ep?.still { art = app.imageURL(still, width: 640) }
        }
        return NowPlayingItem(key: key, title: t.name, subtitle: subtitle, artworkURL: art)
    }

    /// The movie, or the episode Play would start.
    private var primaryKey: MediaKey? {
        model.title.kind == .movie ? model.title.key : model.target?.key
    }

    // MARK: Overview

    @ViewBuilder private func overview(compact: Bool) -> some View {
        let t = model.display
        VStack(alignment: .leading, spacing: Spacing.s) {
            if model.detail == nil && model.error == nil {
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBlock(height: 14, radius: 4)
                    SkeletonBlock(height: 14, radius: 4)
                    SkeletonBlock(width: 200, height: 14, radius: 4)
                }
            }
            if let tagline = model.detail?.tagline, !tagline.isEmpty {
                Text(tagline).font(.headline).italic().foregroundStyle(Palette.textSecondary)
            }
            if !t.overview.isEmpty {
                Text(t.overview)
                    .font(compact ? .subheadline : .body)
                    .lineLimit(compact && !overviewExpanded ? 4 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { withAnimation(Motion.standard(reduceMotion)) { overviewExpanded.toggle() } }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }

    /// The detail fetch failed and nothing is saved: the offline page (with
    /// Go to Downloads) or a failed state with Try Again, where the tabs go.
    @ViewBuilder private func detailFailure(_ error: Error) -> some View {
        if app.settings.isOffline || UserFacingError.isOffline(error) {
            OfflineMessage(reason: "Episodes, cast and more need the internet.") { Task { await model.load(app) } }
        } else {
            StateMessage(.failed, title: "Couldn't load \(model.display.name)",
                         message: UserFacingError.message(for: error, context: .catalog),
                         actionTitle: "Try Again") { Task { await model.load(app) } }
        }
    }

    // MARK: Spot (a): credits summary under the synopsis
    // "Starring A, B, C" and "Director X" / "Creator X", two lines. With TMDB
    // each name is a link to that person's page (`Route.person`); Cinemeta
    // only knows names, so they stay plain.

    @ViewBuilder private var creditsSummary: some View {
        let cast = Array((model.detail?.cast ?? []).prefix(3))
        let lead = model.detail?.crew.first
        if !cast.isEmpty || lead != nil {
            VStack(alignment: .leading, spacing: 4) {
                if !cast.isEmpty { creditLinks("Starring", cast) }
                if let lead { creditLinks(lead.role, [lead]) }
            }
            .font(.footnote)
            .tint(Palette.textPrimary)  // linked names: white against the grey
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == Self.personScheme, let id = Int(url.host() ?? "") else { return .systemAction }
                pushRoute(.person(id))
                return .handled
            })
            .accessibilityIdentifier("creditsSummary")
        }
    }

    private static let personScheme = "bluebox-person"

    /// "Label: A, B, C" on one line; names link to their pages when people have pages.
    private func creditLinks(_ label: String, _ people: [CreditPerson]) -> some View {
        var line = AttributedString("\(label): ")
        line.foregroundColor = Palette.textTertiary
        for (i, person) in people.enumerated() {
            var name = AttributedString(person.name)
            if app.hasPersonPages, person.id > 0, let url = URL(string: "\(Self.personScheme)://\(person.id)") {
                name.link = url
            } else {
                name.foregroundColor = Palette.textSecondary
            }
            line += name
            if i < people.count - 1 {
                var comma = AttributedString(", ")
                comma.foregroundColor = Palette.textSecondary
                line += comma
            }
        }
        return Text(line).lineLimit(1)
    }

    @ViewBuilder private var genresLine: some View {
        let t = model.display
        if let genres = model.detail?.genres, !genres.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Genres:").foregroundStyle(Palette.textTertiary)
                ForEach(Array(genres.prefix(4).enumerated()), id: \.element.id) { i, g in
                    NavigationLink(value: Route.genre(g, t.kind)) {
                        Text(g.name + (i < min(genres.count, 4) - 1 ? "," : "")).foregroundStyle(Palette.textSecondary)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .font(.footnote)
            .lineLimit(1)
        }
    }

    /// "Part of …" for a film in a collection (TMDB only).
    @ViewBuilder private var collectionRow: some View {
        if let ref = model.detail?.collection { CollectionRow(ref: ref) }
    }

    // MARK: Tabs

    /// Trailers & More stays hidden until there's something to show in it.
    private var hasTrailersAndMore: Bool { model.hasExtras }

    private var availableTabs: [Tab] {
        var tabs: [Tab] = []
        if model.title.kind == .series { tabs.append(.episodes) }
        if !(model.detail?.related.isEmpty ?? true) { tabs.append(.related) }
        if hasTrailersAndMore { tabs.append(.trailers) }
        if !(model.detail?.cast.isEmpty ?? true) || !(model.detail?.crew.isEmpty ?? true) { tabs.append(.cast) }
        return tabs
    }

    @ViewBuilder private func tabs(inset: CGFloat, width: CGFloat) -> some View {
        let tabs = availableTabs
        if !tabs.isEmpty {
            // The picked tab, or the first one this title has (a film without
            // More Like This opens on the next tab, highlighted as such).
            let current = tabs.contains(tab) ? tab : tabs[0]
            VStack(alignment: .leading, spacing: Spacing.l) {
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.xl) {
                        ForEach(tabs) { t in
                            Button { withAnimation(Motion.snappy(reduceMotion)) { tab = t } } label: {
                                Text(t.rawValue)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(current == t ? Palette.textPrimary : Palette.textSecondary)
                                    .fixedSize()
                                    .padding(.top, Spacing.m)
                                    .padding(.bottom, Spacing.xs)
                                    // The indicator sits on the divider, as wide as the label.
                                    .overlay(alignment: .top) {
                                        if current == t {
                                            Rectangle().fill(Palette.brand).frame(height: 4)
                                                .matchedGeometryEffect(id: "tab", in: tabIndicator)
                                        }
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityAddTraits(current == t ? [.isSelected, .isHeader] : .isHeader)
                        }
                    }
                    .padding(.horizontal, inset)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Palette.separator).frame(height: 1) }
                .selectionHaptic(tab)

                switch current {
                case .episodes: episodes(inset: inset, width: width)
                case .related: related(inset: inset, width: width)
                case .trailers: trailersAndMore(inset: inset, width: width)
                case .cast: castAndCrew(inset: inset)
                }
            }
        }
    }

    // MARK: Spot: Trailers & More
    // Trailers, teasers, featurettes and clips: the season's own when it has
    // any, else the title's. Each card plays in `TrailerSheet`.

    @ViewBuilder private func trailersAndMore(inset: CGFloat, width: CGFloat) -> some View {
        ExtrasSection(key: model.title.key, season: model.extrasSeason, inset: inset, showsTitle: false)
            .id(model.extrasSeason)
    }

    // MARK: Episodes

    @ViewBuilder private func episodes(inset: CGFloat, width: CGFloat) -> some View {
        let seasons = model.detail?.seasons ?? []
        let content = min(width - inset * 2, 1400)
        let columns = content >= 1180 ? 2 : 1
        let thumb: CGFloat = width < 600 ? 128 : columns == 2 ? 200 : 184
        VStack(alignment: .leading, spacing: Spacing.m) {
            seasonHeader(seasons: seasons, wide: width >= 600)
            if let season = model.season { ObservationScope { seasonDownloadBar(season) }.frame(maxWidth: 640, alignment: .leading) }
            if let season = model.season {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.m, alignment: .top), count: columns),
                          alignment: .leading, spacing: width < 600 ? Spacing.s : Spacing.xs) {
                    ForEach(season.episodes) { ep in
                        ObservationScope { episodeRow(ep, thumbnailWidth: thumb) }.id(ep.key)
                    }
                }
                // The row's inner padding lines thumbnails up with the page's edge.
                .padding(.horizontal, -(Spacing.m - 2))
                .transition(.opacity)
            } else if let err = model.seasonError {
                StateMessage(.failed, title: "Couldn't load episodes", message: UserFacingError.message(for: err, context: .catalog),
                             actionTitle: "Try Again") { Task { if let n = model.selectedSeason { await model.loadSeason(n, app) } } }
            } else {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    ForEach(0..<3, id: \.self) { _ in EpisodeSkeleton(thumbnailWidth: thumb) }
                }
            }
        }
        .padding(.horizontal, inset)
        .frame(maxWidth: (columns == 2 ? 1400 : 1000) + inset * 2, alignment: .leading)
        .animation(Motion.standard(reduceMotion), value: model.season?.number)
    }

    private func episodeRow(_ ep: Episode, thumbnailWidth: CGFloat) -> some View {
        let name = model.display.name
        let subtitle = "S\(ep.seasonNumber)·E\(ep.number)"
        return EpisodeRow(
            episode: ep, progress: model.seriesProgress[ep.key],
            isPlayable: model.playableEpisodes.contains(ep.key),
            isNext: model.hasSeriesProgress && model.target?.key == ep.key,
            canDownload: model.downloadableEpisodes.contains(ep.key),
            thumbnailWidth: thumbnailWidth,
            imageURL: app.imageURL(ep.still ?? model.display.backdrop, width: thumbnailWidth),
            seriesName: name,
            download: app.visibleDownload(for: ep.key),
            isPreparing: app.preparingDownloads.contains(ep.key),
            actions: EpisodeRowActions(
                play: { Task { await play(key: ep.key, resume: true) } },
                playFromStart: { Task { await play(key: ep.key, resume: false) } },
                setWatched: { watched in markEpisodes([ep], watched: watched) },
                chooseRelease: app.addonSettings.isEnabled
                    ? { releaseItem = ReleaseRequest(item: nowPlayingItem(for: ep.key)) } : nil,
                download: { Task { await app.startDownload(key: ep.key, title: name, subtitle: subtitle) } },
                deleteDownload: { app.deleteDownloadWithUndo($0) }))
    }

    /// "Season 2 ▾", the season ⋯ menu, and on wider screens the season's tally.
    @ViewBuilder private func seasonHeader(seasons: [SeasonSummary], wide: Bool) -> some View {
        let current = seasons.first { $0.number == model.selectedSeason }
        HStack(spacing: Spacing.s) {
            if !seasons.isEmpty {
                SeasonPickerButton(title: current.map { $0.number == 0 ? "Specials" : $0.name } ?? "Season",
                                   enabled: seasons.count > 1) { openSeasons() }
            }
            if let season = model.season {
                if !model.downloadableEpisodes.isEmpty { ObservationScope { seasonDownloadButton(season) } }
                seasonMenu(season)
            }
            Spacer(minLength: 0)
            if wide, let season = model.season {
                let watched = season.episodes.filter { model.seriesProgress[$0.key]?.isCompleted == true }.count
                Text("\(season.episodes.count) episodes" + (watched > 0 ? " · \(watched) watched" : ""))
                    .font(.footnote).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private func openSeasons() {
        #if os(iOS)
        // The list fades itself in; the cover shouldn't slide up under it.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { showingSeasons = true }
        #else
        showingSeasons = true
        #endif
    }

    private func closeSeasons() {
        #if os(iOS)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { showingSeasons = false }
        #else
        showingSeasons = false
        #endif
    }

    private var seasonList: some View {
        SeasonListOverlay(
            seasons: SeasonChoice.make(model.detail?.seasons ?? [], progress: model.seriesProgress),
            current: model.selectedSeason,
            choose: { n in
                closeSeasons()
                model.selectSeason(n, app)
            },
            close: closeSeasons)
    }

    private func seasonPlan(_ season: Season) -> SeasonActionPlan {
        SeasonActionPlan(episodes: season.episodes, progress: model.seriesProgress,
                         downloads: { app.visibleDownload(for: $0) }, downloadable: model.downloadableEpisodes)
    }

    private func seasonName(_ season: Season) -> String {
        season.number == 0 ? "Specials" : season.name.isEmpty ? "Season \(season.number)" : season.name
    }

    /// Sizes from downloads that already know theirs; estimates for the rest.
    private func knownSizes(_ plan: SeasonActionPlan) -> [MediaKey: Int64] {
        Dictionary(plan.downloads.compactMap { r in r.mediaKey.flatMap { k in r.expectedBytes.map { (k, $0) } } },
                   uniquingKeysWith: { a, _ in a })
    }

    /// What the season's ↓ menu offers: every episode not downloaded yet,
    /// the unwatched ones when that's fewer, and a season pack once there are
    /// a few episodes to get. Episodes already preparing aren't offered again.
    private func seasonOffers(_ season: Season) -> (all: SeasonDownloadBar.Offer?, unwatched: SeasonDownloadBar.Offer?,
                                                    pack: SeasonPackRequest?, notDownloaded: [Episode], remaining: [Episode]) {
        let plan = seasonPlan(season)
        let estimate = model.sizeEstimate
        let notDownloaded = plan.notDownloaded.filter { !app.preparingDownloads.contains($0.key) }
        let remaining = plan.remaining.filter { !app.preparingDownloads.contains($0.key) }
        let all = notDownloaded.isEmpty ? nil
            : SeasonDownloadBar.Offer(count: notDownloaded.count,
                                      sizeLabel: SeasonActionPlan.sizeLabel(estimate.bytes(for: notDownloaded, knownSizes: [:])))
        let unwatched = remaining.isEmpty || remaining.count == notDownloaded.count ? nil
            : SeasonDownloadBar.Offer(count: remaining.count,
                                      sizeLabel: SeasonActionPlan.sizeLabel(estimate.bytes(for: remaining, knownSizes: [:])))
        let pack = notDownloaded.count >= 2
            ? SeasonPackRequest(series: model.title.key, season: season.number, episodes: notDownloaded, seriesName: model.display.name,
                                separateBytes: estimate.bytes(for: notDownloaded, knownSizes: [:]))
            : nil
        return (all, unwatched, pack, notDownloaded, remaining)
    }

    private func seasonStatus(_ season: Season) -> SeasonDownloadStatus {
        let series = model.title.key
        return SeasonDownloadStatus(records: app.seasonDownloads(series, season: season.number),
                                    preparing: app.preparingCount(series, season: season.number))
    }

    /// The ↓ beside the season: its menu downloads the season, or opens the show's rules.
    private func seasonDownloadButton(_ season: Season) -> some View {
        let offers = seasonOffers(season)
        let series = model.title.key
        let settings = app.downloadSettings
        return SeasonDownloadButton(
            seasonName: seasonName(season), status: seasonStatus(season), all: offers.all, unwatched: offers.unwatched,
            pack: offers.pack,
            rulesSummary: DownloadRuleSummary.text(settings.rule(for: series), window: settings.window,
                                                   newEpisodes: app.autoDownloadsNewEpisodes(series)),
            downloadAll: { requestSeasonDownload(season, episodes: offers.notDownloaded) },
            downloadUnwatched: { requestSeasonDownload(season, episodes: offers.remaining) },
            editRules: { editingRules = true })
    }

    /// The season's download line under the picker: progress with Pause and Cancel, or done.
    @ViewBuilder private func seasonDownloadBar(_ season: Season) -> some View {
        let series = model.title.key
        let status = seasonStatus(season)
        let name = seasonName(season)
        if !status.isEmpty {
            SeasonDownloadBar(
                seasonName: name, status: status, allSaved: seasonOffers(season).all == nil,
                pause: { app.pauseSeasonDownload(series, season: season.number) },
                resume: { app.resumeSeasonDownload(series, season: season.number) },
                cancel: { app.cancelSeasonDownload(series, season: season.number, seasonName: name) })
        }
    }

    /// Download Season: starts at once, or asks first on mobile data, when
    /// it's big, or when it won't fit.
    private func requestSeasonDownload(_ season: Season, episodes: [Episode]) {
        guard !episodes.isEmpty else { return }
        let bytes = model.sizeEstimate.bytes(for: episodes, knownSizes: [:])
        let check = SeasonDownloadCheck.check(bytes: bytes, episodes: episodes.count, onMobileData: app.settings.isOnMobileData,
                                              wifiOnly: app.downloadSettings.wifiOnly, freeBytes: app.downloads.freeBytes())
        let request = SeasonDownloadRequest(seriesKey: model.title.key, season: season.number, seasonName: seasonName(season),
                                            seriesName: model.display.name, episodes: episodes, bytes: bytes, check: check)
        if check == .none { startSeason(request, mobileData: nil) } else { seasonRequest = request }
    }

    private func startSeason(_ request: SeasonDownloadRequest, mobileData: Bool?) {
        withAnimation(Motion.snappy(reduceMotion)) {
            app.downloadSeason(request.episodes, seriesKey: request.seriesKey, season: request.season,
                               seriesName: request.seriesName, mobileData: mobileData)
        }
    }

    /// "Delete every download of Season 2?", with what it frees.
    private var seasonDeleteTitle: String {
        guard let season = confirmSeasonDelete else { return "" }
        let name = season.name.isEmpty ? "Season \(season.number)" : season.name
        return "Delete every download of \(name)?"
    }

    /// The season ⋯ menu: mark the season watched or unwatched, and delete its downloads.
    private func seasonMenu(_ season: Season) -> some View {
        Button { seasonMenuOpen.toggle() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 36, height: 36)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .blueboxMenu(isPresented: $seasonMenuOpen, title: "Season Actions") { seasonMenuEntries(season) }
        .fixedSize()
        .help("Season Actions")
        .accessibilityLabel("Season Actions")
        .accessibilityIdentifier("seasonActions")
    }

    /// Marking the season, and deleting its downloads. Downloading it is the
    /// season bar's; the show's Smart Downloads rules are its Download Rules card.
    private func seasonMenuEntries(_ season: Season) -> [BlueboxMenuEntry] {
        let plan = seasonPlan(season)
        let d = plan.downloads.count
        let deleteSubtitle = "\(d) episode\(d == 1 ? "" : "s") · " + Formatters.bytes(plan.downloadedBytes)
        var entries: [BlueboxMenuEntry] = []
        func add(@BlueboxMenuBuilder _ e: () -> [BlueboxMenuEntry]) { entries += e() }
        add {
            BlueboxMenuSection {
                if !plan.allWatched {
                    BlueboxMenuButton("Mark Season as Watched", systemImage: "checkmark.circle") {
                        markEpisodes(season.episodes, watched: true)
                    }
                }
                if plan.anyWatched {
                    BlueboxMenuButton("Mark Season as Unwatched", systemImage: "circle") {
                        markEpisodes(season.episodes, watched: false)
                    }
                }
            }
            if !plan.downloads.isEmpty {
                BlueboxMenuSection {
                    // Many files at once: asks first, like deleting a show on Downloads.
                    BlueboxMenuButton("Delete Season Downloads…", systemImage: "trash", subtitle: deleteSubtitle, role: .destructive) {
                        confirmSeasonDelete = season
                    }
                }
            }
        }
        return entries
    }

    /// Once a season has loaded, bring the episode you're up to into view,
    /// the first time only.
    /// An episode the page was opened on (a new-episode alert) wins over the one you're up to.
    private func scrollToNextEpisode(_ proxy: ScrollViewProxy) {
        let key = model.focus ?? (model.hasSeriesProgress ? model.target?.key : nil)
        guard !model.didScrollToNext, let key,
              model.season?.episodes.contains(where: { $0.key == key }) == true else { return }
        model.didScrollToNext = true
        Task { @MainActor in
            // Let the rows lay out first.
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(Motion.spatial(reduceMotion)) { proxy.scrollTo(key, anchor: .center) }
        }
    }

    private func related(inset: CGFloat, width: CGFloat) -> some View {
        let metrics = CardMetrics(containerWidth: width)
        let cols = width < 600 ? 3 : max(3, Int((width - inset * 2) / (metrics.posterWidth + Spacing.cardGap)))
        let w = ((width - inset * 2) - CGFloat(cols - 1) * Spacing.cardGap) / CGFloat(cols)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: Spacing.cardGap), count: cols),
                         alignment: .leading, spacing: Spacing.cardGap) {
            ForEach(model.detail?.related ?? []) { t in
                TitleCardLink(t) {
                    PosterCard(title: t.name, url: app.imageURL(t.poster, width: w), width: w, isDownloaded: isDownloaded(t.key))
                }
            }
        }
        .padding(.horizontal, inset)
    }

    // MARK: Spot (b): Cast & Crew
    // "Directed by" / "Created by", round cast photos that open each person's
    // page, and "Cast & Crew ›" for everyone by department.

    private func castAndCrew(inset: CGFloat) -> some View {
        CastCrewSection(key: model.title.key, inset: inset)
    }
}

/// Netflix's three thumbs, stored as a 1–10 rating.
enum RatingThumb: Equatable {
    case down, up, love

    init?(_ rating: Int?) {
        guard let rating else { return nil }
        self = rating <= 4 ? .down : rating <= 8 ? .up : .love
    }

    var rating: Int {
        switch self {
        case .down: 2
        case .up: 7
        case .love: 10
        }
    }

    var label: String {
        switch self {
        case .down: "Not for Me"
        case .up: "I Like This"
        case .love: "Love This!"
        }
    }

    var symbol: String {
        switch self {
        case .down: "hand.thumbsdown.fill"
        case .up: "hand.thumbsup.fill"
        case .love: "heart.fill"
        }
    }
}

/// An action tile's look (icon over a caption) for controls that aren't
/// plain buttons, such as a menu trigger.
private struct TileLabel: View {
    let title: String
    let symbol: String
    var highlighted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3.weight(.regular)).frame(height: 24)
                .foregroundStyle(highlighted ? Palette.brandBright : Palette.textPrimary)
                .contentTransition(.symbolEffect(.replace))
            Text(ui: title).font(.caption2.weight(.medium)).foregroundStyle(Palette.textSecondary).lineLimit(1)
        }
        .frame(minWidth: 64, minHeight: 52)
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
    }
}

/// Lines a self-styled tile (Remind Me) up with `ActionTileStyle` tiles.
private struct TileFrame: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minWidth: 64, minHeight: 52).padding(.vertical, Spacing.xs)
    }
}

private struct EpisodeSkeleton: View {
    let thumbnailWidth: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                SkeletonBlock(width: thumbnailWidth, height: thumbnailWidth * 9 / 16, radius: Radius.card)
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBlock(width: 160, height: 14, radius: 4)
                    SkeletonBlock(width: 60, height: 12, radius: 4)
                }
                Spacer()
            }
            SkeletonBlock(height: 12, radius: 4)
        }
        .shimmering()
    }
}

/// IMDb, Rotten Tomatoes and Metacritic scores as compact text pills.
struct RatingsRow: View {
    let ratings: ExternalRatings

    var body: some View {
        HStack(spacing: Spacing.s) {
            if let v = ratings.imdb { pill("IMDb", v, label: "IMDb rating \(v) out of 10" + (ratings.imdbVotes.map { ", \($0) votes" } ?? "")) }
            if let v = ratings.rottenTomatoes { pill("Rotten Tomatoes", v, label: "Rotten Tomatoes \(v)") }
            if let v = ratings.metacritic { pill("Metacritic", v, label: "Metacritic \(v) out of 100") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("externalRatings")
    }

    private func pill(_ name: String, _ value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(Palette.textSecondary)
            Text(value).fontWeight(.semibold).foregroundStyle(Palette.textPrimary)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.brand.opacity(0.35), lineWidth: 1))
        .accessibilityLabel(label)
    }
}
