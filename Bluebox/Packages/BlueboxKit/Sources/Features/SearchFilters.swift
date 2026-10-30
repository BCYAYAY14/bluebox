import Addons
import DesignSystem
import Domain
import Foundation
import SwiftUI

// MARK: - Filter chips

/// Search's chips (decision 14): one scope (All, Films, TV, People), plus
/// "Playable now", "4K" and a decade, which narrow the titles.
struct SearchFilter: Hashable, Sendable {
    enum Scope: String, CaseIterable, Sendable {
        case all, films, shows, people

        var title: String {
            switch self {
            case .all: "All"
            case .films: "Films"
            case .shows: "TV"
            case .people: "People"
            }
        }
    }

    var scope: Scope = .all
    var playableNow = false
    var uhd = false
    /// The decade's first year (2010 for the 2010s); `Self.earlier` for before the first chip.
    var decade: Int?

    /// Newest first; the last chip is everything before 1980.
    static let decades = [2020, 2010, 2000, 1990, 1980]
    static let earlier = 0

    static func decadeTitle(_ d: Int) -> String { d == earlier ? "Earlier" : "\(d)s" }

    /// Narrowing by availability or year leaves people out: they have neither.
    var includesPeople: Bool { (scope == .all || scope == .people) && !narrowsTitles }
    var includesTitles: Bool { scope != .people }
    var narrowsTitles: Bool { playableNow || uhd || decade != nil }
    /// "Playable now" and "4K" need to know what's downloaded, in the debrid cloud or found.
    var needsAvailability: Bool { playableNow || uhd }
    /// Any chip other than All is on: Search offers Clear Filters.
    var isNarrowed: Bool { self != SearchFilter() }

    func matches(_ t: Title, availability: SearchAvailability) -> Bool {
        switch scope {
        case .films: if t.kind != .movie { return false }
        case .shows: if t.kind != .series { return false }
        case .people: return false
        case .all: break
        }
        if playableNow, !availability.playable.contains(t.key) { return false }
        if uhd, !availability.uhd.contains(t.key) { return false }
        if let decade {
            guard let year = t.year else { return false }
            if decade == Self.earlier {
                if year >= Self.decades.last! { return false }
            } else if !(decade..<(decade + 10)).contains(year) {
                return false
            }
        }
        return true
    }

    /// Sections for the query with the chips applied. The top result is picked
    /// from what's left, so "TV" never leads with a film.
    func sections(query: String, titles: [Title], people: [Person], availability: SearchAvailability) -> SearchSections {
        SearchSections.build(query: query,
                             titles: includesTitles ? titles.filter { matches($0, availability: availability) } : [],
                             people: includesPeople ? people : [])
    }
}

/// A query that ends in a year ("dune 2021", "the thing (1982)"): the
/// catalog is searched for the words, and titles from that year lead.
struct SearchQuery: Equatable, Sendable {
    let text: String
    let year: Int?

    init(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = q.split(separator: " ")
        if words.count > 1, let last = words.last,
           let year = Int(last.trimmingCharacters(in: CharacterSet(charactersIn: "()"))),
           (1900...2100).contains(year) {
            words.removeLast()
            self.text = words.joined(separator: " ")
            self.year = year
        } else {
            self.text = q
            self.year = nil
        }
    }

    /// Titles from `year` first (keeping the catalog's order otherwise).
    func ranked(_ titles: [Title]) -> [Title] {
        guard let year else { return titles }
        let hits = titles.filter { $0.year == year }
        return hits + titles.filter { $0.year != year }
    }

    /// Your-library matching: the words, and the year when one was typed.
    func matches(_ t: Title) -> Bool {
        guard t.name.localizedStandardContains(text) else { return false }
        return year == nil || t.year == year
    }
}

/// Chips last for the app's run, per profile: the next search keeps them,
/// a relaunch starts from All.
@MainActor
enum SearchFilterMemory {
    private static var byProfile: [String: SearchFilter] = [:]
    static func filter(profile: String) -> SearchFilter { byProfile[profile] ?? SearchFilter() }
    static func set(_ filter: SearchFilter, profile: String) { byProfile[profile] = filter }
}

/// Which titles play right away or come in 4K, from what's known without
/// asking anyone: finished downloads, the debrid cloud, and releases the
/// add-ons found this session. Keyed by title (a show, not its episodes).
struct SearchAvailability: Equatable, Sendable {
    var playable: Set<MediaKey> = []
    var uhd: Set<MediaKey> = []

    /// - Parameters:
    ///   - downloads: finished downloads' keys and resolutions.
    ///   - cloud: debrid cloud files' keys and resolutions.
    ///   - offers: what add-on searches found, per movie or episode.
    static func make(downloads: [(MediaKey, String?)], cloud: [(MediaKey, String?)],
                     offers: [MediaKey: ReleaseOffer]) -> SearchAvailability {
        var out = SearchAvailability()
        for (key, resolution) in downloads + cloud {
            let title = key.seriesKey ?? key
            out.playable.insert(title)
            if isUHD(resolution) { out.uhd.insert(title) }
        }
        for (key, offer) in offers {
            let title = key.seriesKey ?? key
            if offer.instant { out.playable.insert(title) }
            if offer.uhd { out.uhd.insert(title) }
        }
        return out
    }

    static func isUHD(_ resolution: String?) -> Bool {
        guard let r = resolution?.lowercased() else { return false }
        return r.contains("2160") || r.contains("4k")
    }
}

