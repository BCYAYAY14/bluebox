//
//  AddonClient.swift
//  Bluebox
//
//  Written for Bluebox from public documentation: the Stremio add-on SDK's
//  protocol (docs/protocol.md and docs/api/requests/defineCatalogHandler.md).
//  Fetches manifests, stream lists and catalogs over HTTPS, each with its
//  own deadline, and asks several add-ons at once for streams, answering
//  as soon as the results are good enough while slower add-ons finish in the
//  background.
//

import Foundation

/// The network, for add-ons and debrid checks. Tests pass a fake.
public protocol AddonTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionAddonTransport: AddonTransport {
    let session: URLSession
    let maxBytes: Int

    public init(session: URLSession = .shared, maxBytes: Int = AddonClient.maxResponseBytes) {
        self.session = session; self.maxBytes = maxBytes
    }

    /// Reads the body as it arrives and gives up past `maxBytes`, so an add-on
    /// can't make Bluebox hold an endless answer in memory.
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AddonError.unexpectedResponse }
        if http.expectedContentLength > Int64(maxBytes) { throw AddonError.responseTooLarge }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw AddonError.responseTooLarge }
        }
        return (data, http)
    }
}

/// Talks to Stremio add-ons.
public struct AddonClient: Sendable {
    public let transport: any AddonTransport
    /// The largest answer read (`maxResponseBytes` unless a test lowers it).
    let responseLimit: Int

    public init(transport: any AddonTransport = URLSessionAddonTransport(), responseLimit: Int = AddonClient.maxResponseBytes) {
        self.transport = transport
        self.responseLimit = responseLimit
    }

    /// The largest manifest or stream list read: generous for thousands of
    /// streams, small enough that a hostile answer can't exhaust memory.
    public static let maxResponseBytes = 8 << 20

    static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Bluebox/\(version) (Stremio add-on client)"
    }()

    /// GET with a total deadline (URLRequest's own timeout only covers idle time).
    func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let transport = transport, limit = responseLimit
        let finished = request
        return try await Self.withDeadline(seconds: timeout) {
            let (data, response) = try await transport.data(for: finished)
            guard (200..<300).contains(response.statusCode) else { throw AddonError.badStatus(response.statusCode) }
            guard data.count <= limit else { throw AddonError.responseTooLarge }
            return data
        }
    }

    /// Runs `work`, throwing `AddonError.timedOut` if it takes longer than `seconds`.
    static func withDeadline<T: Sendable>(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AddonError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AddonError.timedOut }
            return first
        }
    }

    /// Reads and checks an add-on's manifest: it must offer streams for
    /// movies or series by IMDb ID, and not need configuring first.
    public func manifest(base: URL, timeout: TimeInterval = 10) async throws -> AddonManifest {
        let data = try await get(base.appending(path: "manifest.json"), timeout: timeout)
        let manifest: AddonManifest
        do {
            manifest = try JSONDecoder().decode(AddonManifest.self, from: data)
        } catch {
            throw AddonError.invalidManifest
        }
        try Self.validate(manifest)
        return manifest
    }

    public static func validate(_ manifest: AddonManifest) throws {
        if manifest.behaviorHints?.configurationRequired == true { throw AddonError.needsConfiguration(manifest.name) }
        // One with only catalogs (lists for Home) is welcome too; it's never asked for streams.
        guard !manifest.streamTypes.isEmpty || !manifest.homeCatalogs.isEmpty else { throw AddonError.noStreams(manifest.name) }
    }

    /// One add-on's streams for a movie or episode.
    public func streams(_ addon: ResolvedAddon, request: StreamRequest, timeout: TimeInterval) async throws -> StreamResponse {
        let data = try await get(request.url(base: addon.base), timeout: timeout)
        return try StreamParser.parse(data, addonID: addon.id, addonName: addon.name)
    }

    /// One page of an add-on's catalog: `{base}/catalog/{type}/{id}.json`, or
    /// `…/{id}/genre=Action&skip=100.json` with extras. Items that don't
    /// decode are left out.
    public func catalog(base: URL, type: String, id: String, extra: [String: String] = [:],
                        timeout: TimeInterval = 10) async throws -> [AddonMetaItem] {
        let data = try await get(AddonCatalogPath.url(base: base, resource: "catalog", type: type, id: id, extra: extra),
                                 timeout: timeout)
        do {
            return try JSONDecoder().decode(AddonMetaItem.CatalogResponse.self, from: data).metas?.compactMap(\.value) ?? []
        } catch {
            throw AddonError.unexpectedResponse
        }
    }
}

