import Domain
import Foundation

/// Runs `transform` over `items` with up to `limit` at a time and returns the
/// results in the items' order. For lookups that each may wait on the network
/// (a title per Continue Watching entry), where one after another adds up.
func concurrentMap<Item: Sendable, Result: Sendable>(
    _ items: [Item], limit: Int = 6, _ transform: @escaping @Sendable (Item) async -> Result
) async -> [Result] {
    guard !items.isEmpty else { return [] }
    return await withTaskGroup(of: (Int, Result).self) { group in
        var results = [Result?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(max(limit, 1), items.count) {
            let i = next, item = items[i]
            group.addTask { (i, await transform(item)) }
            next += 1
        }
        for await (i, value) in group {
            results[i] = value
            if next < items.count {
                let j = next, item = items[j]
                group.addTask { (j, await transform(item)) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}

extension AppModel {
    /// `title(for:)` for many keys at once, side by side, in the keys' order.
    func titles(for keys: [MediaKey]) async -> [Title?] {
        let resolver = TitleLookup(app: self)
        return await concurrentMap(keys) { await resolver.title(for: $0) }
    }
}

/// Lets a `@Sendable` closure call back into the main-actor app.
private struct TitleLookup: Sendable {
    weak var app: AppModel?
    @MainActor init(app: AppModel) { self.app = app }
    func title(for key: MediaKey) async -> Title? { await app?.title(for: key) }
}
