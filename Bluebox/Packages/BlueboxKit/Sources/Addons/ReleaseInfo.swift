//
//  ReleaseInfo.swift
//  Bluebox
//
//  Written for Bluebox from public documentation (the Stremio add-on SDK's
//  stream response docs) and the scene naming conventions found in release
//  names themselves. Reads a release's facts out of its file name and the
//  text an add-on shows with it: resolution, source, codec, HDR, audio,
//  languages, release group, size and seeders.
//

import Foundation

/// What a release is, as far as its name and the add-on's text say.
public struct ReleaseInfo: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable, CaseIterable, Comparable {
        case cam, telesync, telecine, screener, dvdRip, hdtv, webRip, webDL, bluRay, remux

        public var title: String {
            switch self {
            case .cam: "CAM"
            case .telesync: "Telesync"
            case .telecine: "Telecine"
            case .screener: "Screener"
            case .dvdRip: "DVDRip"
            case .hdtv: "HDTV"
            case .webRip: "WEBRip"
            case .webDL: "WEB-DL"
            case .bluRay: "BluRay"
            case .remux: "Remux"
            }
        }

        /// Recorded in a cinema or leaked before release: poor picture and sound.
        public var isPreRelease: Bool { self <= .screener }

        public static func < (a: Source, b: Source) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public enum VideoCodec: String, Codable, Sendable {
        case h264, hevc, av1, vp9, xvid, mpeg2, vc1

        public var title: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC"
            case .av1: "AV1"
            case .vp9: "VP9"
            case .xvid: "XviD"
            case .mpeg2: "MPEG-2"
            case .vc1: "VC-1"
            }
        }
    }

    public enum HDRFormat: String, Codable, Sendable, CaseIterable {
        case dolbyVision, hdr10Plus, hdr10, hlg

        public var title: String {
            switch self {
            case .dolbyVision: "Dolby Vision"
            case .hdr10Plus: "HDR10+"
            case .hdr10: "HDR10"
            case .hlg: "HLG"
            }
        }
    }

    public enum AudioFormat: String, Codable, Sendable, CaseIterable {
        case atmos, trueHD, dtsX, dtsHDMA, dts, ddPlus, dd, aac, flac, opus, mp3, pcm

        public var title: String {
            switch self {
            case .atmos: "Atmos"
            case .trueHD: "TrueHD"
            case .dtsX: "DTS:X"
            case .dtsHDMA: "DTS-HD MA"
            case .dts: "DTS"
            case .ddPlus: "DD+"
            case .dd: "DD"
            case .aac: "AAC"
            case .flac: "FLAC"
            case .opus: "Opus"
            case .mp3: "MP3"
            case .pcm: "PCM"
            }
        }
    }

    /// "2160p", "1440p", "1080p", "720p" or "480p".
    public var resolution: String?
    public var source: Source?
    public var videoCodec: VideoCodec?
    public var tenBit = false
    /// In the order of `HDRFormat.allCases`.
    public var hdr: [HDRFormat] = []
    public var audio: [AudioFormat] = []
    /// "7.1", "5.1", "2.0".
    public var channels: String?
    /// ISO 639-1 codes of the audio, plus "multi" for multi-language releases.
    public var languages: [String] = []
    /// The release group ("FLUX", "NTb"), when the name carries one.
    public var group: String?
    public var is3D = false
    public var sizeBytes: Int64?
    /// The size as the add-on wrote it ("4.78 GB").
    public var sizeText: String?
    public var seeders: Int?
    /// "mkv", "mp4"…
    public var container: String?

    public init() {}

    public var isHDR: Bool { !hdr.isEmpty }
    public var isDolbyVision: Bool { hdr.contains(.dolbyVision) }
    /// Dolby Vision with no HDR10 base layer: shows wrong colours where DV isn't decoded.
    public var isDolbyVisionOnly: Bool { isDolbyVision && !hdr.contains(.hdr10) && !hdr.contains(.hdr10Plus) }

    /// Short tags for the release picker's menu: source, codec, HDR, audio.
    public var tags: [String] {
        var out: [String] = []
        if let source { out.append(source.title) }
        if let videoCodec { out.append(videoCodec.title) }
        if tenBit { out.append("10-bit") }
        out += hdr.map(\.title)
        out += audio.map(\.title)
        if let channels { out.append(channels) }
        if is3D { out.append("3D") }
        if let container { out.append(container.uppercased()) }
        return out
    }

    /// Fills what this lacks from `other` (this wins where both know).
    mutating func fill(from other: ReleaseInfo) {
        resolution = resolution ?? other.resolution
        source = source ?? other.source
        videoCodec = videoCodec ?? other.videoCodec
        tenBit = tenBit || other.tenBit
        hdr = HDRFormat.allCases.filter { hdr.contains($0) || other.hdr.contains($0) }
        audio = AudioFormat.allCases.filter { audio.contains($0) || other.audio.contains($0) }
        channels = channels ?? other.channels
        if languages.isEmpty { languages = other.languages }
        group = group ?? other.group
        is3D = is3D || other.is3D
        sizeBytes = sizeBytes ?? other.sizeBytes
        sizeText = sizeText ?? other.sizeText
        seeders = seeders ?? other.seeders
        container = container ?? other.container
    }
}

