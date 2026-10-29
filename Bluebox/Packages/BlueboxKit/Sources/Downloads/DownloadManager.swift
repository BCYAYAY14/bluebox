import Domain
import Foundation

/// Runs downloads the manager doesn't transfer itself: torrents, which
/// libtorrent fetches. The manager decides when each one runs (queue order,
/// concurrency limit, Wi‑Fi, app in background, holds) and the runner reports
/// back through `externalProgress`, `externalCompleted` and `externalFailed`.
public struct ExternalDownloadRunner: Sendable {
    /// Start or resume transferring.
    public var start: @Sendable (DownloadRecord) async -> Void
    /// Stop transferring and keep what has arrived. Returns once files are closed.
    public var stop: @Sendable (String) async -> Void
    /// Stop and delete partial data.
    public var delete: @Sendable (String) async -> Void

    public init(start: @escaping @Sendable (DownloadRecord) async -> Void,
                stop: @escaping @Sendable (String) async -> Void,
                delete: @escaping @Sendable (String) async -> Void) {
        self.start = start; self.stop = stop; self.delete = delete
    }
}

/// Bytes on disk for downloads and free space on the device.
public struct DownloadStorage: Sendable, Equatable {
    public var usedBytes: Int64
    public var freeBytes: Int64?
    public var totalBytes: Int64?
}

/// Saves movies and episodes for offline playback.
///
/// HTTP downloads (direct links, debrid, Jellyfin) use a background
/// `URLSession`, so on iOS they continue while the app is suspended. Torrent
/// downloads run through an `ExternalDownloadRunner` and only progress while
/// the app runs. Both share one ordered queue with a concurrency limit; the
/// queue resumes unfinished downloads after a relaunch.
public final class DownloadManager: NSObject, @unchecked Sendable {
    public static let backgroundIdentifier = "app.bluebox.downloads"
    /// The session for Wi‑Fi Only: its configuration forbids cellular, which
    /// (unlike a request's flag) also binds tasks rebuilt from resume data.
    public static let wifiOnlyBackgroundIdentifier = "app.bluebox.downloads.wifi"
    public static let backgroundIdentifiers: Set<String> = [backgroundIdentifier, wifiOnlyBackgroundIdentifier]
    /// Free space a new download must leave behind.
    public static let reserveBytes: Int64 = 500_000_000
    /// Below this, running downloads stop so the device doesn't fill up.
    public static let lowSpaceBytes: Int64 = 200_000_000

    public let directory: URL
    private let lock = NSLock()
    /// Orders index writes (never taken while holding `lock`).
    private let saveLock = NSLock()
    private var records: [String: DownloadRecord] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// HTTP downloads resolving a fresh link before their task exists.
    private var starting: Set<String> = []
    private var externalRunning: Set<String> = []
    private var externalOps: [String: Task<Void, Never>] = [:]
    private var externalOpTokens: [String: UUID] = [:]
    /// Tasks cancelled on purpose (pause, queue changes, delete): their errors aren't failures.
    private var stoppedTasks: Set<Int> = []
    private var resumedTasks: Set<Int> = []
    private var autoRetries: [String: Int] = [:]
    private var pendingResources: [String: PlaybackResource] = [:]
    private var pendingSubtitles: [String: [ExternalSubtitle]] = [:]
    private var live: [String: DownloadLiveStats] = [:]
    private var speedSamples: [String: (bytes: Int64, at: Date)] = [:]
    private var waits: [String: DownloadWait] = [:]
    /// When each running download last got new bytes (or started), for the queue's stall reason.
    private var lastBytesAt: [String: Date] = [:]
    /// Info hash or download ID → why it has to wait.
    private var holds: [String: String] = [:]
    private var conditions = DownloadConditions()
    private var settings: DownloadSettings
    private var reattached = false
    private var activated: Bool
    #if DEBUG
    /// Set by `debugSeed`: the queue never starts anything.
    private var frozenForReview = false
    #else
    private let frozenForReview = false
    #endif
    private var lastSave = Date.distantPast
    private var lastNotify = Date.distantPast
    private var lastSpaceCheck = Date.distantPast
    /// HTTP transfers that may use cellular; `wifiSession` ones may not.
    private var session: URLSession!
    private var wifiSession: URLSession!
    /// Per running HTTP download: whether its session allows cellular.
    private var taskAllowsCellular: [String: Bool] = [:]
    /// getAllTasks callbacks still to come (one per session).
    private var reattachPending = 2
    /// Downloads stopped for resume data that hasn't arrived yet, and the
    /// data once it has (kept in memory too: the file is written after).
    private var awaitingResumeData: Set<String> = []
    private var resumeDataReady: [String: Data] = [:]
    /// Tests: told about every HTTP task launched (id, from resume data, cellular allowed).
    var onHTTPLaunch: (@Sendable (String, Bool, Bool) -> Void)?
    private var monitor: NetworkMonitor?
    private let subtitleFetch: @Sendable (URL) async throws -> Data
    private let freeSpaceProvider: @Sendable (URL) -> Int64?

    /// Called on the main actor after any change.
    public var onChange: (@MainActor @Sendable () -> Void)?
    /// Fresh links for HTTP downloads that restart without resume data (debrid links expire).
    public var resolveResource: (@Sendable (MediaVariant) async throws -> PlaybackResource)?
    /// Runs torrent downloads. Without one they fail with a clear message.
    public var external: ExternalDownloadRunner?

    /// iOS hands this to the app delegate when it relaunches the app for
    /// finished background downloads; it's called once events are handled.
    nonisolated(unsafe) private static var pendingCompletions: [String: @Sendable () -> Void] = [:]
    private static let completionLock = NSLock()
    public static func setBackgroundCompletion(_ handler: @escaping @Sendable () -> Void,
                                               for identifier: String = backgroundIdentifier) {
        completionLock.withLock { pendingCompletions[identifier] = handler }
    }

