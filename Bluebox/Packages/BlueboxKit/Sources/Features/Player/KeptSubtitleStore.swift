import Domain
import Foundation

/// The subtitle file last chosen for a title (downloaded, imported, picked
/// from Search Online or found by the automatic search), kept with it so the
/// next viewing puts it back instead of searching and downloading again
/// against the site's daily limit. One file per title, in Application
/// Support › Bluebox › Kept Subtitles › <title> (Bluebox's own folder, so
/// Erase All Data takes it). Like generated subtitles, it's only put back for
/// a video of the same length, since another release can be cut differently.
struct KeptSubtitleStore: Sendable {
    let folder: URL

    static let shared = KeptSubtitleStore(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Bluebox/Kept Subtitles", directoryHint: .isDirectory))

    struct Note: Codable, Hashable, Sendable {
        /// The file's name in the title's folder (the original name, so its
        /// language tag still names the track).
        var file: String
        /// How long the video was, when known.
        var duration: TimeInterval?
        var kept: Date
    }

    /// A title's folder name: its key with the characters a file name can't have replaced.
    private func folder(for key: MediaKey) -> URL {
        let safe = key.rawValue.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        return folder.appending(path: safe, directoryHint: .isDirectory)
    }

    private func noteURL(for key: MediaKey) -> URL { folder(for: key).appending(path: "kept.json") }

    /// True for a file this store already holds (putting it back mustn't keep it again).
    func holds(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// Copies `url` in as the title's file, in place of the one before. Returns the kept copy.
    @discardableResult
    func keep(_ url: URL, for key: MediaKey, duration: TimeInterval?, now: Date = .now) throws -> URL {
        let dir = folder(for: key)
        if holds(url) { return url }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = url.lastPathComponent == "kept.json" ? "subtitles.srt" : url.lastPathComponent
        let copy = dir.appending(path: name)
        try FileManager.default.copyItem(at: url, to: copy)
        let note = Note(file: name, duration: duration.flatMap { $0 > 0 ? $0 : nil }, kept: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(note).write(to: noteURL(for: key), options: .atomic)
        return copy
    }

    /// The title's kept file, for a video `duration` long (any length when nil or not noted).
    func kept(for key: MediaKey, duration: TimeInterval?) -> URL? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: noteURL(for: key)), let note = try? decoder.decode(Note.self, from: data) else { return nil }
        if let duration, duration > 0, let saved = note.duration, abs(saved - duration) > 5 { return nil }
        let file = folder(for: key).appending(path: note.file)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    func delete(_ key: MediaKey) { try? FileManager.default.removeItem(at: folder(for: key)) }
}
