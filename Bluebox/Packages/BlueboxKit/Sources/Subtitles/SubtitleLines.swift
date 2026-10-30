import Foundation

/// Previous and next line (⇧← ⇧→) and the Lines page: where each line
/// starts on the video's clock, after the subtitle delay and speed.
public enum SubtitleLines {
    /// A line counts as "the one you just heard" for this long after it starts:
    /// pressing ⇧← then replays it; later, it goes to the one before.
    public static let replayWindow: TimeInterval = 1.5
    /// How far before a line's start the jump lands, so its first word isn't clipped.
    public static let lead: TimeInterval = 0.15

    /// Where ⇧← goes from `playerTime`: the start of the line showing (or the
    /// last one shown), or the one before it when that one has only just started.
    public static func previous(_ cues: [SubtitleCue], at playerTime: TimeInterval, offset: SubtitleOffset = .init()) -> TimeInterval? {
        let starts = startTimes(cues, offset: offset)
        guard let i = starts.lastIndex(where: { $0 <= playerTime + 0.05 }) else { return nil }
        let target = playerTime - starts[i] < replayWindow && i > 0 ? starts[i - 1] : starts[i]
        return max(0, target - lead)
    }

    /// Where ⇧→ goes: the start of the first line after the playhead.
    public static func next(_ cues: [SubtitleCue], at playerTime: TimeInterval, offset: SubtitleOffset = .init()) -> TimeInterval? {
        let starts = startTimes(cues, offset: offset)
        // Past a jump's lead-in: the line it landed before isn't "next" again.
        guard let s = starts.first(where: { $0 > playerTime + lead + 0.05 }) else { return nil }
        return max(0, s - lead)
    }

    /// The line on screen at `playerTime`, or the last one before it: the Lines page highlights it.
    public static func currentIndex(_ cues: [SubtitleCue], at playerTime: TimeInterval, offset: SubtitleOffset = .init()) -> Int? {
        let t = offset.cueTime(forPlayerTime: playerTime)
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }

    /// Lines whose text contains every word of `query` (any case and accent).
    public static func search(_ cues: [SubtitleCue], query: String) -> [Int] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Array(cues.indices) }
        return cues.indices.filter { i in
            words.allSatisfy { cues[i].text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    static func startTimes(_ cues: [SubtitleCue], offset: SubtitleOffset) -> [TimeInterval] {
        // Distinct and in order: two cues starting together (two speakers) are one line to jump to.
        var out: [TimeInterval] = []
        for c in cues.sorted(by: { $0.start < $1.start }) {
            let t = offset.playerTime(forCueTime: c.start)
            if let last = out.last, t - last < 0.05 { continue }
            out.append(t)
        }
        return out
    }
}
