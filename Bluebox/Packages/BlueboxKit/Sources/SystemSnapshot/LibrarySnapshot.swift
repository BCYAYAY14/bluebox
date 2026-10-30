import Foundation

/// What Bluebox shows outside itself: the current profile's Continue
/// Watching, next episodes and My List, written by the app whenever the
/// library changes (`AppModel+System.swift`) and read by the widgets and Siri.
public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Hashable, Sendable, Identifiable {
        /// The `MediaKey` raw value of what plays (an episode for a show).
        public var key: String
        /// The title's own key: the series for an episode.
        public var titleKey: String
        public var title: String
        /// "S1·E2", "S1·E3 · New Episode"; nil for a film.
        public var subtitle: String?
        /// 0…1, nil when not started (a next episode) or unknown.
        public var progress: Double?
        public var minutesLeft: Int?
        /// A poster file in the snapshot's folder (`LibrarySnapshotStore.thumbnailURL`).
        public var thumbnail: String?
        public var isNew: Bool
        /// Opens it: a `SystemLink`.
        public var link: URL

        public var id: String { key }

        public init(key: String, titleKey: String, title: String, subtitle: String? = nil, progress: Double? = nil,
                    minutesLeft: Int? = nil, thumbnail: String? = nil, isNew: Bool = false, link: URL) {
            self.key = key; self.titleKey = titleKey; self.title = title; self.subtitle = subtitle
            self.progress = progress; self.minutesLeft = minutesLeft; self.thumbnail = thumbnail
            self.isNew = isNew; self.link = link
        }
    }

    public static let version = 1

    public var version: Int
    public var generatedAt: Date
    /// In progress, newest first (films and episodes).
    public var continueWatching: [Item]
    /// Next episodes of shows you're watching, new airings first.
    public var upNext: [Item]
    /// My List, newest first (titles; no progress).
    public var myList: [Item]

    public init(generatedAt: Date = .now, continueWatching: [Item] = [], upNext: [Item] = [], myList: [Item] = []) {
        self.version = Self.version
        self.generatedAt = generatedAt
        self.continueWatching = continueWatching; self.upNext = upNext; self.myList = myList
    }

    public static let empty = LibrarySnapshot(generatedAt: .distantPast)

    /// Every title once (Continue Watching first), for Siri's title entities.
    public var titles: [Item] {
        var seen = Set<String>()
        return (continueWatching + upNext + myList).filter { seen.insert($0.titleKey).inserted }
    }

    /// The first thing to resume: the newest in progress, else the first next episode.
    public var resumeFirst: Item? { continueWatching.first ?? upNext.first }

    /// What there is to resume for one title (a show's episode in progress or next).
    public func resumable(titleKey: String) -> Item? {
        (continueWatching + upNext).first { $0.titleKey == titleKey }
    }

    /// One Spotlight result. Its `id` is the link it opens, so a result
    /// needs nothing else to find its way back.
    public struct SpotlightEntry: Equatable, Sendable {
        public var id: String { item.link.absoluteString }
        public let item: Item
        /// "Continue Watching", "Up Next", "New Episode", "My List", "Downloads".
        public let detail: String

        public var displayName: String { item.subtitle.map { "\(item.title) · \($0)" } ?? item.title }
        public var contentDescription: String { [item.subtitle, detail].compactMap { $0 }.joined(separator: " · ") }
    }

    /// Everything Bluebox puts in Spotlight: the snapshot's rows and finished
    /// downloads, each link once (the first row it's in wins). Spotlight is
    /// replaced with exactly this set, so a title that leaves them leaves
    /// Spotlight too.
    public func spotlightEntries(downloads: [Item] = []) -> [SpotlightEntry] {
        var seen = Set<String>()
        var entries: [SpotlightEntry] = []
        func add(_ items: [Item], _ detail: (Item) -> String) {
            for item in items where seen.insert(item.link.absoluteString).inserted {
                entries.append(SpotlightEntry(item: item, detail: detail(item)))
            }
        }
        add(continueWatching) { _ in "Continue Watching" }
        add(upNext) { $0.isNew ? "New Episode" : "Up Next" }
        add(myList) { _ in "My List" }
        add(downloads) { _ in "Downloads" }
        return entries
    }
}

