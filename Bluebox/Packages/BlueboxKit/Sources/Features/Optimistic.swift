import Domain
import Foundation

/// Optimistic updates: the screen changes the moment you tap, the save runs
/// after, and if it fails the old state comes back with a toast that says so
/// (and offers Try Again).
@MainActor
enum Optimistic {
    /// Shows `new` at once, then runs `commit`. On failure puts `old` back
    /// and calls `failed`. Returns whether the change stuck.
    @discardableResult
    static func update<Value>(from old: Value, to new: Value, apply: (Value) -> Void,
                              commit: () async throws -> Void, failed: (Error) -> Void = { _ in }) async -> Bool {
        apply(new)
        do {
            try await commit()
            return true
        } catch {
            apply(old)
            failed(error)
            return false
        }
    }
}

extension AppModel {
    /// `Optimistic.update`, rolling back with an error toast ("Couldn't update
    /// My List") whose Try Again repeats the whole change.
    @discardableResult
    func optimistic<Value>(_ failureTitle: String, from old: Value, to new: Value, apply: @escaping (Value) -> Void,
                           commit: @escaping () async throws -> Void) async -> Bool {
        await Optimistic.update(from: old, to: new, apply: apply, commit: commit) { [weak self] error in
            self?.report(error, title: failureTitle, context: .general) { [weak self] in
                await self?.optimistic(failureTitle, from: old, to: new, apply: apply, commit: commit)
            }
        }
    }

    /// Adds to or takes off My List. Throws when the library can't be saved.
    public func setOnMyList(_ title: Title, _ on: Bool) async throws {
        try await store.setWatchlisted(title, on)
        noteLibraryChanged()
    }
}
