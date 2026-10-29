import DesignSystem
import Domain
import Downloads
import Playback
import SwiftUI

/// The series around the episode that's playing: its seasons, the episodes of
/// the season on show in the Episodes panel, what's been watched, and the
/// episodes before and after this one (for Previous and Next).
@MainActor @Observable
final class PlayerEpisodes {
    private(set) var seriesKey: MediaKey?
    private(set) var seriesName = ""
    private(set) var seasons: [SeasonSummary] = []
    /// The season the panel shows (the playing one until another is picked).
    private(set) var season: Int?
    private(set) var episodes: [Episode] = []
    private(set) var progress: [MediaKey: WatchProgress] = [:]
    private(set) var loadingSeason = false
    private(set) var next: Neighbour?
    private(set) var previous: Neighbour?
    private var seasonCache: [Int: [Episode]] = [:]
    private var loadedFor: MediaKey?

    struct Neighbour: Equatable {
        let key: MediaKey
        /// "S2·E1 · Pilot"
        let label: String
    }

    var isSeries: Bool { seriesKey != nil }

    /// Loads the series around `key`. Cheap to call again for the same key.
    func load(for key: MediaKey?, app: AppModel) async {
        guard let key, let series = key.seriesKey, let (s, e) = key.episodeNumbers else {
            reset(); return
        }
        if loadedFor == key { return }
        if seriesKey != series { reset() }
        loadedFor = key
        seriesKey = series
        guard let detail = try? await app.metadata.detail(for: series), loadedFor == key else { return }
        seriesName = detail.title.name
        seasons = detail.seasons.filter { $0.episodeCount > 0 }.sorted { ($0.number == 0 ? 1000 : $0.number) < ($1.number == 0 ? 1000 : $1.number) }
        await refreshProgress(app: app)
        await show(season: s, app: app)
        let nextNumbers = SeriesCursor.next(after: s, e, seasons: detail.seasons)
        let prevNumbers = Self.previous(before: s, e, seasons: detail.seasons)
        next = await neighbour(nextNumbers, series: series, app: app)
        previous = await neighbour(prevNumbers, series: series, app: app)
    }

    /// Re-reads watched state (after an episode finishes or the panel opens).
    func refreshProgress(app: AppModel) async {
        guard let seriesKey, let all = try? await app.store.progress(forSeries: seriesKey) else { return }
        progress = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
    }

    func show(season number: Int, app: AppModel) async {
        season = number
        if let cached = seasonCache[number] { episodes = cached; return }
        guard let seriesKey else { return }
        loadingSeason = true
        defer { loadingSeason = false }
        let list = (try? await app.metadata.season(number, of: seriesKey).episodes) ?? []
        seasonCache[number] = list
        if season == number { episodes = list }
    }

    private func neighbour(_ numbers: (season: Int, episode: Int)?, series: MediaKey, app: AppModel) async -> Neighbour? {
        guard let (s, e) = numbers, let key = series.episode(season: s, episode: e) else { return nil }
        if seasonCache[s] == nil, let list = try? await app.metadata.season(s, of: series).episodes { seasonCache[s] = list }
        let name = seasonCache[s]?.first { $0.number == e }?.name
        return Neighbour(key: key, label: "S\(s)·E\(e)" + (name.map { " · \($0)" } ?? ""))
    }

    private func reset() {
        seriesKey = nil; seriesName = ""; seasons = []; season = nil; episodes = []; progress = [:]
        next = nil; previous = nil; seasonCache = [:]; loadedFor = nil
    }

    /// The episode before S`s`E`e`: the one before it in the season, or the
    /// last of the season before (specials, season 0, aren't stepped into).
    nonisolated static func previous(before season: Int, _ episode: Int, seasons: [SeasonSummary]) -> (season: Int, episode: Int)? {
        if episode > 1 { return (season, episode - 1) }
        guard season > 1,
              let prior = seasons.filter({ $0.number > 0 && $0.number < season && $0.episodeCount > 0 }).max(by: { $0.number < $1.number })
        else { return nil }
        return (prior.number, prior.episodeCount)
    }
}

