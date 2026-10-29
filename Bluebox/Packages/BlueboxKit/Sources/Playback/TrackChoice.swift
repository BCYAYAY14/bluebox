import Foundation

/// An audio or subtitle choice, kept so the next episode can pick the same
/// kind of track: the language first, then the variant (SDH, Forced,
/// Commentary, Audio Description) where the new file has it.
public struct TrackChoice: Equatable, Sendable {
    /// ISO 639-1 where known ("en"); nil when the track had no language.
    public var languageCode: String?
    /// Subtitles turned off.
    public var isOff = false
    public var details: Set<String> = []
    /// Position in the list it was picked from: the fallback for tracks with no language.
    public var index: Int?

    public static let off = TrackChoice(isOff: true)

    public init(languageCode: String? = nil, isOff: Bool = false, details: Set<String> = [], index: Int? = nil) {
        self.languageCode = languageCode.map(Self.normalized); self.isOff = isOff; self.details = details; self.index = index
    }

    public init(_ track: MediaTrack, index: Int? = nil) {
        let label = TrackLabel.parse(track.label, languageCode: track.languageCode)
        self.init(languageCode: label.languageCode ?? track.languageCode, details: Set(label.details).intersection(Self.variants),
                  index: index)
    }

    /// The details that make a different track of the same language.
    static let variants: Set<String> = ["SDH", "Forced", "Commentary", "Audio Description", "Signs & Songs"]

    public static func normalized(_ code: String) -> String {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? code.lowercased()
        return Locale.LanguageCode(base).identifier(.alpha2) ?? TrackLabel.bibliographic[base] ?? base
    }

    /// The closest track in `tracks`: same language, then the same variant
    /// (an SDH choice prefers SDH; a plain choice avoids Forced and Commentary).
    public func best(in tracks: [MediaTrack]) -> MediaTrack? {
        guard !isOff, !tracks.isEmpty else { return nil }
        let scored = tracks.enumerated().compactMap { i, t -> (MediaTrack, Int)? in
            let label = TrackLabel.parse(t.label, languageCode: t.languageCode)
            let code = (label.languageCode ?? t.languageCode).map(Self.normalized)
            if let languageCode {
                guard code == languageCode else { return nil }
            } else if i != index {
                return nil
            }
            let theirs = Set(label.details).intersection(Self.variants)
            // Every variant in common counts; every one that differs costs more.
            let score = theirs.intersection(details).count * 4 - theirs.symmetricDifference(details).count * 3 - (i == index ? 0 : 1)
            return (t, score)
        }
        return scored.max { $0.1 < $1.1 }?.0
    }
}
