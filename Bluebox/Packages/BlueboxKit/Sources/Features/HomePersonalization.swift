import Domain
import Foundation

// Home, on the device (design questions 13–17, all A): Top Picks scored from
// your watch history, two "Because You Watched" rows from TMDB's
// recommendations, one Continue Watching row that moves on to the next
// episode, and Not Interested. No server and no model: the pure rules are
// here (tested in HomePersonalizationTests); `HomeModel` feeds them.

// MARK: - Row titles

/// Every personal row's title, in one place (the profile work may name them
/// "Continue Watching for Sam").
enum HomeRowTitles {
    /// Continue Watching names the profile once there's more than one
    /// ("Continue Watching for Sam"); with one profile it stays plain.
    static func continueWatching(_ profile: Profile, profiles: Int = 1) -> String {
        profiles > 1 ? "Continue Watching for \(name(profile))" : "Continue Watching"
    }
    /// Always "My List": it's the name of a list (beside your own lists), the
    /// same on Home, in My Library and on the title page's + tile. Whose list
    /// it is shows in the profile avatar, not the row title.
    static func myList(_ profile: Profile, profiles: Int = 1) -> String { "My List" }
    static func topPicks(_ profile: Profile) -> String { "Top Picks for \(name(profile))" }
    static func becauseYouWatched(_ seed: String) -> String { "Because You Watched \(seed)" }

    /// The default profile is called "Me" until it's renamed: "Top Picks for You" reads better.
    static func name(_ profile: Profile) -> String {
        profile.name.trimmingCharacters(in: .whitespaces).isEmpty || profile.name == "Me" ? "You" : profile.name
    }
}

// MARK: - Taste

/// A rating with when it was given.
struct RatingEntry: Hashable, Sendable {
    let rating: Int
    let date: Date
}

/// One title in your history, as Top Picks sees it.
struct WatchedTitle: Hashable, Sendable {
    /// The movie or series key.
    let key: MediaKey
    let lastWatched: Date
    /// 2 finished (a film, or three or more episodes of a show), 1 past 25%, 0 not really watched.
    let base: Double
}

enum TasteRules {
    /// Watches count half as much every 30 days.
    static let halfLife: TimeInterval = 30 * 86_400
    static let seriesFinishedEpisodes = 3

    /// Progress records grouped by title (episodes by their show), newest first.
    static func watched(_ records: [WatchProgress], policy: ProgressPolicy = .standard) -> [WatchedTitle] {
        var groups: [MediaKey: (date: Date, completed: Int, pastQuarter: Bool)] = [:]
        for p in records {
            let key = p.key.seriesKey ?? p.key
            let done = isFinished(p, policy: policy)
            let quarter = done || (p.fraction ?? 0) >= 0.25
            var g = groups[key] ?? (p.updatedAt, 0, false)
            g.date = max(g.date, p.updatedAt)
            if done { g.completed += 1 }
            g.pastQuarter = g.pastQuarter || quarter
            groups[key] = g
        }
        return groups.map { key, g in
            let finished = key.isSeries ? g.completed >= seriesFinishedEpisodes : g.completed > 0
            return WatchedTitle(key: key, lastWatched: g.date, base: finished ? 2 : g.pastQuarter ? 1 : 0)
        }
        .sorted { ($0.lastWatched, $0.key.rawValue) > ($1.lastWatched, $1.key.rawValue) }
    }

    static func isFinished(_ p: WatchProgress, policy: ProgressPolicy = .standard) -> Bool {
        p.isCompleted || (p.duration.map { policy.isComplete(position: p.position, duration: $0) } ?? false)
    }

    /// A title's weight: 1 past 25%, 2 finished; "I Like This" doubles it (up
    /// to 3), "Love This!" is 3 and "Not for Me" counts against (−2).
    static func weight(base: Double, rating: Int?) -> Double {
        switch RatingThumb(rating) {
        case .down?: -2
        case .love?: 3
        case .up?: min(max(base, 1) * 2, 3)
        case nil: base
        }
    }

    /// 0.5^(days ago / 30).
    static func decay(since date: Date, now: Date) -> Double {
        pow(0.5, max(0, now.timeIntervalSince(date)) / halfLife)
    }

