import Domain
import Foundation

/// Keeps the torrents the user added, their sessions and their files.
///
/// Bluebox never searches for torrents. It only downloads what the user adds
/// themselves, from a magnet link or a .torrent file they have the right to use.
/// Playback URLs look like `bluebox-torrent://<info hash>/<file index>.<ext>`.
public actor TorrentClient: StreamDataProvider {
    public static let scheme = "bluebox-torrent"

    let directory: URL
    let fetch: Tracker.Fetch
    let peerID: Data
    private var descriptors: [InfoHash: TorrentDescriptor] = [:]
    private var order: [InfoHash] = []
    private var sessions: [InfoHash: TorrentSession] = [:]
    private var indexURL: URL { directory.appending(path: "index.json") }

    public init(directory: URL, fetch: Tracker.Fetch? = nil) {
        self.directory = directory
        self.fetch = fetch ?? { req in
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw TorrentError.storage("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            return data
        }
        var id = Data("-BJ0100-".utf8)
        id.append(contentsOf: (0..<12).map { _ in UInt8.random(in: 0...255) })
        peerID = id
        if let data = try? Data(contentsOf: directory.appending(path: "index.json")),
           let list = try? JSONDecoder().decode([TorrentDescriptor].self, from: data) {
            for d in list { descriptors[d.infoHash] = d; order.append(d.infoHash) }
        }
    }

    // MARK: Library

    public func all() -> [TorrentDescriptor] { order.compactMap { descriptors[$0] } }

    /// Adds a magnet link or .torrent contents and starts fetching it.
    @discardableResult
    public func add(_ descriptor: TorrentDescriptor) throws -> InfoHash {
        var d = descriptor
        if let existing = descriptors[d.infoHash] {
            d.trackers = Array(Set(existing.trackers + d.trackers))
            d.webSeeds = Array(Set(existing.webSeeds + d.webSeeds))
            d.infoData = existing.infoData ?? d.infoData
            d.displayName = existing.displayName ?? d.displayName
        }
        guard !d.trackers.isEmpty || !d.webSeeds.isEmpty || d.infoData != nil else { throw TorrentError.noTrackers }
        // Only after validation: a rejected add must not leave its hash in `order`, or
        // adding it again later lists (and resumes) the torrent twice.
        if !order.contains(d.infoHash) { order.append(d.infoHash) }
        descriptors[d.infoHash] = d
        try save()
        _ = session(for: d.infoHash)
        return d.infoHash
    }

    public func remove(_ hash: InfoHash, deleteFiles: Bool = true) async {
        if let s = sessions.removeValue(forKey: hash) { await s.stop() }
        descriptors[hash] = nil
        order.removeAll { $0 == hash }
        try? save()
        if deleteFiles { try? FileManager.default.removeItem(at: folder(for: hash)) }
    }

    /// The file list, fetching it from peers first for magnet links.
    public func info(for hash: InfoHash, timeout: TimeInterval = 60) async throws -> TorrentInfo {
        guard let s = session(for: hash) else { throw TorrentError.metadataUnavailable }
        return try await s.waitForInfo(timeout: timeout)
    }

    /// Info that's already known, without waiting.
    public func knownInfo(for hash: InfoHash) -> TorrentInfo? {
        descriptors[hash]?.infoData.flatMap { try? TorrentInfo(raw: $0) }
    }

    public func status(_ hash: InfoHash) async -> TorrentStatus? {
        guard descriptors[hash] != nil else { return nil }
        if let s = sessions[hash] { return await s.status() }
        let info = knownInfo(for: hash)
        return TorrentStatus(phase: .paused, name: info?.name ?? descriptors[hash]?.displayName ?? hash.hex,
                             haveBytes: 0, wantedBytes: info?.totalLength ?? 0, peers: 0, bytesPerSecond: 0)
    }

    public func resume(_ hash: InfoHash) async { await session(for: hash)?.start() }
    public func pause(_ hash: InfoHash) async { await sessions[hash]?.stop() }

    /// Starts sessions for every torrent (call at launch).
    public func resumeAll() async {
        for h in order { await session(for: h)?.start() }
    }

    public func stopAll() async {
        for s in sessions.values { await s.stop() }
    }

    // MARK: Playback

    public static func streamURL(_ hash: InfoHash, file index: Int, ext: String) -> URL {
        URL(string: "\(scheme)://\(hash.hex)/\(index)\(ext.isEmpty ? "" : "." + ext)")!
    }

    static func parse(_ url: URL) -> (InfoHash, Int)? {
        guard url.scheme == scheme, let host = url.host(), let hash = InfoHash(hex: host),
              let idx = Int(url.lastPathComponent.split(separator: ".").first ?? "") else { return nil }
        return (hash, idx)
    }

    /// A finished file's local URL (plays like any local file), else nil.
    public func completedFileURL(_ hash: InfoHash, file index: Int) async -> URL? {
        guard let s = session(for: hash) else { return nil }
        return await s.completedFileURL(index)
    }

    public nonisolated func canProvide(_ url: URL) -> Bool { url.scheme == Self.scheme }

    public func contentLength(of url: URL) async throws -> Int64 {
        guard let (hash, idx) = Self.parse(url), let s = session(for: hash) else { throw TorrentError.storage("unknown torrent") }
        await s.start()
        return try await s.fileLength(idx)
    }

    public func read(_ url: URL, offset: Int64, length: Int) async throws -> Data {
        guard let (hash, idx) = Self.parse(url), let s = session(for: hash) else { throw TorrentError.storage("unknown torrent") }
        return try await s.read(file: idx, offset: offset, length: length)
    }

    // MARK: Plumbing

    func folder(for hash: InfoHash) -> URL { directory.appending(path: hash.hex, directoryHint: .isDirectory) }

    private func session(for hash: InfoHash) -> TorrentSession? {
        if let s = sessions[hash] { return s }
        guard let d = descriptors[hash] else { return nil }
        let s = TorrentSession(descriptor: d, directory: folder(for: hash), peerID: peerID, fetch: fetch) { [weak self] updated in
            Task { await self?.metadataArrived(updated) }
        }
        sessions[hash] = s
        Task { await s.start() }
        return s
    }

    private func metadataArrived(_ d: TorrentDescriptor) {
        guard descriptors[d.infoHash] != nil else { return }
        descriptors[d.infoHash] = d
        try? save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(all()).write(to: indexURL, options: .atomic)
    }
}
