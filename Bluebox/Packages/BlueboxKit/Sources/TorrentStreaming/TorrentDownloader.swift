//
//  TorrentDownloader.swift
//  Bluebox
//
//  Downloads one file of a torrent for offline viewing, into
//  <root>/<info hash>/<path in torrent>. Several downloads from one torrent
//  (episodes of a season pack) and a stream of it all share one libtorrent
//  torrent: each asks for its own file, and nothing is fetched twice.
//  Pausing saves resume data and keeps what arrived; deleting removes it.
//  The records themselves live in DownloadManager. Written for Bluebox.
//

import Foundation
#if canImport(LibTorrentEngine)
import LibTorrentEngine
#endif

public typealias TorrentDownloadEvent = TorrentDownloader.Event
public typealias TorrentDownloadProgress = TorrentDownloader.Progress

public actor TorrentDownloader {
    public enum Event: Sendable, Equatable {
        /// Finding peers and the file list.
        case connecting
        case progress(Progress)
        /// Done; the path is relative to `folder(for:)`.
        case completed(String)
        case failed(String)
    }

    public struct Progress: Sendable, Equatable {
        public var receivedBytes: Int64
        public var totalBytes: Int64?
        public var bytesPerSecond: Double
        public var peers: Int

        public init(receivedBytes: Int64, totalBytes: Int64?, bytesPerSecond: Double, peers: Int) {
            self.receivedBytes = receivedBytes
            self.totalBytes = totalBytes
            self.bytesPerSecond = bytesPerSecond
            self.peers = peers
        }
    }

    /// What's remembered per download, so pause, delete and pruning work after a relaunch.
    struct Record: Codable, Sendable, Equatable {
        var key: String
        var fileIndex: Int?
        var path: String?
    }

    public nonisolated let root: URL
    private var settings: TorrentStreamSettings
    private var records: [String: Record] = [:]
    /// Downloads deleted while a stream still used their torrent: their files go once it's free.
    private var pendingDeletes: [String: Record] = [:]
    #if canImport(LibTorrentEngine)
    private var jobs: [String: Job] = [:]

    private struct Job {
        var handle: BBTorrentHandle?
        var task: Task<Void, Never>
    }
    #endif

    /// Metadata can take a while for thin torrents; a download waits longer than a stream.
    static let metadataTimeout: TimeInterval = 300

    public init(root: URL, settings: TorrentStreamSettings) {
        self.root = root
        self.settings = settings
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: root.appending(path: ".downloads.json")),
           let saved = try? JSONDecoder().decode(Index.self, from: data) {
            records = saved.records
            pendingDeletes = saved.pendingDeletes
        }
        #if canImport(LibTorrentEngine)
        TorrentEngine.shared.update(EngineSettings(settings))
        #endif
    }

    private struct Index: Codable {
        var records: [String: Record]
        var pendingDeletes: [String: Record]
    }

    private func saveIndex() {
        let index = Index(records: records, pendingDeletes: pendingDeletes)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: root.appending(path: ".downloads.json"), options: .atomic)
    }

    public func update(settings: TorrentStreamSettings) {
        self.settings = settings
        #if canImport(LibTorrentEngine)
        TorrentEngine.shared.update(EngineSettings(settings))
        #endif
    }

    /// The folder completed paths are relative to.
    public nonisolated func folder(for id: String) -> URL { root }

    private func user(_ id: String) -> String { "download:\(id)" }

    /// Starts or resumes download `id`. Returns once it's under way; progress
    /// arrives through `onEvent`.
    public func start(id: String, magnet: String, fileIndex: Int?, episode: EpisodeNumber? = nil,
                      onEvent: @escaping @Sendable (Event) -> Void) async {
        #if canImport(LibTorrentEngine)
        guard jobs[id] == nil else { return }
        guard let link = MagnetLink(string: magnet) else {
            onEvent(.failed(TorrentStreamError.invalidMagnet.localizedDescription))
            return
        }
        let folder = root.appending(path: link.key, directoryHint: .isDirectory)
        var record = records[id] ?? Record(key: link.key, fileIndex: fileIndex)
        record.key = link.key
        records[id] = record
        saveIndex()
        onEvent(.connecting)

        let handle: BBTorrentHandle
        do {
            handle = try TorrentEngine.shared.acquire(link, user: user(id), savePath: folder,
                                                      extraTrackers: settings.extraTrackers.map(\.absoluteString))
        } catch {
            onEvent(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            return
        }
        // Streaming got here first: its files move from the stream cache into Downloads.
        if URL(fileURLWithPath: handle.savePath).standardizedFileURL.path != folder.standardizedFileURL.path {
            handle.moveStorage(toPath: folder.path)
        }
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.run(id: id, handle: handle, link: link, fileIndex: fileIndex, episode: episode, onEvent: onEvent)
        }
        jobs[id] = Job(handle: handle, task: task)
        #else
        onEvent(.failed(TorrentStreamError.unavailableOnThisPlatform.localizedDescription))
        #endif
    }

    /// Stops download `id` and keeps what has arrived (resume data included).
    public func pause(_ id: String) async {
        #if canImport(LibTorrentEngine)
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.task.cancel()
        if let handle = job.handle {
            await TorrentEngine.shared.saveResumeData(handle)
            TorrentEngine.shared.release(handle, user: user(id), deleteFiles: false)
        }
        #endif
    }

    /// Stops download `id` and deletes its file.
    public func delete(_ id: String) async {
        #if canImport(LibTorrentEngine)
        let job = jobs.removeValue(forKey: id)
        job?.task.cancel()
        guard let record = records.removeValue(forKey: id) else { saveIndex(); return }
        if let handle = job?.handle {
            let removed = TorrentEngine.shared.release(handle, user: user(id), deleteFiles: true)
            if removed { removeFolderIfUnused(record.key) }
        } else if TorrentEngine.shared.session?.torrent(withInfoHash: record.key) != nil {
            // A stream is reading this torrent: delete once it's done.
            pendingDeletes[id] = record
        } else {
            deleteFiles(of: record)
        }
        saveIndex()
        #else
        records[id] = nil
        saveIndex()
        #endif
    }

    /// Deletes folders no download refers to (left by deleted or old records).
    public func pruneFolders(keeping ids: Set<String>) async {
        for id in records.keys where !ids.contains(id) { records[id] = nil }
        let fm = FileManager.default
        for (id, record) in pendingDeletes {
            #if canImport(LibTorrentEngine)
            if TorrentEngine.shared.isRunning, TorrentEngine.shared.session?.torrent(withInfoHash: record.key) != nil { continue }
            #endif
            deleteFiles(of: record)
            pendingDeletes[id] = nil
        }
        let used = Set(records.values.map(\.key))
        if let names = try? fm.contentsOfDirectory(atPath: root.path) {
            for name in names where !name.hasPrefix(".") && !used.contains(name) && !ids.contains(name) {
                try? fm.removeItem(at: root.appending(path: name))
            }
        }
        saveIndex()
    }

    // MARK: Internals

    private func deleteFiles(of record: Record) {
        let folder = root.appending(path: record.key, directoryHint: .isDirectory)
        if let path = record.path { try? FileManager.default.removeItem(at: folder.appending(path: path)) }
        removeFolderIfUnused(record.key)
    }

    /// Removes a torrent's folder when no other download uses it.
    private func removeFolderIfUnused(_ key: String) {
        guard !records.values.contains(where: { $0.key == key }) else { return }
        try? FileManager.default.removeItem(at: root.appending(path: key, directoryHint: .isDirectory))
    }

    private func remember(_ id: String, path: String, fileIndex: Int) {
        guard var record = records[id] else { return }
        record.path = path
        record.fileIndex = fileIndex
        records[id] = record
        saveIndex()
    }

    private func finished(_ id: String) {
        jobs[id] = nil
    }

    #if canImport(LibTorrentEngine)
    private func run(id: String, handle: BBTorrentHandle, link: MagnetLink, fileIndex: Int?, episode: EpisodeNumber?,
                     onEvent: @escaping @Sendable (Event) -> Void) async {
        let user = user(id)
        // 1. The file list.
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                handle.waitForMetadata(timeout: Self.metadataTimeout) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            TorrentEngine.shared.release(handle, user: user, deleteFiles: false)
            finished(id)
            onEvent(.failed(TorrentStreamError.noPeers.localizedDescription))
            return
        }
        guard !Task.isCancelled else { return }

        // 2. Which file.
        let files = handle.files.map { TorrentFileEntry(index: $0.index, path: $0.path, size: $0.size, isPadding: $0.isPadding) }
        guard let file = FileSelection.choose(files, preferred: fileIndex, episode: episode) else {
            TorrentEngine.shared.release(handle, user: user, deleteFiles: true)
            finished(id)
            onEvent(.failed(TorrentStreamError.noPlayableFile.localizedDescription))
            return
        }
        remember(id, path: file.path, fileIndex: file.index)
        handle.setFilePriorities([NSNumber(value: file.index): NSNumber(value: 4)], user: user)
        handle.resume()

        // 3. Progress until the file is complete.
        var lastDone: Int64 = -1
        var lastProgress = Date()
        var lastReport = Date.distantPast
        while !Task.isCancelled {
            // Completion counts checked pieces only; what's shown also counts
            // pieces still arriving (with 16 MiB pieces, checked bytes sit at
            // zero for minutes).
            let progress = handle.fileProgress()
            let done = progress.indices.contains(file.index) ? progress[file.index].int64Value : 0
            let partial = handle.fileProgressIncludingPartialPieces()
            let arrived = max(done, partial.indices.contains(file.index) ? partial[file.index].int64Value : 0)
            let status = handle.status()
            if Date().timeIntervalSince(lastReport) >= 30 {
                lastReport = Date()
                torrentLog.notice("""
                    download: \(id, privacy: .public) \(arrived)/\(file.size) bytes (checked \(done)), \
                    \(status.downloadRate) B/s, peers \(status.peers) (seeds \(status.seeds), known \(status.knownPeers), \
                    candidates \(status.connectCandidates)), hash failures \(status.hashFailures), \
                    state \(status.state.rawValue), paused \(status.isPaused), \
                    net \(TorrentEngine.shared.currentNetwork.kind, privacy: .public)\(TorrentEngine.shared.currentNetwork.isExpensive ? " (expensive)" : "", privacy: .public)
                    """)
            }
            if done >= file.size {
                await TorrentEngine.shared.saveResumeData(handle)
                TorrentEngine.shared.release(handle, user: user, deleteFiles: false)
                finished(id)
                torrentLog.notice("download: \(id, privacy: .public) complete (\(file.size) bytes)")
                onEvent(.completed("\(link.key)/\(file.path)"))
                return
            }
            if let error = status.errorMessage {
                await TorrentEngine.shared.saveResumeData(handle)
                TorrentEngine.shared.release(handle, user: user, deleteFiles: false)
                finished(id)
                onEvent(.failed(error))
                return
            }
            onEvent(.progress(Progress(receivedBytes: arrived, totalBytes: file.size,
                                       bytesPerSecond: Double(status.downloadRate), peers: status.peers)))
            if arrived > lastDone {
                lastDone = arrived
                lastProgress = Date()
            } else if Date().timeIntervalSince(lastProgress) > 30 {
                // Stalled: ask for more peers and add trackers.
                handle.addTrackers(DefaultTrackers.fallback)
                handle.reannounce()
                lastProgress = Date()
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
    #endif
}
