import Foundation

public enum SubtitleParser {
    public static func parse(_ data: Data, format: SubtitleFormat) throws -> SubtitleTimeline {
        guard let text = decode(data) else { throw SubtitleError.unreadable }
        let cues: [SubtitleCue]
        switch format {
        case .srt: cues = parseSRT(text)
        case .webVTT: cues = parseVTT(text)
        case .ass: cues = parseASS(text)
        }
        guard !cues.isEmpty else { throw SubtitleError.empty }
        return SubtitleTimeline(cues: cues)
    }

    /// UTF-8 (with or without BOM), UTF-16 with a BOM or without one (told by
    /// its zero bytes), then Windows-1252 as a last resort.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let wide = utf16WithoutBOM(data) { return wide }
        if let s = String(data: data, encoding: .utf8) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        // Windows-1252 leaves five bytes undefined (0x81, 0x8D, 0x8F, 0x90, 0x9D) and
        // refuses the whole file if one appears; Latin-1 maps every byte.
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Latin text in UTF-16 has a zero in every other byte: mostly the odd
    /// ones for little-endian, the even ones for big-endian.
    static func utf16WithoutBOM(_ data: Data) -> String? {
        let sample = data.prefix(2000)
        guard sample.count >= 8 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (i, b) in sample.enumerated() where b == 0 { if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 } }
        let half = sample.count / 2
        if oddZeros > half * 6 / 10, evenZeros < half / 10 { return String(data: data, encoding: .utf16LittleEndian) }
        if evenZeros > half * 6 / 10, oddZeros < half / 10 { return String(data: data, encoding: .utf16BigEndian) }
        return nil
    }

    static func blocks(_ text: String) -> [[Substring]] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out: [[Substring]] = []
        var current: [Substring] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { out.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: SRT

    static func parseSRT(_ text: String) -> [SubtitleCue] {
        blocks(text).flatMap(splitRunTogether).compactMap { lines in
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let (start, end) = parseTiming(lines[timingIndex]) else { return nil }
            let body = lines[(timingIndex + 1)...].map { stripTags(String($0)) }.joined(separator: "\n")
            return body.isEmpty ? nil : SubtitleCue(start: start, end: end, text: body)
        }
    }

    /// Files that leave out the blank line between cues: a block is split at
    /// every later timing line, and the cue number just above it is dropped.
    static func splitRunTogether(_ lines: [Substring]) -> [[Substring]] {
        let timings = lines.indices.filter { lines[$0].contains("-->") }
        guard timings.count > 1 else { return [lines] }
        var out: [[Substring]] = []
        var start = lines.startIndex
        for t in timings.dropFirst() {
            var end = t
            if end - 1 > start, lines[end - 1].trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber) { end -= 1 }
            out.append(Array(lines[start..<end]))
            start = end
        }
        out.append(Array(lines[start...]))
        return out
    }

    // MARK: WebVTT

    static func parseVTT(_ text: String) -> [SubtitleCue] {
        blocks(text).compactMap { lines in
            let first = lines[0].trimmingCharacters(in: .whitespaces)
            if first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") {
                return nil
            }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let (start, end) = parseTiming(lines[timingIndex]) else { return nil }
            let body = lines[(timingIndex + 1)...].map { stripTags(String($0)) }.joined(separator: "\n")
            return body.isEmpty ? nil : SubtitleCue(start: start, end: end, text: body)
        }
    }

    // MARK: ASS/SSA (text only; styling and positioning are dropped)

    static func parseASS(_ text: String) -> [SubtitleCue] {
        var format: [String] = []
        var cues: [SubtitleCue] = []
        var inEvents = false
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in normalized.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if line.hasPrefix("[") { inEvents = lower == "[events]"; continue }
            guard inEvents else { continue }
            if lower.hasPrefix("format:") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if lower.hasPrefix("dialogue:"), !format.isEmpty {
                // Text is the last field and may itself contain commas.
                let fields = line.dropFirst(9).split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count == format.count,
                      let si = format.firstIndex(of: "start"), let ei = format.firstIndex(of: "end"),
                      let ti = format.firstIndex(of: "text"),
                      let s = parseTimestamp(fields[si]), let e = parseTimestamp(fields[ei]) else { continue }
                let body = plainASSText(fields[ti])
                if !body.isEmpty { cues.append(SubtitleCue(start: s, end: e, text: body)) }
            }
        }
        return cues
    }

    /// An ASS event's text as plain lines: override blocks and drawings
    /// dropped, `\N` and `\n` as line breaks, `\h` as a space.
    static func plainASSText(_ text: String) -> String {
        removingDrawings(text)
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops vector drawings: text after `\p1` (or any `\pN`, N > 0) up to `\p0` is
    /// drawing commands such as `m 0 0 l 100 0`, not words to show.
    static func removingDrawings(_ text: String) -> String {
        guard text.contains("\\p") else { return text }
        var out = ""
        var drawing = false
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            if !drawing { out += rest[..<open] }
            guard let close = rest[open...].firstIndex(of: "}") else { rest = rest[rest.endIndex...]; break }
            let block = rest[open...close]
            out += block  // override blocks are stripped by the caller
            if let r = block.range(of: #"\\p(\d+)"#, options: .regularExpression), let level = Int(block[r].dropFirst(2)) {
                drawing = level > 0
            }
            rest = rest[rest.index(after: close)...]
        }
        if !drawing { out += rest }
        return out
    }

    // MARK: Shared

    static func parseTiming(_ line: Substring) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        // VTT cue settings follow the end time after whitespace.
        let endToken = parts[1].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard let s = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
              let e = parseTimestamp(endToken) else { return nil }
        return (s, e)
    }

    /// Accepts `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, `MM:SS.mmm`, and ASS `H:MM:SS.cc`.
    static func parseTimestamp(_ s: String) -> TimeInterval? {
        let parts = s.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        guard let secs = Double(parts.last!) , secs >= 0, secs < 60 else { return nil }
        let ints = parts.dropLast().compactMap { Int($0) }
        guard ints.count == parts.count - 1, ints.allSatisfy({ $0 >= 0 }) else { return nil }
        let minutes = ints.last!
        let hours = ints.count == 2 ? ints[0] : 0
        guard minutes < 60 else { return nil }
        return Double(hours * 3600 + minutes * 60) + secs
    }

    static func stripTags(_ s: String) -> String {
        // Only markup (<i>, </b>, <font …>, VTT's <c.yellow>, <v Bob>, <00:01.000>): "a < b and c > d" stays.
        s.replacingOccurrences(of: #"</?(?:[ibus]|font|c|v|ruby|rt|lang)(?:[.\s][^<>]*)?>|<\d{1,2}:\d{2}(?::\d{2})?\.\d{3}>"#,
                               with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
