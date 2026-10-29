import Foundation

/// A track's name, cleaned up for people: VLC's "English (SDH / US) - [English]"
/// becomes title "English (US)" with detail "SDH". The language comes first,
/// a region stays beside it, and everything that describes the track (SDH,
/// Forced, Commentary, 5.1, Atmos…) goes in `details`.
public struct TrackLabel: Hashable, Sendable {
    public var title: String
    public var details: [String]
    /// The language this track is in, as an ISO 639-1 code where known ("en").
    public var languageCode: String?

    public init(title: String, details: [String] = [], languageCode: String? = nil) {
        self.title = title; self.details = details; self.languageCode = languageCode
    }

    /// "SDH · 5.1", or nil when there's nothing to add.
    public var detail: String? { details.isEmpty ? nil : details.joined(separator: " · ") }

    /// Title and detail together, for flashes and VoiceOver: "English (US), SDH".
    public var spoken: String { ([title] + details).joined(separator: ", ") }

    // MARK: Parsing

    /// Parses a track's raw name. `languageCode` is the engine's code for the
    /// track (VLC's "eng", AVFoundation's "en-US"), used when the name has none.
    public static func parse(_ raw: String, languageCode: String? = nil, index: Int? = nil,
                             locale: Locale = .current) -> TrackLabel {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var bracketLanguage: String?

        // VLC appends " - [Language]" (or just "[Language]").
        if let r = name.range(of: #"\s*-?\s*\[([^\]]*)\]\s*$"#, options: .regularExpression) {
            let inner = name[r].drop { $0 != "[" }.dropFirst().prefix { $0 != "]" }
            // "[Spanish; Castilian]": the first name is the language.
            let trimmed = (inner.split(separator: ";").first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { bracketLanguage = trimmed }
            name.removeSubrange(r)
        }
        // Release-group and source tags in front: "[NF] Spanish", "{AMZN} English".
        while let r = name.range(of: #"^\s*[\[{][^\]}]*[\]}]\s*"#, options: .regularExpression), r.upperBound < name.endIndex {
            name.removeSubrange(r)
        }

        // Parenthesised parts: "(SDH / US)", "(Forced)", "(AD)".
        var parts: [String] = []
        while let r = name.range(of: #"\s*\(([^()]*)\)"#, options: .regularExpression) {
            let inner = name[r].drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
            parts += inner.split(whereSeparator: { "/,;|".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
            name.removeSubrange(r)
        }
        // Dashes and similar separate parts too: "English - SDH", "English, Forced".
        let pieces = name.components(separatedBy: CharacterSet(charactersIn: "|;,")).flatMap { $0.components(separatedBy: " - ") }
        var base = pieces.first?.trimmingCharacters(in: .whitespaces) ?? ""
        parts += pieces.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }

        var tags: [String] = []
        var regions: [String] = []
        var extra: [String] = []
        var language: (code: String, name: String)?

        // The base: a language name, a language with tags ("English SDH", "English 5.1"),
        // or a description ("Director's Commentary", "Track 2").
        let (baseLanguage, rest) = leadingLanguage(in: base, locale: locale)
        if let baseLanguage {
            language = baseLanguage
            base = rest
        }
        let (baseTags, leftover) = extractTags(from: base)
        tags += baseTags
        let leftoverText = leftover.trimmingCharacters(in: .whitespaces)

        for part in parts where !part.isEmpty {
            if language == nil, let l = languageNamed(part, locale: locale) { language = l; continue }
            if let l = languageNamed(part, locale: locale), l.code == language?.code { continue }  // "English (English)"
            let (partTags, partRest) = extractTags(from: part)
            tags += partTags
            let r = partRest.trimmingCharacters(in: .whitespaces)
            guard !r.isEmpty, !isGenericTrackName(r) else { continue }
            if isRegion(r) { regions.append(r) } else { extra.append(r) }
        }

        if language == nil, let bracketLanguage { language = languageNamed(bracketLanguage, locale: locale) }
        if language == nil, let code = languageCode, let l = Self.language(forCode: code, locale: locale) { language = l }

        // A leftover description ("Director's Commentary") is kept whole, in place of
        // the tags it contains.
        if language != nil, !leftoverText.isEmpty, isRegion(leftoverText) {
            regions.insert(leftoverText, at: 0)  // "Chinese Simplified", "Spanish Castilian"
        } else if !leftoverText.isEmpty, !isGenericTrackName(leftoverText) {
            if language == nil, extra.isEmpty, tags.isEmpty {
                // Nothing else to go on: the name is the title.
                return TrackLabel(title: base.trimmingCharacters(in: .whitespaces), details: [], languageCode: nil)
            }
            let phrase = base.trimmingCharacters(in: .whitespaces)
            tags.removeAll { phrase.localizedCaseInsensitiveContains($0) }
            extra.insert(phrase, at: 0)
        }

        var title: String
        if let language {
            title = language.name
            if !regions.isEmpty { title += " (\(regions.joined(separator: ", ")))" }
        } else if let first = regions.first ?? extra.first {
            title = first
            if regions.first == first { regions.removeFirst() } else { extra.removeFirst() }
        } else if !tags.isEmpty, base.isEmpty || leftoverText.isEmpty {
            // "SDH", "Forced", "Stereo": a tag alone. Name the track by number.
            title = index.map { "Track \($0 + 1)" } ?? "Unknown"
        } else {
            title = index.map { "Track \($0 + 1)" } ?? (raw.isEmpty ? "Unknown" : raw)
        }
        if language == nil, !regions.isEmpty { extra += regions }

        var details: [String] = []
        for d in extra + orderedTags(tags) where !details.contains(where: { $0.caseInsensitiveCompare(d) == .orderedSame }) {
            details.append(d)
        }
        return TrackLabel(title: title, details: details, languageCode: language?.code)
    }

    /// Labels for a whole list, with identical ones told apart by number
    /// ("English", "English · Track 2").
    public static func labels(for tracks: [MediaTrack], locale: Locale = .current) -> [String: TrackLabel] {
        var out: [String: TrackLabel] = [:]
        var parsed = tracks.enumerated().map { i, t in (t.id, parse(t.label, languageCode: t.languageCode, index: i, locale: locale)) }
        var seen: [TrackLabel: Int] = [:]
        for (_, l) in parsed { seen[l, default: 0] += 1 }
        for i in parsed.indices where seen[parsed[i].1, default: 0] > 1 {
            parsed[i].1.details.append("Track \(i + 1)")
        }
        for (id, l) in parsed { out[id] = l }
        return out
    }

    // MARK: Tags

    /// Known descriptive words, in the order they're shown, with their spellings.
    static let tagTable: [(display: String, patterns: [String])] = [
        ("Forced", ["forced", "forced only", "foreign parts", "foreign"]),
        ("SDH", ["sdh", "hearing impaired", "hi", "cc", "closed captions", "closed caption"]),
        ("Signs & Songs", ["signs & songs", "signs and songs", "signs/songs", "signs", "songs"]),
        ("Commentary", ["commentary", "comment"]),
        ("Audio Description", ["audio description", "descriptive audio", "described video", "ad", "dvs"]),
        ("Dubbed", ["dub", "dubbed"]),
        ("Original", ["original", "orig"]),
        ("Atmos", ["atmos", "dolby atmos"]),
        ("7.1", ["7.1", "7.1ch", "7.1 ch"]),
        ("5.1", ["5.1", "5.1ch", "5.1 ch", "6ch"]),
        ("Stereo", ["stereo", "2.0", "2ch", "2.0ch"]),
        ("Mono", ["mono", "1.0"]),
    ]

    /// Codec and container noise, dropped: the language and the layout say enough.
    static let noise: Set<String> = [
        "aac", "ac3", "ac-3", "eac3", "e-ac3", "e-ac-3", "dd", "dd+", "ddp", "dolby digital", "dolby digital plus",
        "dts", "dts-hd", "dts-hd ma", "dts-hd master audio", "dts-x", "dts:x", "ma", "truehd", "flac", "opus", "mp3",
        "pcm", "lpcm", "vorbis", "srt", "subrip", "ass", "ssa", "pgs", "vobsub", "webvtt", "full", "default",
        "text", "utf-8", "track", "audio", "subtitle", "subtitles", "sub", "subs",
    ]

    /// Pulls known tags out of `text` (longest spellings first), returning the
    /// tags and whatever words are left.
    static func extractTags(from text: String) -> (tags: [String], rest: String) {
        var words = text.split(whereSeparator: { $0 == " " || $0 == "_" }).map(String.init)
        var tags: [String] = []
        var i = 0
        outer: while i < words.count {
            // Try three-, two- then one-word phrases.
            for len in stride(from: min(4, words.count - i), through: 1, by: -1) {
                let phrase = words[i..<(i + len)].joined(separator: " ").lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]{}:-–"))
                if let tag = tagTable.first(where: { $0.patterns.contains(phrase) }) {
                    if !tags.contains(tag.display) { tags.append(tag.display) }
                    words.removeSubrange(i..<(i + len))
                    continue outer
                }
                if noise.contains(phrase) {
                    words.removeSubrange(i..<(i + len))
                    continue outer
                }
            }
            i += 1
        }
        let rest = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -–:"))
        return (tags, rest)
    }

    static func orderedTags(_ tags: [String]) -> [String] {
        tagTable.map(\.display).filter(tags.contains)
    }

    static func isGenericTrackName(_ s: String) -> Bool {
        s.range(of: #"^(track|audio|subtitle|subtitles|stream)\s*#?\s*\d*$"#, options: [.regularExpression, .caseInsensitive]) != nil
            || s.range(of: #"^\d+$"#, options: .regularExpression) != nil
            || ["und", "undetermined", "unknown", "disable", "disabled"].contains(s.lowercased())
    }

    /// "US", "UK", "BR", "Latin America", "Brazil", "Castilian"…
    static func isRegion(_ s: String) -> Bool {
        if !s.isEmpty, s.count <= 3, s == s.uppercased(), s.allSatisfy(\.isLetter) { return true }
        let named: Set<String> = ["latin america", "latin american", "latam", "brazil", "brazilian", "portugal", "european",
                                  "castilian", "castellano", "canada", "canadian", "france", "mexico", "mexican", "spain",
                                  "simplified", "traditional", "hong kong", "taiwan", "mainland", "cantonese", "mandarin",
                                  "american", "british", "australia", "flemish", "swiss", "austria", "belgium",
                                  "united states", "united kingdom", "international"]
        return named.contains(s.lowercased())
    }

    // MARK: Languages

    /// The display name for a language code ("eng", "en-US", "pt-BR" → "Portuguese (Brazil)"
    /// is left to the region logic: this returns the language only).
    static func language(forCode code: String, locale: Locale) -> (code: String, name: String)? {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? code.lowercased()
        guard base.count >= 2, base.count <= 3, base.allSatisfy(\.isLetter), !["und", "mis", "mul", "zxx"].contains(base) else { return nil }
        // Three-letter codes only when they have a two-letter twin ("eng" → "en"); the
        // rest are too easily something else ("sdh" is a code too).
        guard let alpha2 = base.count == 2 ? base : (Locale.LanguageCode(base).identifier(.alpha2) ?? bibliographic[base]) else { return nil }
        guard let name = locale.localizedString(forLanguageCode: alpha2), name.lowercased() != alpha2 else { return nil }
        return (alpha2, name)
    }

    /// ISO 639-2/B codes (Matroska uses them) that Foundation only knows in their /T form.
    static let bibliographic: [String: String] = [
        "fre": "fr", "ger": "de", "dut": "nl", "chi": "zh", "cze": "cs", "gre": "el", "per": "fa", "rum": "ro",
        "slo": "sk", "wel": "cy", "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "geo": "ka", "ice": "is",
        "mac": "mk", "mao": "mi", "may": "ms", "tib": "bo",
    ]

    /// A language from its name in the user's language or in English ("English",
    /// "Français", "Italian"), or from a code ("eng", "it").
    static func languageNamed(_ text: String, locale: Locale) -> (code: String, name: String)? {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty, !noise.contains(key), !tagTable.contains(where: { $0.patterns.contains(key) }) else { return nil }
        if let code = LanguageNames.shared.code(forName: key, locale: locale), let l = language(forCode: code, locale: locale) { return l }
        if key.count <= 3, let l = language(forCode: key, locale: locale) { return l }
        return nil
    }

    /// The language a name starts with, and the rest: "English SDH" → English, "SDH".
    static func leadingLanguage(in text: String, locale: Locale) -> ((code: String, name: String)?, String) {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return (nil, text) }
        for len in stride(from: min(3, words.count), through: 1, by: -1) {
            let phrase = words[0..<len].joined(separator: " ")
            // Two- and three-letter words count as codes only when they're the whole name.
            if len == 1, phrase.count <= 3, words.count > 1 { continue }
            if let l = languageNamed(phrase, locale: locale) {
                return (l, words[len...].joined(separator: " "))
            }
        }
        return (nil, text)
    }
}

/// Every language's name, in English and the user's language, to its code.
private final class LanguageNames: @unchecked Sendable {
    static let shared = LanguageNames()
    private let lock = NSLock()
    private var tables: [String: [String: String]] = [:]

    func code(forName name: String, locale: Locale) -> String? {
        table(for: locale)[name]
    }

    private func table(for locale: Locale) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let t = tables[locale.identifier] { return t }
        var t: [String: String] = [:]
        let english = Locale(identifier: "en")
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) where code.count == 2 {
            for l in [english, locale] {
                if let n = l.localizedString(forLanguageCode: code)?.lowercased(), t[n] == nil { t[n] = code }
            }
            // Its own name too ("français", "deutsch").
            if let n = Locale(identifier: code).localizedString(forLanguageCode: code)?.lowercased(), t[n] == nil { t[n] = code }
        }
        // Common spellings the tables don't have.
        for (n, c) in ["castilian": "es", "castellano": "es", "brazilian": "pt", "farsi": "fa", "flemish": "nl",
                       "mandarin": "zh", "cantonese": "zh", "chinese simplified": "zh", "chinese traditional": "zh",
                       "brazilian portuguese": "pt", "latin american spanish": "es"] where t[n] == nil {
            t[n] = c
        }
        tables[locale.identifier] = t
        return t
    }
}
