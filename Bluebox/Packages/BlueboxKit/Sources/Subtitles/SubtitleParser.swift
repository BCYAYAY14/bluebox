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

    /// UTF-8 (with or without BOM), UTF-16 with BOM, then Windows-1252 as a last resort.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let s = String(data: data, encoding: .utf8) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        // Windows-1252 leaves five bytes undefined (0x81, 0x8D, 0x8F, 0x90, 0x9D) and
        // refuses the whole file if one appears; Latin-1 maps every byte.
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
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
        blocks(text).compactMap { lines in
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let (start, end) = parseTiming(lines[timingIndex]) else { return nil }
            let body = lines[(timingIndex + 1)...].map { stripTags(String($0)) }.joined(separator: "\n")
            return body.isEmpty ? nil : SubtitleCue(start: start, end: end, text: body)
        }
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
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            if line.hasPrefix("Format:") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if line.hasPrefix("Dialogue:"), !format.isEmpty {
                // Text is the last field and may itself contain commas.
                let fields = line.dropFirst(9).split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count == format.count,
                      let si = format.firstIndex(of: "start"), let ei = format.firstIndex(of: "end"),
                      let ti = format.firstIndex(of: "text"),
                      let s = parseTimestamp(fields[si]), let e = parseTimestamp(fields[ei]) else { continue }
                let body = removingDrawings(fields[ti])
                    .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\h", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { cues.append(SubtitleCue(start: s, end: e, text: body)) }
            }
        }
        return cues
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
        let endToken = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
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
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
