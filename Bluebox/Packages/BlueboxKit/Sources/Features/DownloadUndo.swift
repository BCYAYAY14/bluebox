import Domain
import Downloads
import Foundation
import Observation

/// Downloads deleted a moment ago. They disappear from every screen at once,
/// but stay on disk until their Undo toast has gone, so Undo can bring them
/// back. A single delete gets Undo; deleting many asks first instead.
@MainActor
@Observable
final class PendingDownloadDeletes {
    static let shared = PendingDownloadDeletes()

    private(set) var ids: Set<String> = []
    /// Bumped on every change, for views that reload on it.
    private(set) var revision = 0
    /// Which hold each download belongs to, so a timer only commits what's
    /// still its own (not one undone, then deleted again under a newer hold).
    @ObservationIgnored private var holds: [String: UUID] = [:]

    /// A little longer than a toast with a button stays up (`AppToast.duration`).
    static let grace: Duration = .seconds(8.5)

    /// Deletes still waiting are written down, so one whose app quit before
    /// its toast went (a paused download left behind) is finished at the next launch.
    static let savedKey = "bluebox.downloads.pendingDeletes"
    @ObservationIgnored var defaults: UserDefaults = .standard

    /// The deletes the last launch didn't get to commit; reading them clears them.
    func takeLeftovers() -> [String] {
        let saved = defaults.stringArray(forKey: Self.savedKey) ?? []
        defaults.removeObject(forKey: Self.savedKey)
        return saved.filter { !ids.contains($0) }
    }

    private func persist() {
        if ids.isEmpty { defaults.removeObject(forKey: Self.savedKey) } else { defaults.set(ids.sorted(), forKey: Self.savedKey) }
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Holds a group (one download, or a season's) under one timer, which
    /// commits whatever of it hasn't been undone in one go: one index write
    /// for a season, not one per episode.
    fileprivate func hold(_ group: [String], commit: @escaping @MainActor (Set<String>) -> Void) {
        let token = UUID()
        for id in group { ids.insert(id); holds[id] = token }
        revision += 1
        persist()
        Task { [weak self] in
            try? await Task.sleep(for: Self.grace)
            guard let self else { return }
            let still = Set(group.filter { self.holds[$0] == token })
            guard !still.isEmpty else { return }
            commit(still)
            self.release(still)
        }
    }

    /// Undo: cancels the deletes still waiting. Returns the ones it brought back.
    fileprivate func undo(_ group: [String]) -> Set<String> {
        let back = Set(group.filter { holds[$0] != nil })
        if !back.isEmpty { release(back) }
        return back
    }

    private func release(_ group: Set<String>) {
        for id in group { holds[id] = nil; ids.remove(id) }
        revision += 1
        persist()
    }
}

extension AppModel {
    /// At launch: deletes whose Undo toast was still up when Bluebox quit.
    func finishLeftoverDownloadDeletes() {
        let leftovers = PendingDownloadDeletes.shared.takeLeftovers().compactMap { downloads.record(id: $0) }
        if !leftovers.isEmpty { deleteDownloads(leftovers) }
    }

    /// `download(for:)`, leaving out one that's waiting out its Undo.
    func visibleDownload(for key: MediaKey) -> DownloadRecord? {
        guard let r = download(for: key), !PendingDownloadDeletes.shared.contains(r.id) else { return nil }
        return r
    }

    /// Deletes a finished download, or cancels one in progress, with an Undo
    /// toast. It's gone from the screen at once (and stops downloading); the
    /// file goes when the toast does.
    func deleteDownloadWithUndo(_ r: DownloadRecord, title: String? = nil, message: String? = nil) {
        let pending = PendingDownloadDeletes.shared
        let wasRunning = r.isActive
        if wasRunning { pauseDownload(r) }
        pending.hold([r.id]) { [weak self] _ in self?.deleteDownloads([r]) }
        let name = r.subtitle.map { "\(r.title) · \($0)" } ?? r.title
        showToast(AppToast(title ?? (r.state == .completed ? "Download deleted" : "Download canceled"), message: message ?? name,
                           verbatim: message == nil ? .message : [], actionTitle: "Undo") { [weak self] in
            guard let self, !pending.undo([r.id]).isEmpty else { return }
            if wasRunning { self.downloads.resume(r.id) }
        })
    }

    /// Try Another Release: `old` (already stopped) gives way to `new`, which
    /// is already queued. Undo brings `old` back and takes `new` out again
    /// (nil: it was queued before, so Undo leaves it).
    func replaceDownloadWithUndo(_ old: DownloadRecord, by new: DownloadRecord?, title: String, verbatimMessage: String) {
        let pending = PendingDownloadDeletes.shared
        pending.hold([old.id]) { [weak self] _ in self?.deleteDownloads([old]) }
        showToast(AppToast(title, verbatimMessage: verbatimMessage, style: .success, actionTitle: "Undo") { [weak self] in
            guard let self, !pending.undo([old.id]).isEmpty else { return }
            if let new, let current = self.downloads.record(id: new.id) { self.deleteDownloads([current]) }
        })
    }

    /// Cancels or deletes several downloads at once (a season), with one
    /// Undo that brings them all back and restarts the ones that were running.
    func deleteDownloadsWithUndo(_ records: [DownloadRecord], title: String) {
        guard !records.isEmpty else { return }
        if records.count == 1 { deleteDownloadWithUndo(records[0]); return }
        let pending = PendingDownloadDeletes.shared
        let running = records.filter(\.isActive).map(\.id)
        // One pause, one delete and one resume for the lot, each a single index write.
        if !running.isEmpty { downloads.pause(running) }
        pending.hold(records.map(\.id)) { [weak self] still in
            self?.deleteDownloads(records.filter { still.contains($0.id) })
        }
        let name = records[0].title
        showToast(AppToast(title, message: "\(name) · \(records.count) episodes", actionTitle: "Undo") { [weak self] in
            guard let self else { return }
            let back = pending.undo(records.map(\.id))
            let restart = running.filter(back.contains)
            if !restart.isEmpty { self.downloads.resume(restart) }
        })
    }

    /// Plays a finished download, unless its file has gone missing: then says
    /// so plainly and offers to download it again.
    func playDownloadChecked(_ r: DownloadRecord, in external: ExternalPlayer? = nil) async {
        guard r.state == .completed else { return }
        if let url = downloads.fileURL(r), FileManager.default.fileExists(atPath: url.path) {
            await playDownload(r, in: external)
            return
        }
        let name = r.subtitle.map { "\(r.title) · \($0)" } ?? r.title
        var redownload: (@MainActor () -> Void)?
        if r.mediaKey != nil {
            redownload = { [weak self] in
                Task { await self?.downloadAgain(r) }
            }
        }
        showToast(AppToast("The downloaded file is missing", message: name, style: .error,
                           actionTitle: "Download Again", action: redownload))
    }

    /// Replaces a download whose file is missing with a fresh one.
    func downloadAgain(_ r: DownloadRecord) async {
        deleteDownloads([r])
        guard let key = r.mediaKey else { return }
        await startDownload(key: key, title: r.title, subtitle: r.subtitle)
    }
}
