import Foundation

/// Spoiler guard (Settings › Privacy & Features): with it on, an episode you
/// haven't watched yet keeps its still blurred and its synopsis hidden until
/// you reveal it. Pure rules; the views apply them.
public enum SpoilerGuard {
    /// Once you're this far into an episode you've seen its opening, so its
    /// still and synopsis are no longer a spoiler.
    public static let startedAfter: TimeInterval = 120

    /// True when the episode's still and synopsis should be hidden.
    /// - Parameters:
    ///   - isOn: the profile's spoiler guard switch.
    ///   - progress: the episode's progress, if any.
    ///   - revealed: you asked to see this one.
    public static func hides(isOn: Bool, progress: WatchProgress?, revealed: Bool = false) -> Bool {
        guard isOn, !revealed else { return false }
        guard let progress else { return true }
        return !(progress.isCompleted || progress.position >= startedAfter)
    }
}
