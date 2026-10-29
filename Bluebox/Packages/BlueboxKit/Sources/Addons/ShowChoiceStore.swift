//
//  ShowChoiceStore.swift
//  Bluebox
//
//  Written for Bluebox from public documentation (the Stremio add-on SDK's
//  `behaviorHints.bingeGroup`). Remembers the release group, resolution and binge
//  group last played for each show, so the next episode prefers the same.
//

import Domain
import Foundation

/// Where show choices are kept. The app uses `UserDefaultsShowChoiceStore`.
public protocol ShowChoiceStore: Sendable {
    func choice(for series: MediaKey) -> ShowChoice?
    func remember(_ choice: ShowChoice, for series: MediaKey)
    func forgetAll()
}

/// Keeps choices as one JSON dictionary in user defaults, the newest 300 shows.
public final class UserDefaultsShowChoiceStore: ShowChoiceStore, @unchecked Sendable {
    static let key = "bluebox.addons.showChoices"
    static let limit = 300
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func choice(for series: MediaKey) -> ShowChoice? {
        lock.withLock { load()[series.rawValue] }
    }

    public func remember(_ choice: ShowChoice, for series: MediaKey) {
        lock.withLock {
            var all = load()
            all[series.rawValue] = choice
            if all.count > Self.limit {
                let oldest = all.sorted { $0.value.chosenAt < $1.value.chosenAt }.prefix(all.count - Self.limit)
                for (k, _) in oldest { all[k] = nil }
            }
            if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
        }
    }

    public func forgetAll() {
        lock.withLock { defaults.removeObject(forKey: Self.key) }
    }

    private func load() -> [String: ShowChoice] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: ShowChoice].self, from: data)) ?? [:]
    }
}

/// In memory only (tests, previews).
public final class MemoryShowChoiceStore: ShowChoiceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var choices: [MediaKey: ShowChoice] = [:]
    public init() {}
    public func choice(for series: MediaKey) -> ShowChoice? { lock.withLock { choices[series] } }
    public func remember(_ choice: ShowChoice, for series: MediaKey) { lock.withLock { choices[series] = choice } }
    public func forgetAll() { lock.withLock { choices = [:] } }
}