/// Reads `ReleaseInfo` out of names and add-on text.
public enum ReleaseNameParser {
    /// Facts from a release or file name, such as
    /// "The.Show.S01E02.1080p.WEB-DL.DDP5.1.H.264-GROUP.mkv".
    public static func parse(_ name: String) -> ReleaseInfo {
        var info = ReleaseInfo()
        let (stem, ext) = splitExtension(name)
        info.container = ext
        let text = normalized(stem)

        info.resolution = resolution(in: text)
        info.source = source(in: text)
        info.videoCodec = videoCodec(in: text)
        info.tenBit = has(text, #"10-?bit|hi10p?"#)
        info.hdr = hdr(in: text)
        info.audio = audio(in: text)
        info.channels = channels(in: text)
        info.languages = languages(in: text)
        info.is3D = has(text, #"3d|h-?sbs|half-?sbs|h-?ou|bd3d"#)
        info.group = group(in: stem)
        if info.resolution == nil, info.source == .dvdRip { info.resolution = "480p" }
        return info
    }

    /// Facts from everything an add-on said about a stream: its short label
    /// ("Torrentio\n4k DV | HDR"), its description lines (emoji stats, flags,
    /// a file name) and the file name hint. The file name wins where both
    /// know something; stats come from the description.
    public static func parse(label: String, description: String, filename: String?) -> ReleaseInfo {
        let lines = description.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        let fileLine = filename ?? lines.first { $0.hasPrefix("📄") }.map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
            ?? lines.first(where: looksLikeFileName)

        var info = fileLine.map(parse) ?? ReleaseInfo()
        // The description's first line is often the torrent's own name.
        if let first = lines.first, first != fileLine {
            var fromTitle = parse(first)
            fromTitle.container = nil
            info.fill(from: fromTitle)
        }
        // The add-on's label and the rest of the text: resolution, HDR, codec words.
        var fromText = parse(label + " " + lines.dropFirst().filter { !$0.hasPrefix("📄") }.joined(separator: " "))
        fromText.group = nil
        fromText.container = nil
        fromText.languages = []
        info.fill(from: fromText)

        let stats = statistics(in: description)
        info.sizeBytes = stats.sizeBytes
        info.sizeText = stats.sizeText
        info.seeders = stats.seeders
        let flagged = audioLanguages(fromDescription: lines)
        if !flagged.isEmpty {
            info.languages = flagged + info.languages.filter { $0 == "multi" && !flagged.contains("multi") }
        }
        return info
    }

    // MARK: Pieces

    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg", "iso"]

    static func splitExtension(_ name: String) -> (stem: String, ext: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = trimmed.lastIndex(of: ".") else { return (trimmed, nil) }
        let ext = trimmed[trimmed.index(after: dot)...].lowercased()
        guard videoExtensions.contains(ext) else { return (trimmed, nil) }
        return (String(trimmed[..<dot]), ext)
    }

    static func looksLikeFileName(_ line: String) -> Bool {
        guard !line.contains(" ") || line.count > 12 else { return false }
        return splitExtension(line).ext != nil
    }

    /// Lowercased, underscores as spaces. Dots stay: "5.1" and "h.264" need them.
    static func normalized(_ s: String) -> String {
        " " + s.lowercased().replacingOccurrences(of: "_", with: " ") + " "
    }

    /// Whether `pattern` matches as a whole token (no letter or digit either side).
    static func has(_ text: String, _ pattern: String) -> Bool {
        text.range(of: #"(?<![a-z0-9])(?:"# + pattern + #")(?![a-z0-9])"#, options: .regularExpression) != nil
    }

    /// The first capture group of `pattern` (token-bounded), if it matches.
    static func capture(_ text: String, _ pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func resolution(in text: String) -> String? {
        if has(text, #"2160p|4k|uhd|4320p|8k"#) { return "2160p" }
        if has(text, #"1440p|2k|qhd"#) { return "1440p" }
        if has(text, #"1080[pi]|fhd"#) { return "1080p" }
        if has(text, #"720p"#) { return "720p" }
        if has(text, #"576p|540p|480p|360p|240p"#) { return "480p" }
        // Odd heights from cropped encodes ("1744p", "800p").
        if let groups = capture(text, #"(?<![a-z0-9])(\d{3,4})p(?![a-z0-9])"#), let height = Int(groups[1]) {
            switch height {
            case 1600...: return "2160p"
            case 1000..<1600: return "1080p"
            case 680..<1000: return "720p"
            default: return "480p"
            }
        }
        // "1920x1080"
        if let groups = capture(text, #"(\d{3,4})x(\d{3,4})"#), let width = Int(groups[1]) {
            switch width {
            case 3000...: return "2160p"
            case 1800..<3000: return "1080p"
            case 1200..<1800: return "720p"
            default: return "480p"
            }
        }
        return nil
    }

    static func source(in text: String) -> ReleaseInfo.Source? {
        if has(text, #"remux|bdremux|bd-remux"#) { return .remux }
        if has(text, #"hd-?cam|cam-?rip|cam|camrip"#) { return .cam }
        if has(text, #"hd-?ts|telesync|pdvd|ts-?rip"#) { return .telesync }
        if has(text, #"hd-?tc|telecine"#) { return .telecine }
        if has(text, #"dvd-?scr|bd-?scr|scr|screener|web-?scr"#) { return .screener }
        if has(text, #"blu-?ray|bd-?rip|br-?rip|bd25|bd50|bdmv|uhd-?bluray"#) { return .bluRay }
        if has(text, #"web-?rip"#) { return .webRip }
        if has(text, #"web-?dl|webdl|web|amzn|nf|dsnp|hmax|atvp|itunes"#) { return .webDL }
        if has(text, #"hdtv|pdtv|dsr|tvrip|sdtv"#) { return .hdtv }
        if has(text, #"dvd-?rip|dvd|dvd5|dvd9|dvdr"#) { return .dvdRip }
        return nil
    }

    static func videoCodec(in text: String) -> ReleaseInfo.VideoCodec? {
        if has(text, #"av1"#) { return .av1 }
        if has(text, #"x265|h\.?265|hevc"#) { return .hevc }
        if has(text, #"x264|h\.?264|avc"#) { return .h264 }
        if has(text, #"vp9"#) { return .vp9 }
        if has(text, #"xvid|divx"#) { return .xvid }
        if has(text, #"mpeg-?2"#) { return .mpeg2 }
        if has(text, #"vc-?1"#) { return .vc1 }
        return nil
    }

    static func hdr(in text: String) -> [ReleaseInfo.HDRFormat] {
        var found: Set<ReleaseInfo.HDRFormat> = []
        if has(text, #"dv|dovi|dolby[ .-]?vision|dvhe|dv-?hdr"#) { found.insert(.dolbyVision) }
        if text.range(of: #"(?<![a-z0-9])(hdr10\+|hdr10plus|hdr10p)"#, options: .regularExpression) != nil { found.insert(.hdr10Plus) }
        // "HDR10" or a bare "HDR" (not part of "HDR10+").
        if text.range(of: #"(?<![a-z0-9])hdr(10)?(?![a-z0-9+])"#, options: .regularExpression) != nil { found.insert(.hdr10) }
        if has(text, #"hlg"#) { found.insert(.hlg) }
        if has(text, #"sdr"#), found.isEmpty { return [] }
        return ReleaseInfo.HDRFormat.allCases.filter(found.contains)
    }

    static func audio(in text: String) -> [ReleaseInfo.AudioFormat] {
        var found: Set<ReleaseInfo.AudioFormat> = []
        if has(text, #"atmos"#) { found.insert(.atmos) }
        if has(text, #"true-?hd(\d\.\d)?"#) { found.insert(.trueHD) }
        if has(text, #"dts-?x"#) { found.insert(.dtsX) }
        if has(text, #"dts-?hd([ .-]?ma)?(\d\.\d)?|dts-?ma"#) { found.insert(.dtsHDMA) }
        else if has(text, #"dts(\d\.\d)?"#), !found.contains(.dtsX) { found.insert(.dts) }
        if has(text, #"ddp(\d\.?\d)?|dd\+(\d\.\d)?|e-?ac-?3|eac3"#) { found.insert(.ddPlus) }
        else if has(text, #"dd(\d\.?\d)?|ac-?3|dolby digital"#) { found.insert(.dd) }
        if has(text, #"aac(\d\.\d)?(lc)?"#) { found.insert(.aac) }
        if has(text, #"flac(\d\.\d)?"#) { found.insert(.flac) }
        if has(text, #"opus"#) { found.insert(.opus) }
        if has(text, #"mp3"#) { found.insert(.mp3) }
        if has(text, #"l?pcm"#) { found.insert(.pcm) }
        return ReleaseInfo.AudioFormat.allCases.filter(found.contains)
    }

    static func channels(in text: String) -> String? {
        if let groups = capture(text, #"(?<![0-9])([1-9])[ .]([01])(?![0-9])(?!\s?(gb|mb|kb|tb|gib|mib))"#) {
            let value = "\(groups[1]).\(groups[2])"
            if ["7.1", "5.1", "2.0", "6.1", "1.0", "2.1"].contains(value) { return value }
        }
        if has(text, #"8ch"#) { return "7.1" }
        if has(text, #"6ch"#) { return "5.1" }
        if has(text, #"2ch|stereo"#) { return "2.0" }
        return nil
    }

    /// Language words in a release name. Three-letter codes count only in
    /// capitals in the original name… which `normalized` lowercases, so the
    /// short words here are the ones release names actually use.
    static let languageWords: [(code: String, pattern: String)] = [
        ("multi", #"multi|multi-?audio|dual|dual-?audio|multi-?lang"#),
        ("en", #"eng|english"#),
        ("it", #"ita|italian|italiano"#),
        ("fr", #"fre|fra|french|truefrench|vff|vfq|vf2|vfi"#),
        ("de", #"ger|german|deutsch"#),
        ("es", #"spa|spanish|esp|espanol|castellano|latino|lat"#),
        ("pt", #"por|portuguese|dublado|pt-?br"#),
        ("ru", #"rus|russian"#),
        ("uk", #"ukr|ukrainian"#),
        ("ja", #"jap|jpn|japanese"#),
        ("ko", #"kor|korean"#),
        ("zh", #"chi|chinese|mandarin|cantonese"#),
        ("hi", #"hin|hindi"#),
        ("ta", #"tam|tamil"#),
        ("te", #"tel|telugu"#),
        ("pl", #"pol|polish"#),
        ("nl", #"dut|dutch"#),
        ("sv", #"swe|swedish"#),
        ("tr", #"tur|turkish"#),
        ("ar", #"ara|arabic"#),
        ("hu", #"hun|hungarian"#),
        ("cs", #"cze|czech"#),
        ("el", #"gre|greek"#),
    ]

    static func languages(in text: String) -> [String] {
        languageWords.compactMap { has(text, $0.pattern) ? $0.code : nil }
    }

    /// Words a trailing "-WORD" can be that aren't a group.
    static let notGroups: Set<String> = [
        "dl", "rip", "hd", "ma", "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "1080p", "720p", "2160p", "480p",
        "4k", "web", "hdr", "dv", "sdr", "aac", "dts", "ddp", "atmos", "remux", "bluray", "sample", "proper", "repack",
        "dual", "multi", "eng", "ita", "rus", "sub", "subs", "dub", "audio", "x", "es", "en", "fr", "de",
    ]

    /// The group after the last "-" ("…H.264-NTb" → "NTb"), or a leading
    /// "[Group]" as anime releases have it. Site tags like "[rarbg]" are dropped.
    static func group(in stem: String) -> String? {
        var s = stem.trimmingCharacters(in: .whitespaces)
        // Trailing "[site]" / "(site)" tags.
        while let last = s.last, last == "]" || last == ")" {
            let open: Character = last == "]" ? "[" : "("
            guard let start = s.lastIndex(of: open) else { break }
            s = String(s[..<start]).trimmingCharacters(in: .whitespaces)
        }
        if let groups = capture(s, #"-\s?([A-Za-z0-9][A-Za-z0-9@&]{1,23})$"#) {
            let candidate = groups[1]
            if !notGroups.contains(candidate.lowercased()), candidate.rangeOfCharacter(from: .letters) != nil,
               !(candidate.allSatisfy(\.isNumber)) {
                return candidate
            }
        }
        if stem.hasPrefix("["), let close = stem.firstIndex(of: "]") {
            let inner = stem[stem.index(after: stem.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            let lowered = inner.lowercased()
            if lowered.hasPrefix("yts") || lowered.hasPrefix("yify") { return "YTS" }
            if !inner.isEmpty, inner.count <= 24, !inner.contains("."), inner.rangeOfCharacter(from: .letters) != nil {
                return inner
            }
        }
        let lowered = stem.lowercased()
        if lowered.contains("[yts") || lowered.contains("yify") { return "YTS" }
        return nil
    }

    // MARK: Add-on description text

    struct Statistics: Equatable {
        var sizeBytes: Int64?
        var sizeText: String?
        var seeders: Int?
    }

    /// Size and seeders from the emoji stats add-ons print ("👤 20 💾 4.78 GB").
    /// The file size (💾) wins over the torrent size (📦).
    static func statistics(in description: String) -> Statistics {
        var stats = Statistics()
        let sizePattern = #"(\d+(?:[.,]\d+)?)\s?(tb|tib|gb|gib|mb|mib|kb|kib)(?![a-z])"#
        for marker in ["💾", "📦"] {
            guard let range = description.range(of: marker) else { continue }
            let after = String(description[range.upperBound...].prefix(24)).lowercased()
            if let groups = capture(after, #"^\s*"# + sizePattern), let bytes = bytes(groups[1], groups[2]) {
                stats.sizeBytes = bytes
                stats.sizeText = sizeText(groups[1], groups[2])
                break
            }
        }
        if stats.sizeBytes == nil, let groups = capture(description.lowercased(), #"(?<![a-z0-9])"# + sizePattern),
           let bytes = bytes(groups[1], groups[2]) {
            stats.sizeBytes = bytes
            stats.sizeText = sizeText(groups[1], groups[2])
        }
        for marker in ["👤", "👥", "🌱"] {
            guard let range = description.range(of: marker) else { continue }
            let after = String(description[range.upperBound...].prefix(12))
            if let groups = capture(after, #"^\s*(\d+)"#) { stats.seeders = Int(groups[1]); break }
        }
        if stats.seeders == nil, let groups = capture(description, #"(?i)seed(?:er)?s?\s*[:=]?\s*(\d+)"#) {
            stats.seeders = Int(groups[1])
        }
        return stats
    }

    /// Binary units: add-ons print sizes from byte counts divided by 1024.
    static func bytes(_ number: String, _ unit: String) -> Int64? {
        guard let value = Double(number.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let scale: Double = switch unit.lowercased() {
        case "tb", "tib": 1_099_511_627_776
        case "gb", "gib": 1_073_741_824
        case "mb", "mib": 1_048_576
        default: 1_024
        }
        return Int64(value * scale)
    }

    static func sizeText(_ number: String, _ unit: String) -> String {
        let u = unit.uppercased().replacingOccurrences(of: "I", with: "")
        return "\(number.replacingOccurrences(of: ",", with: ".")) \(u)"
    }

    /// Flags in the description: StremThru puts audio after 🎙️ (subtitles after
    /// 💬, ignored); Torrentio puts a line of flags last. "Multi Audio" counts.
    static func audioLanguages(fromDescription lines: [String]) -> [String] {
        if let audioLine = lines.first(where: { $0.hasPrefix("🎙") }) {
            return flagLanguages(audioLine)
        }
        // A line of flags with nothing else on it but separators and words like "Multi Subs".
        for line in lines.reversed() where !line.hasPrefix("💬") {
            let codes = flagLanguages(line)
            if !codes.isEmpty {
                var out = codes
                if normalized(line).contains("multi audio") { out.insert("multi", at: 0) }
                return out
            }
        }
        return []
    }

    static let flagCountries: [String: String] = [
        "GB": "en", "US": "en", "AU": "en", "CA": "en", "IE": "en", "NZ": "en",
        "IT": "it", "FR": "fr", "DE": "de", "AT": "de", "ES": "es", "MX": "es", "AR": "es", "CO": "es",
        "PT": "pt", "BR": "pt", "RU": "ru", "UA": "uk", "JP": "ja", "KR": "ko", "CN": "zh", "TW": "zh", "HK": "zh",
        "IN": "hi", "PL": "pl", "NL": "nl", "SE": "sv", "DK": "da", "NO": "no", "FI": "fi", "TR": "tr",
        "GR": "el", "SA": "ar", "AE": "ar", "EG": "ar", "IL": "he", "TH": "th", "VN": "vi", "ID": "id",
        "CZ": "cs", "HU": "hu", "RO": "ro",
    ]

    /// Languages from flag emoji (pairs of regional indicator symbols), in order.
    static func flagLanguages(_ line: String) -> [String] {
        let base: UInt32 = 0x1F1E6
        var letters: [Character] = []
        var codes: [String] = []
        for scalar in line.unicodeScalars {
            if (base...(base + 25)).contains(scalar.value) {
                letters.append(Character(UnicodeScalar(UInt8(65 + scalar.value - base))))
                if letters.count == 2 {
                    if let code = flagCountries[String(letters)], !codes.contains(code) { codes.append(code) }
                    letters = []
                }
            } else {
                letters = []
            }
        }
        return codes
    }
}
