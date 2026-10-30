import Domain
import Foundation
import MediaSources
import Metadata
import Persistence

// Search Online: every subtitle site at once (OpenSubtitles, Subdl,
// Podnapisi and the Jellyfin server's own subtitles), one list with the best
// match for the release first. Sites are turned on and off in Settings ›
// Subtitles; Subdl needs the user's own API key.
extension AppModel {
    /// Sites switched on in Settings.
    var enabledSubtitleSites: [SubtitleSite] {
        SubtitleSite.allCases.filter { !settings.subtitleSitesOff.contains($0.rawValue) }
    }

    func setSubtitleSite(_ site: SubtitleSite, enabled: Bool) {
        var off = Set(settings.subtitleSitesOff)
        if enabled { off.remove(site.rawValue) } else { off.insert(site.rawValue) }
        settings.subtitleSitesOff = SubtitleSite.allCases.map(\.rawValue).filter(off.contains)
    }

    /// True when a site is on and can be asked (OpenSubtitles and Subdl need keys).
    func canAsk(_ site: SubtitleSite) -> Bool {
        guard enabledSubtitleSites.contains(site) else { return false }
        switch site {
        case .openSubtitles: return hasOpenSubtitlesKey
        case .subdl: return hasSubdlKey
        case .podnapisi: return true
        case .jellyfin: return sourceConfigurations.contains { $0.kind == .jellyfin && $0.isEnabled }
        }
    }

    /// Search Online can run for this item.
    func canSearchSubtitlesOnline(for key: MediaKey?) -> Bool {
        guard key != nil else { return false }
        return SubtitleSite.allCases.contains(where: canAsk)
    }

    /// Asks every site that's on at once. Sites that fail are named in `failures`; the rest still show.
    func searchAllSubtitles(for key: MediaKey, release: String?, title: String?) async -> (results: [OnlineSubtitle], failures: [String]) {
        let languages = subtitleSearchLanguages
        let episode = key.episodeNumbers
        let detail = try? await metadata.detail(for: key.seriesKey ?? key)
        let imdb = (key.seriesKey ?? key).imdbID ?? detail?.imdbID
        let name = detail?.title.name ?? title
        let year = key.episodeNumbers == nil ? detail?.title.year : nil
        let open = subtitleSearch, subdl = self.subdl, http = self.http
        let jellyfin = await jellyfinSubtitleSources()

        return await withTaskGroup(of: (SubtitleSite, Result<[OnlineSubtitle], Error>).self) { group in
            for site in SubtitleSite.allCases where canAsk(site) {
                group.addTask {
                    do {
                        switch site {
                        case .openSubtitles:
                            guard let open else { return (site, .success([])) }
                            return (site, .success(try await open.search(key, languages: languages).map(OnlineSubtitle.init)))
                        case .subdl:
                            guard let subdl, let imdb else { return (site, .success([])) }
                            return (site, .success(try await subdl.search(imdbID: imdb, episode: episode, languages: languages)))
                        case .podnapisi:
                            guard let name else { return (site, .success([])) }
                            return (site, .success(try await PodnapisiService(http: http).search(title: name, year: year, episode: episode,
                                                                                                    languages: languages)))
                        case .jellyfin:
                            var found: [OnlineSubtitle] = []
                            for source in jellyfin { found += await Self.jellyfinSubtitles(source, key: key) }
                            return (site, .success(found))
                        }
                    } catch {
                        return (site, .failure(error))
                    }
                }
            }
            var lists: [[OnlineSubtitle]] = [], failures: [String] = []
            for await (site, result) in group {
                switch result {
                case .success(let list): lists.append(list)
                case .failure: failures.append(site.title)
                }
            }
            return (SubtitleSearchMerge.merge(lists, release: release, languages: languages), failures.sorted())
        }
    }

    private func jellyfinSubtitleSources() async -> [JellyfinSource] {
        var out: [JellyfinSource] = []
        for source in await registry.all() {
            if let jf = source as? JellyfinSource, await registry.isEnabled(jf.id) { out.append(jf) }
        }
        return out
    }

    /// The server's text subtitles for this title, as files to fetch.
    nonisolated static func jellyfinSubtitles(_ source: JellyfinSource, key: MediaKey) async -> [OnlineSubtitle] {
        guard let variants = try? await source.variants(for: key) else { return [] }
        var out: [OnlineSubtitle] = []
        for variant in variants.prefix(2) {
            guard let resource = try? await source.resolve(variant) else { continue }
            for sub in resource.externalSubtitles {
                out.append(OnlineSubtitle(site: .jellyfin, source: .url(sub.url, headers: resource.httpHeaders),
                                          language: sub.languageCode, release: sub.label, format: sub.format.isEmpty ? "srt" : sub.format))
            }
        }
        return out
    }

    /// Downloads a found subtitle (the right file out of a ZIP) to the caches folder; returns its file URL.
    func downloadSubtitle(_ result: OnlineSubtitle) async throws -> URL {
        let data: Data, format: String
        switch result.source {
        case .openSubtitles(let r):
            guard let subtitleSearch else { throw SubtitleSearchError.missingKey }
            data = try await subtitleSearch.download(r); format = "srt"
        case .url(let url, let headers):
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            let (body, response): (Data, HTTPURLResponse)
            do { (body, response) = try await http.send(req) } catch { throw SubtitleSearchError.offline }
            guard (200..<300).contains(response.statusCode), body.count < 20_000_000 else { throw SubtitleSearchError.server(response.statusCode) }
            guard let file = OnlineSubtitleFile.extract(body, episode: result.episode) else { throw SubtitleSearchError.decoding }
            data = file.data
            format = SubtitleFileName.extensions.contains(file.format) ? file.format : result.format
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Subtitles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = result.release.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined().prefix(80)
        let tag = String(abs(result.id.hashValue) % 1_000_000)
        let url = dir.appending(path: "\(safe)-\(result.site.rawValue)\(tag).\(result.language ?? "und").\(format)")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Subdl key

    /// Checks a Subdl key with a search, then stores it in the Keychain.
    public func saveSubdlKey(_ raw: String) async throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SubtitleSearchError.missingKey }
        let service = SubdlService(apiKey: key, http: http)
        _ = try await service.search(imdbID: "tt0133093", episode: nil, languages: ["en"])
        try secrets.write(key, for: SecretAccount.subdl)
        subdl = service
        hasSubdlKey = true
    }

    public func removeSubdlKey() {
        try? secrets.write(nil, for: SecretAccount.subdl)
        subdl = nil
        hasSubdlKey = false
    }
}
