import Foundation

/// What the device allows right now.
public struct DownloadConditions: Sendable, Equatable {
    public var isOnline: Bool
    /// Cellular or a personal hotspot.
    public var isExpensive: Bool
    /// iOS: Bluebox is in the background, where torrents can't run.
    public var torrentsSuspended: Bool
    /// Settings › Mobile Data › Torrents allows peer-to-peer on mobile data.
    public var torrentsAllowedOnMobileData: Bool
    /// On mains power (or charging). Devices that can't tell count as charging.
    public var isCharging: Bool
    /// Settings › Downloads › Download Window is open now, so automatic
    /// downloads may run. The manager works it out from the clock and `isCharging`.
    public var automaticWindowOpen: Bool

    public init(isOnline: Bool = true, isExpensive: Bool = false, torrentsSuspended: Bool = false,
                torrentsAllowedOnMobileData: Bool = true, isCharging: Bool = true, automaticWindowOpen: Bool = true) {
        self.isOnline = isOnline; self.isExpensive = isExpensive; self.torrentsSuspended = torrentsSuspended
        self.torrentsAllowedOnMobileData = torrentsAllowedOnMobileData
        self.isCharging = isCharging; self.automaticWindowOpen = automaticWindowOpen
    }
}

/// Decides which downloads transfer and which wait. Pure, so the rules are tested directly.
public enum DownloadScheduler {
    public struct Plan: Sendable, Equatable {
        /// Not running now and should be.
        public var start: [String] = []
        /// Running now and shouldn't be (they go back to the queue).
        public var stop: [String] = []
        /// Why each waiting download waits.
        public var waits: [String: DownloadWait] = [:]
    }

    /// - Parameters:
    ///   - running: IDs with a live transfer.
    ///   - holds: download ID → reason it must wait (e.g. the same release is streaming).
    public static func plan(records: [DownloadRecord], running: Set<String>, settings: DownloadSettings,
                            conditions: DownloadConditions, holds: [String: String] = [:]) -> Plan {
        var plan = Plan()
        let candidates = records.filter(\.isActive).sorted {
            ($0.sortOrder, $0.createdAt.timeIntervalSince1970, $0.id) < ($1.sortOrder, $1.createdAt.timeIntervalSince1970, $1.id)
        }
        var allowed: [DownloadRecord] = []
        for r in candidates {
            if let reason = holds[r.id] {
                plan.waits[r.id] = .held(reason)
            } else if !conditions.isOnline {
                plan.waits[r.id] = .offline
            } else if conditions.isExpensive
                        && (r.allowsMobileData.map { !$0 }
                            // Automatic downloads never use mobile data unless you say so for one.
                            ?? (settings.wifiOnly || r.isAutomatic == true
                                || (r.isTorrent && !conditions.torrentsAllowedOnMobileData))) {
                plan.waits[r.id] = .wifi
            } else if r.isTorrent && conditions.torrentsSuspended {
                plan.waits[r.id] = .appInBackground
            } else if r.isAutomatic == true && !conditions.automaticWindowOpen {
                plan.waits[r.id] = .window(settings.window)
            } else {
                allowed.append(r)
            }
        }
        let limit = settings.concurrencyLimit
        let chosen = allowed.prefix(limit).map(\.id)
        for (i, r) in allowed.dropFirst(limit).enumerated() { plan.waits[r.id] = .queued(position: i + 1) }
        plan.start = chosen.filter { !running.contains($0) }
        let keep = Set(chosen)
        plan.stop = running.filter { !keep.contains($0) }.sorted()
        return plan
    }
}
