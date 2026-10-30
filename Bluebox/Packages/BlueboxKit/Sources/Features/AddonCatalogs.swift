import Addons
import Domain
import Foundation
import Metadata

// Your add-ons' own catalogs as rows on Home (Stremio's Board is the model;
// mockup question 10 A). Items with an IMDb or TMDB ID become the
// catalogue's titles (moved to TMDB keys through `CatalogKeyBridge` when
// TMDB is in use), so they open the usual title page and My List, progress
// and playback treat them like any other. Items with another ID ("kitsu:1")
// have no page Bluebox can build, so they're left out rather than shown
// broken. Pages are cached with the other catalogue answers; a catalog that
// fails just leaves its row out.

/// Reads add-on catalogs and turns their items into titles.
struct AddonCatalogReader: Sendable {
    let client: AddonClient
    /// Translates IMDb keys into TMDB ones; nil keeps them (Cinemeta).
    let bridge: CatalogKeyBridge?
    /// Where pages are kept, and the profile's limit; nil asks every time and shows everything (tests).
    let cache: CachedMetadataProvider?

    /// Titles on a Home row (each new one is a Cinemeta request to bridge, the first time).
    static let rowLength = 20
    /// See All stops here, whatever the add-on says.
    static let maxPages = 40
    static let timeout: TimeInterval = 10

    /// One page of a catalog, page 1 first. `skip` moves by the size of the
    /// first page (add-ons page by a fixed size, often 100). `limit` keeps
    /// only the first few (a Home row), so only those are bridged.
    func page(_ c: ResolvedCatalog, genre: String? = nil, page: Int = 1, limit: Int? = nil) async throws -> Page<Title> {
        let page = max(1, page)
        var skip = 0
        if page > 1 {
            guard c.catalog.canPage, page <= Self.maxPages else { return Page(items: [], page: page, totalPages: page) }
            let first = try await raw(c, genre: genre, skip: 0)
            guard !first.isEmpty else { return Page(items: [], page: page, totalPages: page) }
            skip = (page - 1) * first.count
        }
        let raw = try await raw(c, genre: genre, skip: skip)
        var titles = Self.titles(raw, catalog: c.catalog)
        // A few spare for the ones the profile's limit takes out.
        if let limit { titles = Array(titles.prefix(limit * 2)) }
        titles = await bridged(titles)
        // After bridging, so certifications seen under TMDB keys count.
        if let cache { titles = cache.allowed(titles) }
        if let limit { titles = Array(titles.prefix(limit)) }
        let more = c.catalog.canPage && !raw.isEmpty && page < Self.maxPages
        return Page(items: titles, page: page, totalPages: more ? page + 1 : page)
    }

    private func raw(_ c: ResolvedCatalog, genre: String?, skip: Int) async throws -> [AddonMetaItem] {
        let client = client
        let extra = c.catalog.extra(genre: genre, skip: skip)
        let fetch: @Sendable () async throws -> [AddonMetaItem] = {
            try await client.catalog(base: c.addon.base, type: c.catalog.type, id: c.catalog.catalogID,
                                     extra: extra, timeout: Self.timeout)
        }
        guard let cache else { return try await fetch() }
        // The add-on's ID and a digest of its link (which can hold a key) tell configurations apart.
        var link = HomeHistory.FNV()
        link.add(c.addon.base.absoluteString)
        let query = extra.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return try await cache.cached("addon-catalog:\(c.addon.id):\(String(link.value, radix: 16)):\(c.catalog.id):\(query)", fetch: fetch)
    }

    /// Items as titles, in order, each once; ones without an IMDb or TMDB ID are left out.
    static func titles(_ items: [AddonMetaItem], catalog: AddonCatalog) -> [Title] {
        var seen = Set<MediaKey>()
        return items.compactMap { AddonItemMapping.title($0, catalog: catalog) }.filter { seen.insert($0.key).inserted }
    }

    /// IMDb keys moved to TMDB ones where the bridge finds them (it remembers
    /// answers); the others stay as they are and still open.
    private func bridged(_ titles: [Title]) async -> [Title] {
        guard let bridge else { return titles }
        let out = await concurrentMap(titles, limit: 8) { t -> Title in
            guard t.key.imdbID != nil, let key = await bridge.key(for: t.key, toTMDB: true) else { return t }
            return Title(key: key, kind: t.kind, name: t.name, overview: t.overview, releaseDate: t.releaseDate,
                         genreIDs: t.genreIDs, voteAverage: t.voteAverage, poster: t.poster, backdrop: t.backdrop)
        }
        var seen = Set<MediaKey>()
        return out.filter { seen.insert($0.key).inserted }
    }
}

