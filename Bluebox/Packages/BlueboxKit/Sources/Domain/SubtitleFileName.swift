import Foundation

/// What a subtitle file's name says about it: "Movie.en.srt", "English.srt",
/// "2_English.srt", "Movie.2019.eng.forced.srt", "Spanish (Latin America).srt".
///
/// Used for files bundled in torrents and for files people add. Language
/// names are read in English (how release groups name them) and as ISO codes;
/// two-letter codes only count after the video's own name or in a short
/// name, so "The.It.Crowd.srt" isn't Italian.
public struct SubtitleFileName: Equatable, Sendable {
    /// ISO 639-1 where there is one ("en", "pt"), else the 639-2 code.
    public var languageCode: String?
    /// Sound cues for the deaf and hard of hearing ("SDH", "HI", "CC").
    public var isSDH = false
    /// Only the foreign-language lines.
    public var isForced = false

    public static let extensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    public static func isSubtitle(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Reads a file name (with or without its folders and extension).
    /// - Parameter videoStem: the video's name without extension; what follows it counts most.
    public init(_ path: String, videoStem: String? = nil) {
        let name = (path as NSString).lastPathComponent
        // Only a subtitle extension is dropped: "Movie.2019.en" keeps its "en".
        var stem = Self.isSubtitle(name) ? (name as NSString).deletingPathExtension : name
        var trusted = false
        if let videoStem, !videoStem.isEmpty, stem.lowercased().hasPrefix(videoStem.lowercased()) {
            stem = String(stem.dropFirst(videoStem.count))
            trusted = true
        }
        let tokens = Self.tokens(stem)
        let short = tokens.count <= 3
        for raw in tokens.reversed() {
            let t = raw.lowercased()
            if Self.sdhWords.contains(t) { isSDH = true; continue }
            if t == "forced" { isForced = true; continue }
            if Self.ignoredWords.contains(t) { continue }
            if let code = Self.language(of: t, allowTwoLetter: trusted || short) { languageCode = code; break }
        }
    }

    /// "Movie.en.srt" style tags: letters and digits, split at dots, spaces,
    /// underscores, dashes and brackets. "pt-BR" keeps its dash.
    static func tokens(_ stem: String) -> [String] {
        var out: [String] = []
        let regionTag = try? NSRegularExpression(pattern: #"^[A-Za-z]{2,3}-[A-Za-z]{2}$"#)
        for part in stem.split(whereSeparator: { " ._()[]{},+".contains($0) }) {
            let s = String(part)
            if regionTag?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { out.append(s); continue }
            out += s.split(whereSeparator: { $0 == "-" }).map(String.init)
        }
        return out.filter { !$0.isEmpty }
    }

    static let sdhWords: Set<String> = ["sdh", "hi", "cc", "hoh", "deaf"]
    static let ignoredWords: Set<String> = ["full", "default", "sub", "subs", "subtitle", "subtitles", "track", "dialog",
                                            "dialogue", "signs", "songs", "text", "utf8", "utf", "ansi", "srt", "ass", "vtt"]

    /// English names (and a few release-group spellings) to codes.
    static let names: [String: String] = {
        var map: [String: String] = [:]
        let english = Locale(identifier: "en")
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) where code.count == 2 {
            guard let name = english.localizedString(forLanguageCode: code)?.lowercased() else { continue }
            map[name] = code
            // "Norwegian Bokmål" → also "norwegian"
            if let first = name.split(separator: " ").first, map[String(first)] == nil { map[String(first)] = code }
        }
        let extra: [String: String] = [
            "brazilian": "pt", "portuguese": "pt", "castilian": "es", "latino": "es", "latin": "es", "spanish": "es",
            "farsi": "fa", "persian": "fa", "chinese": "zh", "mandarin": "zh", "cantonese": "zh", "simplified": "zh",
            "traditional": "zh", "flemish": "nl", "dutch": "nl", "greek": "el", "norwegian": "no", "bokmal": "nb",
            "filipino": "tl", "tagalog": "tl", "malay": "ms", "serbian": "sr", "croatian": "hr", "bosnian": "bs",
            "slovenian": "sl", "slovak": "sk", "czech": "cs", "romanian": "ro", "moldavian": "ro", "hebrew": "he",
            "indonesian": "id", "vietnamese": "vi", "ukrainian": "uk", "english": "en", "french": "fr", "german": "de",
            "italian": "it", "japanese": "ja", "korean": "ko", "russian": "ru", "arabic": "ar", "turkish": "tr",
            "polish": "pl", "swedish": "sv", "danish": "da", "finnish": "fi", "hungarian": "hu", "thai": "th",
            "hindi": "hi", "bulgarian": "bg", "estonian": "et", "latvian": "lv", "lithuanian": "lt", "icelandic": "is",
            "catalan": "ca", "basque": "eu", "galician": "gl", "macedonian": "mk", "albanian": "sq",
        ]
        map.merge(extra) { _, new in new }
        // "Indian" or "Swiss" aren't languages; neither are these English words.
        for word in ["interlingua", "volapük", "ido", "on", "or", "as", "to", "is", "it", "an", "no", "me"] { map[word] = nil }
        map["norwegian"] = "no"
        return map
    }()

    /// ISO 639-2 codes, bibliographic and terminology, for the common languages.
    static let threeLetter: [String: String] = [
        "eng": "en", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it", "por": "pt",
        "pob": "pt", "rus": "ru", "jpn": "ja", "chi": "zh", "zho": "zh", "chs": "zh", "cht": "zh", "kor": "ko",
        "ara": "ar", "dut": "nl", "nld": "nl", "swe": "sv", "nor": "no", "nob": "nb", "dan": "da", "fin": "fi",
        "pol": "pl", "tur": "tr", "gre": "el", "ell": "el", "heb": "he", "hin": "hi", "cze": "cs", "ces": "cs",
        "hun": "hu", "rum": "ro", "ron": "ro", "tha": "th", "vie": "vi", "ind": "id", "may": "ms", "msa": "ms",
        "ukr": "uk", "bul": "bg", "hrv": "hr", "srp": "sr", "slv": "sl", "slo": "sk", "slk": "sk", "est": "et",
        "lav": "lv", "lit": "lt", "per": "fa", "fas": "fa", "cat": "ca", "baq": "eu", "eus": "eu", "glg": "gl",
        "ice": "is", "isl": "is", "fil": "tl", "tgl": "tl", "ben": "bn", "tam": "ta", "tel": "te", "urd": "ur",
        "mac": "mk", "mkd": "mk", "alb": "sq", "sqi": "sq", "bos": "bs", "lat": "es",
    ]

    /// Two letters that are release tags, not languages.
    static let releaseTags: Set<String> = ["ts", "tv", "hd", "cc"]

    static func language(of token: String, allowTwoLetter: Bool) -> String? {
        let t = token.lowercased()
        if t.contains("-") {
            // "pt-BR", "zh-Hans": the language part.
            return language(of: String(t.split(separator: "-")[0]), allowTwoLetter: true)
        }
        if let code = names[t] { return code }
        if t.count == 3, let code = threeLetter[t] { return code }
        if t.count == 2, allowTwoLetter, !releaseTags.contains(t), t.allSatisfy(\.isLetter),
           Locale.LanguageCode.isoLanguageCodes.contains(Locale.LanguageCode(t)) {
            return t
        }
        return nil
    }

    /// "English", "English SDH", "Spanish Forced": a label for lists.
    public func label(locale: Locale = .current, fallback: String) -> String {
        guard let code = languageCode, let name = locale.localizedString(forLanguageCode: code) else { return fallback }
        var parts = [name.prefix(1).uppercased() + name.dropFirst()]
        if isSDH { parts.append("SDH") }
        if isForced { parts.append("Forced") }
        return parts.joined(separator: " ")
    }
}
