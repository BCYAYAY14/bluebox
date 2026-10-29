import DesignSystem
import Domain
import SwiftUI

/// Netflix's "Coming Soon": the date in the left margin, a wide still, the
/// title with Remind Me and Info, then what's coming and a short synopsis.
/// New episodes of the shows you follow are listed first. Titles open their
/// page through `Route.title`, so this must sit inside a NavigationStack.
public struct ComingSoonView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettingsPage) private var openSettingsPage
    @State private var upcoming: [ComingSoonItem] = []
    @State private var fresh: [NewEpisodeItem] = []
    @State private var isLoading = true
    @State private var loadError: Error?
    /// Show only titles on My List, followed or reminded.
    @State private var yoursOnly = false

    /// - Parameter embedded: true inside another scroll view (New & Hot), so
    ///   this draws only its rows.
    let embedded: Bool
    /// The page's side inset (New & Hot passes its own).
    let inset: CGFloat
    /// Off where New Episodes already has a row of its own (New & Hot).
    let showsNewEpisodes: Bool

    public init(embedded: Bool = false, inset: CGFloat = Spacing.l, showsNewEpisodes: Bool = true) {
        self.embedded = embedded; self.inset = inset; self.showsNewEpisodes = showsNewEpisodes
    }

    public var body: some View {
        Group {
            if embedded { content } else { ScrollView { content.padding(.vertical, Spacing.l) } }
        }
        .background(Palette.background)
        .task(id: "\(app.features.episodesRevision)-\(app.libraryRevision)-\(app.catalogMode == .live)") { await load() }
        .reloadsWhenBackOnline(phase.reloadsWhenOnline) { await load() }
        #if !os(macOS)
        .refreshable { await load() }
        #endif
    }

    private var shown: [ComingSoonItem] { yoursOnly && hasGeneralReleases ? upcoming.filter(\.isYours) : upcoming }

    @ViewBuilder private var content: some View {
        LazyVStack(alignment: .leading, spacing: Spacing.xxl) {
            if showsNewEpisodes, !fresh.isEmpty {
                header("New Episodes")
                ForEach(fresh) { item in
                    ComingSoonRow(title: item.series, date: item.episode.airDate ?? .now,
                                  line: "New episode · \(item.episode.code) · \(item.episode.name)",
                                  overview: item.episode.overview.isEmpty ? item.series.overview : item.episode.overview,
                                  still: item.episode.still ?? item.series.backdrop, isNew: true, inset: inset)
                }
            }
            HStack {
                header("Coming Soon")
                Spacer()
                // One toggle, not a second row of chips. Without TMDB there are
                // no general releases, so everything listed is yours anyway.
                if hasGeneralReleases {
                    CategoryChip("Yours", selected: yoursOnly) { yoursOnly.toggle() }
                        .padding(.trailing, inset)
                        .accessibilityHint(yoursOnly ? "Shows everything coming soon" : "Shows only your shows and reminders")
                        .accessibilityIdentifier("comingSoon.yours")
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            if case .stale(let offline) = phase {
                StaleNotice(offline: offline) { Task { await load() } }
                    .padding(.horizontal, inset)
            }
            if phase == .loading {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBlock().frame(height: 260).padding(.horizontal, inset)
                }
            } else if phase == .failed || phase == .offline {
                LoadFailureMessage(phase: phase, failedTitle: "Couldn't load Coming Soon", error: loadError,
                                   offlineReason: "Coming Soon needs the internet.") { Task { await load() } }
                    .frame(maxWidth: .infinity)
            } else if shown.isEmpty {
                emptyState
            } else {
                ForEach(shown) { item in
                    ComingSoonRow(title: item.title, date: item.date, line: line(for: item),
                                  overview: overview(for: item), still: still(for: item), isNew: false, inset: inset)
                }
            }
        }
    }

    /// Upcoming films in general come from TMDB; Cinemeta only knows the
    /// next episodes of shows you follow.
    private var hasGeneralReleases: Bool { app.catalogMode == .live }

    @ViewBuilder private var emptyState: some View {
        if !hasGeneralReleases {
            StateMessage(systemImage: "calendar",
                         title: "Nothing coming soon yet",
                         message: "Upcoming films and shows come from TMDB. Add a free TMDB token to see them, or add shows to My List and tap Remind Me to see their next episodes here.",
                         actionTitle: "Set Up TMDB") { openSettingsPage(.catalog) }
                .frame(maxWidth: .infinity)
        } else if yoursOnly {
            StateMessage(systemImage: "calendar",
                         title: "Nothing coming from your shows yet",
                         message: "Add shows to My List, or tap Remind Me on a title, to see their next episodes here.",
                         actionTitle: "Show Everything") { yoursOnly = false }
                .frame(maxWidth: .infinity)
        } else {
            StateMessage(systemImage: "calendar",
                         title: "Nothing coming soon",
                         message: "No upcoming releases have been announced yet. Pull down to check again.")
                .frame(maxWidth: .infinity)
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(Typography.rowTitle).foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, inset)
            .accessibilityAddTraits(.isHeader)
    }

    private func line(for item: ComingSoonItem) -> String {
        let when = Self.relativeDay(item.date)
        switch item.kind {
        case .episode(let e):
            return e.number == 1 ? "Season \(e.seasonNumber) coming \(when)" : "\(e.code) · \(e.name) · coming \(when)"
        case .movie:
            return "Coming \(when)"
        }
    }

    private func overview(for item: ComingSoonItem) -> String {
        if case .episode(let e) = item.kind, !e.overview.isEmpty { return e.overview }
        return item.title.overview
    }

    private func still(for item: ComingSoonItem) -> Artwork? {
        if case .episode(let e) = item.kind, let s = e.still { return s }
        return item.title.backdrop ?? item.title.poster
    }

    /// "today", "tomorrow", "Friday" within a week, else "October 30".
    static func relativeDay(_ date: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "today" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: t) { return "tomorrow" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 99
        if days > 0 && days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.wide).day())
    }

    /// A failed load keeps the list from before (with a notice) instead of
    /// saying nothing is coming.
    private func load() async {
        async let u = app.loadComingSoon()
        async let n = app.newEpisodes()
        let (result, episodes) = await (u, n)
        if result.error == nil || !result.items.isEmpty || upcoming.isEmpty { upcoming = result.items }
        fresh = episodes
        loadError = result.error
        isLoading = false
    }

    private var phase: LoadPhase {
        LoadPhase.resolve(hasContent: !upcoming.isEmpty, isLoading: isLoading, failed: loadError != nil,
                          isOffline: app.settings.isOffline, needsNetwork: hasGeneralReleases)
    }
}

