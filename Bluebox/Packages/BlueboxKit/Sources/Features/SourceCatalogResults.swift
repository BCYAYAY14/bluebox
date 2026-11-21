import Domain
import Foundation

/// My Library › sources while the servers answer one by one: the groups in the
/// sources' order, each filled in when its server answers. A source still
/// answering, or one that couldn't be reached, keeps the group it showed last
/// time, so nothing blinks out while it's asked again.
struct SourceCatalogResults: Equatable {
    /// How long a source is waited for when it doesn't say (`MediaSource.answersWithin`).
    static let defaultLimit: TimeInterval = 4

    enum Outcome: Equatable {
        case loaded(LibraryView.SourceGroup)
        /// Failed, or too slow.
        case unreachable
        /// A folder that can't be read, with the reason to show.
        case problem(String)
    }

    private let sources: [(id: SourceID, name: String)]
    private let previous: [SourceID: LibraryView.SourceGroup]
    private var outcomes: [Int: Outcome] = [:]

    init(sources: [(SourceID, String)], previous: [LibraryView.SourceGroup]) {
        self.sources = sources.map { (id: $0.0, name: $0.1) }
        self.previous = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    mutating func record(_ outcome: Outcome, at index: Int) { outcomes[index] = outcome }

    /// Sources that haven't answered yet.
    var pending: Int { sources.count - outcomes.count }

    var groups: [LibraryView.SourceGroup] {
        sources.indices.compactMap { i in
            switch outcomes[i] {
            case .loaded(let group)?: group
            case .problem?: nil
            case .unreachable?, nil: previous[sources[i].id]
            }
        }
    }

    var unreachable: [String] {
        sources.indices.compactMap { i in outcomes[i] == .unreachable ? sources[i].name : nil }
    }

    var problems: [String] {
        sources.indices.compactMap { i in if case .problem(let message)? = outcomes[i] { message } else { nil } }
    }

    static func == (a: Self, b: Self) -> Bool {
        a.sources.map(\.id) == b.sources.map(\.id) && a.previous == b.previous && a.outcomes == b.outcomes
    }
}

/// Lets the sources' task group look titles up on the main-actor app.
struct SourceTitleLookup: Sendable {
    weak var app: AppModel?
    @MainActor init(app: AppModel) { self.app = app }
    func titles(for keys: [MediaKey]) async -> [Title?] {
        guard let app else { return keys.map { _ in nil } }
        return await app.titles(for: keys)
    }
}
