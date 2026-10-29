import Foundation

/// Which source and variant last played a movie, episode or series, so
/// playing it again (Continue Watching, Resume, the next episode) uses the
/// same source instead of whichever happens to be listed first.
public struct LastPlayedSource: Hashable, Codable, Sendable {
    public var sourceID: SourceID
    public var variantID: String
    public var playedAt: Date

    public init(sourceID: SourceID, variantID: String, playedAt: Date) {
        self.sourceID = sourceID; self.variantID = variantID; self.playedAt = playedAt
    }
}

public enum VariantChooser {
    /// Picks the variant to play.
    ///
    /// Preference order: a downloaded copy; the exact variant that last played this item; any
    /// variant from the source that last played this item; any variant from the
    /// source that last played the series (for episodes); then the first one the
    /// engine can attempt; then the first one at all. Registry order (the user's
    /// source order) breaks ties within each step.
    public static func choose(
        from variants: [MediaVariant], item: LastPlayedSource?, series: LastPlayedSource? = nil,
        canAttempt: (MediaVariant) -> Bool
    ) -> MediaVariant? {
        let playable = variants.filter(canAttempt)
        // A downloaded copy plays offline and starts instantly.
        if let saved = playable.first(where: { $0.location == .downloaded }) { return saved }
        if let item {
            if let exact = playable.first(where: { $0.sourceID == item.sourceID && $0.id == item.variantID }) { return exact }
            if let sameSource = playable.first(where: { $0.sourceID == item.sourceID }) { return sameSource }
        }
        if let series, let sameSource = playable.first(where: { $0.sourceID == series.sourceID }) { return sameSource }
        return playable.first ?? variants.first
    }
}