    /// For each genre, the sum over your titles that have it of weight × decay.
    /// Titles you rated without watching count too, from when you rated them.
    static func affinity(watched: [WatchedTitle], ratings: [MediaKey: RatingEntry],
                         genres: [MediaKey: [Int]], now: Date) -> [Int: Double] {
        var out: [Int: Double] = [:]
        var seen = Set<MediaKey>()
        func add(_ key: MediaKey, weight: Double, date: Date) {
            guard weight != 0, let gs = genres[key] else { return }
            let w = weight * decay(since: date, now: now)
            for g in Set(gs) { out[g, default: 0] += w }
        }
        for w in watched {
            seen.insert(w.key)
            add(w.key, weight: weight(base: w.base, rating: ratings[w.key]?.rating), date: w.lastWatched)
        }
        for (key, r) in ratings where !seen.contains(key) && (key.isMovie || key.isSeries) {
            add(key, weight: weight(base: 0, rating: r.rating), date: r.date)
        }
        return out
    }

    /// Enough history for personal rows: at least two titles that count.
    static func hasEnoughHistory(_ watched: [WatchedTitle], ratings: [MediaKey: RatingEntry]) -> Bool {
        watched.filter { weight(base: $0.base, rating: ratings[$0.key]?.rating) > 0 }.count >= 2
    }
}

// MARK: - Top Picks

/// A Top Picks card: the title and why it's there.
struct ScoredPick: Codable, Hashable, Sendable {
    let title: Title
    let score: Double
    let reason: String
}

enum TopPicks {
    static let minimumPicks = 3
    static let ratingWeight = 0.3
    static let newBonus = 0.5
    static let perFranchise = 2

    /// Σ affinity over the title's genres ÷ √(number of genres), + 0.3 × (rating − 6),
    /// + a small bonus when it came out in the last 30 days. Also the genre that
    /// matched best, for the reason.
    static func score(_ t: Title, affinity: [Int: Double], now: Date) -> (score: Double, taste: Double, genre: Int?) {
        let gs = Array(Set(t.genreIDs))
        let taste = gs.isEmpty ? 0 : gs.reduce(0) { $0 + (affinity[$1] ?? 0) } / Double(gs.count).squareRoot()
        let genre = gs.filter { (affinity[$0] ?? 0) > 0 }
            .max { (affinity[$0] ?? 0, -$0) < (affinity[$1] ?? 0, -$1) }
        let rating = ratingWeight * ((t.voteAverage ?? 6) - 6)
        var isNew = false
        if let d = t.releaseDate { isNew = d <= now && now.timeIntervalSince(d) <= 30 * 86_400 }
        return (taste + rating + (isNew ? newBonus : 0), taste, genre)
    }

    /// The best-scoring candidates you haven't watched, hidden or started, that
    /// match your taste, at most two from one franchise, each with a reason.
    static func picks(candidates: [Title], affinity: [Int: Double], excluded: Set<MediaKey>,
                      genreNames: [Int: String], now: Date, limit: Int = 20) -> [ScoredPick] {
        var seen = Set<MediaKey>()
        var scored: [(Title, Double, Int)] = []
        for t in candidates where !excluded.contains(t.key) && seen.insert(t.key).inserted {
            let s = score(t, affinity: affinity, now: now)
            guard s.taste > 0, let genre = s.genre else { continue }
            scored.append((t, s.score, genre))
        }
        scored.sort { ($0.1, $1.0.name) > ($1.1, $0.0.name) }
        var perFranchise: [String: Int] = [:]
        var out: [ScoredPick] = []
        for (t, s, g) in scored where out.count < limit {
            let f = franchise(t.name)
            guard perFranchise[f, default: 0] < Self.perFranchise else { continue }
            perFranchise[f, default: 0] += 1
            out.append(ScoredPick(title: t, score: s, reason: reason(genre: g, names: genreNames)))
        }
        return out
    }

    static func reason(genre: Int, names: [Int: String]) -> String {
        guard let name = shortNames[genre] ?? names[genre] else { return "Picked for you" }
        return "Because you like \(name)"
    }

    /// TMDB's long genre names, shortened for a card.
    static let shortNames: [Int: String] = [
        878: "Sci-Fi", 10765: "Sci-Fi & Fantasy", 10759: "Action & Adventure", 99: "Documentaries",
        10751: "Family Films", 10749: "Romance", 10402: "Music", 10770: "TV Movies", 10762: "Kids' Shows",
        10764: "Reality TV", 10767: "Talk Shows", 10768: "War & Politics", 10763: "News",
    ]

    /// "Dune: Part Two" and "Dune" → "dune"; "Toy Story 3" → "toy story".
    static func franchise(_ name: String) -> String {
        var s = name.lowercased()
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        let words = s.split(separator: " ").map(String.init)
        let numerals: Set<String> = ["2", "3", "4", "5", "6", "ii", "iii", "iv", "v", "vi", "part", "chapter"]
        var kept = words
        while let last = kept.last, kept.count > 1, numerals.contains(last) || Int(last) != nil { kept.removeLast() }
        return kept.joined(separator: " ")
    }
}