/// Catalog URLs. IDs and extra values are percent-encoded, so a
/// "kitsu:1" or a genre with a slash stays one path segment.
public enum AddonCatalogPath {
    static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))
    static let allowedValue = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    public static func url(base: URL, resource: String, type: String, id: String, extra: [String: String] = [:]) -> URL {
        let encode = { (s: String, set: CharacterSet) in s.addingPercentEncoding(withAllowedCharacters: set) ?? s }
        var path = base.absoluteString
        while path.hasSuffix("/") { path.removeLast() }
        path += "/\(resource)/\(encode(type, allowed))/\(encode(id, allowed))"
        // The protocol's order isn't fixed; sorted keeps cache keys and URLs stable.
        let extras = extra.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
            .map { "\(encode($0.key, allowedValue))=\(encode($0.value, allowedValue))" }.joined(separator: "&")
        if !extras.isEmpty { path += "/" + extras }
        return URL(string: path + ".json") ?? base
    }
}

// MARK: - Asking several add-ons

/// When to stop waiting for slower add-ons.
public struct SearchTiming: Sendable {
    /// Each add-on's own deadline.
    public var perAddon: TimeInterval
    /// After the first add-on with results answers, wait this long for the rest.
    public var grace: TimeInterval
    /// After this, answer with whatever has come in (if anything has).
    public var softDeadline: TimeInterval

    public init(perAddon: TimeInterval = 10, grace: TimeInterval = 0.8, softDeadline: TimeInterval = 3.5) {
        self.perAddon = perAddon; self.grace = grace; self.softDeadline = softDeadline
    }
}

/// The outcome of asking every add-on.
public struct SearchOutcome: Sendable {
    /// Merged and deduplicated, in add-on order (not ranked).
    public var releases: [AddonRelease]
    /// Add-ons still answering when this was returned; their results arrive through `onLate`.
    public var pending: Int
    public var errors: [String: String]
}

