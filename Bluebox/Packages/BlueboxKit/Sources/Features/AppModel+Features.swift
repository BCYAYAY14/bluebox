import Addons
import Domain
import Downloads
import Foundation
import MediaSources
import Metadata
import Persistence
import Playback
#if os(iOS)
import BackgroundTasks
#endif

// Trailers and extras, cast and crew, new episodes (Coming Soon, alerts,
// auto-download), the debrid library, scrobbling and ratings. State lives in
// `features` (FeatureServices); this is the API screens use.

extension AppModel {
    /// The running app, for notification taps and background refresh.
    @MainActor public internal(set) static weak var current: AppModel?
    /// A notification tapped before the app finished launching.
    @MainActor static var pendingNotificationKey: (key: MediaKey, series: MediaKey?)?

    /// The background refresh task that checks for new episodes (Info.plist
    /// › BGTaskSchedulerPermittedIdentifiers).
    public static let episodeRefreshTaskID = "app.bluebox.refresh.episodes"
    /// How often followed shows are checked while Bluebox is open, and at most
    /// how often iOS is asked to check in the background.
    static let episodeCheckInterval: Duration = .seconds(3 * 3600)

    // MARK: Launch

    /// Called from `bootstrap`, after the sources are registered.
    func startFeatureServices() {
        Self.current = self
        refreshDebridLibrarySource()
        features.scrobbler.start(self)
        features.checkTimer?.cancel()
        features.checkTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))  // after launch work settles
            while !Task.isCancelled {
                _ = await self?.checkForNewEpisodes()
                try? await Task.sleep(for: Self.episodeCheckInterval)
            }
        }
        Self.scheduleEpisodeRefresh()
        if Self.pendingNotificationKey != nil { openFromNotification() }
    }

    // MARK: Trailers and extras

    /// Trailers, teasers, featurettes, behind the scenes and clips for a
    /// movie or series (or one season), best first: official ones in your
    /// language lead. Empty when the catalog has none or can't say.
    public func videos(for key: MediaKey, season: Int? = nil) async -> [TitleVideo] {
        guard let extras = metadata as? any MetadataExtras else { return [] }
        return (try? await extras.videos(for: key.seriesKey ?? key, season: season)) ?? []
    }

    /// The trailer Home's hero may play muted, or nil when it shouldn't
    /// autoplay: previews off, mobile data, Low Data Mode, or offline.
    public func heroTrailer(for title: Title) async -> TitleVideo? {
        guard features.canAutoplayPreviews else { return nil }
        return VideoRanking.heroTrailer(await videos(for: title.key), language: Self.preferredLanguage)
    }

    /// True when the hero may play a muted preview right now.
    public var canAutoplayPreviews: Bool { features.canAutoplayPreviews }

    static var preferredLanguage: String {
        Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
    }

    // MARK: Cast and crew

    /// Directors or creators, writers, the cast with their characters, and key
    /// crew. Falls back to what the title's details list when the catalog has
    /// no separate credits.
    public func credits(for key: MediaKey) async -> TitleCredits {
        let key = key.seriesKey ?? key
        if let extras = metadata as? any MetadataExtras, let credits = try? await extras.credits(for: key) { return credits }
        guard let detail = try? await metadata.detail(for: key) else { return .empty }
        let directors = detail.crew.filter { $0.role == "Director" }
        let creators = detail.crew.filter { $0.role == "Creator" }
        let writers = detail.crew.filter { ["Screenplay", "Writer", "Story", "Novel"].contains($0.role) }
        let rest = detail.crew.filter { !directors.contains($0) && !creators.contains($0) && !writers.contains($0) }
        return TitleCredits(directors: directors, creators: creators, writers: writers, cast: detail.cast, crew: rest,
                            hasPersonPages: hasPersonPages)
    }

    /// People have pages with TMDB; Cinemeta and the sample catalog only know names.
    public var hasPersonPages: Bool { catalogMode == .live }

    public func person(id: Int) async throws -> Person {
        guard let extras = metadata as? any MetadataExtras, id > 0 else { throw MetadataError.notFound }
        return try await extras.person(id: id)
    }

    /// Known For, then Movies and TV Shows by year, each with the roles.
    public func filmography(personID: Int) async throws -> Filmography {
        guard let extras = metadata as? any MetadataExtras, personID > 0 else { throw MetadataError.notFound }
        return try await extras.filmography(personID: personID)
    }

    /// Titles you have: My List, anything with progress, downloads, and what
    /// your own sources (folders, servers, debrid library, added torrents) hold.
    /// Episodes count for their series. Not the add-ons, which have everything.
    public func libraryKeys() async -> Set<MediaKey> {
        var keys = Set<MediaKey>()
        func add(_ key: MediaKey?) {
            guard let key else { return }
            keys.insert(key)
            if let s = key.seriesKey { keys.insert(s) }
        }
        for t in (try? await store.watchlist()) ?? [] { add(t.key) }
        for p in (try? await store.recent(limit: 5000)) ?? [] { add(p.key) }
        for r in downloads.all() { add(r.mediaKey) }
        for source in await registry.enabled(with: .browse) where source.id != addons.id {
            for v in (try? await source.catalog()) ?? [] { add(v.mediaKey) }
        }
        return keys
    }

    // MARK: Watched

    /// Marks a movie or episode watched or unwatched. Syncs to the cloud and
    /// Trakt (unwatching removes the play from Trakt).
    public func setWatched(_ key: MediaKey, _ watched: Bool) async throws {
        let existing = try? await store.progress(for: key)
        let duration = existing?.duration
        let p = WatchProgress(key: key, position: watched ? (duration ?? 1) : 0, duration: duration, isCompleted: watched,
                              updatedAt: .now, deviceID: prefs.deviceID)
        _ = try await store.save(p)
        noteLibraryChanged()
        if watched { downloadsFollowProgress([key], fromOtherDevice: false) }  // Smart Downloads
    }

    // MARK: Remind Me and auto-download

    /// "Remind Me" is on for a title (a show's next episodes, or a film's release).
    public func isReminderSet(_ key: MediaKey) -> Bool {
        _ = features.episodesRevision
        return features.tracker.reminders.contains((key.seriesKey ?? key).rawValue)
    }

    /// Turns "Remind Me" on or off. Turning it on asks for notification permission the first time.
    @discardableResult
    public func setReminder(_ on: Bool, for title: Title) async -> Bool {
        let key = title.key.seriesKey ?? title.key
        if on {
            // The bell fills at once; storing the title and the airing check follow.
            features.tracker.reminders.insert(key.rawValue)
            features.noteEpisodesChanged()
            try? await store.store([title])
            if title.kind == .series, features.tracker.lastSeen[key.rawValue] == nil,
               let airing = await airing(key, fresh: false) {
                features.tracker.lastSeen[key.rawValue] = airing.lastEpisode?.key.rawValue ?? ""
            }
        } else {
            features.tracker.reminders.remove(key.rawValue)
        }
        features.noteEpisodesChanged()
        return on ? await EpisodeNotifications.requestPermission() : true
    }

    public func toggleReminder(for title: Title) async {
        await setReminder(!isReminderSet(title.key), for: title)
    }

    /// Whether new episodes of a show download on Wi‑Fi by themselves.
    public func autoDownloadsNewEpisodes(_ series: MediaKey) -> Bool {
        features.newEpisodeSettings.autoDownloads(series.seriesKey ?? series)
    }

    public func setAutoDownloadNewEpisodes(_ on: Bool?, for series: MediaKey) {
        features.newEpisodeSettings.autoDownloadShows[(series.seriesKey ?? series).rawValue] = on
    }

    /// Settings › Notifications: alerts and the auto-download default.
    public var newEpisodeSettings: NewEpisodeSettings {
        get { features.newEpisodeSettings }
        set {
            let askPermission = newValue.notify && !features.newEpisodeSettings.notify
            features.newEpisodeSettings = newValue
            if askPermission { Task { _ = await EpisodeNotifications.requestPermission() } }
        }
    }

    // MARK: Coming Soon and New Episodes

    /// Shows you follow: My List, recent progress (90 days), and reminders.
    func followedShows() async -> [MediaKey] {
        var keys: [MediaKey] = []
        var seen = Set<MediaKey>()
        func add(_ k: MediaKey) { if k.isSeries, seen.insert(k).inserted { keys.append(k) } }
        for t in (try? await store.watchlist()) ?? [] where t.kind == .series { add(t.key) }
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        for p in (try? await store.recent(limit: 400)) ?? [] where p.updatedAt > cutoff {
            if let s = p.key.seriesKey { add(s) }
        }
        for raw in features.tracker.reminders { add(MediaKey(rawValue: raw)) }
        return keys
    }

    private func airing(_ series: MediaKey, fresh: Bool) async -> AiringInfo? {
        if fresh, let cached = metadata as? CachedMetadataProvider { return try? await cached.freshAiring(for: series) }
        guard let extras = metadata as? any MetadataExtras else { return nil }
        return try? await extras.airing(for: series)
    }

    /// Airing info for many shows, six at a time.
    private func airings(_ shows: [MediaKey], fresh: Bool) async -> [MediaKey: AiringInfo] {
        await withTaskGroup(of: (MediaKey, AiringInfo?).self) { group in
            var out: [MediaKey: AiringInfo] = [:]
            var it = shows.makeIterator()
            for _ in 0..<6 { if let k = it.next() { group.addTask { (k, await self.airing(k, fresh: fresh)) } } }
            while let (k, info) = await group.next() {
                if let info { out[k] = info }
                if let next = it.next() { group.addTask { (next, await self.airing(next, fresh: fresh)) } }
            }
            return out
        }
    }

    /// Upcoming episodes of the shows you follow and films you're waiting for,
    /// soonest first, then upcoming films in general.
    public func comingSoon(includeGeneralMovies: Bool = true) async -> [ComingSoonItem] {
        await loadComingSoon(includeGeneralMovies: includeGeneralMovies).items
    }

    /// Coming Soon, with the error that stopped part of it (upcoming films
    /// didn't load, or My List couldn't be read), so the page can tell
    /// "nothing coming" from "couldn't load".
    func loadComingSoon(includeGeneralMovies: Bool = true) async -> (items: [ComingSoonItem], error: Error?) {
        var failure: Error?
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let shows = await followedShows()
        let infos = await airings(shows, fresh: false)
        var items: [ComingSoonItem] = []
        var seen = Set<MediaKey>()
        for (key, info) in infos {
            guard let next = info.nextEpisode, let date = next.airDate, date >= today, let title = await title(for: key) else { continue }
            items.append(ComingSoonItem(title: title, kind: .episode(next), date: date, isYours: true))
            seen.insert(key)
        }
        var movies: [Title] = []
        do {
            for t in try await store.watchlist() where t.kind == .movie { movies.append(t) }
        } catch {
            failure = error
        }
        for raw in features.tracker.reminders where MediaKey(rawValue: raw).isMovie {
            if let t = await title(for: MediaKey(rawValue: raw)) { movies.append(t) }
        }
        for t in movies where seen.insert(t.key).inserted {
            guard let date = t.releaseDate, date >= today else { continue }
            items.append(ComingSoonItem(title: t, kind: .movie, date: date, isYours: true))
        }
        if includeGeneralMovies, let extras = metadata as? any MetadataExtras {
            do {
                let upcoming = try await extras.upcomingMovies(page: 1)
                for t in upcoming.items where seen.insert(t.key).inserted {
                    guard let date = t.releaseDate, date >= today else { continue }
                    items.append(ComingSoonItem(title: t, kind: .movie, date: date, isYours: false))
                }
            } catch is CancellationError {
            } catch {
                failure = failure ?? error
            }
        }
        return (NewEpisodeRules.sortComingSoon(items), failure)
    }

    /// Episodes of shows you follow that came out in the last two weeks, newest first.
    public func newEpisodes(within days: Int = 14) async -> [NewEpisodeItem] {
        let now = Date()
        let infos = await airings(await followedShows(), fresh: false)
        var items: [NewEpisodeItem] = []
        for (key, info) in infos {
            guard let last = info.lastEpisode, let aired = last.airDate, aired <= now,
                  now.timeIntervalSince(aired) <= Double(days) * 86_400, let title = await title(for: key) else { continue }
            items.append(NewEpisodeItem(series: title, episode: last))
        }
        return items.sorted { ($0.episode.airDate ?? .distantPast) > ($1.episode.airDate ?? .distantPast) }
    }

    /// Checks followed shows for newly aired episodes: alerts (if on) and
    /// auto-downloads (Wi‑Fi only). Reminded films that came out are announced
    /// too. Returns how many titles had news. The first check of a show only
    /// records where it stands.
    @discardableResult
    public func checkForNewEpisodes() async -> Int {
        if let running = features.checking { return await running.value }
        let task = Task { await self.runEpisodeCheck() }
        features.checking = task
        defer { features.checking = nil }
        return await task.value
    }

    private func runEpisodeCheck() async -> Int {
        let now = Date()
        let shows = await followedShows()
        let infos = await airings(shows, fresh: true)
        var state = features.tracker
        let settings = features.newEpisodeSettings
        var announced = 0
        for key in shows {
            guard let info = infos[key] else { continue }
            let seenRaw = state.lastSeen[key.rawValue]
            let lastSeen = seenRaw.flatMap { $0.isEmpty ? nil : MediaKey(rawValue: $0) }
            if let episode = NewEpisodeRules.newEpisode(airing: info, lastSeen: lastSeen, isFirstCheck: seenRaw == nil, now: now),
               !state.notified.contains(episode.key.rawValue) {
                state.notified.insert(episode.key.rawValue)
                announced += 1
                let show = await title(for: key)
                if settings.notify || state.reminders.contains(key.rawValue) {
                    await EpisodeNotifications.post(
                        id: "episode:\(episode.key.rawValue)", title: show?.name ?? "New episode",
                        body: "New episode: \(episode.code) · \(episode.name)", key: episode.key, series: key)
                }
                if settings.autoDownloads(key) {
                    let wanted = NewEpisodeRules.episodesToDownload(series: key, latest: episode, lastSeen: lastSeen)
                    for k in wanted where !state.pendingDownloads.contains(k.rawValue) { state.pendingDownloads.append(k.rawValue) }
                }
            }
            if let last = info.lastEpisode, let aired = last.airDate, aired <= now {
                state.lastSeen[key.rawValue] = last.key.rawValue
            } else if seenRaw == nil {
                state.lastSeen[key.rawValue] = ""
            }
        }
        // Films you asked to be reminded of, once they're out.
        for raw in state.reminders where MediaKey(rawValue: raw).isMovie && !state.notified.contains(raw) {
            guard let t = await title(for: MediaKey(rawValue: raw)), let date = t.releaseDate, date <= now else { continue }
            state.notified.insert(raw)
            announced += 1
            await EpisodeNotifications.post(id: "movie:\(raw)", title: t.name, body: "Out now.", key: t.key, series: nil)
        }
        state.notified = Set(state.notified.suffix(2000))
        state.lastCheck = now
        features.tracker = state
        if announced > 0 { features.noteEpisodesChanged() }
        await startPendingAutoDownloads()
        Self.scheduleEpisodeRefresh()
        return announced
    }

    /// Queues waiting new episodes when on Wi‑Fi and the sources are ready.
    func startPendingAutoDownloads() async {
        guard !features.tracker.pendingDownloads.isEmpty, features.isOnUnmeteredNetwork,
              await registry.source(addons.id) != nil else { return }
        var left: [String] = []
        for raw in features.tracker.pendingDownloads {
            let key = MediaKey(rawValue: raw)
            if !downloads.records(for: key).isEmpty { continue }  // already queued or saved
            guard let series = key.seriesKey, let (s, e) = key.episodeNumbers,
                  await downloadableVariant(for: key) != nil else { left.append(raw); continue }
            let show = await title(for: series)
            await startDownload(key: key, title: show?.name ?? "Episode", subtitle: "S\(s)·E\(e)", automatic: true)
        }
        features.tracker.pendingDownloads = Array(left.suffix(50))
    }

    /// Shows the title a tapped notification is about.
    func openFromNotification() {
        guard let (key, series) = Self.pendingNotificationKey else { return }
        Self.pendingNotificationKey = nil
        Task {
            guard let t = await title(for: series ?? key) else { return }
            features.openRequest = OpenRequest(title: t, episode: series == nil ? nil : key)
        }
    }

    // MARK: Background refresh

    /// Runs the new-episode check for iOS's background refresh. Uses the
    /// running app, or opens the library just for the check (alerts go out;
    /// downloads wait until Bluebox is next open on Wi‑Fi).
    public static func handleBackgroundRefresh() async {
        scheduleEpisodeRefresh()
        let app: AppModel
        if let current { app = current } else {
            guard let fresh = try? await AppModel.liveReadingSecrets() else { return }
            current = fresh
            app = fresh
        }
        await app.checkForNewEpisodes()
        await app.checkReleaseAlerts()  // My List films, when release alerts are on (at most every 12 h)
    }

    /// Asks iOS to wake Bluebox to check for new episodes in a few hours.
    static func scheduleEpisodeRefresh() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: episodeRefreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    // MARK: Debrid library

    /// The debrid service whose library can be browsed, from Settings › Sources.
    var debridLibraryService: DebridService? {
        guard !debridKey.isEmpty else { return nil }
        return switch addonSettings.debrid {
        case .realDebrid: .realDebrid
        case .premiumize: .premiumize
        case .torBox: .torBox
        default: nil
        }
    }

    /// Name of the service whose library `DebridLibraryView` shows, or nil
    /// when none is set up (or it's one whose library isn't supported yet).
    public var debridLibraryName: String? { debridLibraryService?.title }

    /// Points the library source at the current service and key. Call when either changes.
    func refreshDebridLibrarySource() {
        let api = debridLibraryService.map { DebridAPIs.make($0, key: debridKey, http: http) }
        let source = features.debridLibrary
        let matcher = makeMatcher()
        Task {
            await source.update(api: api, matcher: matcher)
            features.noteDebridChanged()
        }
    }

    /// Your debrid cloud, matched to titles. `refresh` reloads it from the service.
    public func debridLibrary(refresh: Bool = false) async throws -> DebridLibraryContents {
        let entries = try await features.debridLibrary.library(refresh: refresh)
        if refresh { features.noteDebridChanged() }
        var groups: [MediaKey: [DebridLibrarySource.Entry]] = [:]
        var order: [MediaKey] = []
        var unmatched: [DebridLibrarySource.Entry] = []
        for e in entries {
            guard let key = e.key else { unmatched.append(e); continue }
            let titleKey = key.seriesKey ?? key
            if groups[titleKey] == nil { order.append(titleKey) }
            groups[titleKey, default: []].append(e)
        }
        var titles: [DebridLibraryContents.Group] = []
        for key in order {
            guard let t = await title(for: key) else { unmatched += groups[key] ?? []; continue }
            titles.append(.init(title: t, entries: groups[key] ?? []))
        }
        return DebridLibraryContents(titles: titles, unmatched: unmatched)
    }

    /// Plays one file from the debrid library (e.g. an unmatched one).
    public func play(_ entry: DebridLibrarySource.Entry) async {
        let variant = await features.debridLibrary.variant(for: entry)
        let key = entry.key ?? MediaKey(rawValue: "url:debrid-\(entry.id)")
        if let k = entry.key { _ = await title(for: k.seriesKey ?? k) }
        await play(NowPlayingItem(key: key, title: entry.displayName), variant: variant)
    }
}

/// The debrid library grouped for display.
public struct DebridLibraryContents: Sendable {
    public struct Group: Identifiable, Sendable {
        public let title: Title
        public let entries: [DebridLibrarySource.Entry]
        public var id: MediaKey { title.key }
    }
    public let titles: [Group]
    public let unmatched: [DebridLibrarySource.Entry]
}
