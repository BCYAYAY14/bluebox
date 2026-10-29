import Foundation

/// "Always skip the intro (recap, credits) for this show": remembered per
/// show, per profile, and stronger than the global Skip Intro and Skip
/// Credits settings for that show. Pure value; `AppSettings` stores it.
public struct ShowSkipRules: Codable, Hashable, Sendable {
    /// What can be skipped for a whole show. Previews count as credits.
    public enum Part: String, Codable, CaseIterable, Sendable, Identifiable {
        case intro, recap, credits
        public var id: String { rawValue }

        public init(_ kind: SkipSegment.Kind) {
            switch kind {
            case .intro: self = .intro
            case .recap: self = .recap
            case .credits, .preview: self = .credits
            }
        }

        public var title: String {
            switch self {
            case .intro: "Intro"
            case .recap: "Recap"
            case .credits: "Credits"
            }
        }
    }

    /// Show (or film) key → the parts always skipped.
    public var always: [String: Set<Part>] = [:]
    /// "show|part" pairs whose "Always for this show" was already offered.
    /// It's offered once, the first time that part comes up for a show, so
    /// the pill doesn't nag.
    public var offered: Set<String> = []

    public init(always: [String: Set<Part>] = [:], offered: Set<String> = []) {
        self.always = always; self.offered = offered
    }

    public func alwaysSkips(_ part: Part, show: String) -> Bool { always[show]?.contains(part) ?? false }

    public mutating func setAlways(_ on: Bool, _ part: Part, show: String) {
        var parts = always[show] ?? []
        if on { parts.insert(part) } else { parts.remove(part) }
        always[show] = parts.isEmpty ? nil : parts
        offered.insert(Self.offerID(part, show))
    }

    /// Forgets every rule for a show (Settings › Player › Always Skipping › Remove).
    public mutating func removeShow(_ show: String) { always[show] = nil }

    /// True when the pill should offer "Always for this show" for this part.
    public func shouldOffer(_ part: Part, show: String) -> Bool {
        !alwaysSkips(part, show: show) && !offered.contains(Self.offerID(part, show))
    }

    public mutating func markOffered(_ part: Part, show: String) {
        offered.insert(Self.offerID(part, show))
        // A long-lived install collects these; the oldest don't matter.
        if offered.count > 3000 { offered = Set(offered.sorted().suffix(2000)) }
    }

    /// The modes for one show: a part it always skips is Automatic, whatever
    /// the global setting says; everything else follows the global setting.
    public func modes(show: String, defaults: SkipSegmentPlanner.Modes) -> SkipSegmentPlanner.Modes {
        var m = defaults
        if alwaysSkips(.intro, show: show) { m.intro = .automatic }
        if alwaysSkips(.recap, show: show) { m.recap = .automatic }
        if alwaysSkips(.credits, show: show) { m.credits = .automatic }
        return m
    }

    static func offerID(_ part: Part, _ show: String) -> String { "\(show)|\(part.rawValue)" }
}
