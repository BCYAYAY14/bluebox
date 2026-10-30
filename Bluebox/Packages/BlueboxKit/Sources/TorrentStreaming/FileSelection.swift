//
//  FileSelection.swift
//  Bluebox
//
//  Picks the file to play from a torrent's file list: the one the add-on
//  named, the requested episode of a season pack (by its name: S01E03,
//  1x03, "Episode 3"…), or else the largest video. Written for Bluebox.
//

import Domain
import Foundation

/// A season and episode, for picking a file out of a pack.
public struct EpisodeNumber: Sendable, Hashable {
    public var season: Int
    public var episode: Int

    public init(season: Int, episode: Int) {
        self.season = season
        self.episode = episode
    }
}

/// One file of a torrent, as the picker sees it.
struct TorrentFileEntry: Sendable, Equatable {
    var index: Int
    var path: String
    var size: Int64
    var isPadding = false

    var name: String { (path as NSString).lastPathComponent }
    var fileExtension: String { (path as NSString).pathExtension.lowercased() }
}

enum FileSelection {
    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "webm", "mov", "ts", "m2ts", "mpg", "mpeg", "wmv", "flv", "ogv"]

    static func isVideo(_ file: TorrentFileEntry) -> Bool {
        !file.isPadding && videoExtensions.contains(file.fileExtension)
    }

    /// Samples, trailers and extras are never the film.
    static func isExtra(_ file: TorrentFileEntry) -> Bool {
        let lower = file.path.lowercased()
        let name = file.name.lowercased()
        if name.hasPrefix("sample") || name.contains(".sample.") || name.contains("-sample.") { return true }
        for folder in ["/sample/", "/samples/", "/extras/", "/featurettes/", "/trailers/", "/behind the scenes/"] where lower.contains(folder) {
            return true
        }
        return lower.hasPrefix("sample/") || lower.hasPrefix("extras/")
    }

    /// The file to play.
    /// - `preferred`: an index from the add-on; used when it's a video.
    /// - `episode`: the episode wanted, for packs.
    static func choose(_ files: [TorrentFileEntry], preferred: Int?, episode: EpisodeNumber?) -> TorrentFileEntry? {
        let videos = files.filter(isVideo)
        if let preferred, let file = videos.first(where: { $0.index == preferred }) {
            // Trust the add-on unless the name plainly says another episode.
            if let episode, let named = episodeNumbers(in: file.path), !named.contains(episode),
               let better = bestMatch(videos, episode: episode) {
                return better
            }
            return file
        }
        if let episode, let match = bestMatch(videos, episode: episode) { return match }
        let features = videos.filter { !isExtra($0) }
        return (features.isEmpty ? videos : features).max { $0.size < $1.size }
    }

    /// Subtitle files in the torrent that belong to `video`: beside it with its
    /// name ("Movie.en.srt"), in a Subs folder ("Subs/English.srt",
    /// "Subs/<video name>/2_English.srt", "Subs/S01E03.English.srt"), or beside
    /// it in a folder that holds no other video. A file naming another episode
    /// never belongs.
    static func subtitles(for video: TorrentFileEntry, in files: [TorrentFileEntry]) -> [TorrentFileEntry] {
        let videos = files.filter { isVideo($0) && !isExtra($0) }
        let stem = (video.name as NSString).deletingPathExtension.lowercased()
        let folder = (video.path as NSString).deletingLastPathComponent.lowercased()
        let episode = episodeNumbers(in: video.path)
        func folderOf(_ path: String) -> String { (path as NSString).deletingLastPathComponent.lowercased() }
        let videosInFolder = videos.filter { folderOf($0.path) == folder }.count
        return files.filter { f in
            guard !f.isPadding, SubtitleFileName.isSubtitle(f.path), f.size < 20_000_000 else { return false }
            let name = (f.name as NSString).deletingPathExtension.lowercased()
            let path = f.path.lowercased()
            if name == stem || name.hasPrefix(stem + ".") || name.hasPrefix(stem + "_") || name.hasPrefix(stem + " ") { return true }
            let components = path.split(separator: "/").map(String.init)
            let subsIndex = components.dropLast().lastIndex { ["subs", "sub", "subtitles", "subtitle"].contains($0) }
            let inner = subsIndex.map { Array(components[($0 + 1)..<(components.count - 1)]) } ?? []
            let claimed = claimedEpisodes(name: f.name, folders: inner)
            // Another episode's file.
            if let episode, let claimed, !claimed.contains(where: episode.contains) { return false }
            if let subsIndex {
                let subsParent = components[..<subsIndex].joined(separator: "/")
                guard folder.hasPrefix(subsParent) || subsParent.isEmpty || folder.isEmpty else { return false }
                // "Subs/<video name>/2_English.srt" in a pack: the folder names the video.
                if !inner.isEmpty { return inner.contains(stem) || (episode != nil && claimed != nil) || videos.count == 1 }
                if episode != nil, claimed != nil { return true }
                return videos.count == 1 || videosInFolder == 1 && subsParent == folder
            }
            // Beside the video in a folder that holds only it.
            if folderOf(f.path) == folder, videosInFolder == 1 { return episode == nil || claimed != nil || videos.count == 1 }
            return false
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The episodes a bundled subtitle names: a folder under Subs named for
    /// the video ("Show.S01E02.1080p"), else its own name, read strictly
    /// (S01E02, 1x02): "2_English.srt" is a track number, not episode 2.
    static func claimedEpisodes(name: String, folders: [String]) -> [EpisodeNumber]? {
        for folder in folders.reversed() where hasStrictEpisodeTag(folder) {
            if let found = episodeNumbers(in: folder + ".mkv") { return found }
        }
        return hasStrictEpisodeTag(name) ? episodeNumbers(in: name) : nil
    }

    static func hasStrictEpisodeTag(_ s: String) -> Bool {
        s.range(of: #"(?i)(?<![a-z0-9])(s\d{1,2}[ ._-]?e\d{1,3}|\d{1,2}x\d{2,3})(?![0-9])"#, options: .regularExpression) != nil
    }

    static func bestMatch(_ videos: [TorrentFileEntry], episode: EpisodeNumber) -> TorrentFileEntry? {
        let matches = videos.filter { !isExtra($0) && (episodeNumbers(in: $0.path)?.contains(episode) ?? false) }
        return matches.max { $0.size < $1.size }
    }

    /// Every season/episode a file name claims, from its name and its folders
    /// ("Season 2/03 - Title.mkv"). Multi-episode files ("S01E01E02",
    /// "S01E01-E03") list each episode. Nil when nothing is recognisable.
    static func episodeNumbers(in path: String) -> [EpisodeNumber]? {
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last else { return nil }
        let stem = (name as NSString).deletingPathExtension
        let folderSeason = components.dropLast().reversed().lazy.compactMap(seasonNumber(inFolder:)).first

        // S01E02, S01E02E03, S01E02-E04, s1.e2
        if let found = match(#"(?i)(?<![a-z0-9])s(\d{1,2})[ ._-]?e(\d{1,3})((?:[ ._-]?-?[ ._-]?e\d{1,3})*)"#, in: stem) {
            let season = Int(found[1]) ?? 0
            var episodes = [Int(found[2]) ?? 0]
            let more = all(#"(?i)e(\d{1,3})"#, in: found[3]).compactMap { Int($0[1]) }
            if found[3].contains("-"), let last = more.last, let first = episodes.first, last > first, last - first < 30 {
                episodes = Array(first...last)
            } else {
                episodes += more
            }
            return episodes.map { EpisodeNumber(season: season, episode: $0) }
        }
        // 1x02
        if let found = match(#"(?i)(?<![a-z0-9])(\d{1,2})x(\d{2,3})(?![0-9])"#, in: stem),
           let s = Int(found[1]), let e = Int(found[2]) {
            return [EpisodeNumber(season: s, episode: e)]
        }
        // "Episode 3", "Ep 03", "E03" with the season from a folder (or 1).
        if let found = match(#"(?i)(?<![a-z0-9])(?:episode|ep)[ ._-]?(\d{1,3})(?![0-9])"#, in: stem),
           let e = Int(found[1]) {
            return [EpisodeNumber(season: folderSeason ?? 1, episode: e)]
        }
        if let folderSeason, let found = match(#"(?i)(?<![a-z0-9])e(\d{1,3})(?![0-9])"#, in: stem), let e = Int(found[1]) {
            return [EpisodeNumber(season: folderSeason, episode: e)]
        }
        // "Season 2/03 - Title.mkv": a leading number inside a season folder.
        if let folderSeason, let found = match(#"^(\d{1,3})(?![0-9])"#, in: stem), let e = Int(found[1]) {
            return [EpisodeNumber(season: folderSeason, episode: e)]
        }
        return nil
    }

    /// "Season 2", "S02", "Series 2" folders.
    static func seasonNumber(inFolder folder: String) -> Int? {
        if let found = match(#"(?i)^(?:season|series|staffel|saison)[ ._-]?(\d{1,2})\b"#, in: folder) { return Int(found[1]) }
        if let found = match(#"(?i)(?<![a-z0-9])s(\d{1,2})(?![0-9e])"#, in: folder) { return Int(found[1]) }
        return nil
    }

    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func all(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
            (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
        }
    }
}
