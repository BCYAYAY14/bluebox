import DesignSystem
import Domain
import Observation
import SwiftUI

@Observable
@MainActor
final class NewHotModel {
    enum Section: String, CaseIterable, Identifiable {
        case new = "New on Bluebox", watching = "Everyone's Watching", topShows = "Top 10 Shows", topMovies = "Top 10 Movies"
        var id: String { rawValue }
        var chip: String {
            switch self {
            case .new: "New"
            case .watching: "Everyone's Watching"
            case .topShows: "Top 10 Shows"
            case .topMovies: "Top 10 Movies"
            }
        }
    }

    var new: [Title] = []
    var watching: [Title] = []
    var topShows: [Title] = []
    var topMovies: [Title] = []
    /// Episodes of shows you follow from the last two weeks.
    var newEpisodes: [NewEpisodeItem] = []
    var isLoading = true
    var error: Error?

    func loadNewEpisodes(_ app: AppModel) async {
        newEpisodes = await app.newEpisodes()
    }

    func titles(_ s: Section) -> [Title] {
        switch s {
        case .new: new
        case .watching: watching
        case .topShows: topShows
        case .topMovies: topMovies
        }
    }

    var hasContent: Bool { !new.isEmpty || !watching.isEmpty || !topShows.isEmpty || !topMovies.isEmpty }

    /// Content from an earlier load stays when a reload fails (with a notice).
    func phase(offline: Bool) -> LoadPhase {
        LoadPhase.resolve(hasContent: hasContent, isLoading: isLoading, failed: error != nil, isOffline: offline)
    }

    func load(_ app: AppModel) async {
        error = nil
        if !hasContent { isLoading = true }
        do {
            async let n = app.newReleases(limit: 12)
            async let w = app.metadata.list(.trending, page: 1)
            async let s = app.topTen(.series)
            async let m = app.topTen(.movie)
            (new, watching, topShows, topMovies) = try await (n, Array(w.items.prefix(12)), s, m)
        } catch {
            self.error = error
        }
        isLoading = false
    }
}

