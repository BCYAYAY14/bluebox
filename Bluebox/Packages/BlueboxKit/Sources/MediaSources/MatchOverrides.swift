import Domain
import Foundation

/// What the user said a file is (Fix Match), instead of what its name matched.
public enum MatchOverride: Hashable, Codable, Sendable {
    /// This title, film or episode.
    case title(MediaKey)
    /// Not anything in the catalog (Unmatch): the file stays unmatched.
    case unmatched

    /// The key a file with this override has.
    public var key: MediaKey? {
        if case .title(let key) = self { return key }
        return nil
    }
}

/// Fix Match choices per file, keyed by source and variant ID. Read by
/// `LocalFolderSource` and `DebridLibrarySource` before they ask the matcher;
/// the app saves them on this device (`PreferenceKey.matchOverrides`).
public final class MatchOverrides: @unchecked Sendable {
    private let lock = NSLock()
    private var byFile: [String: MatchOverride]

    public init(_ overrides: [String: MatchOverride] = [:]) { byFile = overrides }

    public static func fileKey(source: SourceID, variant: String) -> String { source.rawValue + "/" + variant }

    public func override(source: SourceID, variant: String) -> MatchOverride? {
        lock.withLock { byFile[Self.fileKey(source: source, variant: variant)] }
    }

    /// nil resets the file to its automatic match.
    public func set(_ override: MatchOverride?, source: SourceID, variant: String) {
        lock.withLock { byFile[Self.fileKey(source: source, variant: variant)] = override }
    }

    /// Everything, for saving.
    public var all: [String: MatchOverride] { lock.withLock { byFile } }
}
