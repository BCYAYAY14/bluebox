//
//  StremioProtocol.swift
//  Bluebox
//
//  Written for Bluebox from public documentation: the Stremio add-on SDK's
//  protocol (docs/protocol.md) and response docs (docs/api/responses/
//  manifest.md and stream.md). An add-on is a base URL; `/manifest.json`
//  describes it and `/stream/{type}/{id}.json` lists streams for a movie
//  ("tt0111161") or an episode ("tt0944947:1:2").
//

import Foundation

// MARK: - Manifest

/// The parts of an add-on's manifest Bluebox uses.
public struct AddonManifest: Decodable, Sendable, Equatable {
    public struct Resource: Decodable, Sendable, Equatable {
        public var name: String
        /// nil: the manifest's own `types` apply.
        public var types: [String]?
        /// nil: the manifest's own `idPrefixes` apply (or any ID).
        public var idPrefixes: [String]?

        public init(name: String, types: [String]? = nil, idPrefixes: [String]? = nil) {
            self.name = name; self.types = types; self.idPrefixes = idPrefixes
        }

        public init(from decoder: any Decoder) throws {
            // A resource is either "stream" or { "name": "stream", "types": [...], "idPrefixes": [...] }.
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.init(name: name)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try c.decode(String.self, forKey: .name),
                      types: try? c.decodeIfPresent([String].self, forKey: .types),
                      idPrefixes: try? c.decodeIfPresent([String].self, forKey: .idPrefixes))
        }

        private enum CodingKeys: String, CodingKey { case name, types, idPrefixes }
    }

    public struct BehaviorHints: Decodable, Sendable, Equatable {
        public var configurable: Bool?
        public var configurationRequired: Bool?
    }

    public var id: String
    public var name: String
    public var version: String?
    public var description: String?
    public var logo: String?
    public var types: [String]
    public var idPrefixes: [String]?
    public var resources: [Resource]
    public var behaviorHints: BehaviorHints?

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        logo = try? c.decodeIfPresent(String.self, forKey: .logo)
        types = (try? c.decodeIfPresent([String].self, forKey: .types)) ?? []
        idPrefixes = try? c.decodeIfPresent([String].self, forKey: .idPrefixes)
        resources = (try? c.decodeIfPresent([Resource].self, forKey: .resources)) ?? []
        behaviorHints = try? c.decodeIfPresent(BehaviorHints.self, forKey: .behaviorHints)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, logo, types, idPrefixes, resources, behaviorHints
    }

    /// Whether the add-on answers stream requests for this type ("movie",
    /// "series") and an IMDb-style ID.
    public func offersStreams(type: String, idPrefix: String = "tt") -> Bool {
        resources.contains { r in
            guard r.name == "stream" else { return false }
            let types = r.types ?? self.types
            // Some add-ons leave the top-level types empty and list them per resource.
            guard types.contains(type) else { return false }
            guard let prefixes = r.idPrefixes ?? idPrefixes, !prefixes.isEmpty else { return true }
            return prefixes.contains { idPrefix.hasPrefix($0) || $0.hasPrefix(idPrefix) }
        }
    }

    /// The content types it streams that Bluebox plays.
    public var streamTypes: [String] {
        ["movie", "series"].filter { offersStreams(type: $0) }
    }
}

// MARK: - Requests

/// What to ask an add-on for.
public struct StreamRequest: Sendable, Hashable {
    public var imdbID: String
    public var season: Int?
    public var episode: Int?

    public init(imdbID: String, season: Int? = nil, episode: Int? = nil) {
        self.imdbID = imdbID; self.season = season; self.episode = episode
    }

    public var type: String { season != nil ? "series" : "movie" }

    /// "tt0944947:1:2" for an episode, "tt1727587" for a movie.
    public var stremioID: String {
        guard let season, let episode else { return imdbID }
        return "\(imdbID):\(season):\(episode)"
    }

    /// `{base}/stream/{type}/{id}.json`.
    public func url(base: URL) -> URL {
        base.appending(path: "stream").appending(path: type).appending(path: stremioID + ".json")
    }
}

