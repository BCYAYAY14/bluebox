import Foundation

/// What a filename says about its contents.
public struct ParsedMediaName: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case movie
        case episode(season: Int, episode: Int)
    }
    public let title: String
    public let year: Int?
    public let kind: Kind
    public let resolution: String?
    public let container: String?
}

/// Parses common release-style filenames:
///
///     The.Matrix.1999.1080p.BluRay.x264.mkv      -> movie "The Matrix" (1999)
///     Severance.S01E03.In.Perpetuity.mkv         -> episode S1E3 of "Severance"
///     Show Name - 2x05 - Title.mp4               -> episode S2E5 of "Show Name"
///     Tears of Steel (2012).mov                  -> movie "Tears of Steel" (2012)
public enum MediaNameParser {
    static let resolutionTokens = ["2160p": "4K", "4k": "4K", "1080p": "1080p", "720p": "720p", "480p": "480p"]
    /// Tokens after which everything is release noise.
    static let noise: Set<String> = [
        "bluray", "blu-ray", "brrip", "bdrip", "webrip", "web-dl", "webdl", "web", "hdtv", "dvdrip", "x264", "x265",
        "h264", "h265", "hevc", "av1", "aac", "ac3", "dts", "hdr", "hdr10", "dv", "remux", "proper", "repack",
        "extended", "unrated", "imax", "10bit", "1080p", "720p", "2160p", "480p", "4k", "uhd", "multi", "subs",
    ]

    public static func parse(filename: String) -> ParsedMediaName {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension.lowercased()
        let base = ext.isEmpty ? filename : url.deletingPathExtension().lastPathComponent
        let lower = base.lowercased()

        let resolution = resolutionTokens.first { lower.contains($0.key) }?.value

        // Normalize separators to spaces.
        let spaced = base.replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)

        // Episode patterns.
        let episodePatterns = [
            #"(?i)\bS(\d{1,2})\s?E(\d{1,3})\b"#,
            #"(?i)\b(\d{1,2})x(\d{1,3})\b"#,
        ]
        for pattern in episodePatterns {
            if let m = spaced.range(of: pattern, options: .regularExpression) {
                let token = String(spaced[m])
                let nums = token.split { !$0.isNumber }.compactMap { Int($0) }
                if nums.count == 2 {
                    let title = clean(String(spaced[..<m.lowerBound]))
                    return ParsedMediaName(title: title, year: nil, kind: .episode(season: nums[0], episode: nums[1]),
                                           resolution: resolution, container: ext.isEmpty ? nil : ext)
                }
            }
        }

        // Movie: title then an optional year (19xx/20xx), possibly in brackets.
        var year: Int?
        var titlePart = spaced
        // The *last* year-like token is the release year ("Blade Runner 2049 2017"),
        // and a leading number is part of the title ("1917", "2001: A Space Odyssey").
        let yearRanges = spaced.ranges(of: #/[\(\[]?\b(19\d{2}|20\d{2})\b[\)\]]?/#).filter { $0.lowerBound != spaced.startIndex }
        if let m = yearRanges.last {
            year = Int(spaced[m].filter(\.isNumber))
            titlePart = String(spaced[..<m.lowerBound])
        } else {
            let words = spaced.split(separator: " ")
            if let cut = words.firstIndex(where: { noise.contains($0.lowercased()) }) {
                titlePart = words[..<cut].joined(separator: " ")
            }
        }
        return ParsedMediaName(title: clean(titlePart), year: year, kind: .movie,
                               resolution: resolution, container: ext.isEmpty ? nil : ext)
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"[\(\[\-–—]+\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—"))
    }

    /// Folded form used to compare a parsed name with catalog titles.
    public static func normalized(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: "and")
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
}
