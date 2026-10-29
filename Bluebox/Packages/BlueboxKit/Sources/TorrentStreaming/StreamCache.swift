//
//  StreamCache.swift
//  Bluebox
//
//  Streamed torrents stay on disk in Application Support/Streams/<info hash>
//  so replaying one is instant. The cache is trimmed least recently used
//  first to a size limit. Written for Bluebox.
//

import Foundation

public enum StreamCache {
    /// Application Support/Streams.
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Streams", directoryHint: .isDirectory)
    }

    static let marker = ".last-used"

    /// The folder for one torrent's stream.
    static func folder(for key: String, root: URL = root) -> URL {
        root.appending(path: key, directoryHint: .isDirectory)
    }

    /// Marks a stream folder as just used (creating it if needed).
    static func touch(_ key: String, root: URL = root, now: Date = Date()) {
        let folder = folder(for: key, root: root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: marker)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }

    /// Bytes on disk used by every cached stream.
    public static func totalBytes() -> Int64 { totalBytes(root: root) }

    static func totalBytes(root: URL) -> Int64 {
        entries(root: root).reduce(0) { $0 + $1.bytes }
    }

    /// Free space on the volume holding the cache, as the system reports it
    /// for important data (purgeable space counts). Nil if it can't be read.
    public static func availableBytes() -> Int64? {
        var url = root
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Deletes every cached stream.
    public static func clear() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Deletes least recently used streams until the cache fits in `limit`
    /// bytes. Folders in `keeping` (streams playing now) are never deleted.
    /// Returns the keys deleted.
    @discardableResult
    public static func prune(toBytes limit: Int64, keeping: Set<String> = []) -> [String] {
        prune(root: root, toBytes: limit, keeping: keeping)
    }

    @discardableResult
    static func prune(root: URL, toBytes limit: Int64, keeping: Set<String>) -> [String] {
        var all = entries(root: root)
        var total = all.reduce(0) { $0 + $1.bytes }
        guard total > limit else { return [] }
        all.sort { $0.lastUsed < $1.lastUsed }
        var removed: [String] = []
        for entry in all where total > limit && !keeping.contains(entry.key) {
            do {
                try FileManager.default.removeItem(at: entry.url)
                total -= entry.bytes
                removed.append(entry.key)
            } catch {
                continue
            }
        }
        return removed
    }

    struct Entry {
        var key: String
        var url: URL
        var bytes: Int64
        var lastUsed: Date
    }

    static func entries(root: URL) -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.compactMap { name in
            let url = root.appending(path: name, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let markerDate = (try? fm.attributesOfItem(atPath: url.appending(path: marker).path))?[.modificationDate] as? Date
            let folderDate = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return Entry(key: name, url: url, bytes: allocatedSize(url), lastUsed: markerDate ?? folderDate ?? .distantPast)
        }
    }

    static func allocatedSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }
}