extension AppModel {
    /// See `SearchAvailability`. The debrid cloud is only read when a service
    /// with a library is set up (and comes from its own cache when fresh).
    func searchAvailability() async -> SearchAvailability {
        let done = downloads.all().compactMap { r -> (MediaKey, String?)? in
            guard r.state == .completed, let key = r.mediaKey else { return nil }
            return (key, r.origin.resolution)
        }
        var cloud: [(MediaKey, String?)] = []
        if debridLibraryService != nil, let entries = try? await features.debridLibrary.library() {
            cloud = entries.compactMap { e in e.key.map { ($0, e.parsed.resolution) } }
        }
        return SearchAvailability.make(downloads: done, cloud: cloud, offers: await addons.cachedOffers())
    }
}

// MARK: - Recent searches

/// A search you ran, with its top result's picture for the list.
struct RecentSearch: Codable, Hashable, Identifiable, Sendable {
    var query: String
    /// The top result's poster (or a person's portrait), once known.
    var artwork: Artwork?
    /// "Harbor Lights · Series", under the query.
    var detail: String?
    var id: String { query.lowercased() }
}

/// Settings › Privacy › Save Search History: off, nothing new is remembered
/// (what's there stays until cleared). One switch for the device.
enum SearchHistoryPreference {
    static let key = "bluebox.searchHistory.saves"
    static var saves: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Recent searches, newest first, at most `limit`. Each profile has its own (`ViewMemory`).
struct RecentSearches: Equatable, Sendable {
    static let limit = 10
    static let memoryKey = "recentSearches.v2"
    /// The old newline-separated list of queries.
    static let oldMemoryKey = "recentSearches"

    private(set) var items: [RecentSearch] = []

    init(_ items: [RecentSearch] = []) { self.items = Array(items.prefix(Self.limit)) }

    var isEmpty: Bool { items.isEmpty }

    /// Moves `query` to the top (one entry per query, whatever its case),
    /// keeping its picture unless a new one is given.
    mutating func add(_ query: String, artwork: Artwork? = nil, detail: String? = nil) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        let old = items.first { $0.query.caseInsensitiveCompare(q) == .orderedSame }
        items.removeAll { $0.query.caseInsensitiveCompare(q) == .orderedSame }
        items.insert(RecentSearch(query: q, artwork: artwork ?? old?.artwork, detail: detail ?? old?.detail), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    /// Gives an entry that has no picture yet its top result's, without moving it.
    @discardableResult
    mutating func fillArtwork(for query: String, artwork: Artwork?, detail: String?) -> Bool {
        guard let artwork, let i = items.firstIndex(where: { $0.query.caseInsensitiveCompare(query) == .orderedSame }),
              items[i].artwork == nil else { return false }
        items[i].artwork = artwork
        items[i].detail = detail
        return true
    }

    mutating func remove(_ query: String) {
        items.removeAll { $0.query.caseInsensitiveCompare(query) == .orderedSame }
    }

    mutating func removeAll() { items = [] }

    // Storage

    @MainActor
    static func load(profile: String) -> RecentSearches {
        if let json = ViewMemory.string(memoryKey, profile: profile),
           let items = try? JSONDecoder().decode([RecentSearch].self, from: Data(json.utf8)) {
            return RecentSearches(items)
        }
        // Before pictures: a newline-separated list, per profile; before that, one
        // list for everyone, which the default profile keeps.
        var old = ViewMemory.string(oldMemoryKey, profile: profile)
        let legacyKey = "bluebox.recentSearches"
        if old == nil, profile == Profile.defaultID, let legacy = UserDefaults.standard.string(forKey: legacyKey) {
            old = legacy
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        guard let old else { return RecentSearches() }
        let migrated = RecentSearches(old.split(separator: "\n").map { RecentSearch(query: String($0)) })
        migrated.save(profile: profile)
        ViewMemory.set(nil as String?, oldMemoryKey, profile: profile)
        return migrated
    }

    @MainActor
    func save(profile: String) {
        let json = items.isEmpty ? nil : (try? JSONEncoder().encode(items)).map { String(decoding: $0, as: UTF8.self) }
        ViewMemory.set(json, Self.memoryKey, profile: profile)
    }
}

// MARK: - Chip

/// A filter chip: outlined when off, solid white with black text when on
/// (the mockups' `.chip.on`), so the choice reads without colour.
struct FilterChip: View {
    let title: String
    var systemImage: String?
    let selected: Bool
    /// Shows a ▾ (the chip opens a menu).
    var opensMenu = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, systemImage: String? = nil, selected: Bool, opensMenu: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.selected = selected; self.opensMenu = opensMenu
        self.action = action
    }

    var body: some View {
        Button(action: action) { FilterChipLabel(title: title, systemImage: systemImage, selected: selected, opensMenu: opensMenu, hovering: hovering) }
            .buttonStyle(PressableStyle())
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The chip's look, also used as a `BlueboxMenu` label.
struct FilterChipLabel: View {
    let title: String
    var systemImage: String?
    let selected: Bool
    var opensMenu = false
    var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption2.weight(.bold)) }
            Text(ui: title).lineLimit(1)
            if opensMenu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .heavy)) }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(selected ? Color.black : Palette.textPrimary)
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .background(selected ? Color.white : (hovering ? Palette.elevated : Palette.surface), in: Capsule())
        .overlay(Capsule().strokeBorder(selected ? .clear : Color.white.opacity(0.16), lineWidth: 1))
        .contentShape(Capsule())
        .frame(minHeight: 44)
        .fixedSize()
    }
}

/// Chips in one line that scroll sideways, past the page's inset to the edge.
struct ChipRow<Content: View>: View {
    let inset: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) { content }
                .padding(.horizontal, inset)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

/// A hairline between groups of chips.
struct ChipDivider: View {
    var body: some View {
        Rectangle().fill(Palette.separator).frame(width: 1, height: 18).padding(.horizontal, 3).accessibilityHidden(true)
    }
}
