import Foundation

/// Hide Sound Cues: takes the parts of SDH subtitles meant for the deaf and
/// hard of hearing out of a line: [bracketed] and (parenthesised) cues,
/// ♪ lyrics ♪ and "NAME:" speaker labels. A line that is only cues is gone.
public enum SoundCues {
    /// The line without its cues, or nil when nothing is left.
    public static func strip(_ text: String) -> String? {
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            line = remove(#"\[[^\]]*\]?"#, in: line)          // [door slams]  (an unclosed one runs to the end)
            line = remove(#"\([^)]*\)?"#, in: line)           // (sighs)
            line = remove(#"[♪♫][^♪♫]*[♪♫]?"#, in: line)          // ♪ la la ♪
            line = removeSpeaker(line)
            line = line.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespaces)
            // Dialogue dashes left with nothing after them ("- [laughs]").
            if line.range(of: #"^[-–—:.,\s]*$"#, options: .regularExpression) != nil { continue }
            lines.append(line)
        }
        // Two speakers marked with dashes, one of them only a cue: the dash goes too.
        if lines.count == 1, let only = lines.first, only.hasPrefix("- ") || only.hasPrefix("-"),
           text.components(separatedBy: "\n").count > 1 {
            lines[0] = String(only.drop(while: { $0 == "-" || $0 == " " }))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// True when the text has anything Hide Sound Cues would take out.
    public static func contains(_ text: String) -> Bool { strip(text) != text }

    /// Cues with their text cleaned; cue-only lines dropped.
    public static func strip(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.compactMap { c in strip(c.text).map { SubtitleCue(start: c.start, end: c.end, text: $0) } }
    }

    private static func remove(_ pattern: String, in s: String) -> String {
        s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }

    /// "DEB: Where were you?" and "- MAN #2: Run!" lose the name; a time
    /// ("At 10:30") or a lower-case word before the colon isn't a speaker.
    private static func removeSpeaker(_ s: String) -> String {
        let pattern = #"^(\s*[-–—]?\s*)([A-Z][A-Z0-9 .'#&-]{0,30}):\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let name = Range(m.range(at: 2), in: s),
              s[name].contains(where: \.isLetter), s[name] == s[name].uppercased(),
              let all = Range(m.range, in: s), let dash = Range(m.range(at: 1), in: s) else { return s }
        return String(s[dash]) + s[all.upperBound...]
    }
}
