import Foundation
import NaturalLanguage

/// Sync to the Audio: lines up words recognised in the soundtrack with the
/// subtitle text and works out the delay and drift.
///
/// Each cue's words get times spread over the cue, and each heard word sits
/// at its middle. Every pair of matching word pairs (two words in a row, so
/// "the" alone matches nothing) votes for the offset between them, one
/// stretch listened to at a time; the strongest offset wins, and the matches
/// near it are kept. Stretches far apart in the film give the drift, which
/// is taken only when it's a real frame-rate change (25 → 23.976 and the
/// like) and every stretch agrees with it; otherwise only the delay is set,
/// and only when the stretches agree on it. Stretches that disagree (a cut
/// partway) set the delay for the one at the playhead, and say so.
public enum SubtitleAudioAlignment {
    /// A word heard in the soundtrack, at a time on the video's clock.
    public struct HeardWord: Equatable, Sendable {
        public var text: String
        public var time: TimeInterval
        /// Which stretch listened to it came from: each stretch votes on its
        /// own, even when they're close together (a torrent early on).
        public var clip: Int
        public init(_ text: String, at time: TimeInterval, clip: Int = 0) { self.text = text; self.time = time; self.clip = clip }
    }

    public struct Result: Equatable, Sendable {
        /// The timing to use (delay and speed), ready for `SubtitleOffset`.
        public var offset: SubtitleOffset
        /// How many word pairs agreed.
        public var matches: Int
        /// True when the drift was fitted too (from two stretches of the film).
        public var fittedDrift: Bool
        /// True when the stretches disagreed (the film's timing changes
        /// partway) and the delay is the one for the stretch at the playhead:
        /// right here, not necessarily elsewhere in the film.
        public var isLocal = false
    }

    /// Why nothing was applied.
    public enum Refusal: Equatable, Sendable {
        /// Too few word pairs agreed: other subtitles, another language, little speech.
        case tooFewMatches
        /// The speech drifts against the lines, and the drift couldn't be fitted
        /// (stretches too close together, a speed that isn't a frame-rate
        /// change, or a track whose speed can't be changed): a delay alone
        /// would be right in one place and wrong everywhere else.
        case drifts
        /// The best timing still leaves the words away from where they were heard.
        case doesNotLand
    }

    public enum Outcome: Equatable, Sendable {
        case fitted(Result)
        case refused(Refusal)

        public var result: Result? { if case .fitted(let r) = self { r } else { nil } }
    }

    typealias Point = (cue: TimeInterval, heard: TimeInterval)
    typealias Match = (cue: TimeInterval, heard: TimeInterval, clip: Int)
    /// A stretch listened to: its agreeing matches, and the line they follow
    /// when they show one (drift is visible within a minute: 4% is 2.4 s).
    typealias Stretch = (points: [Point], line: (k: Double, b: Double)?)

    /// Fewer agreeing word pairs than this: not trusted.
    public static let minimumMatches = 4
    /// A timing lands when the words are this close (median) to where they
    /// were heard, and stretches agree when their delays are this close. It
    /// was 1.2 s, which let a false "+2.8 s · 1.011×" through for a recording
    /// already in sync (lines then 0.9 s off on average, 2.7 s at worst).
    static let tolerance: TimeInterval = 0.4
    /// One word pair this far from the stretch's offset still counts: a
    /// single word's time is rough (spread over its line), their median isn't.
    static let spread: TimeInterval = 1.0
    static let bin: TimeInterval = 0.25
    /// A slope within a stretch this far from the speed in use is drift, not noise.
    static let visibleDrift = 0.02

    /// Frame rates subtitles are made for and videos play at.
    static let frameRates: [Double] = [24000.0 / 1001, 24, 25, 30000.0 / 1001]
    /// Heard against cue time (k in heard = cue × k + b) for subtitles made for
    /// one rate on a video at another: 25 → 23.976, 24 → 23.976, 25 → 24,
    /// 30 → 29.97 and back. Any other speed is noise or a mismatch, not drift.
    static func speeds(videoFrameRate: Double?) -> [(k: Double, video: Double)] {
        let pairs: [(Double, Double)] = [(25, 24000.0 / 1001), (24, 24000.0 / 1001), (25, 24), (30, 30000.0 / 1001)]
        // The listed rate nearest the video's (24 and 23.976 are only 0.024 apart).
        let video = videoFrameRate.flatMap { fps in
            frameRates.filter { abs($0 - fps) < 0.05 }.min { abs($0 - fps) < abs($1 - fps) }
        }
        return pairs.flatMap { s, v in [(k: s / v, video: v), (k: v / s, video: s)] }
            .filter { pair in video.map { $0 == pair.video } ?? true }
    }

