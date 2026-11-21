import Domain
import Foundation
import Subtitles

/// Subtitle timing kept between plays, per movie or episode and subtitle
/// track (`PlayerSession.timingKey`): a delay fixed once holds the next
/// time that file plays, and a different file starts from the default.
@MainActor
public struct SubtitleTimingMemory {
    public var load: (MediaKey, String) -> SubtitleOffset?
    /// Nil forgets the track's timing (back to the default).
    public var save: (MediaKey, String, SubtitleOffset?) -> Void

    public init(load: @escaping (MediaKey, String) -> SubtitleOffset?, save: @escaping (MediaKey, String, SubtitleOffset?) -> Void) {
        self.load = load
        self.save = save
    }
}
