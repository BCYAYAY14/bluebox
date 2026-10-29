//
//  AddonHealth.swift
//  Bluebox
//
//  Written for Bluebox from public documentation (the Stremio add-on SDK's
//  protocol docs). How each add-on has been answering this session:
//  success rate and latency, kept in memory. An add-on that times out
//  repeatedly is skipped for a while, then tried again.
//

import Foundation

/// One add-on's record since launch.
public struct AddonHealth: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Not asked yet.
        case unknown
        case healthy
        /// Answering, but slowly or with some failures.
        case slow
        /// Its last answers failed.
        case failing
        /// Skipped after repeated timeouts until `skippedUntil`.
        case skipped
    }

    public var addonID: String
    public var requests = 0
    public var successes = 0
    public var timeouts = 0
    public var failures = 0
    public var consecutiveFailures = 0
    /// Smoothed time to answer, in seconds.
    public var averageLatency: Double?
    public var lastError: String?
    public var lastReleaseCount: Int?
    public var skippedUntil: Date?
    /// How long the next skip lasts.
    var backoff: TimeInterval = AddonHealthMonitor.firstBackoff

    public init(addonID: String) { self.addonID = addonID }

    public var successRate: Double? {
        requests == 0 ? nil : Double(successes) / Double(requests)
    }

    public func state(at now: Date = Date()) -> State {
        if let until = skippedUntil, until > now { return .skipped }
        if requests == 0 { return .unknown }
        if consecutiveFailures > 0 { return .failing }
        if (successRate ?? 1) < 0.75 || (averageLatency ?? 0) > AddonHealthMonitor.slowLatency { return .slow }
        return .healthy
    }

    /// "Healthy · 0.8 s · 12 of 12", for Settings.
    public func summary(at now: Date = Date()) -> String {
        var parts: [String] = []
        switch state(at: now) {
        case .unknown: return "Not used yet"
        case .healthy: parts.append("Healthy")
        case .slow: parts.append("Slow")
        case .failing: parts.append(lastError ?? "Not answering")
        case .skipped:
            let minutes = max(1, Int(((skippedUntil ?? now).timeIntervalSince(now) / 60).rounded(.up)))
            parts.append("Skipped for \(minutes) min after timeouts")
        }
        if let latency = averageLatency { parts.append(String(format: "%.1f s", latency)) }
        parts.append("\(successes) of \(requests) answered")
        return parts.joined(separator: " · ")
    }
}

/// Keeps `AddonHealth` for every add-on and decides which to skip.
public actor AddonHealthMonitor {
    /// Timeouts in a row before an add-on is skipped.
    static let timeoutsBeforeSkipping = 3
    static let firstBackoff: TimeInterval = 5 * 60
    static let maxBackoff: TimeInterval = 30 * 60
    static let slowLatency: TimeInterval = 4

    private var records: [String: AddonHealth] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Whether to ask this add-on now. A skipped add-on gets one try when its
    /// skip ends; if that fails too, it's skipped for twice as long.
    public func shouldAsk(_ id: String) -> Bool {
        guard let until = records[id]?.skippedUntil else { return true }
        return until <= now()
    }

    public func recordSuccess(_ id: String, latency: TimeInterval, releases: Int) {
        var r = records[id] ?? AddonHealth(addonID: id)
        r.requests += 1
        r.successes += 1
        r.consecutiveFailures = 0
        r.lastError = nil
        r.lastReleaseCount = releases
        r.skippedUntil = nil
        r.backoff = Self.firstBackoff
        r.averageLatency = r.averageLatency.map { $0 * 0.7 + latency * 0.3 } ?? latency
        records[id] = r
    }

    public func recordFailure(_ id: String, error: Error, latency: TimeInterval) {
        var r = records[id] ?? AddonHealth(addonID: id)
        r.requests += 1
        r.consecutiveFailures += 1
        let isTimeout = Self.isTimeout(error)
        if isTimeout {
            r.timeouts += 1
            r.lastError = "Timed out"
        } else {
            r.failures += 1
            r.lastError = Self.shortDescription(error)
        }
        r.averageLatency = r.averageLatency.map { $0 * 0.7 + latency * 0.3 } ?? latency
        if isTimeout || Self.isUnreachable(error), r.consecutiveFailures >= Self.timeoutsBeforeSkipping {
            r.skippedUntil = now().addingTimeInterval(r.backoff)
            r.backoff = min(r.backoff * 2, Self.maxBackoff)
        }
        records[id] = r
    }

    public func health(_ id: String) -> AddonHealth { records[id] ?? AddonHealth(addonID: id) }

    public func all() -> [String: AddonHealth] { records }

    /// Ends a skip early ("Try Again" in Settings).
    public func reset(_ id: String) { records[id] = nil }

    static func isTimeout(_ error: Error) -> Bool {
        if let e = error as? AddonError, e == .timedOut { return true }
        return (error as? URLError)?.code == .timedOut
    }

    static func isUnreachable(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost].contains(code)
    }

    static func shortDescription(_ error: Error) -> String {
        switch error {
        case AddonError.timedOut: "Timed out"
        case AddonError.badStatus(let code): "HTTP \(code)"
        case AddonError.unexpectedResponse: "Unreadable answer"
        case AddonError.debridRejected: "Debrid key rejected"
        case let e as URLError: e.code == .notConnectedToInternet ? "Offline" : "Network error"
        default: "Failed"
        }
    }
}