    /// - Parameters:
    ///   - words: what was heard, on the video's clock.
    ///   - cues: the subtitle lines as timed in the file.
    ///   - current: the timing in use; its speed is kept when the drift can't be fitted.
    ///   - fitsDrift: false where only a delay can be applied (a track in the video).
    ///   - playhead: where the video is: when stretches disagree, the delay is the one here.
    ///   - videoFrameRate: the video's, when known: only speeds that end at it are drift.
    public static func fit(words: [HeardWord], cues: [SubtitleCue], current: SubtitleOffset = .init(), fitsDrift: Bool = true,
                           playhead: TimeInterval? = nil, videoFrameRate: Double? = nil) -> Result? {
        match(words: words, cues: cues, current: current, fitsDrift: fitsDrift, playhead: playhead, videoFrameRate: videoFrameRate).result
    }

    /// `fit`, saying why when nothing fits.
    public static func match(words: [HeardWord], cues: [SubtitleCue], current: SubtitleOffset = .init(), fitsDrift: Bool = true,
                             playhead: TimeInterval? = nil, videoFrameRate: Double? = nil) -> Outcome {
        // Pairs within a stretch only: the last word of one and the first of the next weren't said together.
        let heard = Dictionary(grouping: words, by: \.clip).flatMap { clip, words in
            pairs(words.sorted { $0.time < $1.time }.map { ($0.text, $0.time) }).map { (key: $0.key, time: $0.time, clip: clip) }
        }
        let written = pairs(cueWords(cues))
        guard !heard.isEmpty, !written.isEmpty else { return .refused(.tooFewMatches) }
        var byKey: [String: [TimeInterval]] = [:]
        for w in written { byKey[w.key, default: []].append(w.time) }

        // Every match: (cue time, heard time, stretch).
        var matches: [Match] = []
        for h in heard {
            guard let times = byKey[h.key], times.count <= 6 else { continue }  // too common to place
            for c in times { matches.append((c, h.time, h.clip)) }
        }
        guard matches.count >= minimumMatches else { return .refused(.tooFewMatches) }

        // Each stretch listened to votes on its own: with drift, the offset
        // differs from one stretch of the film to another.
        let stretches = windows(matches).compactMap { window -> Stretch? in
            let found = agreeing(window)
            return found.points.count >= 3 && beatsChance(found.points.count, among: window) ? found : nil
        }
        let inliers = stretches.flatMap(\.points)
        guard inliers.count >= minimumMatches else { return .refused(.tooFewMatches) }

        let cueTimes = inliers.map(\.cue)
        let span = (cueTimes.max() ?? 0) - (cueTimes.min() ?? 0)
        // Drift needs two stretches of the film: one alone only places the delay.
        // (No drift heard while a speed is set by hand also counts: back to 1×.)
        if fitsDrift, stretches.count >= 2, span >= 10, let k = speed(inliers, videoFrameRate: videoFrameRate),
           k != 1 || current.scale != 1 {
            var fitted = current
            fitted.setScale(1 / k)
            fitted.align(cueStart: 0, to: median(inliers.map { $0.heard - $0.cue * k }))
            if agree(fitted, stretches), lands(fitted, inliers) {
                return .fitted(Result(offset: fitted, matches: inliers.count, fittedDrift: k != 1))
            }
        }
        // Delay only, at the current speed: heard = cue / scale + seconds.
        var offset = current
        offset.align(cueStart: 0, to: median(inliers.map { $0.heard - $0.cue / current.scale }))
        if agree(offset, stretches), lands(offset, inliers) {
            return .fitted(Result(offset: offset, matches: inliers.count, fittedDrift: false))
        }
        // A stretch that slopes against the lines: drift a delay can't hold.
        if stretches.contains(where: { slopes($0, against: current) }) { return .refused(.drifts) }
        // Stretches that disagree: the film's timing changes partway (a cut,
        // an extra scene). The delay for the stretch at the playhead.
        if stretches.count >= 2, let here = nearest(stretches, to: playhead) {
            var local = current
            local.align(cueStart: 0, to: median(here.points.map { $0.heard - $0.cue / current.scale }))
            if lands(local, here.points) {
                return .fitted(Result(offset: local, matches: here.points.count, fittedDrift: false, isLocal: true))
            }
        }
        // Past what a delay can hold (another cut of the film), or a speed that
        // doesn't suit what was heard: better nothing than lines in the wrong place.
        return .refused(.doesNotLand)
    }