/// Asks add-ons in parallel. Returns once every add-on has answered, or a
/// short grace after the first useful answer, or at the soft deadline if
/// anything has come in. Add-ons still answering keep going; each late
/// answer calls `onLate` with the full merged list. Cancelling the caller
/// cancels every request.
public enum AddonSearch {
    public static func run(_ addons: [ResolvedAddon], request: StreamRequest, client: AddonClient,
                           health: AddonHealthMonitor, timing: SearchTiming = SearchTiming(),
                           onLate: @escaping @Sendable ([AddonRelease]) async -> Void = { _ in }) async throws -> SearchOutcome {
        var asked: [ResolvedAddon] = []
        for addon in addons where addon.types.isEmpty || addon.types.contains(request.type) {
            if await health.shouldAsk(addon.id) { asked.append(addon) }
        }
        guard !asked.isEmpty else { throw addons.isEmpty ? AddonError.noAddons : AddonError.timedOut }

        let collector = Collector(count: asked.count, onLate: onLate)
        let grace = timing.grace
        await collector.setGrace { Task { try? await Task.sleep(for: .seconds(grace)); await collector.graceEnded() } }
        var tasks: [Task<Void, Never>] = []
        for (index, addon) in asked.enumerated() {
            tasks.append(Task {
                let started = Date()
                do {
                    let response = try await client.streams(addon, request: request, timeout: timing.perAddon)
                    let elapsed = Date().timeIntervalSince(started)
                    if response.debridRejected {
                        await health.recordFailure(addon.id, error: AddonError.debridRejected, latency: elapsed)
                        await collector.deliver(index, .failure(AddonError.debridRejected), name: addon.id)
                    } else {
                        await health.recordSuccess(addon.id, latency: elapsed, releases: response.releases.count)
                        await collector.deliver(index, .success(response.releases), name: addon.id)
                    }
                } catch {
                    if !(error is CancellationError), !Task.isCancelled {
                        await health.recordFailure(addon.id, error: error, latency: Date().timeIntervalSince(started))
                    }
                    await collector.deliver(index, .failure(error), name: addon.id)
                }
            })
        }
        let timers = [
            Task { try? await Task.sleep(for: .seconds(timing.softDeadline)); await collector.softDeadlinePassed() },
        ]

        return try await withTaskCancellationHandler {
            let outcome = await collector.wait()
            timers.forEach { $0.cancel() }
            try Task.checkCancellation()
            if outcome.releases.isEmpty, outcome.pending == 0 {
                // Nothing at all: report why, the most telling error first.
                let errors = outcome.failures
                if errors.contains(where: { ($0 as? AddonError) == .debridRejected }) { throw AddonError.debridRejected }
                if let first = errors.first(where: { !($0 is CancellationError) }), errors.count == asked.count { throw first }
            }
            return SearchOutcome(releases: outcome.releases, pending: outcome.pending, errors: outcome.errorTexts)
        } onCancel: {
            tasks.forEach { $0.cancel() }
            timers.forEach { $0.cancel() }
        }
    }

    /// Gathers answers and decides when the caller has waited enough.
    actor Collector {
        struct Outcome: Sendable {
            var releases: [AddonRelease]
            var pending: Int
            var failures: [Error]
            var errorTexts: [String: String]
        }

        private let count: Int
        private var lists: [Int: [AddonRelease]] = [:]
        private var failures: [Int: Error] = [:]
        private var errorTexts: [String: String] = [:]
        private var waiter: CheckedContinuation<Outcome, Never>?
        private var answered = false
        private var graceStarted = false
        private var softPassed = false
        private var startGrace: (@Sendable () -> Void)?
        private let onLate: @Sendable ([AddonRelease]) async -> Void

        init(count: Int, onLate: @escaping @Sendable ([AddonRelease]) async -> Void) {
            self.count = count
            self.onLate = onLate
        }

        func setGrace(_ start: @escaping @Sendable () -> Void) { startGrace = start }

        func deliver(_ index: Int, _ result: Result<[AddonRelease], Error>, name: String) async {
            switch result {
            case .success(let list): lists[index] = list
            case .failure(let error):
                failures[index] = error
                errorTexts[name] = AddonHealthMonitor.shortDescription(error)
            }
            if answered {
                if case .success(let list) = result, !list.isEmpty { await onLate(merged) }
                return
            }
            if pending == 0 { finish(); return }
            if case .success(let list) = result, !list.isEmpty {
                if softPassed { finish(); return }
                if !graceStarted { graceStarted = true; startGrace?() }
            }
        }

        func softDeadlinePassed() {
            softPassed = true
            if !answered, hasResults { finish() }
        }

        func graceEnded() {
            if !answered { finish() }
        }

        func wait() async -> Outcome {
            if answered { return outcome }
            return await withCheckedContinuation { continuation in
                waiter = continuation
                if pending == 0 { finish() }
            }
        }

        private var pending: Int { count - lists.count - failures.count }
        private var hasResults: Bool { lists.values.contains { !$0.isEmpty } }

        private var merged: [AddonRelease] {
            ReleaseDeduplicator.merge((0..<count).compactMap { lists[$0] })
        }

        private var outcome: Outcome {
            Outcome(releases: merged, pending: pending, failures: Array(failures.values), errorTexts: errorTexts)
        }

        private func finish() {
            guard !answered else { return }
            answered = true
            waiter?.resume(returning: outcome)
            waiter = nil
        }
    }
}
