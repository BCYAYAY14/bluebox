import Domain
import Downloads
import Foundation
import Persistence
import Playback
import VLCPlayback

// Lists (UI review decisions 10–12): My List, your own lists, and smart lists
// that fill themselves. The rules are pure, so they're tested
// (FeaturesTests/ListsTests); `AppModel` feeds them what the app knows.

/// Which list a page or tile is about.
public enum LibraryListID: Hashable, Sendable {
    case myList
    case own(String)
    case smart(SmartList)

    var isEditable: Bool { if case .smart = self { false } else { true } }
}

/// Lists that fill themselves from what the app already knows. Not stored:
/// worked out each time from My List, your lists, progress and downloads.
public enum SmartList: String, CaseIterable, Identifiable, Hashable, Sendable {
    case shortFilms, available4K, downloaded, continueWatching
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .shortFilms: "Unwatched films under 100 min"
        case .available4K: "Available in 4K"
        case .downloaded: "Downloaded"
        case .continueWatching: "Continue Watching"
        }
    }

    /// A shorter name for the grid's caption line.
    var shortTitle: String {
        switch self {
        case .shortFilms: "Under 100 min"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .shortFilms: "timer"
        case .available4K: "4k.tv"
        case .downloaded: "arrow.down.circle"
        case .continueWatching: "play.circle"
        }
    }
}

/// What the smart lists are built from.
struct SmartListInput: Sendable {
    /// My List and your lists, deduplicated, in that order.
    var pool: [Title] = []
    var facts: [MediaKey: TitleFacts] = [:]
    /// Finished films and episodes.
    var completed: Set<MediaKey> = []
    /// Titles with a finished download (shows by their series), newest first.
    var downloaded: [Title] = []
    /// Movie or series keys whose finished download is 4K.
    var downloaded4K: Set<MediaKey> = []
    /// Continue Watching's titles, most recent first.
    var watching: [Title] = []
}

enum SmartListRules {
    static let shortFilmMinutes = 100

    static func titles(_ list: SmartList, from input: SmartListInput) -> [Title] {
        switch list {
        case .shortFilms:
            // Only films whose runtime is known: an unknown one isn't "under 100 min".
            return input.pool.filter { t in
                guard t.kind == .movie, !input.completed.contains(t.key),
                      let minutes = input.facts[t.key]?.runtimeMinutes, minutes > 0 else { return false }
                return minutes < shortFilmMinutes
            }
        case .available4K:
            var seen = Set<MediaKey>()
            return (input.pool + input.downloaded).filter { t in
                (input.facts[t.key]?.has4K == true || input.downloaded4K.contains(t.key)) && seen.insert(t.key).inserted
            }
        case .downloaded:
            return input.downloaded
        case .continueWatching:
            return input.watching
        }
    }

    /// Whether a release's resolution label is 4K ("2160p", "4K", "UHD").
    static func is4K(_ resolution: String?) -> Bool {
        guard let r = resolution?.lowercased() else { return false }
        return r.contains("2160") || r.contains("4k") || r.contains("uhd")
    }
}

/// A tile in the Lists grid.
struct ListSummary: Identifiable, Hashable {
    let id: LibraryListID
    let name: String
    let symbol: String
    let count: Int
    /// Up to four, for the mosaic.
    let covers: [Title]

    var caption: String {
        let titles = "\(count) title\(count == 1 ? "" : "s")"
        if case .smart = id { return "Smart · \(titles)" }
        return titles
    }
}

/// Play All and Shuffle: what plays, in what order.
enum ListPlayOrder {
    /// Shows first (each plays its episodes in order, from where you are),
    /// then films, each group in the list's order. Shuffle mixes everything.
    static func order(_ titles: [Title], shuffled: Bool) -> [Title] {
        if shuffled { return titles.shuffled() }
        return titles.filter { $0.kind == .series } + titles.filter { $0.kind == .movie }
    }

    /// What comes after the title now playing (an episode counts as its show).
    /// Nil when what's playing isn't on the queue (something else was started).
    static func after(_ key: MediaKey, in queue: [Title]) -> ArraySlice<Title>? {
        let playing = key.seriesKey ?? key
        guard let i = queue.firstIndex(where: { $0.key == playing }) else { return nil }
        return queue[(i + 1)...]
    }

    /// "7 titles · 9 h 40 min" (the runtime only when some are known).
    static func summary(count: Int, minutes: Int) -> String {
        let titles = "\(count) title\(count == 1 ? "" : "s")"
        guard minutes > 0 else { return titles }
        let h = minutes / 60, m = minutes % 60
        let time = h == 0 ? "\(m) min" : m == 0 ? "\(h) h" : "\(h) h \(m) min"
        return "\(titles) · \(time)"
    }
}