public enum AddonURL {
    /// Turns what someone pasted ("stremio://host/config/manifest.json",
    /// "https://host/manifest.json", "host/config") into the add-on's base
    /// URL, which `/manifest.json` and `/stream/…` are appended to.
    public static func base(from input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { throw AddonError.invalidAddonURL }
        if text.lowercased().hasPrefix("stremio://") {
            text = "https://" + text.dropFirst("stremio://".count)
        } else if !text.contains("://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else { throw AddonError.invalidAddonURL }
        // Plain HTTP only for the local network (a self-hosted add-on).
        if scheme == "http", !(host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")) {
            components.scheme = "https"
        }
        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/manifest.json") { path.removeLast("/manifest.json".count) }
        else if path.lowercased() == "manifest.json" { path = "" }
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        guard let url = components.url else { throw AddonError.invalidAddonURL }
        return url
    }

    /// The host, for showing a custom add-on without its configuration (which may hold keys).
    public static func displayHost(_ base: String) -> String {
        URL(string: base)?.host ?? base
    }
}

// MARK: - Stream responses

/// What an add-on's stream response held: playable releases, and messages
/// add-ons send as fake streams ("Invalid Real-Debrid key", "Non-debrid
/// searches disabled").
public struct StreamResponse: Sendable, Equatable {
    public var releases: [AddonRelease]
    public var notices: [String]

    /// True when the add-on's only answer was that the debrid key is wrong.
    public var debridRejected: Bool {
        releases.isEmpty && notices.contains(where: StreamParser.isKeyProblem)
    }
}

/// Decodes stream responses.
public enum StreamParser {
    /// One stream as the docs describe it. Numbers are read leniently, as
    /// some add-ons send `fileIdx` or `videoSize` as strings or floats.
    struct Wire: Decodable {
        var url: String?
        var infoHash: String?
        var fileIdx: Int?
        var ytId: String?
        var externalUrl: String?
        var nzbUrl: String?
        var name: String?
        var title: String?
        var description: String?
        var sources: [String]?
        var behaviorHints: Hints?

        struct Hints: Decodable {
            var bingeGroup: String?
            var filename: String?
            var videoSize: Int64?
            var notWebReady: Bool?
            var hasProxyHeaders = false

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                bingeGroup = try? c.decodeIfPresent(String.self, forKey: .bingeGroup)
                filename = try? c.decodeIfPresent(String.self, forKey: .filename)
                videoSize = StreamParser.lenientInt(c, .videoSize)
                notWebReady = try? c.decodeIfPresent(Bool.self, forKey: .notWebReady)
                if let headers = try? c.nestedContainer(keyedBy: Keys.self, forKey: .proxyHeaders),
                   headers.contains(.request) {
                    hasProxyHeaders = true
                }
            }

            enum Keys: String, CodingKey { case bingeGroup, filename, videoSize, notWebReady, proxyHeaders, request }
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            url = try? c.decodeIfPresent(String.self, forKey: .url)
            infoHash = try? c.decodeIfPresent(String.self, forKey: .infoHash)
            fileIdx = StreamParser.lenientInt(c, .fileIdx).map(Int.init)
            ytId = try? c.decodeIfPresent(String.self, forKey: .ytId)
            externalUrl = try? c.decodeIfPresent(String.self, forKey: .externalUrl)
            nzbUrl = try? c.decodeIfPresent(String.self, forKey: .nzbUrl)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            description = try? c.decodeIfPresent(String.self, forKey: .description)
            sources = try? c.decodeIfPresent([String].self, forKey: .sources)
            behaviorHints = try? c.decodeIfPresent(Hints.self, forKey: .behaviorHints)
        }

        enum Keys: String, CodingKey {
            case url, infoHash, fileIdx, ytId, externalUrl, nzbUrl, name, title, description, sources, behaviorHints
        }
    }

    /// `{ "streams": [...] }`, skipping entries that don't decode.
    struct Envelope: Decodable {
        var streams: [Wire]

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            var list = try c.nestedUnkeyedContainer(forKey: .streams)
            var out: [Wire] = []
            while !list.isAtEnd {
                if let wire = try? list.decode(Wire.self) { out.append(wire) } else { _ = try? list.decode(Skip.self) }
            }
            streams = out
        }

