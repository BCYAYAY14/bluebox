//
//  AddonCatalogs.swift
//  Bluebox
//
//  Written for Bluebox from public documentation: the Stremio add-on SDK's
//  catalog docs (docs/api/requests/defineCatalogHandler.md,
//  docs/api/responses/meta.md). An add-on's own lists, shown as rows on
//  Home: which of its catalogs Bluebox can show, which you've chosen and in
//  what order, and the items they hold.
//

import Foundation

// MARK: - Your choices

/// One of an add-on's catalogs as Settings and Home see it: what it is, what
/// it can be asked with, and whether it's shown on Home. Kept on the
/// `InstalledAddon` in the order you put them.
public struct AddonCatalog: Codable, Sendable, Hashable, Identifiable {
    /// "movie", "series" or "anime".
    public var type: String
    /// The add-on's ID for it ("top", "trakt-trending").
    public var catalogID: String
    /// The add-on's name for it, never translated.
    public var name: String
    /// The genres it can be filtered by (its "genre" extra's options).
    public var genres: [String]
    /// It only answers with a genre: Home uses the first.
    public var genreRequired: Bool
    /// It takes `skip`, so See All can load more than the first page.
    public var canPage: Bool
    public var isShown: Bool

    public var id: String { "\(type)/\(catalogID)" }

    public init(type: String, catalogID: String, name: String, genres: [String] = [], genreRequired: Bool = false,
                canPage: Bool = true, isShown: Bool = true) {
        self.type = type; self.catalogID = catalogID; self.name = name; self.genres = genres
        self.genreRequired = genreRequired; self.canPage = canPage; self.isShown = isShown
    }

    /// The types Bluebox can show and open.
    public static let showableTypes: Set<String> = ["movie", "series", "anime"]

    /// A catalog from the manifest, or nil when Bluebox can't show it: another
    /// type (TV channels), or one that only answers a search or other input.
    public init?(_ catalog: AddonManifest.Catalog, manifest: AddonManifest) {
        guard Self.showableTypes.contains(catalog.type), !catalog.id.isEmpty else { return nil }
        let genre = catalog.extra("genre")
        for extra in catalog.extra where extra.isRequired && extra.name != "skip" {
            guard extra.name == "genre", !extra.options.isEmpty else { return nil }
        }
        let typeName = catalog.type == "movie" ? "Movies" : catalog.type == "anime" ? "Anime" : "Series"
        let name = catalog.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(type: catalog.type, catalogID: catalog.id,
                  name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "\(manifest.name) \(typeName)",
                  genres: genre?.options ?? [], genreRequired: genre?.isRequired ?? false,
                  canPage: catalog.extra("skip") != nil)
    }

    /// Movies or not (series and anime open as shows).
    public var isMovie: Bool { type == "movie" }

    /// The extras for one page: the genre (the first when one is required), and `skip`.
    public func extra(genre: String? = nil, skip: Int = 0) -> [String: String] {
        var out: [String: String] = [:]
        if let genre = genre ?? (genreRequired ? genres.first : nil) { out["genre"] = genre }
        if skip > 0 { out["skip"] = String(skip) }
        return out
    }

    private enum CodingKeys: String, CodingKey { case type, catalogID, name, genres, genreRequired, canPage, isShown }

    /// Lenient, so a field added later doesn't cost the add-on its catalogs.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        catalogID = try c.decode(String.self, forKey: .catalogID)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? catalogID
        genres = (try? c.decodeIfPresent([String].self, forKey: .genres)) ?? []
        genreRequired = (try? c.decodeIfPresent(Bool.self, forKey: .genreRequired)) ?? false
        canPage = (try? c.decodeIfPresent(Bool.self, forKey: .canPage)) ?? false
        isShown = (try? c.decodeIfPresent(Bool.self, forKey: .isShown)) ?? true
    }
}

extension AddonManifest {
    /// Its catalogs Bluebox can show, each once, in the manifest's order.
    public var homeCatalogs: [AddonCatalog] {
        var seen = Set<String>()
        return catalogs.compactMap { AddonCatalog($0, manifest: self) }.filter { seen.insert($0.id).inserted }
    }
}

/// A catalog ready to ask: the add-on it's from (with its configured link) and the catalog.
public struct ResolvedCatalog: Sendable, Hashable, Identifiable {
    public var addon: ResolvedAddon
    public var catalog: AddonCatalog
    public var id: String { "\(addon.id)/\(catalog.id)" }

    public init(addon: ResolvedAddon, catalog: AddonCatalog) {
        self.addon = addon; self.catalog = catalog
    }
}

extension AddonSettings {
    /// Add-on catalogs shown on Home unless you turn more on: a new add-on's
    /// first few, not all twenty of a list add-on's.
    public static let defaultHomeCatalogs = 6

    /// How many add-on catalogs are on Home now.
    public var shownCatalogCount: Int {
        addons.reduce(0) { $0 + ($1.catalogs?.filter(\.isShown).count ?? 0) }
    }

    /// Takes in an add-on's catalogs from its manifest. Ones you had keep their
    /// place and switch; ones it no longer has go; new ones go at the end,
    /// shown while Home has fewer than `defaultHomeCatalogs`.
    public mutating func updateCatalogs(of addonID: String, from manifest: AddonManifest) {
        guard let i = addons.firstIndex(where: { $0.id == addonID }) else { return }
        let fresh = manifest.homeCatalogs
        let old = addons[i].catalogs ?? []
        var kept: [AddonCatalog] = old.compactMap { had in
            guard var now = fresh.first(where: { $0.id == had.id }) else { return nil }
            now.isShown = had.isShown
            return now
        }
        addons[i].catalogs = kept
        var shown = shownCatalogCount
        for var c in fresh where !old.contains(where: { $0.id == c.id }) {
            c.isShown = shown < Self.defaultHomeCatalogs
            if c.isShown { shown += 1 }
            kept.append(c)
        }
        addons[i].catalogs = kept
    }