// MARK: - Mapping

enum AddonItemMapping {
    /// The item as a title, or nil when it has neither an IMDb nor a TMDB ID.
    static func title(_ item: AddonMetaItem, catalog: AddonCatalog) -> Title? {
        // The item's own type wins: a mixed catalog can hold both.
        let isMovie = (item.type ?? catalog.type) == "movie"
        let key: MediaKey
        if let imdb = item.imdb {
            key = isMovie ? .movie(imdbID: imdb) : .series(imdbID: imdb)
        } else if let tmdb = item.tmdb {
            key = isMovie ? .movie(tmdbID: tmdb) : .series(tmdbID: tmdb)
        } else {
            return nil
        }
        return Title(key: key, kind: isMovie ? .movie : .series, name: item.name, overview: item.description ?? "",
                     releaseDate: date(item.released) ?? yearDate(item.releaseInfo), genreIDs: item.genres.map(genreID),
                     voteAverage: item.imdbRating.flatMap(Double.init).flatMap { (0...10).contains($0) ? $0 : nil },
                     poster: item.poster.map { Artwork(.poster, path: $0) },
                     backdrop: item.background.map { Artwork(.backdrop, path: $0) })
    }

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: String(s.prefix(10)))
    }

    /// "2008–2013" or "1999" → the middle of the first year, so it reads as
    /// that year in every time zone.
    static func yearDate(_ s: String?) -> Date? {
        guard let s, let year = Int(s.prefix(4)), year > 1800 else { return nil }
        return DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt, year: year, month: 7, day: 1).date
    }

    /// Add-ons name genres. The family ones get TMDB's IDs, so a Kids
    /// profile's "family titles only when unrated" keeps them; the rest a
    /// stable made-up ID per name (the range Cinemeta's use).
    static func genreID(_ name: String) -> Int {
        switch name.lowercased() {
        case "animation", "anime": 16
        case "family": 10751
        case "kids", "children": 10762
        default: 9500 + name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 400 }
        }
    }
}

// MARK: - The app

extension AppModel {
    /// The catalogs on Home, in order. None with the sample catalogue, whose
    /// title pages can't open the add-ons' IMDb titles.
    func homeCatalogs() -> [ResolvedCatalog] {
        guard catalogMode != .sample else { return [] }
        return addonSettings.homeCatalogs(debridKey: debridKey)
    }

    func resolvedCatalog(addonID: String, catalogID: String) -> ResolvedCatalog? {
        addonSettings.resolvedCatalog(addonID: addonID, catalogID: catalogID, debridKey: debridKey)
    }

    var addonCatalogs: AddonCatalogReader {
        AddonCatalogReader(client: addonCatalogClient, bridge: catalogMode == .live ? keyBridge : nil,
                           cache: metadata as? CachedMetadataProvider)
    }

    /// Reads the catalogs of add-ons added before Home showed them, once.
    /// Saved without reloading Home: it's loading them now.
    func readMissingAddonCatalogs() async {
        let missing = addonSettings.addonsMissingCatalogs
        guard !missing.isEmpty else { return }
        let client = addonCatalogClient
        let links = addonSettings.customLinks
        var manifests: [String: AddonManifest] = [:]
        await withTaskGroup(of: (String, AddonManifest?).self) { group in
            for addon in missing {
                guard let base = links[addon.id].flatMap(URL.init(string:)) else { continue }
                group.addTask { (addon.id, try? await client.manifest(base: base, timeout: AddonCatalogReader.timeout)) }
            }
            for await (id, manifest) in group { manifests[id] = manifest }
        }
        guard !manifests.isEmpty else { return }
        var settings = addonSettings
        // In list order, so the first add-ons get the first places on Home.
        for addon in missing { if let m = manifests[addon.id] { settings.updateCatalogs(of: addon.id, from: m) } }
        saveAddonSettings(settings, reloading: false)
    }

    public func setAddonCatalog(_ catalogID: String, of addonID: String, shown: Bool) {
        var settings = addonSettings
        settings.setCatalog(catalogID, of: addonID, shown: shown)
        setAddonSettings(settings)
    }

    public func moveAddonCatalogs(of addonID: String, from offsets: IndexSet, to destination: Int) {
        var settings = addonSettings
        settings.moveCatalogs(of: addonID, from: offsets, to: destination)
        setAddonSettings(settings)
    }
}
