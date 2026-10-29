import Addons
import Domain
import Foundation
import Observation
import Persistence

// Release alerts (Settings › Privacy & Features): films on My List that had
// nothing to play are looked up again now and then, and you're told when
// your add-ons first find streams, or when a debrid-cached release (one that
// starts at once) appears. Off until you turn it on.
//
// Each check costs add-on requests (and a debrid cache lookup), so it's
// throttled three ways: at most every 12 hours, at most a few films per run
// (the longest-unchecked first), and a pause between films.

// MARK: - State

/// What the last checks found, kept on this device.
struct ReleaseAlertState: Codable, Equatable, Sendable {
    enum Availability: String, Codable, Sendable, Comparable {
        /// No add-on returned a stream.
        case unavailable
        /// Streams, but none a debrid service already holds.
        case streams
        /// A debrid service holds one: it starts at once.
        case cached

        private var rank: Int { self == .unavailable ? 0 : self == .streams ? 1 : 2 }
        static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    }

    struct Entry: Codable, Equatable, Sendable {
        var availability: Availability
        var checkedAt: Date
    }

    /// When the last run started.
    var lastRun: Date?
    /// Film key → what its last check found.
    var titles: [String: Entry] = [:]
}

/// What to tell you about one film.
enum ReleaseAlert: Equatable, Sendable {
    /// Add-ons found streams for a film that had none.
    case available
    /// A debrid service now holds a release.
    case cached

    func body(debrid: String?) -> String {
        switch self {
        case .available: "Now available to stream from your add-ons."
        case .cached: "A release is ready on \(debrid ?? "your debrid service"). It starts instantly."
        }
    }
}

/// The pure rules: when a run is due, which films it looks at, and what's worth an alert.
enum ReleaseAlertRules {
    /// At most one run every 12 hours (launch, foreground and background refresh all ask).
    static let interval: TimeInterval = 12 * 3600
    /// Films looked up per run, so a long My List costs a few requests, not dozens.
    static let perRun = 6
    /// The pause between films in one run.
    static let gap: Duration = .seconds(2)
    /// A film further than this from its release date isn't worth asking about yet.
    static let lookahead: TimeInterval = 14 * 86_400

    static func isDue(_ state: ReleaseAlertState, now: Date) -> Bool {
        guard let last = state.lastRun else { return true }
        // A clock set back counts as due rather than waiting days.
        return now.timeIntervalSince(last) >= interval || last > now
    }

    /// The films to look up this run: on My List, out (or out within two
    /// weeks), and not already as available as they'll get (cached, or
    /// streaming when there's no debrid service to wait for). Never-checked
    /// first, then the longest since a check.
    static func candidates(watchlist: [Title], state: ReleaseAlertState, hasDebrid: Bool, now: Date,
                           limit: Int = perRun) -> [Title] {
        let films = watchlist.filter { t in
            guard t.key.isMovie else { return false }
            if let date = t.releaseDate, date.timeIntervalSince(now) > lookahead { return false }
            switch state.titles[t.key.rawValue]?.availability {
            case .cached?: return false
            case .streams?: return hasDebrid
            case .unavailable?, nil: return true
            }
        }
        return Array(films.sorted { a, b in
            let ca = state.titles[a.key.rawValue]?.checkedAt ?? .distantPast
            let cb = state.titles[b.key.rawValue]?.checkedAt ?? .distantPast
            return (ca, a.key.rawValue) < (cb, b.key.rawValue)
        }.prefix(limit))
    }

    static func availability(_ releases: [AddonRelease]) -> ReleaseAlertState.Availability {
        if releases.contains(where: { $0.isDebrid && $0.cache == .cached }) { return .cached }
        return releases.isEmpty ? .unavailable : .streams
    }

    /// Only a change for the better is news. The first look at a film is the
    /// baseline: one that already streams when you add it isn't announced.
    static func alert(previous: ReleaseAlertState.Availability?, now: ReleaseAlertState.Availability) -> ReleaseAlert? {
        guard let previous, now > previous else { return nil }
        return now == .cached ? .cached : .available
    }

    /// Forgets films no longer on My List.
    static func pruned(_ state: ReleaseAlertState, keeping keys: Set<String>) -> ReleaseAlertState {
        var s = state
        s.titles = s.titles.filter { keys.contains($0.key) }
        return s
    }
}

// MARK: - Checking

extension AppModel {
    /// Looks My List's unreleased films up again when release alerts are on
    /// and a run is due (or `force`). Returns how many alerts went out.
    @discardableResult
    func checkReleaseAlerts(force: Bool = false, now: Date = Date()) async -> Int {
        guard featureSwitches.releaseAlerts, addonSettings.isEnabled, !settings.isOffline,
              !insights.isCheckingReleases else { return 0 }
        var state = insights.releaseState
        guard force || ReleaseAlertRules.isDue(state, now: now) else { return 0 }
        insights.isCheckingReleases = true
        defer { insights.isCheckingReleases = false }
        state.lastRun = now
        insights.releaseState = state

        guard let list = try? await store.watchlist() else { return 0 }
        state = ReleaseAlertRules.pruned(state, keeping: Set(list.map(\.key.rawValue)))
        let films = ReleaseAlertRules.candidates(watchlist: list, state: state, hasDebrid: !debridKey.isEmpty, now: now)
        var sent = 0
        for (i, film) in films.enumerated() {
            if i > 0 { try? await Task.sleep(for: ReleaseAlertRules.gap) }
            guard !Task.isCancelled, featureSwitches.releaseAlerts else { break }
            // A failed lookup (add-ons down, offline) leaves the film as it was.
            guard let releases = try? await addons.releases(for: film.key, refresh: true) else { continue }
            let found = ReleaseAlertRules.availability(releases)
            let previous = state.titles[film.key.rawValue]?.availability
            state.titles[film.key.rawValue] = .init(availability: max(found, previous ?? .unavailable), checkedAt: Date())
            insights.releaseState = state
            if let alert = ReleaseAlertRules.alert(previous: previous, now: found) {
                sent += 1
                await announce(alert, film: film)
            }
        }
        insights.releaseState = state
        Log.metadata.info("Release alerts: checked \(films.count) film(s), \(sent) alert(s)")
        return sent
    }

    /// Runs a due check without holding up the caller (launch, foreground).
    func checkReleaseAlertsIfDue() {
        guard featureSwitches.releaseAlerts else { return }
        Task { await checkReleaseAlerts() }
    }

    private func announce(_ alert: ReleaseAlert, film: Title) async {
        let debrid = addonSettings.debrid == .none ? nil : addonSettings.debrid.title
        let body = alert.body(debrid: debrid)
        // Notification Center keeps it; while Bluebox is open, the router
        // lists it quietly and this notice is what you see.
        await EpisodeNotifications.post(id: "release:\(film.key.rawValue)", title: film.name, body: body,
                                        key: film.key, series: nil, category: EpisodeNotifications.releaseCategory)
        showToast(AppToast(film.name, message: body, style: .success, actionTitle: "View") { [weak self] in
            self?.features.openRequest = OpenRequest(title: film, episode: nil)
        })
    }

    /// Turning release alerts on: ask for notifications then (and only then),
    /// and run a first check so the baseline is set.
    public func releaseAlertsTurnedOn() async {
        let allowed = await EpisodeNotifications.requestPermission()
        if !allowed {
            showToast(AppToast("Notifications are off for Bluebox",
                               message: "Release alerts will show here while Bluebox is open. Allow notifications in System Settings to get them otherwise."))
        }
        await checkReleaseAlerts(force: true)
    }
}
