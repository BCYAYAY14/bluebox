import Domain
import Subtitles

/// What the Turn On setting (`SubtitleStyle.TurnOn`) asks for when a video
/// starts with nothing chosen: the preferred language's full track, only a
/// Forced one, or wait to hear which audio plays.
public enum SubtitleTurnOnRule {
    public enum Decision: Equatable, Sendable {
        case fullTrack
        case forcedOnly
        /// The rule depends on the audio and its tracks aren't known yet.
        case waitForAudio
    }

    /// - Parameters:
    ///   - audioLanguage: the playing audio track's language; nil when it has none.
    ///   - audioKnown: the video's audio tracks are known.
    public static func decision(_ rule: SubtitleStyle.TurnOn, preferred: String, audioLanguage: String?, audioKnown: Bool) -> Decision {
        switch rule {
        case .always: return .fullTrack
        case .forcedOnly: return .forcedOnly
        case .foreignAudio:
            guard audioKnown else { return .waitForAudio }
            // Audio with no language can't be told apart: subtitles on, as before.
            guard let audioLanguage, audioLanguage != "und" else { return .fullTrack }
            return TrackChoice.normalized(audioLanguage) == TrackChoice.normalized(preferred) ? .forcedOnly : .fullTrack
        }
    }

    /// The Forced tracks among `tracks` ("English (Forced)", "eng.forced.srt").
    public static func forced(_ tracks: [MediaTrack]) -> [MediaTrack] {
        tracks.filter { TrackLabel.parse($0.label, languageCode: $0.languageCode).details.contains("Forced") }
    }
}