private struct ComingSoonRow: View {
    @Environment(AppModel.self) private var app
    let title: Title
    let date: Date
    let line: String
    let overview: String
    let still: Artwork?
    let isNew: Bool
    var inset: CGFloat = Spacing.l

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            // Date in the margin.
            VStack(spacing: 0) {
                Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 30, weight: .heavy, design: .default)).foregroundStyle(Palette.textPrimary)
            }
            .frame(width: 48)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(date.formatted(date: .complete, time: .omitted))

            VStack(alignment: .leading, spacing: Spacing.s) {
                NavigationLink(value: Route.title(title)) {
                    ArtworkView(url: app.imageURL(still, width: 640), fallbackTitle: title.name, kind: .backdrop, pixelWidth: 1280)
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .frame(maxWidth: 720)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .buttonStyle(PressableStyle())

                HStack(alignment: .center, spacing: Spacing.l) {
                    Text(title.name)
                        .font(.title3.weight(.heavy)).foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if !isNew { RemindMeButton(title: title) }
                    NavigationLink(value: Route.title(title)) {
                        VStack(spacing: 4) {
                            Image(systemName: "info.circle").font(.system(size: 20, weight: .regular))
                            Text("Info").font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(Palette.textPrimary)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("More about \(title.name)")
                }
                Text(line)
                    .font(Typography.meta).foregroundStyle(isNew ? Palette.brandBright : Palette.textSecondary)
                if !overview.isEmpty {
                    Text(overview)
                        .font(Typography.body).foregroundStyle(Palette.textSecondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
        .padding(.horizontal, inset)
    }
}

/// The "Remind Me" bell. On: a filled bell and "Reminder Set".
public struct RemindMeButton: View {
    @Environment(AppModel.self) private var app
    let title: Title
    /// Drawn like the title page's action tiles (grey caption, taller icon).
    let tile: Bool

    public init(title: Title, tile: Bool = false) { self.title = title; self.tile = tile }

    public var body: some View {
        let on = app.isReminderSet(title.key)
        Button {
            Task {
                let granted = await app.setReminder(!on, for: title)
                if !granted {
                    // Bluebox's own dialog, not the system alert.
                    app.alert = AppAlert(title: "Notifications are off",
                                         message: "Bluebox will list \(title.name) in Coming Soon. To get an alert, allow notifications for Bluebox in System Settings.")
                }
            }
        } label: {
            VStack(spacing: tile ? 6 : 4) {
                Image(systemName: on ? "bell.fill" : "bell")
                    .font(tile ? .title3.weight(.regular) : .system(size: 20, weight: .regular))
                    .frame(height: tile ? 24 : nil)
                    .foregroundStyle(on ? Palette.brandBright : Palette.textPrimary)
                    .contentTransition(.symbolEffect(.replace))
                Text(on ? "Reminder Set" : "Remind Me").font(.caption2.weight(.medium))
                    .foregroundStyle(on ? Palette.brandBright : (tile ? Palette.textSecondary : Palette.textPrimary))
            }
            .frame(minWidth: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(haptic: true))
        .accessibilityLabel(on ? "Reminder set for \(title.name)" : "Remind me about \(title.name)")
    }
}
