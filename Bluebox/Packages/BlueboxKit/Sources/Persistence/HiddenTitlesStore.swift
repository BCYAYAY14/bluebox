import Domain
import Foundation

/// A title someone chose "Not Interested" on.
public struct HiddenTitle: Codable, Hashable, Sendable, Identifiable {
    public let title: Title
    public let hiddenAt: Date
    public var id: MediaKey { title.key }

    public init(title: Title, hiddenAt: Date) {
        self.title = title; self.hiddenAt = hiddenAt
    }
}

/// Each profile's Hidden Titles ("Not Interested" on a poster), kept in
/// preferences. Discovery rows on Home leave these out; Search and My List
/// still show them. Settings › Hidden Titles lists them and un-hides.
public final class HiddenTitlesStore: @unchecked Sendable {
    private let prefs: PreferencesStore
    private let lock = NSLock()

    public init(prefs: PreferencesStore) { self.prefs = prefs }

    static func key(_ profileID: String) -> String { "bluebox.hiddenTitles.\(profileID)" }

    /// Newest first.
    public func all(profileID: String) -> [HiddenTitle] {
        lock.withLock { read(profileID) }.sorted { $0.hiddenAt > $1.hiddenAt }
    }

    public func keys(profileID: String) -> Set<MediaKey> {
        Set(lock.withLock { read(profileID) }.map(\.title.key))
    }

    public func hide(_ title: Title, profileID: String, at date: Date = .now) {
        lock.withLock {
            var list = read(profileID).filter { $0.title.key != title.key }
            list.append(HiddenTitle(title: title, hiddenAt: date))
            prefs.set(list, for: Self.key(profileID))
        }
    }

    public func unhide(_ key: MediaKey, profileID: String) {
        lock.withLock {
            let list = read(profileID).filter { $0.title.key != key }
            prefs.set(list.isEmpty ? nil : list, for: Self.key(profileID))
        }
    }

    /// A profile was deleted.
    public func removeAll(profileID: String) {
        lock.withLock { prefs.set([HiddenTitle]?.none, for: Self.key(profileID)) }
    }

    private func read(_ profileID: String) -> [HiddenTitle] {
        prefs.value([HiddenTitle].self, for: Self.key(profileID)) ?? []
    }
}
