import Foundation

/// The audio and subtitle choices a profile made for each show (the series
/// for episodes, the film itself otherwise), so the next episode starts with
/// them even when it opens a new player. A session's own choices
/// (`PlayerSession.rememberedAudio`) only last while that player is open.
/// Ahead of the preferred languages: a show watched in Japanese with subtitles
/// Off stays that way though the profile likes English subtitles elsewhere.
public struct ShowTrackMemory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var audio: TrackChoice?
        public var subtitle: TrackChoice?
        public var chosenAt: Date

        public init(audio: TrackChoice? = nil, subtitle: TrackChoice? = nil, chosenAt: Date) {
            self.audio = audio; self.subtitle = subtitle; self.chosenAt = chosenAt
        }
    }

    public private(set) var shows: [String: Entry] = [:]
    /// The most recent shows kept; a convenience, not history.
    public static let limit = 300

    public init() {}

    public func entry(for show: String) -> Entry? { shows[show] }

    /// Keeps what was chosen for `show`; nil leaves that part as it was (a
    /// person who only changed the audio keeps the subtitles they had).
    public mutating func remember(audio: TrackChoice?, subtitle: TrackChoice?, for show: String, at date: Date = .now) {
        guard audio != nil || subtitle != nil else { return }
        var e = shows[show] ?? Entry(chosenAt: date)
        if let audio { e.audio = audio }
        if let subtitle { e.subtitle = subtitle }
        e.chosenAt = date
        shows[show] = e
        if shows.count > Self.limit {
            shows = Dictionary(uniqueKeysWithValues: shows.sorted { $0.value.chosenAt > $1.value.chosenAt }.prefix(Self.limit).map { ($0.key, $0.value) })
        }
    }
}
