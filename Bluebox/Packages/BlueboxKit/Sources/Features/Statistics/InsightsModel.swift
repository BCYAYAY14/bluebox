import Domain
import Foundation
import Metadata
import Observation
import Persistence

/// My Bluebox statistics and the release alerts' state, held by
/// `AppModel.insights`. Both work from what's already on the device.
@Observable
@MainActor
public final class InsightsModel {
    /// The current profile's statistics, once worked out (nil before, or while switched off).
    public internal(set) var statistics: WatchStatistics?
    public internal(set) var isComputing = false
    /// The library revision the statistics were worked out at.
    @ObservationIgnored var statisticsRevision: Int?

    /// Release alerts: what the last checks found (this device only).
    @ObservationIgnored var releaseState: ReleaseAlertState { didSet { prefs.set(releaseState, for: Self.releaseStateKey) } }
    @ObservationIgnored var isCheckingReleases = false

    @ObservationIgnored private let prefs: PreferencesStore
    static let releaseStateKey = "bluebox.releaseAlerts.state"

    init(prefs: PreferencesStore) {
        self.prefs = prefs
        releaseState = prefs.value(ReleaseAlertState.self, for: Self.releaseStateKey) ?? ReleaseAlertState()
    }

    /// Another profile's library is showing: its numbers aren't these.
    func profileChanged() {
        statistics = nil
        statisticsRevision = nil
    }
}

extension AppModel {
    /// Works the current profile's statistics out again if the library
    /// changed since. Does nothing while Statistics is switched off.
    public func refreshStatistics(now: Date = Date()) async {
        guard featureSwitches.statistics else {
            insights.profileChanged()
            return
        }
        let revision = libraryRevision
        guard insights.statisticsRevision != revision || insights.statistics == nil, !insights.isComputing else { return }
        insights.isComputing = true
        defer { insights.isComputing = false }
        let profile = currentProfileID
        let store = self.store
        let records = (try? await store.recent(limit: 20_000)) ?? []
        // Names and genres from the cached title data: nothing is fetched for this.
        var titles: [MediaKey: WatchStatistics.TitleInfo] = [:]
        for key in Set(records.map { $0.key.seriesKey ?? $0.key }) {
            if let t = try? await store.title(for: key) { titles[key] = .init(name: t.name, genreIDs: t.genreIDs) }
        }
        let names = await statisticsGenreNames()
        let stats = await Task.detached(priority: .userInitiated) {
            WatchStatistics.compute(records: records, titles: titles, genreNames: names, now: now)
        }.value
        // Switched profile or turned off while working: drop it.
        guard profile == currentProfileID, featureSwitches.statistics else { return }
        insights.statistics = stats
        insights.statisticsRevision = revision
    }

    /// TMDB's genre names: the catalogue's (usually cached), filled in with
    /// the standard list so an offline device still names them.
    private func statisticsGenreNames() async -> [Int: String] {
        var names = StatisticsGenres.standard
        if let listed = try? await metadata.genres() {
            for g in listed { names[g.id] = g.name }
        }
        return names
    }
}

/// TMDB's film and TV genres, for naming genres without a network request.
enum StatisticsGenres {
    static let standard: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary",
        18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
        9648: "Mystery", 10749: "Romance", 878: "Science Fiction", 10770: "TV Movie", 53: "Thriller",
        10752: "War", 37: "Western", 10759: "Action & Adventure", 10762: "Kids", 10763: "News",
        10764: "Reality", 10765: "Sci-Fi & Fantasy", 10766: "Soap", 10767: "Talk", 10768: "War & Politics",
    ]
}