// MARK: - Genre rows by taste

enum GenreRowOrder {
    static let movieGenres: Set<Int> = [28, 12, 16, 35, 80, 99, 18, 10751, 14, 36, 27, 10402, 9648, 10749, 878, 10770, 53, 10752, 37]
    static let tvGenres: Set<Int> = [10759, 16, 35, 80, 99, 18, 10751, 10762, 9648, 10763, 10764, 10765, 10766, 10767, 10768, 37]
    /// Today's fixed rows, used when there's no taste to go on.
    static let defaults: Set<Int> = [878, 18, 35, 53, 9648, 16]

    /// The genre rows to fetch: your strongest genres first, then the usual
    /// ones, `count` in all, so it's the same number of requests as before.
    static func pick(available: [Genre], affinity: [Int: Double], kind: TitleKind, count: Int) -> [Genre] {
        let allowed = kind == .movie ? movieGenres : tvGenres
        var mapped: [Int: Double] = [:]
        for (g, a) in affinity {
            for id in equivalents(g, kind: kind) where allowed.contains(id) { mapped[id, default: 0] += a }
        }
        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Genre] = mapped.filter { $0.value > 0 }
            .sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }
            .compactMap { byID[$0.key] }
        // The fixed rows, minus genres that don't apply to this kind (a TV-only genre on Movies).
        for g in available where defaults.contains(g.id) && !out.contains(g) && (allowed.contains(g.id) || kind == .movie) {
            out.append(g)
        }
        return Array(out.prefix(count))
    }

    /// TMDB's TV and film genres differ for a few (Sci-Fi & Fantasy vs Science Fiction).
    static func equivalents(_ id: Int, kind: TitleKind) -> [Int] {
        switch (id, kind) {
        case (10765, .movie): [878, 14]
        case (10759, .movie): [28, 12]
        case (878, .series), (14, .series): [10765]
        case (28, .series), (12, .series): [10759]
        default: [id]
        }
    }
}

// MARK: - Row order

enum HomeLayout {
    /// Balanced (question 17 A): the first `lead` editorial rows, then personal
    /// and editorial rows take turns; whatever's left of either follows. With
    /// no personal rows it's the editorial order unchanged.
    static func interleave(editorial: [HomeRow], personal: [HomeRow], lead: Int = 2) -> [HomeRow] {
        var out = Array(editorial.prefix(lead))
        var e = editorial.dropFirst(lead).makeIterator()
        var p = personal.makeIterator()
        var nextE = e.next(), nextP = p.next()
        while nextE != nil || nextP != nil {
            if let row = nextP { out.append(row); nextP = p.next() }
            if let row = nextE { out.append(row); nextE = e.next() }
        }
        return out
    }

    /// Takes hidden titles out of every row (and drops a row left empty).
    static func hiding(_ hidden: Set<MediaKey>, from rows: [HomeRow]) -> [HomeRow] {
        guard !hidden.isEmpty else { return rows }
        return rows.compactMap { row in
            let kept = row.titles.filter { !hidden.contains($0.key) }
            guard !kept.isEmpty else { return nil }
            var r = row
            r.titles = kept
            return r
        }
    }
}

// MARK: - Continue Watching

enum ContinueWatchingRules {
    /// A show you finished an episode of moves on for this long (the new-episode
    /// tracker follows shows for as long).
    static let nextUpWindow: TimeInterval = 90 * 86_400

    /// What Home knows about a show without asking: its seasons (from a
    /// detail still in memory) and the last aired episode (the new-episode
    /// tracker's).
    struct ShowInfo: Hashable, Sendable {
        var seasons: [SeasonSummary]?
        var lastAired: MediaKey?
        var lastAiredDate: Date?
        init(seasons: [SeasonSummary]? = nil, lastAired: MediaKey? = nil, lastAiredDate: Date? = nil) {
            self.seasons = seasons; self.lastAired = lastAired; self.lastAiredDate = lastAiredDate
        }
    }

    /// The episode after a finished one. `key` is nil when Bluebox can't tell
    /// (a season finale without the season list): playing asks then.
    struct NextEpisode: Hashable, Sendable {
        let key: MediaKey?
        let season: Int?
        let episode: Int?
        /// Newly aired: the card gets a "New Episode" tag and goes first.
        let isNew: Bool
    }

    struct Entry: Hashable, Sendable {
        /// The record shown: in progress, or the finished episode the next one follows.
        let progress: WatchProgress
        let next: NextEpisode?
    }