    /// True when the timing puts the agreeing words, mostly, where they were heard.
    static func lands(_ offset: SubtitleOffset, _ points: [Point]) -> Bool {
        median(points.map { abs(offset.playerTime(forCueTime: $0.cue) - $0.heard) }) <= tolerance
    }

    /// True when every stretch's words sit, in the middle, where the timing puts them.
    static func agree(_ offset: SubtitleOffset, _ stretches: [Stretch]) -> Bool {
        stretches.allSatisfy { s in abs(median(s.points.map { $0.heard - offset.playerTime(forCueTime: $0.cue) })) <= tolerance }
    }

    /// The speed (heard per cue second) the points follow, when it's a real
    /// frame-rate change or none (1); nil for any other.
    static func speed(_ points: [Point], videoFrameRate: Double?) -> Double? {
        guard let line = lineFit(points) else { return nil }
        // How sure the slope is: stretches far apart pin it to a few parts in ten thousand.
        let margin = max(3 * slopeError(points, line), 0.0008)
        if abs(line.k - 1) <= margin { return 1 }
        return speeds(videoFrameRate: videoFrameRate).map(\.k)
            .filter { abs(line.k - $0) <= margin }
            .min { abs(line.k - $0) < abs(line.k - $1) }
    }

    /// True when the stretch's own words show a slope (drift) against the speed in use.
    static func slopes(_ stretch: Stretch, against current: SubtitleOffset) -> Bool {
        guard let line = stretch.line, stretch.points.count >= 8 else { return false }
        let cues = stretch.points.map(\.cue)
        guard (cues.max() ?? 0) - (cues.min() ?? 0) >= 30 else { return false }
        let off = abs(line.k - 1 / current.scale)
        return off >= visibleDrift && off > 4 * slopeError(stretch.points, line)
    }

    /// True when `found` agreeing matches are more than chance gives: with a
    /// few hundred matches scattered over the film's length, three or four
    /// land within a second of some offset by luck (gibberish from speech in
    /// another language was applied 5 times in 40). The chance of that many
    /// in one band, times the bands they could have landed in, must be small.
    static func beatsChance(_ found: Int, among window: [Point]) -> Bool {
        let offsets = window.map { $0.heard - $0.cue }
        let range = max(2 * spread, (offsets.max() ?? 0) - (offsets.min() ?? 0))
        let bands = range / (2 * spread)
        // The background is the matches outside the peak: a stretch where nearly
        // every match agrees has little scatter, which isn't chance.
        let expected = Double(max(0, window.count - found)) / max(1, bands)
        // P(at least `found` in a band) for a Poisson count with that mean.
        var term = exp(-expected), below = 0.0
        for i in 0..<found {
            below += term
            term *= expected / Double(i + 1)
        }
        return max(0, 1 - below) * bands < 0.01
    }

    /// The stretch at the playhead (or nearest it); the one with the most matches when it isn't known.
    static func nearest(_ stretches: [Stretch], to playhead: TimeInterval?) -> Stretch? {
        guard let playhead else { return stretches.max { $0.points.count < $1.points.count } }
        func distance(_ s: Stretch) -> TimeInterval {
            let times = s.points.map(\.heard)
            let lo = times.min() ?? 0, hi = times.max() ?? 0
            return playhead < lo ? lo - playhead : playhead > hi ? playhead - hi : 0
        }
        return stretches.min { distance($0) < distance($1) }
    }

    /// Matches split by stretch listened to, and within one where nothing was
    /// heard for a minute. Close stretches used to merge (a torrent's first
    /// minutes, under a minute apart), so drift was never fitted there and a
    /// delay was set from the middle of a slope: −6 s for subtitles made for
    /// 25 fps, lines up to 283 s off by the end.
    static func windows(_ matches: [Match]) -> [[Point]] {
        var out: [[Point]] = []
        for (_, group) in Dictionary(grouping: matches, by: \.clip).sorted(by: { $0.key < $1.key }) {
            var last: TimeInterval?
            for m in group.sorted(by: { $0.heard < $1.heard }) {
                if let last, m.heard - last <= 60 { out[out.count - 1].append((m.cue, m.heard)) } else { out.append([(m.cue, m.heard)]) }
                last = m.heard
            }
        }
        return out
    }

