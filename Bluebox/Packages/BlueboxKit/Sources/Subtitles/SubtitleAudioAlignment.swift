import Foundation

/// Sync to the Audio: lines up words recognised in the soundtrack with the
/// subtitle text and works out the delay and drift.
///
/// Each cue's words get times spread over the cue. Every pair of matching
/// word pairs (two words in a row, so "the" alone matches nothing) votes for
/// the offset between them; the strongest offset wins, and the matches near
/// it are fitted with a line (heard = cue × k + b). Points far apart in the
/// film give the drift; close together, only the delay is set.
public enum SubtitleAudioAlignment {
    /// A word heard in the soundtrack, at a time on the video's clock.
    public struct HeardWord: Equatable, Sendable {
        public var text: String
        public var time: TimeInterval
        public init(_ text: String, at time: TimeInterval) { self.text = text; self.time = time }
    }

    public struct Result: Equatable, Sendable {
        /// The timing to use (delay and speed), ready for `SubtitleOffset`.
        public var offset: SubtitleOffset
        /// How many word pairs agreed.
        public var matches: Int
        /// True when the drift was fitted too (from two stretches of the film).
        public var fittedDrift: Bool
    }

    /// Fewer agreeing word pairs than this: not trusted.
    public static let minimumMatches = 4
    /// Offsets this close to the winner count as agreeing.
    static let tolerance: TimeInterval = 1.2
    static let bin: TimeInterval = 0.25

    /// - Parameters:
    ///   - words: what was heard, on the video's clock.
    ///   - cues: the subtitle lines as timed in the file.
    ///   - current: the timing in use; its speed is kept when the drift can't be fitted.
    ///   - fitsDrift: false where only a delay can be applied (a track in the video).
    public static func fit(words: [HeardWord], cues: [SubtitleCue], current: SubtitleOffset = .init(), fitsDrift: Bool = true) -> Result? {
        let heard = pairs(words.map { ($0.text, $0.time) })
        let written = pairs(cueWords(cues))
        guard !heard.isEmpty, !written.isEmpty else { return nil }
        var byKey: [String: [TimeInterval]] = [:]
        for w in written { byKey[w.key, default: []].append(w.time) }

        // Every match: (cue time, heard time).
        var matches: [(cue: TimeInterval, heard: TimeInterval)] = []
        for h in heard {
            guard let times = byKey[h.key], times.count <= 6 else { continue }  // too common to place
            for c in times { matches.append((c, h.time)) }
        }
        guard matches.count >= minimumMatches else { return nil }

        // Each stretch listened to votes on its own: with drift, the offset
        // differs from one stretch of the film to another.
        var inliers: [(cue: TimeInterval, heard: TimeInterval)] = []
        var stretches = 0
        for window in windows(matches) {
            let found = agreeing(window)
            if found.count >= 3 { inliers += found; stretches += 1 }
        }
        guard inliers.count >= minimumMatches else { return nil }

        var offset = current
        let cueTimes = inliers.map(\.cue)
        let span = (cueTimes.max() ?? 0) - (cueTimes.min() ?? 0)
        // Drift needs two stretches of the film: one alone only places the delay.
        if fitsDrift, stretches >= 2, span >= 10, let (k, b) = lineFit(inliers), let first = cueTimes.min(), let last = cueTimes.max() {
            // Through SubtitleOffset's own two-point fit, which checks the speed is plausible.
            var fitted = current
            if fitted.align((cue: first, heard: k * first + b), (cue: last, heard: k * last + b)) {
                // Speeds within 0.2% of 1× are noise from the word timings.
                if abs(fitted.scale - 1) < 0.002 {
                    fitted.setScale(1)
                    fitted.align(cueStart: 0, to: median(inliers.map { $0.heard - $0.cue }))
                }
                return Result(offset: fitted, matches: inliers.count, fittedDrift: abs(fitted.scale - 1) >= 0.002)
            }
        }
        // Delay only, at the current speed: heard = cue / scale + seconds.
        let delay = median(inliers.map { $0.heard - $0.cue / current.scale })
        offset.align(cueStart: 0, to: delay)
        return Result(offset: offset, matches: inliers.count, fittedDrift: false)
    }

    /// Matches split where nothing was heard for a minute (separate stretches listened to).
    static func windows(_ matches: [(cue: TimeInterval, heard: TimeInterval)]) -> [[(cue: TimeInterval, heard: TimeInterval)]] {
        var out: [[(cue: TimeInterval, heard: TimeInterval)]] = []
        for m in matches.sorted(by: { $0.heard < $1.heard }) {
            if let last = out.last?.last, m.heard - last.heard <= 60 { out[out.count - 1].append(m) } else { out.append([m]) }
        }
        return out
    }

    /// The matches that agree on the most common offset (heard − cue), one per heard word.
    static func agreeing(_ matches: [(cue: TimeInterval, heard: TimeInterval)]) -> [(cue: TimeInterval, heard: TimeInterval)] {
        var votes: [Int: Int] = [:]
        for m in matches { votes[Int(((m.heard - m.cue) / bin).rounded()), default: 0] += 1 }
        // Neighbouring bins together, so an offset on a bin edge isn't split.
        func weight(_ k: Int) -> Int { (votes[k - 1] ?? 0) + (votes[k] ?? 0) + (votes[k + 1] ?? 0) }
        guard let best = votes.keys.max(by: { weight($0) == weight($1) ? abs($0) > abs($1) : weight($0) < weight($1) }) else { return [] }
        let peak = Double(best) * bin
        let near = matches.filter { abs(($0.heard - $0.cue) - peak) <= tolerance }
        return Dictionary(grouping: near, by: { $0.heard }).values.compactMap { group in
            group.min { abs(($0.heard - $0.cue) - peak) < abs(($1.heard - $1.cue) - peak) }
        }
    }

    /// Words of each cue, with times spread evenly across it.
    static func cueWords(_ cues: [SubtitleCue]) -> [(String, TimeInterval)] {
        var out: [(String, TimeInterval)] = []
        for c in cues {
            let words = normalizedWords(c.text)
            guard !words.isEmpty else { continue }
            let step = (c.end - c.start) / Double(words.count)
            for (i, w) in words.enumerated() { out.append((w, c.start + step * (Double(i) + 0.5))) }
        }
        return out
    }

    /// Two words in a row, keyed together, at the first word's time.
    static func pairs(_ words: [(String, TimeInterval)]) -> [(key: String, time: TimeInterval)] {
        let flat = words.flatMap { w, t in normalizedWords(w).map { ($0, t) } }
        guard flat.count >= 2 else { return [] }
        return (0..<(flat.count - 1)).compactMap { i in
            // Too far apart to be said together.
            guard flat[i + 1].1 - flat[i].1 < 4 else { return nil }
            let key = flat[i].0 + " " + flat[i + 1].0
            return key.count >= 6 ? (key, flat[i].1) : nil
        }
    }

    /// Lower case, no accents or punctuation; cues in brackets and speaker names left out.
    static func normalizedWords(_ text: String) -> [String] {
        let clean = SoundCues.strip(text) ?? ""
        return clean.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func lineFit(_ points: [(cue: TimeInterval, heard: TimeInterval)]) -> (k: Double, b: Double)? {
        let n = Double(points.count)
        let mx = points.map(\.cue).reduce(0, +) / n, my = points.map(\.heard).reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for p in points { sxx += (p.cue - mx) * (p.cue - mx); sxy += (p.cue - mx) * (p.heard - my) }
        guard sxx > 0 else { return nil }
        let k = sxy / sxx
        return (k, my - k * mx)
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