/// Where the snapshot lives. In the App Group container when the build has
/// one (signed with `group.app.bluebox.Bluebox`), so the widget extension can
/// read it; otherwise in the app's own Application Support, where Siri and
/// Spotlight (in the app's process) still can, and the widgets show their
/// placeholder. Sideloaded and ad-hoc signed builds have no App Group.
public struct LibrarySnapshotStore: Sendable {
    public static let appGroup = "group.app.bluebox.Bluebox"

    public let folder: URL
    /// True when `folder` is shared with the widget extension.
    public let isShared: Bool

    public init(folder: URL, isShared: Bool) {
        self.folder = folder; self.isShared = isShared
    }

    /// The App Group's folder, or nil where the build isn't entitled to it.
    /// Never on the Mac, which has no widgets yet: there the container's path
    /// comes back unentitled too, and touching it asks to "access data from
    /// other apps" (macOS 15).
    public static var shared: LibrarySnapshotStore? {
        #if os(macOS)
        return nil
        #else
        let groups = appGroupCandidates(info: Bundle.main.infoDictionary ?? [:])
        guard let container = groups.lazy.compactMap({
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }).first else { return nil }
        return LibrarySnapshotStore(folder: container.appending(path: "Library/Application Support/SystemSnapshot", directoryHint: .isDirectory),
                                    isShared: true)
        #endif
    }

    /// Ours first, then the groups a sideloading tool renamed it to. A
    /// re-signed build can't keep `group.app.bluebox.Bluebox` (groups belong to
    /// a team); AltStore registers its own under the user's team and lists
    /// them in each bundle's Info.plist as `ALTAppGroups`, so the app and the
    /// widgets still meet there. Other tools drop the group, and the widgets
    /// show their placeholder.
    static func appGroupCandidates(info: [String: Any]) -> [String] {
        let renamed = (info["ALTAppGroups"] as? [String] ?? []).filter { $0.hasPrefix("group.") && $0 != appGroup }
        return [appGroup] + renamed
    }

    /// The App Group when there is one, else the app's own folder.
    public static var `default`: LibrarySnapshotStore {
        if let shared { return shared }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LibrarySnapshotStore(folder: support.appending(path: "Bluebox/SystemSnapshot", directoryHint: .isDirectory), isShared: false)
    }

    var fileURL: URL { folder.appending(path: "snapshot.json") }
    var thumbnailFolder: URL { folder.appending(path: "Thumbnails", directoryHint: .isDirectory) }

    /// The saved snapshot; nil when there's none yet (or it's from another version).
    public func read() -> LibrarySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(LibrarySnapshot.self, from: data),
              snapshot.version == LibrarySnapshot.version else { return nil }
        return snapshot
    }

    /// Saves it, and deletes posters it no longer uses.
    public func write(_ snapshot: LibrarySnapshot) throws {
        try FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        let used = Set((snapshot.continueWatching + snapshot.upNext + snapshot.myList).compactMap(\.thumbnail))
        for file in (try? FileManager.default.contentsOfDirectory(atPath: thumbnailFolder.path)) ?? [] where !used.contains(file) {
            try? FileManager.default.removeItem(at: thumbnailFolder.appending(path: file))
        }
    }

    /// Profile switch and Erase All Data: nothing of the last profile stays behind.
    public func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    public func thumbnailURL(_ name: String) -> URL { thumbnailFolder.appending(path: name) }

    /// The file name a title's poster is kept under.
    public static func thumbnailName(for titleKey: String) -> String {
        titleKey.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined() + ".jpg"
    }

    /// Writes a poster (already small) for a title, returning its name.
    public func saveThumbnail(_ data: Data, for titleKey: String) throws -> String {
        try FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
        let name = Self.thumbnailName(for: titleKey)
        try data.write(to: thumbnailURL(name), options: .atomic)
        return name
    }

    public func hasThumbnail(for titleKey: String) -> Bool {
        FileManager.default.fileExists(atPath: thumbnailURL(Self.thumbnailName(for: titleKey)).path)
    }
}
