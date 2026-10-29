import Foundation

/// Pure rules for combining sources and deciding what the player offers.
public enum SkipSegmentPlanner {
    /// Combines source results, best source first. Each kind comes from the
    /// best source that has it: a file whose chapters mark the credits but not
    /// the intro still gets the intro from a crowd source.
    public static func merge(_ results: [[SkipSegment]], duration: TimeInterval?) -> [SkipSegment] {
        var chosen: [SkipSegment.Kind: [SkipSegment]] = [:]
        let all = results.flatMap { validated($0, duration: duration) }
        for kind in SkipSegment.Kind.allCases {
            let ofKind = all.filter { $0.kind == kind }
            guard let best = ofKind.map(\.source).min() else { continue }
            chosen[kind] = ofKind.filter { $0.source == best }
        }
        return chosen.values.flatMap { $0 }.sorted { $0.start < $1.start }
    }

    /// Drops timestamps that can't belong to this file, and clamps the rest.
    /// Crowd timestamps for a different cut (say, 10 minutes longer) would
    /// otherwise skip into the middle of a scene.
    static func validated(_ segments: [SkipSegment], duration: TimeInterval?) -> [SkipSegment] {
        segments.compactMap { s in
            var s = s
            guard s.start.isFinite, s.start >= 0 else { return nil }
            if let end = s.end, !(end.isFinite && end > s.start) { return nil }
            guard let duration, duration > 0 else { return s }
            guard s.start < duration - 1 else { return nil }
            if let end = s.end, end > duration {
                // A little past the end is rounding; far past it is another release.
                if end - duration > 15 { return nil }
                s.end = nil
            }
            // An intro or recap longer than a third of the file is a mistake.
            if s.kind == .intro || s.kind == .recap, (s.resolvedEnd(duration: duration) ?? duration) - s.start > duration / 3 {
                return nil
            }
            return s
        }
    }

    /// True when the local sources leave out something crowd sources may know.
    public static func needsCrowdSources(_ local: [SkipSegment], isEpisode: Bool) -> Bool {
        let kinds = Set(local.map(\.kind))
        let hasOpening = kinds.contains(.intro)
        let hasEnd = kinds.contains(.credits)
        return isEpisode ? !(hasOpening && hasEnd) : !hasEnd
    }

    /// The segment the playhead is in, if any. Preview counts as credits
    /// territory for the "Next Episode" offer.
    public static func active(at position: TimeInterval, in segments: [SkipSegment], duration: TimeInterval?) -> SkipSegment? {
        segments.last { $0.contains(position, duration: duration) }
    }

    // MARK: What to show

    public enum Mode: String, Codable, CaseIterable, Sendable, Identifiable {
        case off
        /// Show a "Skip Intro" (or "Next Episode") button.
        case button
        /// Skip without asking.
        case automatic
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .off: "Off"
            case .button: "Show Button"
            case .automatic: "Automatic"
            }
        }
    }

    public enum Offer: Equatable, Sendable {
        /// Seek to `to` (end of the intro or recap, or of mid-film credits).
        case skip(SkipSegment.Kind, to: TimeInterval)
        /// Credits of an episode with a next one.
        case nextEpisode
    }

    /// The mode for each part. Recaps have their own, so "always skip the
    /// recap" doesn't have to mean the intro too.
    public struct Modes: Equatable, Sendable {
        public var intro: Mode
        public var recap: Mode
        public var credits: Mode
        public init(intro: Mode, recap: Mode, credits: Mode) {
            self.intro = intro; self.recap = recap; self.credits = credits
        }
    }

    /// What the player should offer at `position`. `autoTriggered` says the
    /// offer should be taken without a press (Automatic mode).
    public static func offer(at position: TimeInterval, segments: [SkipSegment], duration: TimeInterval?,
                             introMode: Mode, creditsMode: Mode, hasNextEpisode: Bool) -> (Offer, auto: Bool)? {
        offer(at: position, segments: segments, duration: duration,
              modes: Modes(intro: introMode, recap: introMode, credits: creditsMode), hasNextEpisode: hasNextEpisode)
    }

    /// As above, with a mode per part. `autoplayNext` is the profile's
    /// Autoplay Next Episode: with it off, Automatic credits still offer
    /// "Next Episode" but never move on by themselves.
    public static func offer(at position: TimeInterval, segments: [SkipSegment], duration: TimeInterval?,
                             modes: Modes, hasNextEpisode: Bool, autoplayNext: Bool = true) -> (Offer, auto: Bool)? {
        guard let s = active(at: position, in: segments, duration: duration) else { return nil }
        switch s.kind {
        case .intro, .recap:
            let mode = s.kind == .intro ? modes.intro : modes.recap
            guard mode != .off, let end = s.resolvedEnd(duration: duration) else { return nil }
            // Not worth a button in the last two seconds of it.
            guard end - position > 2 else { return nil }
            return (.skip(s.kind, to: end), mode == .automatic)
        case .credits, .preview:
            guard modes.credits != .off else { return nil }
            if hasNextEpisode { return (.nextEpisode, modes.credits == .automatic && autoplayNext) }
            // A film: only worth skipping when something follows the credits
            // (a mid-credits scene), not when they run to the end.
            guard let end = s.end, let duration, duration - end > 20, end - position > 2 else { return nil }
            return (.skip(.credits, to: end), modes.credits == .automatic)
        }
    }

    /// The button's title.
    public static func title(for offer: Offer) -> String {
        switch offer {
        case .skip(.intro, _): "Skip Intro"
        case .skip(.recap, _): "Skip Recap"
        case .skip(.preview, _): "Skip Preview"
        case .skip(.credits, _): "Skip Credits"
        case .nextEpisode: "Next Episode"
        }
    }
}
