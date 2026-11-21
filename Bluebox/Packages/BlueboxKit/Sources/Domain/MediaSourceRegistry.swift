import Foundation
import Synchronization

/// Result of asking every enabled source whether it can play a key.
public struct Availability: Sendable, Hashable {
    public let variants: [MediaVariant]
    /// Sources that failed while answering; they are reported, not fatal.
    public let failures: [SourceID: SourceError]
    public init(variants: [MediaVariant], failures: [SourceID: SourceError]) {
        self.variants = variants; self.failures = failures
    }
    public var isPlayable: Bool { !variants.isEmpty }
    public static let none = Availability(variants: [], failures: [:])
}

/// Holds the configured media sources and fans queries out to them.
public actor MediaSourceRegistry {
    private var sources: [SourceID: any MediaSource] = [:]
    private var order: [SourceID] = []
    private var disabled: Set<SourceID> = []

    public init(sources: [any MediaSource] = []) {
        for s in sources { self.sources[s.id] = s; order.append(s.id) }
    }

    public func register(_ source: any MediaSource) {
        if sources[source.id] == nil { order.append(source.id) }
        sources[source.id] = source
    }

    public func unregister(_ id: SourceID) {
        sources[id] = nil
        order.removeAll { $0 == id }
        disabled.remove(id)
    }

    public func setEnabled(_ enabled: Bool, for id: SourceID) {
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
    }

    public func isEnabled(_ id: SourceID) -> Bool { sources[id] != nil && !disabled.contains(id) }

    public func source(_ id: SourceID) -> (any MediaSource)? { sources[id] }

    /// Registered sources in registration order, enabled or not.
    public func all() -> [any MediaSource] { order.compactMap { sources[$0] } }

    /// Enabled sources that advertise every capability in `required`.
    public func enabled(with required: SourceCapabilities = []) -> [any MediaSource] {
        order.compactMap { id in
            guard !disabled.contains(id), let s = sources[id], s.capabilities.isSuperset(of: required) else { return nil }
            return s
        }
    }

    /// Asks all enabled, playable sources for variants of `key` concurrently.
    /// Results keep registration order so the preferred source comes first.
    /// A source that hasn't answered within its `answersWithin` is reported
    /// in `failures` as timed out, so an offline Plex or a cold library
    /// doesn't hold up Play for the others.
    public func availability(for key: MediaKey) async -> Availability {
        let candidates = enabled(with: .play)
        var byIndex: [Int: [MediaVariant]] = [:]
        var failures: [SourceID: SourceError] = [:]
        await withTaskGroup(of: (Int, SourceID, Result<[MediaVariant], SourceError>).self) { group in
            for (i, source) in candidates.enumerated() {
                group.addTask { (i, source.id, await Self.answer(from: source, for: key)) }
            }
            for await (i, id, result) in group {
                switch result {
                case .success(let v): byIndex[i] = v
                case .failure(let e): failures[id] = e
                }
            }
        }
        let variants = byIndex.keys.sorted().flatMap { byIndex[$0]! }
        return Availability(variants: variants, failures: failures)
    }

    /// One source's variants, or `.timedOut` once its deadline passes. The
    /// work isn't cancelled at the deadline: it goes on filling the source's
    /// cache, so the next look has the answer at once.
    private static func answer(from source: any MediaSource, for key: MediaKey) async -> Result<[MediaVariant], SourceError> {
        let work = Task { () -> Result<[MediaVariant], SourceError> in
            do { return .success(try await source.variants(for: key)) }
            catch let e as SourceError { return .failure(e) }
            catch is CancellationError { return .failure(.cancelled) }
            catch { return .failure(.unreachable(error.localizedDescription)) }
        }
        guard let limit = source.answersWithin else {
            return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Result<[MediaVariant], SourceError>, Never>) in
                let answered = Mutex(false)
                // Whichever comes first, the answer or the deadline, resumes; the other is dropped.
                let finish: @Sendable (Result<[MediaVariant], SourceError>) -> Void = { result in
                    let first = answered.withLock { was in defer { was = true }; return !was }
                    if first { done.resume(returning: result) }
                }
                Task { finish(await work.value) }
                Task {
                    try? await Task.sleep(for: .seconds(limit))
                    finish(.failure(.timedOut))
                }
            }
        } onCancel: { work.cancel() }
    }

    public func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        guard let source = sources[variant.sourceID] else { throw SourceError.notFound }
        guard !disabled.contains(variant.sourceID) else { throw SourceError.notConfigured }
        guard source.supports(.play) else { throw SourceError.capabilityUnavailable("playback") }
        return try await source.resolve(variant)
    }
}
