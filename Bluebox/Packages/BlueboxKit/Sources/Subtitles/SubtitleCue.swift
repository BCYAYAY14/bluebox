import Foundation

public struct SubtitleCue: Hashable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    /// Plain text with line breaks; markup is stripped by the parser.
    public let text: String
    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

public enum SubtitleFormat: String, Sendable, CaseIterable {
    case srt, webVTT = "vtt", ass

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "srt": self = .srt
        case "vtt", "webvtt": self = .webVTT
        case "ass", "ssa": self = .ass
        default: return nil
        }
    }
}

public enum SubtitleError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedFormat(String)
    case unreadable
    case empty

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let f): "Subtitle format “\(f)” isn't supported yet."
        case .unreadable: "The subtitle file couldn't be read."
        case .empty: "The subtitle file has no cues."
        }
    }
}

/// Subtitle timing: a delay plus an optional speed factor, so the cue time for
/// player time `t` is `(t - seconds) * scale`.
///
/// A positive delay shows subtitles *later* (use when text appears before the
/// speech). `scale` fixes subtitles made for a different frame rate (e.g. 25 fps
/// PAL subtitles on a 23.976 fps video) or that drift steadily out of sync.
public struct SubtitleOffset: Hashable, Sendable, Codable {
    public static let step: TimeInterval = 0.1
    public static let coarseStep: TimeInterval = 1.0
    public static let limit: TimeInterval = 600
    public static let scaleRange: ClosedRange<Double> = 0.8...1.25

    public private(set) var seconds: TimeInterval
    public private(set) var scale: Double

    public init(seconds: TimeInterval = 0, scale: Double = 1) {
        self.seconds = Self.clamp(seconds)
        self.scale = Self.clampScale(scale)
    }

    public mutating func nudge(by delta: TimeInterval) { seconds = Self.clamp(seconds + delta) }
    public mutating func reset() { seconds = 0; scale = 1 }

    /// Converts a player time into the time to look up in the cue list.
    public func cueTime(forPlayerTime t: TimeInterval) -> TimeInterval { (t - seconds) * scale }

    /// Player time at which a cue time is shown.
    public func playerTime(forCueTime c: TimeInterval) -> TimeInterval { c / scale + seconds }

    /// Sets the speed for subtitles timed to `subtitleFPS` on a `videoFPS` video.
    public mutating func convertFrameRate(subtitleFPS: Double, videoFPS: Double) {
        guard subtitleFPS > 0, videoFPS > 0 else { return }
        let anchor = playerTime(forCueTime: 0)
        scale = Self.clampScale(videoFPS / subtitleFPS)
        seconds = Self.clamp(anchor)
    }

    public mutating func setScale(_ s: Double) { scale = Self.clampScale(s) }

    /// "Sync this line": the cue starting at `cueStart` was heard at `playerTime`.
    public mutating func align(cueStart: TimeInterval, to playerTime: TimeInterval) {
        seconds = Self.clamp(playerTime - cueStart / scale)
    }

    /// Two-point sync from two lines and when each was heard. Returns false
    /// (and changes nothing) when the points don't give a plausible fit.
    @discardableResult
    public mutating func align(_ first: (cue: TimeInterval, heard: TimeInterval),
                               _ second: (cue: TimeInterval, heard: TimeInterval)) -> Bool {
        let dt = second.heard - first.heard, dc = second.cue - first.cue
        guard abs(dt) >= 10, dc != 0 else { return false }
        let a = dc / dt
        guard Self.scaleRange.contains(a) else { return false }
        scale = a
        seconds = Self.clamp(first.heard - first.cue / a)
        return true
    }

    /// "+0.3 s", "−1.5 s", "0.0 s", with the speed when it isn't 1×.
    public var label: String {
        let rounded = (seconds * 10).rounded() / 10
        var text: String
        if rounded == 0 { text = "0.0 s" }
        else {
            let mag = String(format: "%.1f", abs(rounded))
            text = rounded > 0 ? "+\(mag) s" : "−\(mag) s"
        }
        if abs(scale - 1) > 0.0005 { text += String(format: " · %.3f×", scale) }
        return text
    }

    public var isDefault: Bool { seconds == 0 && scale == 1 }

    static func clamp(_ s: TimeInterval) -> TimeInterval {
        guard s.isFinite else { return 0 }
        // Round to milliseconds so repeated 0.1 nudges don't accumulate float error.
        return (min(max(s, -limit), limit) * 1000).rounded() / 1000
    }

    static func clampScale(_ s: Double) -> Double {
        guard s.isFinite else { return 1 }
        return (min(max(s, scaleRange.lowerBound), scaleRange.upperBound) * 100_000).rounded() / 100_000
    }

    enum CodingKeys: String, CodingKey { case seconds, scale }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(seconds: try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0,
                  scale: try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1)
    }
}

/// A parsed subtitle file with fast time lookup.
public struct SubtitleTimeline: Sendable, Hashable {
    public let cues: [SubtitleCue]   // sorted by start
    /// `latestEnd[i]` is the latest end time among `cues[0...i]`, so a lookup knows
    /// how far back a still-visible cue can be (a sign shown for minutes while
    /// dozens of dialogue lines come and go).
    private let latestEnd: [TimeInterval]

    public init(cues: [SubtitleCue]) {
        self.cues = cues.filter { $0.end > $0.start }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var running = -TimeInterval.infinity
        latestEnd = self.cues.map { running = max(running, $0.end); return running }
    }

    public static func == (a: Self, b: Self) -> Bool { a.cues == b.cues }
    public func hash(into h: inout Hasher) { h.combine(cues) }

    /// Cues visible at `playerTime` after applying `offset`. Overlapping cues
    /// are all returned, in start order.
    public func cues(at playerTime: TimeInterval, offset: SubtitleOffset = .init()) -> [SubtitleCue] {
        let t = offset.cueTime(forPlayerTime: playerTime)
        // Binary search for the first cue starting after t; walk back over candidates.
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        var result: [SubtitleCue] = []
        var i = lo - 1
        // Walk back while some earlier cue could still be on screen.
        while i >= 0, latestEnd[i] > t {
            if cues[i].start <= t, t < cues[i].end { result.append(cues[i]) }
            i -= 1
        }
        return result.reversed()
    }

    /// Cues around the current moment, for picking the line you just heard.
    public func cues(near playerTime: TimeInterval, offset: SubtitleOffset, before: Int = 6, after: Int = 6) -> [SubtitleCue] {
        let t = offset.cueTime(forPlayerTime: playerTime)
        let idx = cues.firstIndex { $0.start > t } ?? cues.count
        return Array(cues[max(0, idx - before)..<min(cues.count, idx + after)])
    }

    /// When a line next comes or goes after `playerTime`, on the player's clock.
    public func nextChange(after playerTime: TimeInterval, offset: SubtitleOffset = .init()) -> TimeInterval? {
        let t = offset.cueTime(forPlayerTime: playerTime)
        // The next start after t, and the earliest end after t among lines already started.
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        var next = lo < cues.count ? cues[lo].start : TimeInterval.infinity
        var i = lo - 1
        while i >= 0, latestEnd[i] > t {
            if cues[i].end > t { next = min(next, cues[i].end) }
            i -= 1
        }
        return next.isFinite ? offset.playerTime(forCueTime: next) : nil
    }

    public func text(at playerTime: TimeInterval, offset: SubtitleOffset = .init()) -> String? {
        let c = cues(at: playerTime, offset: offset)
        return c.isEmpty ? nil : c.map(\.text).joined(separator: "\n")
    }
}