    private var indexURL: URL { directory.appending(path: "index.json") }
    private func resumeURL(_ id: String) -> URL { directory.appending(path: ".resume-\(Self.safeName(id))") }

    /// - Parameters:
    ///   - configuration: nil for the shared background session; tests pass an ephemeral one.
    ///   - startsQueue: false to hold the queue until `activate()` (the app does this until its sources are registered).
    ///   - monitorsNetwork: watch Wi‑Fi / cellular; defaults to on for the background session.
    ///   - freeSpace: free bytes on the volume; injectable for tests.
    public init(directory: URL, configuration: URLSessionConfiguration? = nil,
                subtitleFetch: (@Sendable (URL) async throws -> Data)? = nil,
                settings: DownloadSettings = DownloadSettings(), startsQueue: Bool = true,
                monitorsNetwork: Bool? = nil, freeSpace: (@Sendable (URL) -> Int64?)? = nil) {
        self.directory = directory
        self.subtitleFetch = subtitleFetch ?? { try await URLSession.shared.data(from: $0).0 }
        self.freeSpaceProvider = freeSpace ?? { Self.freeSpace(at: $0) }
        self.settings = settings
        self.activated = startsQueue
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var dir = directory; try? dir.setResourceValues(excluded)
        if let data = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            records = Dictionary(list.map { ($0.id, $0) }) { a, _ in a }
        }
        repairAfterLaunch()
        let config = configuration ?? {
            let c = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
            c.sessionSendsLaunchEvents = true
            c.isDiscretionary = false
            return c
        }()
        config.allowsCellularAccess = true
        let wifiConfig: URLSessionConfiguration
        if configuration == nil {
            wifiConfig = URLSessionConfiguration.background(withIdentifier: Self.wifiOnlyBackgroundIdentifier)
            wifiConfig.sessionSendsLaunchEvents = true
            wifiConfig.isDiscretionary = false
        } else {
            wifiConfig = config.copy() as! URLSessionConfiguration
        }
        wifiConfig.allowsCellularAccess = false
        // One serial queue for both, so delegate callbacks never overlap.
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        wifiSession = URLSession(configuration: wifiConfig, delegate: self, delegateQueue: queue)
        // Reattach tasks that kept running while the app was gone, then start the queue.
        for (s, cellular) in [(session!, true), (wifiSession!, false)] {
            s.getAllTasks { [weak self] all in self?.reattach(all, allowsCellular: cellular) }
        }
        if monitorsNetwork ?? (configuration == nil) {
            let monitor = NetworkMonitor()
            // Low Data Mode and hotspots count as mobile data, like cellular (Settings › Mobile Data).
            monitor.start { [weak self] path in self?.networkChanged(online: path.isOnline, expensive: path.isMobileData) }
            self.monitor = monitor
        }
    }

    private func reattach(_ all: [URLSessionTask], allowsCellular: Bool) {
        var orphans: [URLSessionTask] = []
        let done = lock.withLock { () -> Bool in
            for case let t as URLSessionDownloadTask in all {
                guard let id = t.taskDescription, let r = records[id], r.isActive, !r.isTorrent, tasks[id] == nil else {
                    orphans.append(t); continue
                }
                tasks[id] = t
                taskAllowsCellular[id] = allowsCellular
                records[id]?.state = .downloading
            }
            reattachPending -= 1
            if reattachPending == 0 { reattached = true }
            return reattached
        }
        for t in orphans { lock.withLock { _ = stoppedTasks.insert(t.taskIdentifier) }; t.cancel() }
        guard done else { return }
        save()
        moveTransfersToMatchCellularSetting()  // Wi‑Fi Only may have changed while the app was closed
        pump()
    }

    #if DEBUG
    /// Screenshots and design review only (the app's `-seed-screens` launch
    /// argument): puts records in place, with speeds and waiting reasons, and
    /// freezes the queue so none of them runs or changes.
    public func debugSeed(_ seeded: [DownloadRecord], live seededLive: [String: DownloadLiveStats] = [:],
                          waits seededWaits: [String: DownloadWait] = [:]) {
        lock.withLock {
            frozenForReview = true
            for r in seeded { records[r.id] = r }
            live.merge(seededLive) { $1 }
            waits.merge(seededWaits) { $1 }
        }
        notify()
    }
    #endif

    /// Starts the queue for a manager created with `startsQueue: false`.
    public func activate() {
        lock.withLock { activated = true }
        pump()
    }

    // MARK: Queries

    /// Newest first.
    public func all() -> [DownloadRecord] {
        lock.withLock { records.values.sorted { $0.createdAt > $1.createdAt } }
    }

    /// Unfinished downloads in queue order (paused and failed ones included).
    public func queue() -> [DownloadRecord] {
        lock.withLock { records.values.filter { $0.state != .completed }.sorted { $0.sortOrder < $1.sortOrder } }
    }

    public func record(id: String) -> DownloadRecord? { lock.withLock { records[id] } }

    public func record(for variant: MediaVariant) -> DownloadRecord? {
        lock.withLock { records[DownloadRecord.id(for: variant)] }
    }

    public func records(for key: MediaKey) -> [DownloadRecord] {
        lock.withLock { records.values.filter { $0.mediaKey == key } }
    }

    /// True when a finished download of `key` is on the device. For a series
    /// key, true when any of its episodes is.
    public func isDownloaded(_ key: MediaKey) -> Bool {
        lock.withLock {
            records.values.contains { $0.state == .completed && ($0.mediaKey == key || $0.mediaKey?.seriesKey == key) }
        }
    }

    /// The finished download of `key`, if any.
    public func completedRecord(for key: MediaKey) -> DownloadRecord? {
        lock.withLock {
            records.values.filter { $0.state == .completed && $0.mediaKey == key }.max { $0.createdAt < $1.createdAt }
        }
    }

    /// Speed and peers while transferring.
    public func liveStats(_ id: String) -> DownloadLiveStats? { lock.withLock { live[id] } }

    /// Why a queued download is waiting.
    public func wait(_ id: String) -> DownloadWait? { lock.withLock { waits[id] } }

    /// Seconds since a running download last got new bytes; nil when it isn't running.
    public func idleSeconds(_ id: String, now: Date = Date()) -> TimeInterval? {
        lock.withLock {
            guard records[id]?.state == .downloading, let at = lastBytesAt[id] else { return nil }
            return now.timeIntervalSince(at)
        }
    }

    public var currentConditions: DownloadConditions { lock.withLock { conditions } }
    public var currentSettings: DownloadSettings { lock.withLock { settings } }

    public func fileURL(_ r: DownloadRecord) -> URL? { r.fileName.map { directory.appending(path: $0) } }

    public func subtitleURL(_ f: DownloadRecord.SubtitleFile) -> URL { directory.appending(path: f.fileName) }

    /// Bytes used by finished downloads.
    public func usedBytes() -> Int64 {
        all().compactMap { r in fileURL(r).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }
            .reduce(0) { $0 + Int64($1) }
    }

    /// Everything in the downloads folder (partial files included) and the device's free space.
    /// Walks the folder, so call it off the main thread.
    public func storage() -> DownloadStorage {
        var used: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        if let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) {
            for case let url as URL in walker {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                used += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        let total = (try? directory.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map(Int64.init)
        return DownloadStorage(usedBytes: used, freeBytes: freeSpaceProvider(directory), totalBytes: total)
    }

    /// Free space on the downloads volume, without walking the folder.
    public func freeBytes() -> Int64? { freeSpaceProvider(directory) }

    // MARK: Commands

    /// Downloads a resolved resource (queued behind others if the limit is reached).
    @discardableResult
    public func start(_ resource: PlaybackResource, key: MediaKey?, title: String, subtitle: String? = nil,
                      artworkURL: URL? = nil) throws -> DownloadRecord {
        try enqueue(resource.variant, key: key, title: title, subtitle: subtitle, artworkURL: artworkURL, resource: resource)
    }

    /// Adds a download to the queue. HTTP variants without a `resource` are
    /// resolved through `resolveResource` when their turn comes; torrent
    /// variants (`<info hash>:<file index>`) run through `external`.
    ///
    /// Asking again for something already queued throws `alreadyInQueue`; a
    /// paused or failed one is resumed instead.
    ///
    /// - Parameters:
    ///   - automatic: Bluebox started it (Smart Downloads, new episodes, an upgrade), so it keeps to the download window.
    ///   - replaces: a download this one upgrades; the app deletes that one once this finishes.
    @discardableResult
    public func enqueue(_ variant: MediaVariant, key: MediaKey?, title: String, subtitle: String? = nil,
                        artworkURL: URL? = nil, resource: PlaybackResource? = nil,
                        automatic: Bool = false, replaces: String? = nil) throws -> DownloadRecord {
        let id = DownloadRecord.id(for: variant)
        let isTorrent = DownloadRecord.infoHash(fromVariantID: variant.id) != nil
        guard variant.isDownloadable || isTorrent else { throw DownloadError.notDownloadable }
        if let resource, !isTorrent, !["http", "https"].contains(resource.url.scheme?.lowercased() ?? "") {
            throw DownloadError.notDownloadable
        }
        if let existing = lock.withLock({ records[id] }) {
            switch existing.state {
            case .completed: throw DownloadError.alreadyDownloaded
            case .queued, .downloading: throw DownloadError.alreadyInQueue
            case .paused, .failed:
                if let resource { lock.withLock { pendingResources[id] = resource } }
                resume(id)
                return lock.withLock { records[id] } ?? existing
            }
        }
        if let size = variant.sizeBytes, let free = freeSpaceProvider(directory), size > free - Self.reserveBytes {
            throw DownloadError.insufficientSpace(needed: size, free: free - Self.reserveBytes)
        }
        let record = lock.withLock { () -> DownloadRecord in
            let last = records.values.map(\.sortOrder).max() ?? 0
            var r = DownloadRecord(id: id, mediaKey: key, title: title, subtitle: subtitle, origin: variant, state: .queued,
                                   receivedBytes: 0, expectedBytes: variant.sizeBytes, createdAt: Date(), fileName: nil,
                                   subtitleFiles: [], artworkURL: artworkURL,
                                   order: max(last + 1, Date().timeIntervalSince1970))
            if automatic { r.isAutomatic = true }
            r.replaces = replaces
            records[id] = r
            if let resource { pendingResources[id] = resource }
            return r
        }
        save()
        pump()
        return lock.withLock { records[id] } ?? record
    }

    /// Pauses until you resume it, across launches too.
    public func pause(_ id: String) {
        let changed = lock.withLock { () -> Bool in
            guard let r = records[id], r.isActive else { return false }
            records[id]?.state = .paused
            live[id] = nil
            return true
        }
        guard changed else { return }
        stopTransfer(id)
        save()
        pump()
    }

    /// Resumes a paused or failed download (it rejoins the queue in its old place).
    public func resume(_ id: String, resource: PlaybackResource? = nil) {
        let changed = lock.withLock { () -> Bool in
            guard let r = records[id], r.state == .paused || r.isFailed else { return false }
            records[id]?.state = .queued
            autoRetries[id] = nil
            if let resource { pendingResources[id] = resource }
            return true
        }
        guard changed else { return }
        save()
        pump()
    }

    /// Same as resume, for failed downloads.
    public func retry(_ id: String) { resume(id) }

    /// Moves a download to the front of the queue; it may take a running one's slot.
    /// An automatic download asked for by hand stops waiting for the download window.
    public func prioritize(_ id: String) {
        lock.withLock {
            let first = records.values.map(\.sortOrder).min() ?? 0
            records[id]?.order = first - 1
            records[id]?.isAutomatic = nil
        }
        save()
        pump()
    }

    /// The queue screen's drag to reorder: `ids` in their new order. They
    /// take over the queue positions they held between them, so downloads
    /// not in `ids` keep their places.
    public func reorder(_ ids: [String]) {
        let changed = lock.withLock { () -> Bool in
            let known = ids.filter { records[$0] != nil }
            let slots = known.compactMap { records[$0]?.sortOrder }.sorted()
            guard slots.count == known.count else { return false }
            var changed = false
            for (id, slot) in zip(known, Self.distinct(slots)) where records[id]?.sortOrder != slot {
                records[id]?.order = slot
                changed = true
            }
            return changed
        }
        guard changed else { return }
        save()
        pump()
    }

    /// Equal positions nudged apart, so a reorder always takes.
    static func distinct(_ sorted: [Double]) -> [Double] {
        var out: [Double] = []
        for v in sorted { out.append(out.last.map { max(v, $0 + 0.001) } ?? v) }
        return out
    }

    /// Mains power came or went (iOS battery state; Mac power source). Pumps
    /// when it opens or closes the download window.
    public func setCharging(_ charging: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard conditions.isCharging != charging else { return false }
            conditions.isCharging = charging
            return true
        }
        if changed { refreshWindow() }
    }

    /// Re-checks the download window against the clock (overnight opens at
    /// 1 am); call every minute or so. Pumps only when it changed.
    public func refreshWindow(now: Date = Date()) {
        let changed = lock.withLock { () -> Bool in
            let open = settings.window.isOpen(at: now, isCharging: conditions.isCharging)
            guard open != conditions.automaticWindowOpen else { return false }
            conditions.automaticWindowOpen = open
            return true
        }
        if changed { pump() }
    }

    /// Saves a subtitle next to a download (Smart Downloads fetch one in the
    /// profile's language), so it plays offline with it.
    public func addSubtitle(_ data: Data, languageCode: String?, label: String, format: String, to id: String) throws {
        guard lock.withLock({ records[id] != nil }) else { return }
        let name = "\(Self.safeName(id)).\(languageCode ?? "und").\(UUID().uuidString.prefix(6)).\(format)"
        try data.write(to: directory.appending(path: name), options: .atomic)
        let kept = lock.withLock { () -> Bool in
            guard records[id] != nil else { return false }
            records[id]?.subtitleFiles.append(.init(fileName: name, languageCode: languageCode, label: label, format: format))
            return true
        }
        if kept { save() } else { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
    }

    /// Cancels a download and deletes its files, partial data included.
    public func delete(_ id: String) {
        let (task, record) = lock.withLock { () -> (URLSessionDownloadTask?, DownloadRecord?) in
            let task = tasks.removeValue(forKey: id)
            if let task { stoppedTasks.insert(task.taskIdentifier) }
            starting.remove(id)
            externalRunning.remove(id)
            pendingResources[id] = nil; pendingSubtitles[id] = nil; live[id] = nil; waits[id] = nil; autoRetries[id] = nil
            speedSamples[id] = nil
            awaitingResumeData.remove(id); resumeDataReady[id] = nil; taskAllowsCellular[id] = nil
            let record = records.removeValue(forKey: id)
            if record?.isTorrent == true, let external { runExternalLocked(id) { await external.delete(id) } }
            return (task, record)
        }
        task?.cancel()
        if let record {
            if let f = fileURL(record) { try? FileManager.default.removeItem(at: f) }
            record.subtitleFiles.forEach { try? FileManager.default.removeItem(at: subtitleURL($0)) }
        }
        try? FileManager.default.removeItem(at: resumeURL(id))
        save()
        pump()
    }

    public func delete(_ ids: [String]) { ids.forEach(delete) }

    /// Waits until queued deletes and stops of torrent downloads have finished (tests, teardown).
    public func settle() async {
        let ops = lock.withLock { Array(externalOps.values) }
        for op in ops { await op.value }
    }

    public func update(settings new: DownloadSettings) {
        lock.withLock { settings = new }
        moveTransfersToMatchCellularSetting()
        pump()
    }

    /// "Download Now" on mobile data (`true`): this download ignores Wi‑Fi Only
    /// and the torrent rule for mobile data. "Download on Wi‑Fi Later" (`false`):
    /// it waits for Wi‑Fi whatever Wi‑Fi Only says. nil follows the settings.
    public func setMobileData(_ id: String, allowed: Bool?) {
        let changed = lock.withLock { () -> Bool in
            guard records[id] != nil, records[id]?.allowsMobileData != allowed else { return false }
            records[id]?.allowsMobileData = allowed
            return true
        }
        guard changed else { return }
        save()
        moveTransfersToMatchCellularSetting()
        pump()
    }

    /// Settings › Mobile Data › Torrents: whether torrent downloads may run on mobile data.
    public func setTorrentsAllowedOnMobileData(_ allowed: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard conditions.torrentsAllowedOnMobileData != allowed else { return false }
            conditions.torrentsAllowedOnMobileData = allowed
            return true
        }
        if changed { pump() }
    }

    /// True when the download may use cellular data. Call with the lock held.
    private func allowsCellularLocked(_ id: String) -> Bool {
        records[id]?.allowsMobileData ?? (!settings.wifiOnly && records[id]?.isAutomatic != true)
    }

    /// A transfer keeps the cellular rule of the session it started in, so when
    /// Wi‑Fi Only changes, running HTTP transfers stop (keeping resume data) and
    /// continue in the session that matches.
    private func moveTransfersToMatchCellularSetting() {
        let moving = lock.withLock { () -> [String] in
            guard reattached else { return [] }
            let ids = tasks.keys.filter { taskAllowsCellular[$0] != allowsCellularLocked($0) }
            for id in ids where records[id]?.state == .downloading { records[id]?.state = .queued }
            return ids
        }
        moving.forEach(stopTransfer)
    }

    /// The same release can't download and stream at once (libtorrent keys
    /// torrents by info hash), so a download of a release that's streaming
    /// waits. Returns once any running transfer of it has stopped and closed
    /// its files.
    public func hold(_ token: String, reason: String) async {
        let token = token.lowercased()
        lock.withLock { holds[token] = reason }
        pump()
        await settle()
    }

    public func releaseHold(_ token: String) {
        let removed = lock.withLock { holds.removeValue(forKey: token.lowercased()) != nil }
        if removed { pump() }
    }

    /// iOS: torrents can't run in the background. Suspending stops them
    /// (keeping their data and their place in the queue); they continue when
    /// this is turned off again. Returns once they've stopped.
    public func setTorrentsSuspended(_ suspended: Bool) async {
        suspendTorrents(suspended)
        if suspended { await settle() }
    }

    /// The same, without waiting: callers that flip it quickly (background,
    /// foreground) must apply it in order, which separate Tasks don't.
    public func suspendTorrents(_ suspended: Bool) {
        lock.withLock { conditions.torrentsSuspended = suspended }
        pump()
    }

    /// iOS: whether the app should keep running in the background for torrent
    /// downloads, given the queue, settings, network and holds right now.
    public func backgroundDecision(isPlaying: Bool) -> BackgroundDownloadPolicy.Decision {
        lock.withLock {
            var heldIDs: [String: String] = [:]
            for r in records.values where r.isActive {
                if let reason = holds[r.id] ?? r.infoHash.flatMap({ holds[$0] }) { heldIDs[r.id] = reason }
            }
            return BackgroundDownloadPolicy.decide(records: Array(records.values), settings: settings,
                                                   conditions: conditions, holds: heldIDs, isPlaying: isPlaying)
        }
    }

    /// True when a torrent download is queued or transferring.
    public var hasActiveTorrents: Bool { lock.withLock { records.values.contains { $0.isTorrent && $0.isActive } } }

    /// True when a torrent download is transferring right now.
    public var hasRunningTorrents: Bool { lock.withLock { records.values.contains { $0.isTorrent && $0.state == .downloading } } }

    /// Writes the index now (progress is otherwise saved every few seconds),
    /// e.g. when iOS may suspend or end the app.
    public func saveNow() { save() }

    /// Test seam and manual override for the network state.
    public func networkChanged(online: Bool, expensive: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard conditions.isOnline != online || conditions.isExpensive != expensive else { return false }
            conditions.isOnline = online; conditions.isExpensive = expensive
            return true
        }
        if changed { pump() }
    }

    // MARK: Torrent (external) events

    public func externalConnecting(_ id: String) {
        let ok = lock.withLock { () -> Bool in
            guard externalRunning.contains(id) else { return false }
            live[id] = DownloadLiveStats(bytesPerSecond: 0, peers: 0, isConnecting: true)
            return true
        }
        if ok { notify() }
    }

    public func externalProgress(_ id: String, receivedBytes: Int64, totalBytes: Int64?, bytesPerSecond: Double, peers: Int) {
        let learnedSize = lock.withLock { () -> Int64?? in
            guard externalRunning.contains(id), records[id]?.state == .downloading else { return nil }
            let hadTotal = records[id]?.expectedBytes
            if receivedBytes > records[id]?.receivedBytes ?? 0 { lastBytesAt[id] = Date() }
            records[id]?.receivedBytes = receivedBytes
            if let totalBytes { records[id]?.expectedBytes = totalBytes }
            live[id] = DownloadLiveStats(bytesPerSecond: bytesPerSecond, peers: peers)
            return .some(hadTotal == totalBytes ? nil : totalBytes)
        }
        guard let learnedSize else { return }
        // Torrent sizes are only certain once the file list arrives.
        if let total = learnedSize, let free = freeSpaceProvider(directory), total - receivedBytes > free - Self.lowSpaceBytes {
            fail(id, DownloadError.insufficientSpace(needed: total - receivedBytes, free: free - Self.lowSpaceBytes).errorDescription!)
            return
        }
        progressChanged()
    }

    /// `fileName` is relative to `directory`.
    public func externalCompleted(_ id: String, fileName: String) {
        let url = directory.appending(path: fileName)
        guard lock.withLock({ externalRunning.remove(id) != nil }) else { return }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            lock.withLock { records[id]?.state = .failed("The download finished, but its file wasn't found. Retry to download it again.") }
            save(); pump()
            return
        }
        lock.withLock {
            records[id]?.state = .completed
            records[id]?.fileName = fileName
            records[id]?.receivedBytes = Int64(size)
            records[id]?.expectedBytes = Int64(size)
            records[id]?.completedAt = Date()
            live[id] = nil
        }
        save()
        pump()
    }

    public func externalFailed(_ id: String, message: String) {
        guard lock.withLock({ externalRunning.remove(id) != nil }) else { return }
        lock.withLock {
            if records[id]?.state == .downloading { records[id]?.state = .failed(message) }
            live[id] = nil
        }
        save()
        pump()
    }

    // MARK: Queue

    /// Starts and stops transfers to match the queue, settings and conditions.
    public func pump() {
        var startHTTP: [DownloadRecord] = []
        var startExternal: [DownloadRecord] = []
        var stops: [String] = []
        var refusedForSpace = false
        let ran = lock.withLock { () -> Bool in
            guard reattached && activated && !frozenForReview else { return false }
            conditions.automaticWindowOpen = settings.window.isOpen(at: Date(), isCharging: conditions.isCharging)
            let running = Set(tasks.keys).union(starting).union(externalRunning)
            var heldIDs: [String: String] = [:]
            for r in records.values where r.isActive {
                if let reason = holds[r.id] ?? r.infoHash.flatMap({ holds[$0] }) { heldIDs[r.id] = reason }
            }
            let plan = DownloadScheduler.plan(records: Array(records.values), running: running, settings: settings,
                                              conditions: conditions, holds: heldIDs)
            waits = plan.waits
            // Downloads started together share the free space.
            var free = plan.start.isEmpty ? nil : freeSpaceProvider(directory)
            for id in plan.stop {
                stops.append(id)
                if records[id]?.state == .downloading { records[id]?.state = .queued }
                live[id] = nil
            }
            for id in plan.start {
                guard var r = records[id] else { continue }
                if let remaining = r.remainingBytes, remaining > 0, let available = free {
                    guard remaining <= available - Self.lowSpaceBytes else {
                        r.state = .failed(DownloadError.insufficientSpace(needed: remaining, free: available - Self.lowSpaceBytes).errorDescription!)
                        records[id] = r
                        refusedForSpace = true
                        continue
                    }
                    free = available - remaining
                }
                r.state = .downloading
                records[id] = r
                waits[id] = nil
                lastBytesAt[id] = Date()
                if r.isTorrent {
                    externalRunning.insert(id)
                    if let external {
                        let record = r
                        runExternalLocked(id) { await external.start(record) }
                    } else {
                        startExternal.append(r)
                    }
                } else {
                    starting.insert(id)
                    startHTTP.append(r)
                }
            }
            return true
        }
        guard ran else { return }
        for id in stops { stopTransfer(id) }
        for r in startExternal { fail(r.id, "Torrent downloads need an iPhone or iPad.") }
        for r in startHTTP { beginHTTP(r) }
        save()
        if refusedForSpace { pump() }
    }

    /// Runs torrent start/stop/delete for one download in order.
    /// Call while holding `lock`, in the same critical section that decided
    /// on the op: otherwise a pause or delete decided later can be queued
    /// first, and the torrent starts after it was stopped, untracked.
    private func runExternalLocked(_ id: String, _ op: @escaping @Sendable () async -> Void) {
        let previous = externalOps[id]
        let token = UUID()
        externalOpTokens[id] = token
        externalOps[id] = Task { [weak self] in
            await previous?.value
            await op()
            guard let self else { return }
            self.lock.withLock {
                if self.externalOpTokens[id] == token { self.externalOps[id] = nil; self.externalOpTokens[id] = nil }
            }
        }
    }

    private func stopTransfer(_ id: String) {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            starting.remove(id)
            let task = tasks.removeValue(forKey: id)
            taskAllowsCellular[id] = nil
            if let task {
                stoppedTasks.insert(task.taskIdentifier)
                awaitingResumeData.insert(id)
            }
            speedSamples[id] = nil
            let wasExternal = externalRunning.remove(id) != nil
            if wasExternal, let external { runExternalLocked(id) { await external.stop(id) } }
            return task
        }
        task?.cancel { [weak self] data in self?.resumeDataArrived(id, data) }
    }

    /// The stopped transfer's resume data (nil if it can't resume). A resume
    /// that came in meanwhile was waiting for it, and starts now.
    func resumeDataArrived(_ id: String, _ data: Data?) {
        let restart = lock.withLock { () -> DownloadRecord? in
            guard awaitingResumeData.remove(id) != nil, records[id] != nil else { return nil }
            if let data { resumeDataReady[id] = data }
            return starting.contains(id) && records[id]?.state == .downloading ? records[id] : nil
        }
        if let data, lock.withLock({ records[id] != nil }) {
            try? data.write(to: resumeURL(id))
            // Deleted while writing: don't leave the file behind.
            if lock.withLock({ records[id] == nil }) { try? FileManager.default.removeItem(at: resumeURL(id)) }
        }
        if let restart { beginHTTP(restart) }
    }

    /// Tests: as if a transfer of `id` had just been stopped and its resume data is on the way.
    func expectResumeData(_ id: String) { lock.withLock { _ = awaitingResumeData.insert(id) } }

    private func fail(_ id: String, _ message: String) {
        let wasRunning = lock.withLock { () -> Bool in
            let running = externalRunning.contains(id) || tasks[id] != nil || starting.contains(id)
            // A late failure doesn't turn a download you paused into a failed one.
            if records[id]?.isActive == true { records[id]?.state = .failed(message) }
            live[id] = nil
            return running
        }
        if wasRunning { stopTransfer(id) }
        save()
        pump()
    }

    // MARK: HTTP transfers

    private func beginHTTP(_ r: DownloadRecord) {
        let id = r.id
        let (waiting, ready, http) = lock.withLock {
            (awaitingResumeData.contains(id), resumeDataReady.removeValue(forKey: id), allowsCellularLocked(id) ? session! : wifiSession!)
        }
        // Paused and resumed quickly: the stopped transfer's resume data is
        // still coming. Wait for it (resumeDataArrived restarts this) rather
        // than start again from zero.
        if waiting {
            // Backstop in case the system never answers: go on without it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.resumeDataArrived(id, nil) }
            return
        }
        if let data = ready ?? (try? Data(contentsOf: resumeURL(id))) {
            if Self.isUsableResumeData(data) {
                launch(id, task: http.downloadTask(withResumeData: data), fromResumeData: true)
                return
            }
            // Corrupt (say, half written): URLSession raises an Objective-C
            // exception on it, which would crash the app. Start over instead.
            try? FileManager.default.removeItem(at: resumeURL(id))
        }
        if let resource = lock.withLock({ pendingResources.removeValue(forKey: id) }) {
            launch(id, resource: resource)
            return
        }
        guard let resolve = resolveResource else {
            fail(id, "This download can't restart on its own. Delete it and download it again.")
            return
        }
        Task {
            do {
                let resource = try await resolve(r.origin)
                launch(id, resource: resource)
            } catch {
                guard lock.withLock({ starting.contains(id) }) else { return }
                fail(id, "Couldn't reach the source: \(error.localizedDescription)")
            }
        }
    }

    private func launch(_ id: String, resource: PlaybackResource) {
        guard ["http", "https"].contains(resource.url.scheme?.lowercased() ?? "") else {
            fail(id, DownloadError.notDownloadable.errorDescription!)
            return
        }
        var request = URLRequest(url: resource.url)
        resource.httpHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        // The session decides cellular (Wi‑Fi Only uses one that forbids it),
        // so a later resume from this task's data follows the setting too.
        let http = lock.withLock { () -> URLSession in
            pendingSubtitles[id] = resource.externalSubtitles
            return allowsCellularLocked(id) ? session : wifiSession
        }
        launch(id, task: http.downloadTask(with: request), fromResumeData: false)
    }

    private func launch(_ id: String, task: URLSessionDownloadTask, fromResumeData: Bool) {
        task.taskDescription = id
        let ok = lock.withLock { () -> Bool in
            guard starting.remove(id) != nil, records[id]?.state == .downloading else { return false }
            tasks[id] = task
            taskAllowsCellular[id] = allowsCellularLocked(id)
            if fromResumeData { resumedTasks.insert(task.taskIdentifier) }
            return true
        }
        if ok {
            onHTTPLaunch?(id, fromResumeData, lock.withLock { taskAllowsCellular[id] ?? true })
            task.resume()
        } else {
            task.cancel()
        }
    }

    // MARK: Plumbing

    /// Resume data is a property list naming the download; anything else
    /// makes `downloadTask(withResumeData:)` throw an Objective-C exception.
    static func isUsableResumeData(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return plist["NSURLSessionDownloadURL"] != nil || plist["NSURLSessionResumeCurrentRequest"] != nil
    }

    static func safeName(_ id: String) -> String {
        id.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
    }

    static func freeSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// After a relaunch: nothing is transferring yet, finished files must exist,
    /// and files no record points to are leftovers of deleted downloads.
    private func repairAfterLaunch() {
        let fm = FileManager.default
        for (id, r) in records {
            if r.state == .downloading { records[id]?.state = .queued }
            if r.state == .completed, let url = fileURL(r), !fm.fileExists(atPath: url.path) {
                records[id]?.state = .failed("The downloaded file is missing. Retry to download it again.")
                records[id]?.fileName = nil
                records[id]?.receivedBytes = 0
            }
        }
        var keep: Set<String> = ["index.json"]
        for r in records.values {
            if let f = r.fileName { keep.insert(f) }
            r.subtitleFiles.forEach { keep.insert($0.fileName) }
            keep.insert(".resume-\(Self.safeName(r.id))")
        }
        let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for url in contents where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            if !keep.contains(url.lastPathComponent) { try? fm.removeItem(at: url) }
        }
        save()
    }

    private func save() {
        // Snapshot and write under one lock: saves come from several threads,
        // and an older snapshot written last would undo a delete or a finish.
        saveLock.withLock {
            let list = all()
            lock.withLock { lastSave = Date() }
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: indexURL, options: .atomic) }
        }
        notify()
    }

    private func notify() {
        if let onChange { Task { @MainActor in onChange() } }
    }

    /// Progress: tell observers at most twice a second, save every few seconds, watch free space.
    private func progressChanged() {
        let (shouldSave, shouldNotify, checkSpace) = lock.withLock { () -> (Bool, Bool, Bool) in
            let now = Date()
            let n = now.timeIntervalSince(lastNotify) > 0.5
            if n { lastNotify = now }
            let c = now.timeIntervalSince(lastSpaceCheck) > 10
            if c { lastSpaceCheck = now }
            return (now.timeIntervalSince(lastSave) > 5, n, c)
        }
        if checkSpace, let free = freeSpaceProvider(directory), free < Self.lowSpaceBytes {
            let running = lock.withLock { Array(Set(tasks.keys).union(externalRunning)) }
            let message = "Stopped because your device is almost full. Free up space, then tap Retry."
            for id in running {
                lock.withLock { records[id]?.state = .failed(message); live[id] = nil }
                stopTransfer(id)
            }
            save()
            return
        }
        if shouldSave { save() } else if shouldNotify { notify() }
    }

    private func finish(_ id: String, task: URLSessionDownloadTask, at location: URL) {
        let r = lock.withLock { () -> DownloadRecord? in
            if tasks[id] === task { return records[id] }
            // A transfer from before a relaunch that finished before the
            // sessions reported their tasks (or while it sat queued): the
            // file is complete, so keep it rather than fetch it again.
            guard let r = records[id], r.isActive, !r.isTorrent, tasks[id] == nil else { return nil }
            tasks[id] = task
            starting.remove(id)
            awaitingResumeData.remove(id); resumeDataReady[id] = nil
            return r
        }
        guard let r else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.withLock {
                tasks[id] = nil
                records[id]?.state = .failed(http.statusCode == 403 || http.statusCode == 410
                                             ? "The link expired (HTTP \(http.statusCode)). Tap Retry for a fresh one."
                                             : "The server returned \(http.statusCode).")
            }
            try? FileManager.default.removeItem(at: resumeURL(id))
            return
        }
        let name = "\(Self.safeName(id)).\(Self.fileExtension(container: r.origin.container, response: task.response))"
        let dest = directory.appending(path: name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            lock.withLock {
                tasks[id] = nil
                records[id]?.state = .failed("Couldn't save the file: \(error.localizedDescription)")
            }
            return
        }
        try? FileManager.default.removeItem(at: resumeURL(id))
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let subs = lock.withLock { () -> [ExternalSubtitle] in
            records[id]?.state = .completed
            records[id]?.fileName = name
            records[id]?.completedAt = Date()
            if let size { records[id]?.receivedBytes = size; records[id]?.expectedBytes = size }
            tasks[id] = nil
            live[id] = nil
            autoRetries[id] = nil
            return pendingSubtitles.removeValue(forKey: id) ?? []
        }
        if !subs.isEmpty { Task { await self.saveSubtitles(subs, for: id) } }
    }

    static func fileExtension(container: String?, response: URLResponse?) -> String {
        func usable(_ e: String?) -> String? {
            guard let e = e?.lowercased(), !e.isEmpty, e.count <= 5, e.allSatisfy({ $0.isLetter || $0.isNumber }),
                  !["m3u8", "html", "json", "php"].contains(e) else { return nil }
            return e
        }
        return usable(container) ?? usable(response?.suggestedFilename.map { ($0 as NSString).pathExtension }) ?? "mp4"
    }

    private func saveSubtitles(_ subs: [ExternalSubtitle], for id: String) async {
        var files: [DownloadRecord.SubtitleFile] = []
        for (i, s) in subs.enumerated() {
            let name = "\(Self.safeName(id)).\(i).\(s.format)"
            let dest = directory.appending(path: name)
            do {
                let data = s.url.isFileURL ? try Data(contentsOf: s.url) : try await subtitleFetch(s.url)
                guard data.count < 10_000_000 else { continue }
                try data.write(to: dest, options: .atomic)
                files.append(.init(fileName: name, languageCode: s.languageCode, label: s.label, format: s.format))
            } catch { continue }
        }
        lock.withLock { records[id]?.subtitleFiles = files }
        save()
    }

    static func isConnectivity(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff,
                NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed].contains(error.code)
    }

    static func describe(_ error: NSError) -> String {
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed: "No internet connection."
        case NSURLErrorTimedOut: "The server stopped responding."
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: "Couldn't reach the server."
        case NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile: "Couldn't write the file. Your device may be full."
        default: error.localizedDescription
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // `location` is deleted when this method returns, so move it now.
        finish(id, task: downloadTask, at: location)
        save()
        pump()
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let current = lock.withLock { () -> Bool in
            guard tasks[id] === downloadTask else { return false }
            if totalBytesWritten > records[id]?.receivedBytes ?? 0 { lastBytesAt[id] = Date() }
            records[id]?.receivedBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { records[id]?.expectedBytes = totalBytesExpectedToWrite }
            let now = Date()
            if let sample = speedSamples[id] {
                let dt = now.timeIntervalSince(sample.at)
                if dt >= 1 {
                    let instant = Double(max(totalBytesWritten - sample.bytes, 0)) / dt
                    let previous = live[id]?.bytesPerSecond ?? 0
                    live[id] = DownloadLiveStats(bytesPerSecond: previous == 0 ? instant : previous * 0.6 + instant * 0.4)
                    speedSamples[id] = (totalBytesWritten, now)
                }
            } else {
                speedSamples[id] = (totalBytesWritten, now)
                live[id] = DownloadLiveStats()
            }
            return true
        }
        if current { progressChanged() }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        let ns = error as NSError?
        let resumeData = ns?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let (stopped, fromResume, current, exists) = lock.withLock {
            (stoppedTasks.remove(task.taskIdentifier) != nil, resumedTasks.remove(task.taskIdentifier) != nil,
             tasks[id] === task, records[id] != nil)
        }
        if stopped || !current {
            if let resumeData, exists { try? resumeData.write(to: resumeURL(id)) }
            return
        }
        guard let ns else { return }  // success is handled in didFinishDownloadingTo
        if let resumeData {
            try? resumeData.write(to: resumeURL(id))
        } else if fromResume {
            try? FileManager.default.removeItem(at: resumeURL(id))  // stale; the next try starts over
        }
        lock.withLock {
            tasks[id] = nil
            live[id] = nil
            speedSamples[id] = nil
            guard records[id]?.state == .downloading else { return }
            let retries = autoRetries[id, default: 0]
            if Self.isConnectivity(ns) && retries < 3 {
                // Picks up again when the connection is back.
                autoRetries[id] = retries + 1
                records[id]?.state = .queued
            } else {
                records[id]?.state = .failed(Self.describe(ns))
            }
        }
        save()
        if lock.withLock({ conditions.isOnline }) && Self.isConnectivity(ns) {
            // The monitor still says online; give the network a moment before retrying.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.pump() }
        } else {
            pump()
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let key = session.configuration.identifier ?? Self.backgroundIdentifier
        let done = Self.completionLock.withLock { Self.pendingCompletions.removeValue(forKey: key) }
        if let done { DispatchQueue.main.async { done() } }
    }
}
