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
    @ObservationIgnored private var commits: [String: Task<Void, Never>] = [:]

    /// A little longer than a toast with a button stays up (`AppToast.duration`).
    static let grace: Duration = .seconds(8.5)

    func contains(_ id: String) -> Bool { ids.contains(id) }

    fileprivate func hold(_ id: String, commit: @escaping @MainActor () -> Void) {
        ids.insert(id)
        revision += 1
        commits[id]?.cancel()
        commits[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.grace)
            guard !Task.isCancelled, let self, self.ids.contains(id) else { return }
            commit()
            self.release(id)
        }
    }

    /// Undo: cancels the delete. Returns false if it already happened.
    fileprivate func undo(_ id: String) -> Bool {
        guard ids.contains(id) else { return false }
        commits[id]?.cancel()
        release(id)
        return true
    }

    private func release(_ id: String) {
        commits[id] = nil
        ids.remove(id)
        revision += 1
    }
}

extension AppModel {
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
        pending.hold(r.id) { [weak self] in self?.deleteDownloads([r]) }
        let name = r.subtitle.map { "\(r.title) · \($0)" } ?? r.title
        showToast(AppToast(title ?? (r.state == .completed ? "Download deleted" : "Download canceled"), message: message ?? name,
                           actionTitle: "Undo") { [weak self] in
            guard let self, pending.undo(r.id) else { return }
            if wasRunning { self.downloads.resume(r.id) }
        })
    }

    /// Cancels or deletes several downloads at once (a season), with one
    /// Undo that brings them all back and restarts the ones that were running.
    func deleteDownloadsWithUndo(_ records: [DownloadRecord], title: String) {
        guard !records.isEmpty else { return }
        if records.count == 1 { deleteDownloadWithUndo(records[0]); return }
        let pending = PendingDownloadDeletes.shared
        let running = Set(records.filter(\.isActive).map(\.id))
        for r in records {
            if running.contains(r.id) { pauseDownload(r) }
            pending.hold(r.id) { [weak self] in self?.deleteDownloads([r]) }
        }
        let name = records[0].title
        showToast(AppToast(title, message: "\(name) · \(records.count) episodes", actionTitle: "Undo") { [weak self] in
            guard let self else { return }
            for r in records where pending.undo(r.id) && running.contains(r.id) { self.downloads.resume(r.id) }
        })
    }

    /// Plays a finished download, unless its file has gone missing: then says
    /// so plainly and offers to download it again.
    func playDownloadChecked(_ r: DownloadRecord) async {
        guard r.state == .completed else { return }
        if let url = downloads.fileURL(r), FileManager.default.fileExists(atPath: url.path) {
            await playDownload(r)
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