    public mutating func setCatalog(_ catalogID: String, of addonID: String, shown: Bool) {
        guard let i = addons.firstIndex(where: { $0.id == addonID }),
              let j = addons[i].catalogs?.firstIndex(where: { $0.id == catalogID }) else { return }
        addons[i].catalogs?[j].isShown = shown
    }

    public mutating func moveCatalogs(of addonID: String, from offsets: IndexSet, to destination: Int) {
        guard let i = addons.firstIndex(where: { $0.id == addonID }), let catalogs = addons[i].catalogs else { return }
        // List's move, by hand: SwiftUI's `move(fromOffsets:)` isn't linked here.
        let moving = offsets.filter(catalogs.indices.contains).map { catalogs[$0] }
        var rest = catalogs.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let at = min(rest.count, destination - offsets.filter { $0 < destination }.count)
        rest.insert(contentsOf: moving, at: max(0, at))
        addons[i].catalogs = rest
    }

    /// The catalogs on Home, in order: add-ons in their order (turned on,
    /// with their links), each one's shown catalogs in yours.
    public func homeCatalogs(debridKey: String) -> [ResolvedCatalog] {
        guard isEnabled else { return [] }
        let byID = Dictionary(addons.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return resolvedAddons(debridKey: debridKey, includingCatalogsOnly: true).flatMap { addon in
            (byID[addon.id]?.catalogs ?? []).filter(\.isShown).map { ResolvedCatalog(addon: addon, catalog: $0) }
        }
    }

    /// A shown-or-not catalog by add-on and catalog ID (a See All page).
    public func resolvedCatalog(addonID: String, catalogID: String, debridKey: String) -> ResolvedCatalog? {
        guard let addon = resolvedAddons(debridKey: debridKey, includingCatalogsOnly: true).first(where: { $0.id == addonID }),
              let catalog = addons.first(where: { $0.id == addonID })?.catalogs?.first(where: { $0.id == catalogID }) else { return nil }
        return ResolvedCatalog(addon: addon, catalog: catalog)
    }

    /// Add-ons added by link whose catalogs haven't been read yet (added
    /// before Bluebox showed them). Presets have none.
    public var addonsMissingCatalogs: [InstalledAddon] {
        addons.filter { $0.isEnabled && $0.preset == nil && $0.catalogs == nil && !needsLink($0) }
    }
}

// MARK: - Items

/// An item in a catalog, as the docs describe it. Every field is read
/// leniently: add-ons send numbers as strings and the other way round, and
/// one odd field shouldn't cost the item.
public struct AddonMetaItem: Decodable, Sendable, Hashable {
    public var id: String
    public var type: String?
    public var name: String
    /// IMDb ID when the add-on knows it (Kitsu's anime often do).
    public var imdbID: String?
    public var poster: String?
    public var background: String?
    public var description: String?
    public var releaseInfo: String?
    public var released: String?
    public var genres: [String]
    public var imdbRating: String?

    /// The IMDb ID, from `imdb_id` or an ID that is one.
    public var imdb: String? {
        if let imdbID, Self.isIMDb(imdbID) { return imdbID }
        return Self.isIMDb(id) ? id : nil
    }

    /// The TMDB ID, from an ID like "tmdb:603".
    public var tmdb: Int? {
        guard id.hasPrefix("tmdb:"), let n = Int(id.dropFirst(5)), n > 0 else { return nil }
        return n
    }

    static func isIMDb(_ s: String) -> Bool {
        s.count > 2 && s.hasPrefix("tt") && s.dropFirst(2).allSatisfy(\.isNumber)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, name, imdbID = "imdb_id", poster, background, description, releaseInfo, released, year
        case genres, genre, imdbRating
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = Self.string(c, .id), !id.isEmpty,
              let name = Self.string(c, .name)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No id or name"))
        }
        self.id = id
        self.name = name
        type = Self.string(c, .type)
        imdbID = Self.string(c, .imdbID)
        poster = Self.link(Self.string(c, .poster))
        background = Self.link(Self.string(c, .background))
        description = Self.string(c, .description)
        releaseInfo = Self.string(c, .releaseInfo) ?? Self.string(c, .year)
        released = Self.string(c, .released)
        genres = Self.strings(c, .genres) ?? Self.strings(c, .genre) ?? []
        imdbRating = Self.string(c, .imdbRating)
    }

    /// Only web images: anything else (a `file:` URL, a data blob) is dropped.
    static func link(_ s: String?) -> String? {
        guard let s, let scheme = URL(string: s)?.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return s
    }

    static func string<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let n = try? c.decodeIfPresent(Double.self, forKey: key) {
            return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        }
        return nil
    }

    static func strings<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [String]? {
        if let a = try? c.decodeIfPresent([String].self, forKey: key) { return a.filter { !$0.isEmpty } }
        return string(c, key).map { [$0] }
    }

    struct Lenient<T: Decodable & Sendable>: Decodable, Sendable {
        let value: T?
        init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
    }

    struct CatalogResponse: Decodable { let metas: [Lenient<AddonMetaItem>]? }
}