    /// One row: in-progress films and episodes resume; a show whose latest
    /// episode is finished moves on to the next one, and leaves the row when
    /// you're caught up. New airings go first, then the most recent.
    /// - Parameters:
    ///   - inProgress: `continueWatching(limit:)`, one per show, newest first.
    ///   - recent: the latest progress records (any state).
    ///   - announced: episodes the new-episode check announced.
    static func build(inProgress: [WatchProgress], recent: [WatchProgress], shows: [MediaKey: ShowInfo],
                      announced: Set<String> = [], now: Date, limit: Int = 20,
                      policy: ProgressPolicy = .standard) -> [Entry] {
        var latest: [MediaKey: WatchProgress] = [:]
        for p in recent {
            guard let s = p.key.seriesKey, p.key.episodeNumbers != nil else { continue }
            if let have = latest[s], have.updatedAt >= p.updatedAt { continue }
            latest[s] = p
        }
        var out: [Entry] = []
        var seen = Set<MediaKey>()
        for p in inProgress {
            let key = p.key.seriesKey ?? p.key
            // A show whose newest record is a finished episode moves on instead.
            if let s = p.key.seriesKey, let l = latest[s], l.key != p.key, l.updatedAt > p.updatedAt,
               TasteRules.isFinished(l, policy: policy) { continue }
            guard seen.insert(key).inserted else { continue }
            out.append(Entry(progress: p, next: nil))
        }
        for (s, l) in latest where !seen.contains(s) {
            guard now.timeIntervalSince(l.updatedAt) <= nextUpWindow else { continue }
            guard TasteRules.isFinished(l, policy: policy) else {
                // Taken out of the row (reset to 0) or barely started: not shown, as before.
                if policy.isInProgress(l) { out.append(Entry(progress: l, next: nil)); seen.insert(s) }
                continue
            }
            guard let next = nextEpisode(after: l.key, info: shows[s] ?? ShowInfo(), announced: announced, now: now) else {
                continue  // caught up
            }
            seen.insert(s)
            out.append(Entry(progress: l, next: next))
        }
        out.sort { a, b in
            let an = a.next?.isNew ?? false, bn = b.next?.isNew ?? false
            if an != bn { return an }
            return (a.progress.updatedAt, a.progress.key.rawValue) > (b.progress.updatedAt, b.progress.key.rawValue)
        }
        return Array(out.prefix(limit))
    }

    /// Nil when you're caught up.
    static func nextEpisode(after key: MediaKey, info: ShowInfo, announced: Set<String>, now: Date) -> NextEpisode? {
        guard let series = key.seriesKey, let (s, e) = key.episodeNumbers else { return nil }
        let aired = info.lastAired?.episodeNumbers
        func make(_ ns: Int, _ ne: Int) -> NextEpisode {
            let k = series.episode(season: ns, episode: ne)
            var isNew = false
            if let k, k == info.lastAired {
                if let date = info.lastAiredDate {
                    isNew = date <= now && now.timeIntervalSince(date) <= NewEpisodeRules.newWindow + 86_400
                } else {
                    isNew = announced.contains(k.rawValue)
                }
            }
            return NextEpisode(key: k, season: ns, episode: ne, isNew: isNew)
        }
        if let seasons = info.seasons, !seasons.isEmpty {
            guard let (ns, ne) = SeriesCursor.next(after: s, e, seasons: seasons) else { return nil }
            // Listed but not out yet.
            if let aired, (ns, ne) > (aired.season, aired.episode) { return nil }
            return make(ns, ne)
        }
        if let aired {
            if (s, e) >= (aired.season, aired.episode) { return nil }
            if aired.season == s { return make(s, e + 1) }
            // Maybe the season's finale: which episode is next isn't known yet.
            return NextEpisode(key: nil, season: nil, episode: nil, isNew: false)
        }
        return NextEpisode(key: nil, season: nil, episode: nil, isNew: false)
    }
}

// MARK: - The per-profile file

/// "Because You Watched" seeds and their recommendations.
struct BecauseRow: Codable, Hashable, Sendable {
    let seed: Title
    let titles: [Title]
}

/// Home's personal rows for one profile, kept in a small file so they show
/// at once at launch. Rebuilt when watch history changes or after 6 hours;
/// recommendations are kept for 24 hours.
struct PersonalHomeSnapshot: Codable, Equatable, Sendable {
    static let rowsLifetime: TimeInterval = 6 * 3600
    static let recommendationsLifetime: TimeInterval = 24 * 3600

    struct Rows: Codable, Equatable, Sendable {
        var fingerprint: String
        var builtAt: Date
        var topPicks: [ScoredPick]
        var because: [BecauseRow]
        /// Genre IDs, strongest first, for the genre rows.
        var genreOrder: [Int]
    }

