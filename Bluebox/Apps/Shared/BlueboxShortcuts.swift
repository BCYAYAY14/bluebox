import AppIntents
import Features
import SystemSnapshot

// Siri, Shortcuts and Spotlight's actions: resume a title, continue watching,
// search, open My List. Each opens Bluebox on a bluebox:// link
// (SystemLink), the way a widget does. Titles come from the library snapshot
// the app writes (Features/AppModel+System.swift), so Siri can list them
// without opening the library.

/// A title in this profile's Continue Watching, Up Next or My List.
struct TitleEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Title")
    static let defaultQuery = TitleQuery()

    /// The title's `MediaKey` (the series for a show).
    let id: String
    let name: String
    let detail: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: detail.map { "\($0)" })
    }

    init(_ item: LibrarySnapshot.Item, in snapshot: LibrarySnapshot) {
        id = item.titleKey
        name = item.title
        if let resumable = snapshot.resumable(titleKey: item.titleKey) {
            detail = resumable.subtitle ?? "Continue Watching"
        } else {
            detail = "My List"
        }
    }
}

struct TitleQuery: EntityStringQuery {
    private var snapshot: LibrarySnapshot { LibrarySnapshotStore.default.read() ?? .empty }

    func entities(for identifiers: [TitleEntity.ID]) async throws -> [TitleEntity] {
        let s = snapshot
        return s.titles.filter { identifiers.contains($0.titleKey) }.map { TitleEntity($0, in: s) }
    }

    func entities(matching string: String) async throws -> [TitleEntity] {
        let s = snapshot
        return s.titles.filter { $0.title.localizedStandardContains(string) }.map { TitleEntity($0, in: s) }
    }

    /// What's in progress first: these are the titles Siri learns for "Resume …".
    func suggestedEntities() async throws -> [TitleEntity] {
        let s = snapshot
        return s.titles.prefix(30).map { TitleEntity($0, in: s) }
    }
}

/// Opens a link once the library is open (Siri may launch Bluebox to run an intent).
@MainActor
enum IntentLinks {
    static func open(_ link: SystemLink) async {
        for _ in 0..<150 {
            if let model = AppModel.current {
                model.handleOpenURL(link.url)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

struct ResumeTitleIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume a Title"
    static let description = IntentDescription("Plays a show or film from your Bluebox library where you left off. A show plays its episode in progress, or the next one.")
    static let openAppWhenRun = true

    @Parameter(title: "Title")
    var show: TitleEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let snapshot = LibrarySnapshotStore.default.read() ?? .empty
        if let item = snapshot.resumable(titleKey: show.id), let link = SystemLink(url: item.link) {
            await IntentLinks.open(link)
        } else {
            // Nothing in progress (a My List title): its page, to choose from.
            await IntentLinks.open(.title(key: show.id, episode: nil))
        }
        return .result()
    }
}

struct ContinueWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Watching"
    static let description = IntentDescription("Plays the latest thing you were watching in Bluebox.")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let item = (LibrarySnapshotStore.default.read() ?? .empty).resumeFirst,
              let link = SystemLink(url: item.link) else {
            return .result(dialog: "There's nothing to continue in Bluebox.")
        }
        await IntentLinks.open(link)
        return .result(dialog: "Playing \(item.title).")
    }
}

struct SearchBlueboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Bluebox"
    static let description = IntentDescription("Searches Bluebox for shows, films and people.")
    static let openAppWhenRun = true

    @Parameter(title: "Search For", requestValueDialog: "What do you want to search for?")
    var query: String

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await IntentLinks.open(.search(query))
        return .result()
    }
}

struct OpenMyListIntent: AppIntent {
    static let title: LocalizedStringResource = "Open My List"
    static let description = IntentDescription("Opens My List in Bluebox.")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await IntentLinks.open(.myList)
        return .result()
    }
}

/// Every phrase names the app, as Siri requires. A search query can't be part
/// of a phrase (only titles and lists can), so Siri asks for it.
struct BlueboxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeTitleIntent(), phrases: [
            "Resume \(\.$show) in \(.applicationName)",
            "Continue \(\.$show) in \(.applicationName)",
            "Play \(\.$show) in \(.applicationName)",
        ], shortTitle: "Resume a Title", systemImageName: "play.fill")
        AppShortcut(intent: ContinueWatchingIntent(), phrases: [
            "Continue watching in \(.applicationName)",
            "Resume \(.applicationName)",
        ], shortTitle: "Continue Watching", systemImageName: "play.circle")
        AppShortcut(intent: SearchBlueboxIntent(), phrases: [
            "Search \(.applicationName)",
            "Search in \(.applicationName)",
        ], shortTitle: "Search", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenMyListIntent(), phrases: [
            "Open My List in \(.applicationName)",
            "Show my list in \(.applicationName)",
        ], shortTitle: "My List", systemImageName: "plus.rectangle.on.rectangle")
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}