/// The player's Episodes panel: a season switcher and the season's episodes,
/// each with its still, number and title, runtime, watched or started state
/// and whether it's downloaded. The playing one is marked; picking another
/// switches to it without leaving the player.
struct EpisodesPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: PlayerEpisodes
    let currentKey: MediaKey?
    /// The episode being switched to (a spinner on its row).
    let switchingTo: MediaKey?
    let onPick: (Episode) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if model.loadingSeason && model.episodes.isEmpty {
                            ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 120)
                        }
                        ForEach(model.episodes) { ep in
                            row(ep).id(ep.key)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                .onAppear { if let currentKey { proxy.scrollTo(currentKey, anchor: .center) } }
                .onChange(of: model.season) { if let currentKey { proxy.scrollTo(currentKey, anchor: .center) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Episodes")
        .accessibilityIdentifier("episodesPanel")
        .task { await model.refreshProgress(app: app) }
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Text(model.seriesName.isEmpty ? "Episodes" : model.seriesName)
                .font(.headline).lineLimit(1)
            Spacer(minLength: Spacing.s)
            if model.seasons.count > 1 {
                BlueboxMenu("Season") {
                    for s in model.seasons {
                        BlueboxMenuButton(s.number == 0 ? "Specials" : "Season \(s.number)", subtitle: "\(s.episodeCount) episodes",
                                          checked: s.number == model.season) {
                            Task { await model.show(season: s.number, app: app) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(seasonTitle).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: PanelMetrics.control)
                    .background(.white.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
                }
                .accessibilityIdentifier("episodesSeasonMenu")
            } else if model.season != nil {
                Text(seasonTitle).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.leading, 4)
        .padding(.bottom, 6)
    }

    private var seasonTitle: String {
        guard let s = model.season else { return "" }
        return s == 0 ? "Specials" : "Season \(s)"
    }

    private func row(_ ep: Episode) -> some View {
        let isCurrent = ep.key == currentKey
        let p = model.progress[ep.key]
        let watched = p?.isCompleted == true
        let started = p.flatMap { !$0.isCompleted && $0.position > 0 ? $0.fraction : nil }
        let download = app.visibleDownload(for: ep.key)
        return Button { if !isCurrent { onPick(ep) } } label: {
            HStack(spacing: Spacing.m) {
                ZStack(alignment: .bottom) {
                    ArtworkView(url: app.imageURL(ep.still, width: 300), fallbackTitle: "E\(ep.number)", kind: .still,
                                pixelWidth: 256, showsFallbackTitle: false)
                        .frame(width: thumbWidth, height: thumbWidth * 9 / 16)
                        .spoilerBlurred(!isCurrent && SpoilerGuard.hides(isOn: app.featureSwitches.spoilerGuard, progress: p))
                    if isCurrent {
                        Image(systemName: "waveform")
                            .font(.system(size: 15, weight: .bold))
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.45))
                            .accessibilityHidden(true)
                    } else if switchingTo == ep.key {
                        ProgressView().tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.45))
                    }
                    if let f = watched ? 1 : started { EdgeProgressBar(fraction: f, height: 3) }
                }
                .frame(width: thumbWidth, height: thumbWidth * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ep.number). \(ep.name)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        if isCurrent {
                            Text("Playing").foregroundStyle(Palette.brandBright).fontWeight(.semibold)
                        } else if watched {
                            Text("Watched")
                        } else if let p, let left = p.remaining, started != nil {
                            Text(Formatters.remaining(left)).foregroundStyle(Palette.brandBright)
                        }
                        if let r = ep.runtimeMinutes {
                            if isCurrent || watched || started != nil { Text("·") }
                            Text(Formatters.runtime(minutes: r))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                }
                Spacer(minLength: Spacing.xs)
                VStack(spacing: 6) {
                    if watched { CheckDot(size: 16).accessibilityHidden(true) }
                    if let download {
                        Image(systemName: download.state == .completed ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.body)
                            .foregroundStyle(download.state == .completed ? Palette.textPrimary : Palette.textTertiary)
                            .help(download.state == .completed ? "Downloaded" : "Downloading")
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: PlayerPopoverMetrics.rowRadius, style: .continuous)
                .fill(isCurrent ? Palette.wash : .clear))
            .overlay(RoundedRectangle(cornerRadius: PlayerPopoverMetrics.rowRadius, style: .continuous)
                .strokeBorder(isCurrent ? Palette.brand.opacity(0.5) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: PlayerPopoverMetrics.rowRadius, style: .continuous))
        }
        .buttonStyle(PopoverRowStyle())
        .disabled(switchingTo != nil)
        .accessibilityLabel(accessibilityLabel(ep, current: isCurrent, watched: watched, downloaded: download?.state == .completed))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("playerEpisode.\(ep.seasonNumber).\(ep.number)")
    }

    private var thumbWidth: CGFloat {
        #if os(macOS)
        112
        #else
        120
        #endif
    }

    private func accessibilityLabel(_ ep: Episode, current: Bool, watched: Bool, downloaded: Bool) -> String {
        var parts = ["Episode \(ep.number), \(ep.name)"]
        if let r = ep.runtimeMinutes { parts.append(Formatters.runtime(minutes: r)) }
        if current { parts.append("playing now") } else if watched { parts.append("watched") }
        if downloaded { parts.append("downloaded") }
        return parts.joined(separator: ", ")
    }
}
