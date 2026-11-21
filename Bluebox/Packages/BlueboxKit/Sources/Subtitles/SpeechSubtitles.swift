import Foundation

/// A word (or a few characters, in languages written without spaces) heard
/// in the soundtrack, with when it starts and ends in the video. The text
/// keeps the space before it, as the recogniser gives it, so words join back
/// up the right way whatever the language.
public struct HeardWord: Hashable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    public init(_ text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text; self.start = start; self.end = max(start, end)
    }
}

/// One sentence as it was spoken: what's translated as a whole, so a
/// translation reads as a sentence rather than as the halves of one.
public struct SpokenSentence: Hashable, Sendable {
    public let words: [HeardWord]
    public var start: TimeInterval { words.first?.start ?? 0 }
    public var end: TimeInterval { words.last?.end ?? 0 }
    public var text: String { SpeechSubtitles.join(words.map(\.text)) }
    public init(words: [HeardWord]) { self.words = words }

    /// Stays the same while the sentence does, so a translation is reused
    /// until more of the sentence is heard.
    public var key: String { "\(Int((start * 10).rounded()))|\(text)" }
}

/// Generated subtitles: turns the words heard in a soundtrack into lines
/// people can read. Sentences are found from punctuation and pauses; each is
/// cut into lines of at most two rows, kept on screen long enough to read
/// and never over the next line.
public enum SpeechSubtitles {
    /// Characters a row holds: the usual broadcast limit, and less for
    /// Chinese, Japanese and Korean, whose characters are wider and denser.
    static func rowLength(for text: String) -> Int { isDense(text) ? 16 : 42 }
    static let rows = 2
    /// The longest a line stays up, and the shortest it shows for.
    static let longest: TimeInterval = 6.5
    static let shortest: TimeInterval = 1.0
    /// How long a line stays after the last word was said, if nothing follows.
    static let linger: TimeInterval = 0.6
    /// A silence this long ends a sentence even without a full stop.
    static let pause: TimeInterval = 0.9
    /// The gap kept before the next line, so two lines never show at once.
    static let gap: TimeInterval = 0.05

    // MARK: Sentences

