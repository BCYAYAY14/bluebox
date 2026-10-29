import Foundation

/// Finds intros, recaps and credits from a file's chapter titles.
///
/// Releases that carry chapters usually name them ("Opening", "Intro",
/// "Previously On", "End Credits", "ED"). Generic names ("Chapter 3",
/// "00:05:12.000") say nothing, so a file with only those yields nothing.
public enum ChapterSegments {
    /// Chapter titles that mark each kind, matched as whole words, case-insensitively.
    static let patterns: [(SkipSegment.Kind, [String])] = [
        // Order matters: "Opening Credits" is an intro, so intro words are tried first.
        (.recap, ["recap", "previously", "previously on", "last time", "summary"]),
        (.intro, ["intro", "introduction", "opening", "opening credits", "opening theme", "op", "theme song",
                  "title sequence", "titles", "main titles", "cold open intro"]),
        (.preview, ["preview", "next episode", "next time", "next on", "coming up"]),
        (.credits, ["credits", "end credits", "ending", "ending credits", "ending theme", "ed", "outro",
                    "closing credits", "closing", "end titles", "end"]),
    ]

    /// Kind of a chapter title, or nil when the title doesn't name one.
    public static func kind(ofTitle raw: String) -> SkipSegment.Kind? {
        let title = normalized(raw)
        guard !title.isEmpty else { return nil }
        // "Opening Credits" means the intro; "Credits" alone means the end.
        if title.contains("opening") { return .intro }
        let words = Set(title.split(separator: " ").map(String.init))
        for (kind, phrases) in patterns {
            for phrase in phrases {
                if phrase.contains(" ") {
                    if title == phrase || title.hasPrefix(phrase + " ") || title.hasSuffix(" " + phrase) || title.contains(" \(phrase) ") {
                        return kind
                    }
                } else if words.contains(phrase) {
                    // Two-letter anime markers ("OP", "ED") only count as the whole title
                    // (optionally numbered): "Ed's Story" is not the ending.
                    if phrase.count <= 2 || phrase == "end" {
                        if words.count <= 2, title.hasPrefix(phrase) { return kind }
                        continue
                    }
                    return kind
                }
            }
        }
        return nil
    }

    /// Segments named by the chapters. Each named chapter runs to the next
    /// chapter's start (or the end of the file).
    public static func segments(from chapters: [ChapterMark], duration: TimeInterval?) -> [SkipSegment] {
        let sorted = chapters.filter { $0.start.isFinite && $0.start >= 0 }.sorted { $0.start < $1.start }
        var out: [SkipSegment] = []
        for (i, chapter) in sorted.enumerated() {
            guard let kind = kind(ofTitle: chapter.title) else { continue }
            let end = i + 1 < sorted.count ? sorted[i + 1].start : duration
            if let end, end - chapter.start < 3 { continue }  // a marker, not a section
            // Merge with the previous one when it's the same kind and touches it
            // ("Credits" then "Credits (cont.)").
            if var last = out.last, last.kind == kind, let lastEnd = last.end, abs(lastEnd - chapter.start) < 1 {
                last.end = end
                out[out.count - 1] = last
                continue
            }
            out.append(SkipSegment(kind: kind, start: chapter.start, end: i + 1 < sorted.count ? end : nil, source: .chapters))
        }
        // An intro that is most of the file is a mislabelled chapter, not an intro.
        if let duration, duration > 0 {
            out.removeAll { s in
                guard s.kind != .credits, s.kind != .preview else { return false }
                return (s.resolvedEnd(duration: duration) ?? duration) - s.start > max(duration * 0.4, 600)
            }
        }
        return out
    }

    static func normalized(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let mapped = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }
}