/// A request to create or edit a list, shown by `listEditorHost()`.
public struct ListEditorRequest: Identifiable, Equatable {
    public let id = UUID()
    /// Editing this list; nil makes a new one.
    let list: UserList?
    /// "New List…" from Add to List: the title goes on the new list.
    let adding: Title?

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

extension AppModel {
    // MARK: Reading

    /// The Lists grid: My List, then your lists, then smart lists.
    func librarySummaries() async throws -> [ListSummary] {
        let myList = try await store.watchlist()
        let lists = try await store.lists()
        let entries = try await store.entriesByList()
        var out = [ListSummary(id: .myList, name: "My List", symbol: "plus", count: myList.count, covers: Array(myList.prefix(4)))]
        for l in lists {
            let titles = (entries[l.id] ?? []).map(\.title)
            out.append(ListSummary(id: .own(l.id), name: l.name, symbol: l.symbol, count: titles.count, covers: Array(titles.prefix(4))))
        }
        let input = await smartListInput(myList: myList, lists: entries)
        for s in SmartList.allCases {
            let titles = SmartListRules.titles(s, from: input)
            // "Available in 4K" stays out until a 4K release has been seen for something here.
            if s == .available4K && titles.isEmpty { continue }
            out.append(ListSummary(id: .smart(s), name: s.title, symbol: s.symbol, count: titles.count, covers: Array(titles.prefix(4))))
        }
        return out
    }

    /// A list's titles, in its own order (My List: manual order; smart lists: their rule's).
    func listTitles(_ id: LibraryListID) async throws -> [Title] {
        switch id {
        case .myList: return try await store.watchlistEntries().map(\.title)
        case .own(let listID): return try await store.entries(in: listID).map(\.title)
        case .smart(let s):
            let myList = try await store.watchlist()
            return SmartListRules.titles(s, from: await smartListInput(myList: myList, lists: try await store.entriesByList()))
        }
    }

    /// Known film runtimes, for the list page's total.
    func runtimes(for titles: [Title]) async -> [MediaKey: Int] {
        let facts = (try? await store.titleFacts(for: titles.map(\.key))) ?? [:]
        return facts.compactMapValues(\.runtimeMinutes)
    }

    private func smartListInput(myList: [Title], lists: [String: [ListEntry]]) async -> SmartListInput {
        var input = SmartListInput()
        var seen = Set<MediaKey>()
        input.pool = (myList + lists.values.flatMap { $0.map(\.title) }).filter { seen.insert($0.key).inserted }
        await learnRuntimes(input.pool.filter { $0.kind == .movie })
        input.facts = (try? await store.titleFacts(for: input.pool.map(\.key))) ?? [:]
        input.completed = Set(((try? await store.recent(limit: 2000)) ?? []).filter(\.isCompleted).map(\.key))

        // Downloads: one title per film or show, newest first.
        var order: [MediaKey] = []
        for r in downloads.all().sorted(by: { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) })
        where r.state == .completed {
            guard let key = r.mediaKey.map({ $0.seriesKey ?? $0 }) else { continue }
            if SmartListRules.is4K(r.origin.resolution) { input.downloaded4K.insert(key) }
            if !order.contains(key) { order.append(key) }
        }
        input.downloaded = await titles(for: order).compactMap { $0 }

        if let watching = try? await store.continueWatching(limit: 30) {
            var shown = Set<MediaKey>()
            let keys = watching.map { $0.key.seriesKey ?? $0.key }.filter { shown.insert($0).inserted }
            input.watching = await titles(for: keys).compactMap { $0 }
        }
        return input
    }

    /// Looks up runtimes the smart lists don't know yet, a few at a time, and
    /// keeps them (`TitleFactsRecord`), so each film is only looked up once.
    private func learnRuntimes(_ films: [Title]) async {
        let known = (try? await store.titleFacts(for: films.map(\.key))) ?? [:]
        let missing = Array(films.filter { known[$0.key]?.runtimeMinutes == nil }.prefix(24))
        guard !missing.isEmpty else { return }
        let lookup = RuntimeLookup(metadata: metadata)
        let found = await concurrentMap(missing.map(\.key)) { await lookup.runtime($0) }
        for (key, minutes) in zip(missing.map(\.key), found) {
            if let minutes { try? await store.noteTitleFacts(key, runtimeMinutes: minutes) }
        }
    }

    /// Remembers whether a title can be had in 4K, from what its sources offered.
    func noteQuality(_ availability: Availability, for key: MediaKey) {
        guard !availability.variants.isEmpty else { return }
        let fourK = availability.variants.contains { SmartListRules.is4K($0.resolution) }
        let store = store
        Task { try? await store.noteTitleFacts(key.seriesKey ?? key, has4K: fourK) }
    }

    // MARK: Changing