        struct Skip: Decodable {}
        enum Keys: String, CodingKey { case streams }
    }

    fileprivate static func lenientInt<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int64? {
        if let v = try? c.decodeIfPresent(Int64.self, forKey: key) { return v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: key), v.isFinite { return Int64(v) }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int64(s) }
        return nil
    }

    /// Parses a stream response from one add-on.
    public static func parse(_ data: Data, addonID: String? = nil, addonName: String? = nil) throws -> StreamResponse {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw AddonError.unexpectedResponse
        }
        var releases: [AddonRelease] = []
        var notices: [String] = []
        for wire in envelope.streams {
            switch classify(wire) {
            case .release:
                if let release = release(from: wire, addonID: addonID, addonName: addonName) { releases.append(release) }
            case .notice(let text):
                notices.append(text)
            case .unsupported:
                continue
            }
        }
        return StreamResponse(releases: releases, notices: notices)
    }

    enum Kind: Equatable { case release, notice(String), unsupported }

    /// Words add-ons use in streams that are really messages.
    static let noticeWords = [
        "invalid", "expired", "unauthori", "not configured", "disabled", "error", "failed", "limit reached",
        "rate limit", "no results", "api key", "apikey", "token", "subscription", "premium required",
        "configure", "not premium", "blocked", "forbidden",
    ]
    static let noticeGlyphs = ["⛔", "❌", "⚠", "🚫", "❗"]

    static func classify(_ wire: Wire) -> Kind {
        if wire.ytId != nil || wire.externalUrl != nil || wire.nzbUrl != nil { return .unsupported }
        if wire.behaviorHints?.hasProxyHeaders == true { return .unsupported }  // needs headers AVPlayer won't send
        let text = [wire.name, wire.title, wire.description].compactMap { $0 }.joined(separator: " ")
        if let hash = wire.infoHash, isInfoHash(hash) { return .release }
        guard let link = wire.url, let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return text.isEmpty ? .unsupported : .notice(text)
        }
        // A link whose label is a warning, with no file name or size: a message, not a release.
        let lowered = text.lowercased()
        let hasFile = wire.behaviorHints?.filename != nil || (wire.behaviorHints?.videoSize ?? 0) > 0
        let looksLikeNotice = noticeGlyphs.contains(where: text.contains)
            || (!hasFile && noticeWords.contains(where: lowered.contains) && ReleaseNameParser.statistics(in: text).sizeBytes == nil)
            || url.lastPathComponent.lowercased().hasPrefix("failed")
        return looksLikeNotice ? .notice(text.trimmingCharacters(in: .whitespacesAndNewlines)) : .release
    }

    static func isKeyProblem(_ notice: String) -> Bool {
        let t = notice.lowercased()
        return (t.contains("invalid") || t.contains("expired") || t.contains("unauthori") || t.contains("wrong"))
            && (t.contains("key") || t.contains("token") || t.contains("debrid") || t.contains("account"))
    }

    static func isInfoHash(_ s: String) -> Bool {
        (s.count == 40 && s.allSatisfy(\.isHexDigit)) || (s.count == 32 && s.allSatisfy { $0.isLetter || ("2"..."7").contains($0) })
    }

    /// Base32 info hashes (32 characters) as hex.
    static func hexHash(_ s: String) -> String {
        guard s.count == 32 else { return s.lowercased() }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for ch in s.uppercased() {
            guard let index = alphabet.firstIndex(of: ch) else { return s.lowercased() }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func release(from wire: Wire, addonID: String?, addonName: String?) -> AddonRelease? {
        let label = wire.name ?? ""
        // `description` replaces the older `title`; some add-ons send both.
        let text = wire.description ?? wire.title ?? ""
        let hints = wire.behaviorHints
        let trackers = (wire.sources ?? []).compactMap { s -> String? in
            s.hasPrefix("tracker:") ? String(s.dropFirst("tracker:".count)) : nil
        }
        let info = ReleaseNameParser.parse(label: label, description: text, filename: hints?.filename)
        if let hash = wire.infoHash, isInfoHash(hash) {
            let hex = hexHash(hash)
            let index = wire.fileIdx.flatMap { $0 >= 0 ? $0 : nil }
            return AddonRelease(id: "\(hex):\(index ?? -1)", title: text, name: label, infoHash: hex, fileIndex: index,
                                trackers: trackers, seeders: nil, sizeText: nil, resolution: nil, container: nil, url: nil,
                                addonID: addonID, addonName: addonName, info: info, cache: .unknown,
                                bingeGroup: hints?.bingeGroup, filename: hints?.filename, videoSize: hints?.videoSize)
        }
        guard let link = wire.url, let url = URL(string: link) else { return nil }
        return AddonRelease(id: url.absoluteString, title: text, name: label, infoHash: nil, fileIndex: nil,
                            trackers: [], seeders: nil, sizeText: nil, resolution: nil, container: nil, url: url,
                            addonID: addonID, addonName: addonName, info: info, cache: cacheMarker(label + " " + text),
                            bingeGroup: hints?.bingeGroup, filename: hints?.filename, videoSize: hints?.videoSize)
    }

    /// Debrid add-ons mark cached links: "[RD+]", "[TB⚡]", "⚡"; and links the
    /// service must fetch first: "[RD download]", "[RD⬇️]", "⏳".
    static func cacheMarker(_ text: String) -> CacheState {
        let lowered = text.lowercased()
        if text.contains("⚡") { return .cached }
        if text.contains("⬇") || text.contains("⏳") || lowered.contains(" download]") || lowered.contains("uncached") {
            return .uncached
        }
        // "[RD+]", "[PM+]", "[AD+]" …
        if text.range(of: #"\[[A-Za-z]{2,3}\+\]"#, options: .regularExpression) != nil { return .cached }
        if lowered.contains("cached") { return .cached }
        return .unknown
    }
}
