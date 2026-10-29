//
//  TorrentEngine.swift
//  Bluebox
//
//  The one libtorrent session the process keeps, shared by streaming and
//  downloads. It stays alive between streams (so peers, the DHT and tracker
//  state stay warm), saves the DHT routing table so the next launch starts
//  warm too, follows network changes, keeps resume data next to each
//  torrent's files, and shuts libtorrent down before the process exits.
//  Written for Bluebox.
//

import Domain
import Foundation
import os

let torrentLog = Logger(subsystem: Log.subsystem, category: "torrent")

#if canImport(LibTorrentEngine)
import LibTorrentEngine
import Network
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Session-wide knobs from `TorrentStreamSettings`.
struct EngineSettings: Sendable, Equatable {
    var maxPeers = 80
    var uploadRateLimit: Int64?
    var uploadOnExpensiveNetwork = true

    init() {}

    init(_ s: TorrentStreamSettings) {
        maxPeers = s.maxPeers
        uploadRateLimit = s.uploadRateLimit
        uploadOnExpensiveNetwork = s.uploadOnExpensiveNetwork
    }
}

final class TorrentEngine: @unchecked Sendable {
    static let shared = TorrentEngine()

    private let lock = NSLock()
    private var current: BBTorrentSession?
    private var settings = EngineSettings()
    private var terminating = false
    private var monitor: NWPathMonitor?
    private var pathSignature: String?
    private var network = NetworkSnapshot()
    var currentNetwork: NetworkSnapshot { lock.withLock { network } }
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var totals = TorrentTransferTotals()
    private var lastCounters: (received: Int64, sent: Int64) = (0, 0)
    private var ticks = 0
    private let queue = DispatchQueue(label: "app.bluebox.torrent.engine")

    struct NetworkSnapshot: Sendable, Equatable {
        var kind = "unknown"
        var isExpensive = false
        var isConstrained = false
        var isSatisfied = true
    }

    #if os(iOS)
    static let lowMemory = true
    #else
    static let lowMemory = false
    #endif

