import Metadata
import Playback

/// Settings › Subtitles › Search Automatically: when a video starts with
/// nothing in your language, every site that's on is asked (with the release
/// playing, so a file made for it comes first) and the best is downloaded.
enum AutoSubtitleSearch {
    /// The language to look for, or nil when nothing should be searched: Off
    /// chosen for the show, or Turn On asking only for a Forced track (sites
    /// rarely mark those). A language picked for the show beats the preferred one.
    static func language(preferred: String?, remembered: TrackChoice?, rule: SubtitleTurnOnRule.Decision?) -> String? {
        if remembered?.isOff == true || rule == .forcedOnly { return nil }
        return remembered?.languageCode ?? preferred
    }

    /// The first result in the language from `results` in `SubtitleSearchMerge`
    /// order: made by a person before machine-translated, a file made for this
    /// release first, then the closest release name and the most downloaded.
    static func best(_ results: [OnlineSubtitle], language: String) -> OnlineSubtitle? {
        results.first { $0.language.map { AppModel.sameLanguage($0, language) } ?? false }
    }
}