/// Netflix's New & Hot: chips that jump between sections, and big vertical
/// cards with a date or rank in the margin. "Coming Soon", the first chip,
/// swaps the feed for upcoming episodes and films (`ComingSoonView`); the
/// feed opens with a row of new episodes of the shows you follow.
struct NewHotView: View {
    @Environment(AppModel.self) private var app
    @State private var model = NewHotModel()
    @State private var section: NewHotModel.Section = .new
    @State private var comingSoon = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.headerScrolled) private var scrolled

    var body: some View {
        GeometryReader { geo in
            let inset = Spacing.pageInset(for: geo.size.width)
            let compact = geo.size.width < 600
            let phase = model.phase(offline: app.settings.isOffline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.xl, pinnedViews: [.sectionHeaders]) {
                        PageTitle(title: "New & Hot", inset: inset)
                        Section {
                            if comingSoon {
                                ComingSoonView(embedded: true, inset: inset, showsNewEpisodes: false)
                                    .id("comingSoon")
                                    .transition(.opacity)
                            } else if phase == .loading {
                                ForEach(0..<3, id: \.self) { _ in NewHotSkeleton(compact: compact).padding(.horizontal, inset) }
                            } else if phase == .failed || phase == .offline {
                                LoadFailureMessage(phase: phase, failedTitle: "Couldn't load New & Hot", error: model.error,
                                                   offlineReason: "New & Hot needs the internet.") {
                                    Task { await model.load(app) }
                                }
                            } else {
                                if case .stale(let offline) = phase {
                                    StaleNotice(offline: offline) { Task { await model.load(app) } }
                                        .padding(.horizontal, inset)
                                }
                                if !model.newEpisodes.isEmpty { newEpisodesRow(width: geo.size.width, inset: inset) }
                                ForEach(NewHotModel.Section.allCases) { s in
                                    let titles = model.titles(s)
                                    if !titles.isEmpty {
                                        VStack(alignment: .leading, spacing: Spacing.l) {
                                            Text(s.rawValue).font(Typography.rowTitle).accessibilityAddTraits(.isHeader)
                                            ForEach(Array(titles.enumerated()), id: \.element.key) { i, t in
                                                NewHotCard(title: t, rank: (s == .topShows || s == .topMovies) ? i + 1 : nil,
                                                           showsDate: s == .new, compact: compact, width: geo.size.width - inset * 2)
                                            }
                                        }
                                        .padding(.horizontal, inset)
                                        .id(s)
                                        .onScrollVisibilityChange(threshold: 0.2) { visible in
                                            if visible, !comingSoon, section != s { section = s }
                                        }
                                    }
                                }
                            }
                        } header: {
                            chips(inset: inset) { s in
                                if let s {
                                    let wasComingSoon = comingSoon
                                    comingSoon = false
                                    section = s
                                    Task { @MainActor in
                                        // Back from Coming Soon, let the feed lay out before jumping.
                                        if wasComingSoon { try? await Task.sleep(for: .milliseconds(120)) }
                                        withAnimation(Motion.spatial(reduceMotion)) { proxy.scrollTo(s, anchor: .top) }
                                    }
                                } else {
                                    withAnimation(Motion.standard(reduceMotion)) { comingSoon = true }
                                }
                            }
                        }
                        CatalogFooter(mode: app.catalogMode).padding(.horizontal, inset)
                    }
                    // The skeleton fades into the feed instead of cutting to it.
                    .animation(Motion.standard(reduceMotion), value: phase == .loading)
                    .padding(.vertical, Spacing.l)
                }
                .scrollIndicators(.hidden)
                .reportsHeaderScroll()
            }
        }
        .blueboxScreen()
        .navigationTitle("New & Hot")
        .task(id: "\(app.catalogMode == .live)") { await model.load(app) }
        .task(id: "\(app.features.episodesRevision)-\(app.libraryRevision)") { await model.loadNewEpisodes(app) }
        .refreshable { await app.refreshCatalog(); await model.load(app); await model.loadNewEpisodes(app) }
        .refreshShortcut { await app.refreshCatalog(); await model.load(app); await model.loadNewEpisodes(app) }
        .reloadsWhenBackOnline(model.phase(offline: app.settings.isOffline).reloadsWhenOnline) { await model.load(app) }
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("-open-coming-soon") { comingSoon = true } }
        #endif
    }

    /// New episodes of the shows you follow; each opens its show on that episode.
    private func newEpisodesRow(width: CGFloat, inset: CGFloat) -> some View {
        let metrics = CardMetrics(containerWidth: width)
        return ShelfRow("New Episodes", items: model.newEpisodes, inset: inset, itemWidth: metrics.landscapeWidth) { item in
            NavigationLink(value: Route.episode(item.series, item.episode.key)) {
                LandscapeCard(title: item.series.name, subtitle: "\(item.episode.code) · \(item.episode.name)",
                              url: app.imageURL(item.episode.still ?? item.series.backdrop, width: metrics.landscapeWidth),
                              width: metrics.landscapeWidth, showsPlayGlyph: false)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("\(item.series.name), new episode \(item.episode.code), \(item.episode.name)")
        }
        .accessibilityIdentifier("newEpisodesRow")
    }

    /// "Coming Soon" (nil) first, then the feed's sections. Pinned under the
    /// bar: once the page scrolls it takes the bar's chrome, with a hairline
    /// and room below so cards don't butt against it.
    private func chips(inset: CGFloat, select: @escaping (NewHotModel.Section?) -> Void) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.s) {
                CategoryChip("Coming Soon", selected: comingSoon) { select(nil) }
                    .accessibilityIdentifier("chip.comingSoon")
                ForEach(NewHotModel.Section.allCases) { s in
                    CategoryChip(s.chip, selected: !comingSoon && section == s) { select(s) }
                }
            }
            .padding(.horizontal, inset)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.s + Spacing.s)
        }
        .scrollIndicators(.hidden)
        .background(scrolled.wrappedValue ? Palette.chrome : Palette.background)
        .overlay(alignment: .bottom) {
            Palette.separator.frame(height: 1).opacity(scrolled.wrappedValue ? 1 : 0)
        }
        .animation(Motion.appear, value: scrolled.wrappedValue)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .selectionHaptic(section)
        .animation(Motion.snappy(reduceMotion), value: section)
    }
}