    /// The matches that agree on the most common offset (heard − cue), one
    /// per heard word, and the line they follow when they show a slope.
    static func agreeing(_ matches: [Point]) -> Stretch {
        var votes: [Int: Int] = [:]
        for m in matches { votes[Int(((m.heard - m.cue) / bin).rounded()), default: 0] += 1 }
        // Neighbouring bins together, so an offset on a bin edge isn't split.
        func weight(_ k: Int) -> Int { (votes[k - 1] ?? 0) + (votes[k] ?? 0) + (votes[k + 1] ?? 0) }
        guard let best = votes.keys.max(by: { weight($0) == weight($1) ? abs($0) > abs($1) : weight($0) < weight($1) }) else { return ([], nil) }
        let peak = Double(best) * bin
        var expected: (TimeInterval) -> TimeInterval = { $0 + peak }
        var near = matches.filter { abs($0.heard - expected($0.cue)) <= spread }
        var line: (k: Double, b: Double)?
        // Drift shows within a stretch: follow the slope the agreeing words
        // show, and gather again along it (a plausible slope, and a clear one:
        // a few noisy words tilt a line by chance).
        let cues = near.map(\.cue)
        if (cues.max() ?? 0) - (cues.min() ?? 0) >= 20, let fit = lineFit(near), abs(fit.k - 1) <= 0.06,
           abs(fit.k - 1) > 3 * slopeError(near, fit) {
            let along = matches.filter { abs($0.heard - (fit.k * $0.cue + fit.b)) <= spread }
            if along.count >= near.count, let refit = lineFit(along), abs(refit.k - 1) <= 0.06 {
                near = along
                line = refit
                expected = { refit.k * $0 + refit.b }
            }
        }
        let points = Dictionary(grouping: near, by: { $0.heard }).values.compactMap { group in
            group.min { abs($0.heard - expected($0.cue)) < abs($1.heard - expected($1.cue)) }
        }
        return (points, line)
    }

    /// A line usually stays up a little after the voice stops: this much of
    /// its end (at most 30% of it) isn't spoken.
    static let linger: TimeInterval = 0.3

    /// Words of each cue, each at its middle, spread across the part of the
    /// cue that's spoken by their length. Spread evenly to the very end, the
    /// words sat late (a recording's lines measured 0.3 s early after syncing).
    static func cueWords(_ cues: [SubtitleCue]) -> [(String, TimeInterval)] {
        var out: [(String, TimeInterval)] = []
        for c in cues {
            let words = normalizedWords(c.text)
            guard !words.isEmpty else { continue }
            let duration = c.end - c.start
            let spoken = max(duration * 0.7, duration - linger)
            // A space's worth each, so short words still take a moment.
            let total = Double(words.reduce(0) { $0 + $1.count + 1 })
            var before = 0.0
            for w in words {
                let length = Double(w.count + 1)
                out.append((w, c.start + spoken * (before + length / 2) / total))
                before += length
            }
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

    /// The language the lines are written in ("en", "fr"), read from their
    /// text, for the recogniser: a track's tag can be missing or wrong, and
    /// listening for English to match French lines finds nothing. Nil when
    /// there's too little text to tell.
    public static func language(of cues: [SubtitleCue]) -> String? {
        // A spread of lines from across the file is plenty.
        let text = Swift.stride(from: 0, to: cues.count, by: max(1, cues.count / 200))
            .compactMap { SoundCues.strip(cues[$0].text) }.joined(separator: "\n")
        guard text.count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.6,
              language != .undetermined else { return nil }
        return language.rawValue
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

    /// The standard error of a fitted slope: how far the true slope may be from it.
    static func slopeError(_ points: [Point], _ line: (k: Double, b: Double)) -> Double {
        let n = Double(points.count)
        guard n > 2 else { return .infinity }
        let mx = points.map(\.cue).reduce(0, +) / n
        let sxx = points.reduce(0) { $0 + ($1.cue - mx) * ($1.cue - mx) }
        let residuals = points.reduce(0) { r, p in let e = p.heard - (line.k * p.cue + line.b); return r + e * e }
        guard sxx > 0 else { return .infinity }
        return (residuals / (n - 2)).squareRoot() / sxx.squareRoot()
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