    /// Adds a title to one of your lists or takes it off, with a toast and Undo.
    func setOnList(_ title: Title, list: UserList, _ on: Bool) async {
        do {
            try await store.setOnList(title, listID: list.id, on)
            noteLibraryChanged()
        } catch {
            report(error, title: "Couldn't update \(list.name)") { [weak self] in await self?.setOnList(title, list: list, on) }
            return
        }
        showToast(AppToast(title.name, message: on ? "Added to \(list.name)" : "Removed from \(list.name)", actionTitle: "Undo") { [weak self] in
            Task {
                try? await self?.store.setOnList(title, listID: list.id, !on)
                self?.noteLibraryChanged()
            }
        })
    }

    /// Creates a list (from the editor), optionally with a first title on it.
    @discardableResult
    func createList(name: String, symbol: String, adding title: Title?) async -> UserList? {
        do {
            let list = try await store.createList(name: name, symbol: symbol)
            if let title { try await store.setOnList(title, listID: list.id, true) }
            noteLibraryChanged()
            if let title { showToast(AppToast(title.name, message: "Added to \(list.name)")) }
            return list
        } catch {
            report(error, title: "Couldn't create the list")
            return nil
        }
    }

    func updateList(_ list: UserList, name: String, symbol: String) async {
        do {
            try await store.updateList(list.id, name: name, symbol: symbol)
            noteLibraryChanged()
        } catch {
            report(error, title: "Couldn't change \(list.name)")
        }
    }

    func deleteList(_ list: UserList) async {
        do {
            try await store.removeList(list.id)
            noteLibraryChanged()
            showToast(AppToast(list.name, message: "List deleted"))
        } catch {
            report(error, title: "Couldn't delete \(list.name)")
        }
    }

    /// Saves Edit's new order.
    func reorder(_ id: LibraryListID, keys: [MediaKey]) async {
        do {
            switch id {
            case .myList: try await store.reorderWatchlist(keys)
            case .own(let listID): try await store.reorderList(listID, keys: keys)
            case .smart: return
            }
            noteLibraryChanged()
        } catch {
            report(error, title: "Couldn't save the order")
        }
    }

    /// Edit's Remove: several titles at once.
    func remove(_ keys: [MediaKey], titles: [Title], from id: LibraryListID) async {
        do {
            switch id {
            case .myList: for t in titles where keys.contains(t.key) { try await store.setWatchlisted(t, false) }
            case .own(let listID): try await store.removeFromList(keys, listID: listID)
            case .smart: return
            }
            noteLibraryChanged()
        } catch {
            report(error, title: "Couldn't remove them")
        }
    }

    // MARK: Play All

    /// Plays a list from the top (or shuffled): the first title now, the rest
    /// through Up Next as each one finishes.
    func playList(_ titles: [Title], shuffled: Bool) async {
        let queue = ListPlayOrder.order(titles, shuffled: shuffled)
        guard let first = queue.first else { return }
        listQueue = queue
        await playQuick(QuickActionSubject(title: first))
    }

    /// Up Next after a show's last episode or a film: the next title on the
    /// list being played that some source has.
    func nextInListQueue(after key: MediaKey) async -> (NowPlayingItem, PlaybackResource)? {
        guard let queue = listQueue, let rest = ListPlayOrder.after(key, in: queue) else { return nil }
        for t in rest.prefix(5) {
            if let resolved = await resolveQueued(t) { return resolved }
        }
        return nil
    }

    private func resolveQueued(_ t: Title) async -> (NowPlayingItem, PlaybackResource)? {
        if t.kind == .series {
            let progress = (try? await store.progress(forSeries: t.key)) ?? []
            guard let detail = try? await metadata.detail(for: t.key),
                  let target = SeriesCursor.target(series: t.key, progress: progress, seasons: detail.seasons) else { return nil }
            return await resolveEpisode(target.key, detail: detail)
        }
        guard maturityBlock(for: t.key) == nil else { return nil }
        let variant: MediaVariant
        if let saved = downloadedVariant(for: t.key) {
            variant = saved
        } else {
            let found = await availability(for: t.key)
            guard let v = chooseVariant(found.variants, for: t.key), PlaybackEngines.canAttempt(container: v.container) else { return nil }
            variant = v
        }
        await holdTorrentDownloads(before: variant, key: t.key)
        guard let resource = try? await registry.resolve(variant) else { return nil }
        await holdTorrentDownloads(streaming: resource.variant)
        rememberSource(variant, for: t.key)
        return (NowPlayingItem(key: t.key, title: t.name, subtitle: t.year.map(String.init), artworkURL: imageURL(t.backdrop, width: 640)),
                resource)
    }
}

/// Lets the runtime lookups run off the main actor.
private struct RuntimeLookup: Sendable {
    let metadata: any MetadataProvider
    func runtime(_ key: MediaKey) async -> Int? { try? await metadata.detail(for: key).runtimeMinutes }
}