    static var stateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Torrent", directoryHint: .isDirectory)
    }

    static var stateFile: URL { stateDirectory.appending(path: "session.state") }

    /// The running session, started on first use. Nil once the app is terminating.
    var session: BBTorrentSession? {
        lock.lock()
        defer { lock.unlock() }
        if let current, !current.isShutDown { return current }
        guard !terminating else { return nil }
        let state = try? Data(contentsOf: Self.stateFile)
        let started = BBTorrentSession(configuration: configuration(), state: state)
        _ = started.setSetting("unchoke_slots_limit", integer: unchokeSlots())
        current = started
        torrentLog.notice("engine: libtorrent \(BBTorrentSession.libtorrentVersion, privacy: .public) started (\(state == nil ? "cold" : "warm", privacy: .public) DHT)")
        startWatching()
        return started
    }

    /// Whether a session is running, without starting one.
    var isRunning: Bool { lock.withLock { current.map { !$0.isShutDown } ?? false } }

    /// Outgoing uTP starts off (TCP reaches full speed sooner) and is turned
    /// on, for the rest of the session, the first time a swarm looks thin:
    /// some peers can only be reached over uTP.
    private var outgoingUTP = false

    /// Settings › Mobile Data › Upload While Streaming (app-wide, beside the stream settings).
    private var expensiveUploadAllowed = true

    func setUploadOnExpensiveNetwork(_ allowed: Bool) {
        let session: BBTorrentSession? = lock.withLock {
            guard expensiveUploadAllowed != allowed else { return nil }
            expensiveUploadAllowed = allowed
            return current
        }
        session.map { apply(to: $0) }
    }

    func allowOutgoingUTP(reason: String) {
        let session: BBTorrentSession? = lock.withLock {
            guard !outgoingUTP else { return nil }
            outgoingUTP = true
            return current
        }
        guard let session else { return }
        torrentLog.notice("engine: turning on outgoing uTP (\(reason, privacy: .public))")
        StreamMetrics.shared.event("utp-on", ["reason": reason])
        apply(to: session)
    }

    func update(_ settings: EngineSettings) {
        let session: BBTorrentSession? = lock.withLock {
            guard settings != self.settings else { return nil }
            self.settings = settings
            return current
        }
        session.map { apply(to: $0) }
    }

    private func apply(to session: BBTorrentSession) {
        let (configuration, slots) = lock.withLock { (configuration(), unchokeSlots()) }
        session.apply(configuration)
        _ = session.setSetting("unchoke_slots_limit", integer: slots)
    }

    /// Call under the lock. Not uploading means sending no peer any pieces
    /// (no unchoke slots), not a tiny rate limit: libtorrent's limit covers
    /// protocol messages too, and at a byte a second the handshakes and piece
    /// requests never go out, so nothing downloads either.
    private func unchokeSlots() -> Int {
        let s = settings
        let noUpload = (network.isExpensive && !(s.uploadOnExpensiveNetwork && expensiveUploadAllowed))
            || (s.uploadRateLimit.map { $0 <= 0 } ?? false)
        return noUpload ? 0 : 8  // libtorrent's default
    }

    /// Call under the lock.
    private func configuration() -> BBSessionConfiguration {
        let c = BBSessionConfiguration()
        let s = settings
        c.connectionsLimit = max(60, s.maxPeers * 2)
        c.listenPort = Self.listenPort
        // No uploading is unchokeSlots(); a limit of 0 here means unlimited.
        if let limit = s.uploadRateLimit, limit > 0 { c.uploadRateLimit = Int(clamping: limit) }
        c.enableDHT = true
        c.enableLSD = true
        c.enableUTP = true
        c.enableOutgoingUTP = outgoingUTP
        c.enablePortMapping = !Self.lowMemory
        c.lowMemory = Self.lowMemory
        c.diskQueueBytes = Self.lowMemory ? 2 * 1024 * 1024 : 8 * 1024 * 1024
        return c
    }

    /// A port kept across launches, so peers and the DHT can find us again.
    private static var listenPort: Int {
        let key = "bluebox.torrent.listenPort"
        let saved = UserDefaults.standard.integer(forKey: key)
        if (20000...60000).contains(saved) { return saved }
        let port = Int.random(in: 20000...60000)
        UserDefaults.standard.set(port, forKey: key)
        return port
    }

    // MARK: Torrents

    /// Adds `magnet` for `user` (or joins it if streaming and downloading
    /// share it). Resume data saved in `savePath` is used when present.
    func acquire(_ magnet: MagnetLink, user: String, savePath: URL, extraTrackers: [String] = [],
                 priorities: [Int: Int]? = nil) throws -> BBTorrentHandle {
        guard let session else { throw TorrentStreamError.unavailableOnThisPlatform }
        try FileManager.default.createDirectory(at: savePath, withIntermediateDirectories: true)
        let resume = try? Data(contentsOf: Self.resumeFile(key: magnet.key, savePath: savePath))
        let trackers = DefaultTrackers.merged(magnet.trackers.map(\.absoluteString) + extraTrackers)
        let prios = priorities.map { Dictionary(uniqueKeysWithValues: $0.map { (NSNumber(value: $0.key), NSNumber(value: $0.value)) }) }
        return try session.acquire(link: magnet.uri, trackers: trackers, savePath: savePath.path,
                                   resumeData: resume, user: user, priorities: prios)
    }

    /// Drops `user` from a torrent. Returns true when the torrent left the session.
    @discardableResult
    func release(_ handle: BBTorrentHandle, user: String, deleteFiles: Bool) -> Bool {
        guard let session = lock.withLock({ current }) else { return false }
        return session.release(handle, user: user, deleteFiles: deleteFiles)
    }

    static func resumeFile(key: String, savePath: URL) -> URL {
        savePath.appending(path: ".resume-\(key)")
    }

    /// Writes resume data for `handle` next to its files (best effort).
    func saveResumeData(_ handle: BBTorrentHandle) async {
        let key = handle.infoHash
        let path = URL(fileURLWithPath: handle.savePath, isDirectory: true)
        guard handle.hasMetadata else { return }
        let data: Data? = await withCheckedContinuation { continuation in
            handle.saveResumeData { data, _ in continuation.resume(returning: data) }
        }
        guard let data else { return }
        try? data.write(to: Self.resumeFile(key: key, savePath: path), options: .atomic)
    }

    /// Saves resume data for every torrent, waiting at most `timeout` seconds.
    func saveAllResumeData(timeout: TimeInterval) {
        guard let session = lock.withLock({ current }), !session.isShutDown else { return }
        let group = DispatchGroup()
        for handle in session.torrents() where handle.hasMetadata {
            group.enter()
            let key = handle.infoHash
            let path = URL(fileURLWithPath: handle.savePath, isDirectory: true)
            handle.saveResumeData { data, _ in
                if let data { try? data.write(to: Self.resumeFile(key: key, savePath: path), options: .atomic) }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    func saveSessionState() {
        guard let session = lock.withLock({ current }), let state = session.sessionState() else { return }
        try? FileManager.default.createDirectory(at: Self.stateDirectory, withIntermediateDirectories: true)
        try? state.write(to: Self.stateFile, options: .atomic)
    }

    // MARK: Totals

    var transferTotals: TorrentTransferTotals {
        sampleCounters()
        return lock.withLock { totals }
    }

    private func sampleCounters() {
        guard let session = lock.withLock({ current }) else { return }
        let stats = session.stats()
        lock.withLock {
            let dr = max(0, stats.bytesReceived - lastCounters.received)
            let ds = max(0, stats.bytesSent - lastCounters.sent)
            lastCounters = (stats.bytesReceived, stats.bytesSent)
            totals.received += dr
            totals.sent += ds
            if network.isExpensive {
                totals.receivedOnExpensiveNetwork += dr
                totals.sentOnExpensiveNetwork += ds
            }
        }
    }

    // MARK: Shutdown

    /// Saves resume data and the DHT state, stops every torrent (trackers get
    /// up to two seconds to hear it) and destroys the session. Safe to call
    /// more than once; a later `session` starts a fresh one unless the app is
    /// terminating.
    func shutdown(terminating: Bool = false) {
        let session: BBTorrentSession? = lock.withLock {
            if terminating { self.terminating = true }
            return current
        }
        guard let session, !session.isShutDown else { return }
        saveAllResumeData(timeout: 1.5)
        saveSessionState()
        let began = Date()
        session.shutdown(withTimeout: 2)
        lock.withLock {
            if current === session { current = nil }
            timer?.cancel()
            timer = nil
            monitor?.cancel()
            monitor = nil
            pathSignature = nil
            lastCounters = (0, 0)
        }
        torrentLog.notice("engine: shut down in \(String(format: "%.2f", Date().timeIntervalSince(began)), privacy: .public)s")
    }

    // MARK: Watching the network and the app (called under the lock)

    private func startWatching() {
        if monitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
            monitor.start(queue: queue)
            self.monitor = monitor
        }
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        #if os(macOS)
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            TorrentEngine.shared.shutdown(terminating: true)
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            TorrentEngine.shared.networkChanged(reason: "wake")
        })
        #elseif canImport(UIKit)
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            TorrentEngine.shared.shutdown(terminating: true)
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            let engine = TorrentEngine.shared
            engine.queue.async {
                engine.saveAllResumeData(timeout: 2)
                engine.saveSessionState()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            TorrentEngine.shared.networkChanged(reason: "foreground")
        })
        #endif
    }

    private func pathChanged(_ path: NWPath) {
        var snapshot = NetworkSnapshot()
        snapshot.kind = path.usesInterfaceType(.wifi) ? "wifi"
            : path.usesInterfaceType(.cellular) ? "cellular"
            : path.usesInterfaceType(.wiredEthernet) ? "wired"
            : path.status == .satisfied ? "other" : "offline"
        snapshot.isExpensive = path.isExpensive
        snapshot.isConstrained = path.isConstrained
        snapshot.isSatisfied = path.status == .satisfied
        let signature = "\(path.status)|" + path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
        let (changed, expensiveChanged, session) = lock.withLock {
            let changed = pathSignature != nil && pathSignature != signature
            let expensiveChanged = network.isExpensive != snapshot.isExpensive
            pathSignature = signature
            network = snapshot
            return (changed, expensiveChanged, current)
        }
        if expensiveChanged { session.map { apply(to: $0) } }
        if changed && snapshot.isSatisfied { networkChanged(reason: snapshot.kind) }
    }

    /// Rebinds listen sockets to the current interfaces and re-announces.
    func networkChanged(reason: String) {
        guard let session = lock.withLock({ current }), !session.isShutDown else { return }
        torrentLog.notice("engine: network changed (\(reason, privacy: .public)); rebinding and re-announcing")
        session.networkChanged()
        StreamMetrics.shared.event("network-change", ["reason": reason])
    }

    private func tick() {
        sampleCounters()
        let n = lock.withLock { () -> Int in ticks += 1; return ticks }
        // Every minute: resume data. Every five: the DHT table.
        if n % 30 == 0 { saveAllResumeData(timeout: 5) }
        if n % 150 == 0 { saveSessionState() }
    }
}
#endif