    struct Recommendations: Codable, Equatable, Sendable {
        var fetchedAt: Date
        var titles: [Title]
    }

    /// By `HomeCategory` raw value.
    var rows: [String: Rows] = [:]
    /// By seed title key raw value.
    var recommendations: [String: Recommendations] = [:]

    func freshRows(_ category: String, fingerprint: String, now: Date) -> Rows? {
        guard let r = rows[category], r.fingerprint == fingerprint,
              now.timeIntervalSince(r.builtAt) < Self.rowsLifetime, r.builtAt <= now.addingTimeInterval(60) else { return nil }
        return r
    }

    func freshRecommendations(for key: MediaKey, now: Date) -> [Title]? {
        guard let r = recommendations[key.rawValue], now.timeIntervalSince(r.fetchedAt) < Self.recommendationsLifetime else { return nil }
        return r.titles
    }

    /// Drops recommendations past their lifetime.
    mutating func prune(now: Date) {
        recommendations = recommendations.filter { now.timeIntervalSince($0.value.fetchedAt) < Self.recommendationsLifetime }
    }
}

/// Reads and writes `PersonalHomeSnapshot`s, one file per profile. The file
/// work (a few hundred KB of JSON) runs off the main actor: Home loads on it.
struct PersonalHomeStore: Sendable {
    let directory: URL

    private func url(_ profileID: String) -> URL {
        let safe = profileID.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appending(path: "home-\(safe).json")
    }

    func load(profileID: String) async -> PersonalHomeSnapshot? {
        let url = url(profileID)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(PersonalHomeSnapshot.self, from: data)
        }.value
    }

    func save(_ snapshot: PersonalHomeSnapshot, profileID: String) async {
        let url = url(profileID), directory = directory
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }

    func remove(profileID: String) {
        try? FileManager.default.removeItem(at: url(profileID))
    }
}

// MARK: - History

/// What Home reads from your library once per load (all local).
struct HomeHistory: Sendable {
    let records: [WatchProgress]
    let ratings: [MediaKey: RatingEntry]
    let watched: [WatchedTitle]
    /// Privacy & Features › Rows Based on Your Taste. Off: no Top Picks, no
    /// Because You Watched, and genre rows in the usual order. Discovery rows
    /// still leave out what you've watched (that's not taste, just not repeating).
    let tasteRows: Bool

    init(records: [WatchProgress], ratings: [MediaKey: RatingEntry], tasteRows: Bool = true) {
        self.records = records
        self.ratings = ratings
        self.tasteRows = tasteRows
        watched = TasteRules.watched(records)
    }

    /// Enough history for the personal rows, and they're wanted.
    var allowsPersonalRows: Bool { tasteRows && TasteRules.hasEnoughHistory(watched, ratings: ratings) }

    /// Watched past 25% (films and shows), for leaving out of discovery rows.
    var watchedKeys: Set<MediaKey> { Set(watched.filter { $0.base > 0 }.map(\.key)) }
    var dislikedKeys: Set<MediaKey> { Set(ratings.filter { RatingThumb($0.value.rating) == .down }.map(\.key)) }
    var discoveryExcluded: Set<MediaKey> { watchedKeys.union(dislikedKeys) }

    /// The two most recent titles you finished or got past 25% of (not ones you rated Not for Me).
    var seeds: [MediaKey] {
        Array(watched.filter { $0.base > 0 && RatingThumb(ratings[$0.key]?.rating) != .down }.prefix(2).map(\.key))
    }

    /// Changes whenever you watch (or rate) something, so the personal rows rebuild.
    func fingerprint(_ category: HomeCategory) -> String {
        var h = FNV()
        for p in records.prefix(400) {
            h.add(p.key.rawValue); h.add("\(Int(p.updatedAt.timeIntervalSince1970))"); h.add(p.isCompleted ? "1" : "0")
        }
        for (k, r) in ratings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { h.add(k.rawValue); h.add("\(r.rating)") }
        // Off never matches a file built while it was on (so its rows aren't shown).
        return "\(category.rawValue):\(records.count):\(String(h.value, radix: 16))" + (tasteRows ? "" : ":plain")
    }

    /// FNV-1a: a stable hash (Swift's `Hasher` changes every launch).
    struct FNV {
        var value: UInt64 = 0xcbf29ce484222325
        mutating func add(_ s: String) {
            for b in s.utf8 { value = (value ^ UInt64(b)) &* 0x100000001b3 }
            value = (value ^ 0x1f) &* 0x100000001b3
        }
    }
}
