import Domain
import Foundation

// My List's type chips and sort menu (with Manual, UI review decision 12),
// and the History section (GAPS L1, L3; decision Q7 A). Pure, so the order
// and grouping are tested.

/// All, Films or TV.
enum MyListFilter: String, CaseIterable, Identifiable, Sendable {
    case all, films, shows
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .films: "Films"
        case .shows: "TV"
        }
    }

    func includes(_ t: Title) -> Bool {
        switch self {
        case .all: true
        case .films: t.kind == .movie
        case .shows: t.kind == .series
        }
    }
}

enum MyListSort: String, CaseIterable, Identifiable, Sendable {
    case recentlyAdded, manual, title, releaseDate, rating
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .manual: "Manual"
        case .title: "Title"
        case .releaseDate: "Release Date"
        case .rating: "Rating"
        }
    }

    /// A smart list has no order of its own to edit: its rule's order is "Default".
    func title(smart: Bool) -> String { smart && self == .manual ? "Default" : title }

    /// The choices for a list: a smart list has no "added" date.
    static func options(smart: Bool) -> [MyListSort] { smart ? allCases.filter { $0 != .recentlyAdded } : allCases }
}

enum MyListArrangement {
    /// `titles` come newest-added first (the store's order). Ties keep that order.
    /// `manual` is the hand-set order (Edit › drag), for `.manual`; titles it
    /// doesn't mention follow, newest first.
    static func arrange(_ titles: [Title], filter: MyListFilter, sort: MyListSort, manual: [MediaKey] = []) -> [Title] {
        let shown = Array(titles.enumerated()).filter { filter.includes($0.element) }
        let sorted: [(offset: Int, element: Title)]
        switch sort {
        case .recentlyAdded:
            sorted = shown
        case .manual:
            let rank = Dictionary(manual.enumerated().map { ($0.element, $0.offset) }) { a, _ in a }
            sorted = shown.sorted { a, b in
                let x = rank[a.element.key] ?? Int.max, y = rank[b.element.key] ?? Int.max
                return x != y ? x < y : a.offset < b.offset
            }
        case .title:
            sorted = shown.sorted { a, b in
                let order = sortKey(a.element.name).localizedStandardCompare(sortKey(b.element.name))
                return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
            }
        case .releaseDate:
            // Newest first; titles without a date last.
            sorted = shown.sorted { a, b in
                switch (a.element.releaseDate, b.element.releaseDate) {
                case let (x?, y?) where x != y: return x > y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.offset < b.offset
                }
            }
        case .rating:
            // Highest first; unrated last.
            sorted = shown.sorted { a, b in
                let x = a.element.voteAverage ?? -1, y = b.element.voteAverage ?? -1
                return x != y ? x > y : a.offset < b.offset
            }
        }
        return sorted.map(\.element)
    }

    /// "The Long Field" sorts under L, as in a shop.
    static func sortKey(_ name: String) -> String {
        for article in ["The ", "A ", "An "] where name.count > article.count && name.hasPrefix(article) {
            return String(name.dropFirst(article.count))
        }
        return name
    }
}

/// One finished title or episode in History.
struct HistoryEntry: Identifiable, Hashable {
    let progress: WatchProgress
    let title: Title
    var id: MediaKey { progress.key }
    var finishedAt: Date { progress.updatedAt }

    var detail: String {
        if let (s, e) = progress.key.episodeNumbers { return "S\(s)·E\(e)" }
        return title.kind == .movie ? "Film" : "Series"
    }
}

enum WatchHistory {
    struct Group: Identifiable, Hashable {
        let title: String
        let entries: [HistoryEntry]
        var id: String { title }
    }

    /// Finished records only, newest first.
    static func finished(_ records: [WatchProgress]) -> [WatchProgress] {
        records.filter(\.isCompleted).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// "Today", "Yesterday", "This Week", "Earlier This Month", then by month
    /// ("September", or "September 2025" in another year). Empty groups are left out.
    static func grouped(_ entries: [HistoryEntry], now: Date = .now, calendar: Calendar = .current) -> [Group] {
        var order: [String] = []
        var buckets: [String: [HistoryEntry]] = [:]
        for e in entries.sorted(by: { $0.finishedAt > $1.finishedAt }) {
            let label = bucket(e.finishedAt, now: now, calendar: calendar)
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(e)
        }
        return order.map { Group(title: $0, entries: buckets[$0] ?? []) }
    }

    static func bucket(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "This Week" }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "Earlier This Month" }
        var style = Date.FormatStyle.dateTime.month(.wide)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }

    /// "14:02" today, "Tue" this week, else "12 Oct": the date in a History row.
    static func shortDate(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