    /// Words, in time order, grouped into sentences: a full stop, question
    /// or exclamation mark ends one, and so does a pause or a sentence
    /// grown too long to read in one go.
    public static func sentences(_ words: [HeardWord]) -> [SpokenSentence] {
        var out: [SpokenSentence] = [], current: [HeardWord] = []
        for word in words.sorted(by: { $0.start < $1.start }) where !word.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let last = current.last, word.start - last.end >= pause || current.count >= 60 {
                out.append(SpokenSentence(words: current)); current = []
            }
            current.append(word)
            if endsSentence(word.text) { out.append(SpokenSentence(words: current)); current = [] }
        }
        if !current.isEmpty { out.append(SpokenSentence(words: current)) }
        return out
    }

    static func endsSentence(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)」』"))
        guard let last = t.last else { return false }
        // A title's full stop isn't the end of a sentence ("Mr. Holmes").
        if last == ".", abbreviations.contains(t.lowercased()) { return false }
        return ".?!…。？！".contains(last)
    }

    static let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "st.", "jr.", "sr.", "prof.", "mt.", "vs.",
                                             "e.g.", "i.e.", "sgt.", "lt.", "capt.", "col.", "gen.", "rev.",
                                             "hr.", "fr.", "sra.", "mme.", "mlle."]

    // MARK: Lines

    /// A sentence's lines. With `translation`, its text replaces the words
    /// heard, and the sentence's time is shared out by the length of each line.
    public static func cues(for sentence: SpokenSentence, translation: String? = nil) -> [SubtitleCue] {
        guard !sentence.words.isEmpty else { return [] }
        if let translation {
            let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            let pieces = split(text, limit: rowLength(for: text) * rows)
            let total = Double(pieces.reduce(0) { $0 + $1.count })
            var t = sentence.start, out: [SubtitleCue] = []
            let span = max(sentence.end - sentence.start, shortest)
            for piece in pieces {
                let length = span * Double(piece.count) / max(1, total)
                out.append(SubtitleCue(start: t, end: t + length, text: wrap(piece)))
                t += length
            }
            return out
        }
        // Words heard: each line takes the times of its own words.
        let limit = rowLength(for: sentence.text) * rows
        var out: [SubtitleCue] = [], line: [HeardWord] = []
        func flush() {
            guard let first = line.first, let last = line.last else { return }
            out.append(SubtitleCue(start: first.start, end: last.end, text: wrap(join(line.map(\.text)))))
            line = []
        }
        for word in sentence.words {
            let longer = join((line + [word]).map(\.text))
            if !line.isEmpty, longer.count > limit || word.end - line[0].start > longest { flush() }
            line.append(word)
        }
        flush()
        return out
    }

    /// Every sentence's lines, settled so each can be read: at least a second
    /// on screen, a moment after the words end, and gone before the next.
    public static func cues(_ sentences: [SpokenSentence], translations: [String: String] = [:]) -> [SubtitleCue] {
        settle(sentences.flatMap { cues(for: $0, translation: translations[$0.key]) })
    }

    static func settle(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        let sorted = cues.sorted { $0.start < $1.start }
        return sorted.indices.map { i in
            let cue = sorted[i]
            let next = i + 1 < sorted.count ? sorted[i + 1].start - gap : .infinity
            let wanted = max(cue.end + linger, cue.start + shortest)
            let end = max(cue.start + 0.3, min(wanted, cue.start + longest + linger, next))
            return SubtitleCue(start: cue.start, end: end, text: cue.text)
        }
    }

    /// Text cut into pieces of at most `limit` characters, at spaces (or
    /// anywhere, in a language written without them), after punctuation where it can.
    static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        let count = Int((Double(text.count) / Double(limit)).rounded(.up))
        let target = Double(text.count) / Double(count)
        var pieces: [String] = [], rest = Substring(text)
        while rest.count > limit {
            let cut = breakPoint(in: rest, near: Int(target), limit: limit)
            pieces.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
            rest = rest[cut...].drop { $0 == " " }
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }

    /// One or two rows: a line too long for one is broken at the space
    /// nearest its middle, so the rows are about the same length.
    public static func wrap(_ text: String) -> String {
        let row = rowLength(for: text)
        guard text.count > row else { return text }
        let cut = breakPoint(in: Substring(text), near: text.count / 2, limit: text.count - 1)
        let first = text[..<cut].trimmingCharacters(in: .whitespaces), second = text[cut...].trimmingCharacters(in: .whitespaces)
        return second.isEmpty ? first : first + "\n" + second
    }

    /// Where to cut `text`: the space (or, failing that, any character) closest
    /// to `near`, preferring one just after punctuation, and never past `limit`.
    private static func breakPoint(in text: Substring, near: Int, limit: Int) -> String.Index {
        let chars = Array(text)
        let dense = isDense(String(text))
        var best: (score: Double, at: Int)?
        for i in 1..<min(chars.count, limit + 1) {
            let atSpace = chars[i] == " "
            guard atSpace || dense else { continue }
            let afterPunctuation = ",;:、，。.!?".contains(chars[i - 1])
            let score = Double(abs(i - near)) - (afterPunctuation ? 6 : 0)
            if best == nil || score < best!.score { best = (score, i) }
        }
        let at = best?.at ?? min(limit, chars.count)
        return text.index(text.startIndex, offsetBy: at)
    }

    /// Joins words as the recogniser gave them (each with its own leading space).
    static func join(_ parts: [String]) -> String {
        parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// Mostly Chinese, Japanese or Korean characters.
    static func isDense(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return false }
        let dense = scalars.filter { s in
            (0x3040...0x30FF).contains(s.value) || (0x3400...0x9FFF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
        }.count
        return dense * 2 > scalars.count
    }

    // MARK: Files

    /// The lines as an SRT file.
    public static func srt(_ cues: [SubtitleCue]) -> String {
        func stamp(_ t: TimeInterval) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return cues.enumerated().map { i, c in "\(i + 1)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(c.text)\n" }
            .joined(separator: "\n")
    }

    /// Lines a speech model makes up from silence or music, which Whisper is
    /// known for: a phrase from the end of a video ("Thanks for watching"),
    /// or the same line again and again.
    public static func withoutInventedLines(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        let invented = ["thanks for watching", "thank you for watching", "please subscribe", "subtitles by",
                        "like and subscribe", "amara.org", "ご視聴ありがとうございました"]
        var out: [SubtitleCue] = []
        for cue in cues {
            let lower = cue.text.lowercased()
            if invented.contains(where: lower.contains) { continue }
            // The third time in a row the same words come back, they're dropped.
            if out.count >= 2, out.suffix(2).allSatisfy({ $0.text == cue.text }) { continue }
            out.append(cue)
        }
        return out
    }
}

/// Which stretches of a video have been listened to, as ranges of seconds
/// kept merged and in order: what's left to do, and how far the lines go
/// from the playhead (the line drawn on the scrub bar).
public struct CoveredTime: Hashable, Sendable, Codable {
    public private(set) var ranges: [ClosedRange<TimeInterval>] = []
    public init(_ ranges: [ClosedRange<TimeInterval>] = []) { ranges.forEach { insert($0) } }

    public mutating func insert(_ range: ClosedRange<TimeInterval>) {
        var merged = range, kept: [ClosedRange<TimeInterval>] = []
        // Within a second counts as touching: clips are cut at round seconds.
        for r in ranges {
            if r.upperBound + 1 >= merged.lowerBound && r.lowerBound - 1 <= merged.upperBound {
                merged = min(r.lowerBound, merged.lowerBound)...max(r.upperBound, merged.upperBound)
            } else {
                kept.append(r)
            }
        }
        ranges = (kept + [merged]).sorted { $0.lowerBound < $1.lowerBound }
    }

    public func contains(_ t: TimeInterval) -> Bool { ranges.contains { $0.contains(t) } }

    /// Where the covered stretch that holds `t` ends (`t` itself when it isn't covered).
    public func reach(from t: TimeInterval) -> TimeInterval {
        ranges.first { $0.contains(t) }?.upperBound ?? t
    }

    /// The first moment from `t` on that hasn't been listened to, before `end`.
    public func firstGap(from t: TimeInterval, before end: TimeInterval) -> TimeInterval? {
        var at = max(0, t)
        while at < end - 1 {
            guard let r = ranges.first(where: { $0.contains(at) }) else { return at }
            // Just past it: ranges within a second of each other are already one.
            at = r.upperBound + 0.01
        }
        return nil
    }

    /// True when everything up to `end` has been listened to.
    public func covers(_ end: TimeInterval) -> Bool { firstGap(from: 0, before: end) == nil }

    /// Seconds listened to in all.
    public var total: TimeInterval { ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
}
