import Domain
import Foundation
import Subtitles

/// Generated subtitles saved with the title they were written for, so the
/// next viewing offers them instead of listening again: an SRT file per
/// language and a note of what it covers, in Application Support › Bluebox ›
/// Generated Subtitles › <title> (Bluebox's own folder, so Erase All Data takes it). A track half written carries on from where it stopped.
/// Only offered for a video of the same length, since another release of the
/// same film can be cut differently.
struct GeneratedSubtitleStore: Sendable {
    let folder: URL

    static let shared = GeneratedSubtitleStore(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Bluebox/Generated Subtitles", directoryHint: .isDirectory))

    /// What a saved track holds, beside its lines.
    struct Note: Codable, Hashable, Sendable {
        var spoken: String
        var language: String
        var duration: TimeInterval
        var covered: CoveredTime
        var engine: String
        var title: String
        var written: Date
    }

    struct Saved: Hashable, Sendable {
        let note: Note
        let file: URL
        var complete: Bool { note.covered.covers(note.duration) }
    }

    /// A videos's folder name: its key with the characters a file name can't have replaced.
    private func folder(for key: MediaKey) -> URL {
        let safe = key.rawValue.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        return folder.appending(path: safe, directoryHint: .isDirectory)
    }

    func files(for key: MediaKey, language: String) -> (srt: URL, note: URL) {
        let dir = folder(for: key)
        return (dir.appending(path: "\(language).srt"), dir.appending(path: "\(language).json"))
    }

    /// The tracks saved for a title, for a video `duration` long (any length when nil).
    func saved(for key: MediaKey, duration: TimeInterval?) -> [Saved] {
        let dir = folder(for: key)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            let noteURL = dir.appending(path: name)
            guard let data = try? Data(contentsOf: noteURL), let note = try? Self.decoder.decode(Note.self, from: data) else { return nil }
            if let duration, abs(note.duration - duration) > 5 { return nil }
            let srt = noteURL.deletingPathExtension().appendingPathExtension("srt")
            guard FileManager.default.fileExists(atPath: srt.path) else { return nil }
            return Saved(note: note, file: srt)
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func save(_ cues: [SubtitleCue], note: Note, for key: MediaKey) throws {
        let (srt, noteURL) = files(for: key, language: note.language)
        try FileManager.default.createDirectory(at: srt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(SpeechSubtitles.srt(cues).utf8).write(to: srt, options: .atomic)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(note).write(to: noteURL, options: .atomic)
    }

    /// The lines of a saved track.
    func cues(_ saved: Saved) -> [SubtitleCue] {
        guard let data = try? Data(contentsOf: saved.file), let timeline = try? SubtitleParser.parse(data, format: .srt) else { return [] }
        return timeline.cues
    }

    func delete(_ key: MediaKey) { try? FileManager.default.removeItem(at: folder(for: key)) }

    func deleteAll() { try? FileManager.default.removeItem(at: folder) }

    /// Titles with saved subtitles, and the space they take (Storage).
    func usage() -> (titles: Int, bytes: Int64) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return (0, 0) }
        var bytes: Int64 = 0, titles = 0
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]), !files.isEmpty else { continue }
            titles += 1
            bytes += files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return (titles, bytes)
    }
}