/// One entry: backdrop, title, overview and actions, with the release date
/// or Top 10 rank in a narrow column on the left.
private struct NewHotCard: View {
    @Environment(AppModel.self) private var app
    let title: Title
    let rank: Int?
    let showsDate: Bool
    let compact: Bool
    let width: CGFloat
    @State private var onList = false

    private var gutter: CGFloat { compact ? 48 : 72 }
    private var cardWidth: CGFloat { min(width - gutter - Spacing.m, 760) }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            margin.frame(width: gutter)
            VStack(alignment: .leading, spacing: Spacing.m) {
                TitleCardLink(title) {
                    ArtworkView(url: app.imageURL(title.backdrop ?? title.poster, width: cardWidth), fallbackTitle: title.name,
                                kind: .backdrop, pixelWidth: Int(cardWidth * 2), showsFallbackTitle: false)
                        .frame(width: cardWidth, height: cardWidth * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            if rank != nil { TopTenBadge().padding(Spacing.s) }
                        }
                }
                .accessibilityLabel(title.name)

                HStack(alignment: .top) {
                    Text(title.name).font(.title3.weight(.heavy).width(.condensed)).lineLimit(2)
                    Spacer(minLength: Spacing.s)
                    HStack(spacing: Spacing.xs) {
                        Button {
                            let on = !onList
                            Task {
                                await app.optimistic(on ? "Couldn't add to My List" : "Couldn't remove from My List",
                                                     from: !on, to: on, apply: { onList = $0 }) { try await app.setOnMyList(title, on) }
                            }
                        } label: {
                            Label("My List", systemImage: onList ? "checkmark" : "plus")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .accessibilityValue(onList ? "On My List" : "Not on My List")
                        NavigationLink(value: Route.title(title)) { Label("Info", systemImage: "info.circle") }
                    }
                    .buttonStyle(ActionTileStyle())
                    .successHaptic(onList)
                }
                if !title.overview.isEmpty {
                    Text(title.overview).font(.callout).foregroundStyle(Palette.textSecondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(meta).font(.caption.weight(.medium)).foregroundStyle(Palette.textTertiary)
            }
            .frame(width: cardWidth, alignment: .leading)
        }
        .padding(.bottom, Spacing.l)
        .task(id: title.key) { onList = (try? await app.store.isOnWatchlist(title.key)) ?? false }
    }

    @ViewBuilder private var margin: some View {
        if let rank {
            Text("\(rank)")
                .font(.system(size: compact ? 40 : 56, weight: .black).width(.condensed))
                .foregroundStyle(Palette.brandBright)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Number \(rank)")
        } else if showsDate, let date = title.releaseDate {
            VStack(spacing: 0) {
                Text(date.formatted(.dateTime.month(.abbreviated))).font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary).textCase(.uppercase)
                Text(date.formatted(.dateTime.day())).font(.system(size: compact ? 28 : 36, weight: .heavy))
                Text(date.formatted(.dateTime.year())).font(.caption2).foregroundStyle(Palette.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Released \(date.formatted(date: .long, time: .omitted))")
        } else {
            Color.clear
        }
    }

    private var meta: String {
        [title.kind == .series ? "Series" : "Movie", title.year.map(String.init),
         title.voteAverage.flatMap { $0 > 0 ? String(format: "★ %.1f", $0) : nil }]
            .compactMap { $0 }.joined(separator: "  ·  ")
    }
}

private struct NewHotSkeleton: View {
    let compact: Bool
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            SkeletonBlock(width: compact ? 40 : 56, height: 56)
            VStack(alignment: .leading, spacing: Spacing.m) {
                SkeletonBlock(height: compact ? 180 : 320).frame(maxWidth: 760)
                SkeletonBlock(width: 220, height: 22, radius: 4)
                SkeletonBlock(height: 14, radius: 4).frame(maxWidth: 520)
                SkeletonBlock(width: 300, height: 14, radius: 4)
            }
        }
        .shimmering()
    }
}
