import Domain
import Downloads
import Foundation
import Observation
import TorrentStreaming
#if os(iOS)
import BackgroundTasks
import UIKit
import UserNotifications
#endif

/// Keeps torrent downloads going after you leave Bluebox on iPhone and iPad.
///
/// HTTP downloads use a background URLSession and aren't affected; torrents
/// need the app running. With Settings › Downloads › Keep Downloading in the
/// Background on (the default):
/// - While a torrent can download and Bluebox is in the background, a silent
///   audio session that mixes with other audio (`SilentAudioKeepAlive`) keeps
///   it running. It stops as soon as no torrent can download (all finished or
///   paused, or waiting for Wi‑Fi or a connection under the Wi‑Fi Only and
///   Mobile Data rules), while real playback plays (that keeps the app running
///   by itself), and when Bluebox comes back. The rules are
///   `BackgroundDownloadPolicy`.
/// - iOS can still stop the app (a long phone call, memory). Torrents are then
///   stopped cleanly (libtorrent saves resume data) and a notification says so.
/// - A processing task (`AppModel.downloadResumeTaskID`) is scheduled for when
///   the device charges on a network; it resumes torrents until iOS ends it.
/// - A torrent finishing in the background posts a notification.
/// With the setting off, Bluebox asks for iOS's ~30 seconds, downloads for
/// most of it, then stops torrents until it's open again.
/// On the Mac the app keeps running, so nothing here applies.
@MainActor
final class DownloadLifecycle {
    /// True while Bluebox is in the background (iOS), including a background
    /// launch for the processing task. Always false on the Mac.
    private(set) var isInBackground = false
    /// The player is playing (that keeps the app running on its own). Set by AppModel.
    var isPlaying: () -> Bool = { false }
    /// A player is open, so the audio session mustn't be deactivated. Set by AppModel.
    var isPlayerOpen: () -> Bool = { false }

    static let notificationCategory = "bluebox.downloads"
    static let pausedNotificationID = "bluebox.downloads.paused"

    #if os(iOS)
    private var manager: DownloadManager?
    private var observers: [NSObjectProtocol] = []
    private let keepAlive = SilentAudioKeepAlive()
    /// iOS's ~30 seconds, held while winding down or waiting out an interruption.
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var windDown: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var processing: BGProcessingTask?
    /// Torrents are being stopped.
    private var pausing = false
    /// Done for this trip to the background (torrents stopped): wait to be
    /// suspended rather than start anything again.
    private var dormant = false
    /// The silent session ran during this trip to the background.
    private var keptAlive = false
    private var pausedNotified = false
    private var lastStartFailure: Date?
    private var lastPlaying = false

    private enum PauseReason { case stopped, waitingForWiFi, offline }
    #endif

    func start(manager: DownloadManager) {
        #if os(iOS)
        guard observers.isEmpty else { return }
        self.manager = manager
        keepAlive.onChange = { [weak self] in self?.evaluate() }
        // Launched in the background (iOS delivering download events, or the
        // processing task): no didEnterBackground comes.
        if UIApplication.shared.applicationState == .background {
            isInBackground = true
            if processing == nil {
                dormant = true
                manager.suspendTorrents(true)
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteringForeground() }
        })
        #endif
    }

    /// The download queue changed (progress, a finish, the network). AppModel calls this.
    func downloadsChanged() {
        #if os(iOS)
        evaluate()
        #endif
    }

    /// Says a torrent finished while Bluebox was in the background.
    static func notifyFinished(_ record: DownloadRecord) {
        #if os(iOS)
        let name = record.subtitle.map { "\(record.title) · \($0)" } ?? record.title
        let key = record.mediaKey
        Task {
            await EpisodeNotifications.post(id: "bluebox.downloads.done.\(record.id)", title: "Downloaded",
                                            body: "“\(name)” is ready to watch offline.", key: key, series: key?.seriesKey,
                                            category: notificationCategory, thread: notificationCategory)
        }
        #endif
    }

    #if os(iOS)
    private var isEnabled: Bool { manager?.currentSettings.keepDownloadingInBackground ?? false }

    // MARK: Foreground and background

    private func enteredBackground() {
        guard let manager else { return }
        isInBackground = true
        dormant = false; pausing = false; keptAlive = false; pausedNotified = false; lastStartFailure = nil
        manager.saveNow()  // libtorrent saves resume data itself (TorrentEngine)
        if isEnabled && manager.hasActiveTorrents { Self.scheduleProcessingTask() }
        beginGrace()
        startTicker()
        watchPlayback()
        evaluate()
    }

    private func enteringForeground() {
        isInBackground = false
        dormant = false; pausing = false
        ticker?.cancel(); ticker = nil
        cancelWindDown()
        stopKeepAlive()
        endGrace()
        finishProcessing(success: true)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppModel.downloadResumeTaskID)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.pausedNotificationID])
        manager?.suspendTorrents(false)
    }

    // MARK: Deciding

    /// Acts on `BackgroundDownloadPolicy` for the state right now. Cheap; called
    /// on every queue change, playback change, audio interruption and every 10 seconds.
    private func evaluate() {
        guard isInBackground, !dormant, !pausing, let manager else { return }
        if processing != nil { evaluateProcessing(manager); return }
        switch manager.backgroundDecision(isPlaying: isPlaying()) {
        case .keepAlive:
            if keepAlive.isInterrupted { beginGrace(); return }  // a call: wait for it to end
            if !keepAlive.isRunning {
                if let last = lastStartFailure, Date().timeIntervalSince(last) < 10 { stopSoon(notify: true); return }
                guard keepAlive.start() else {
                    lastStartFailure = Date()
                    stopSoon(notify: true)
                    return
                }
            }
            keptAlive = true
            resumeTorrents()
            endGrace()
        case .playbackKeepsAlive:
            keepAlive.stop(deactivate: false)
            resumeTorrents()
            beginGrace()  // time to start the silence again when playback stops
        case .stop(.nothingToDownload):
            stopKeepAlive()
            if !manager.currentConditions.torrentsSuspended { manager.suspendTorrents(true) }  // nothing starts while away
            release(after: 3)  // time for a "Downloaded" notification to go out
        case .stop(.settingOff):
            stopKeepAlive()
            stopSoon(notify: false)
        case .stop(.waitingForWiFi):
            stopKeepAlive()
            stopNow(notify: keptAlive ? .waitingForWiFi : nil)
        case .stop(.offline):
            stopKeepAlive()
            stopNow(notify: keptAlive ? .offline : nil)
        case .stop(.held):
            stopKeepAlive()
            stopNow(notify: nil)
        }
    }

    private func resumeTorrents() {
        cancelWindDown()
        if let manager, manager.currentConditions.torrentsSuspended { manager.suspendTorrents(false) }
    }

    private func stopKeepAlive() {
        keepAlive.stop(deactivate: !isPlayerOpen())
    }

    /// Downloads for most of iOS's ~30 seconds, then stops torrents.
    private func stopSoon(notify: Bool) {
        guard windDown == nil else { return }
        beginGrace()
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let keepGoing = remaining.isFinite ? min(max(remaining - 8, 0), 25) : 25
        windDown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(keepGoing))
            guard !Task.isCancelled else { return }
            await self?.pause(notify: notify ? .stopped : nil)
        }
    }

    private func stopNow(notify: PauseReason?) {
        cancelWindDown()
        beginGrace()
        windDown = Task { [weak self] in await self?.pause(notify: notify) }
    }

    /// Lets iOS suspend the app after `seconds`, with nothing left to download.
    private func release(after seconds: Double) {
        guard windDown == nil else { return }
        beginGrace()
        windDown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.windDown = nil
            self.dormant = true
            self.endGrace()
        }
    }

    /// Stops torrents (libtorrent saves resume data as each stops), says so if
    /// they were running, and asks for the processing task.
    private func pause(notify: PauseReason?) async {
        guard let manager, !pausing else { return }
        pausing = true
        let wereRunning = manager.hasRunningTorrents || keptAlive
        stopKeepAlive()
        manager.saveNow()
        await manager.setTorrentsSuspended(true)
        pausing = false
        windDown = nil
        guard isInBackground else { return }  // came back meanwhile
        if let notify, wereRunning, manager.hasActiveTorrents { postPaused(notify) }
        if isEnabled && manager.hasActiveTorrents { Self.scheduleProcessingTask() }
        dormant = true
        endGrace()
    }

    private func cancelWindDown() {
        windDown?.cancel()
        windDown = nil
    }

    // MARK: iOS's grace period

    private func beginGrace() {
        guard grace == .invalid else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "Torrent downloads") { [weak self] in
            MainActor.assumeIsolated { self?.graceExpired() }
        }
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    /// iOS's time is up. If nothing else keeps the app running, stop torrents
    /// now (resume data first), or iOS ends the app.
    private func graceExpired() {
        guard let manager, isInBackground, !dormant, !keepAlive.isRunning, !isPlaying() else { endGrace(); return }
        let wereRunning = manager.hasRunningTorrents || keptAlive
        cancelWindDown()
        stopKeepAlive()
        manager.suspendTorrents(true)
        TorrentStreamer.saveResumeData(timeout: 1)
        manager.saveNow()
        if isEnabled && wereRunning && manager.hasActiveTorrents { postPaused(.stopped) }
        if isEnabled && manager.hasActiveTorrents { Self.scheduleProcessingTask() }
        dormant = true
        endGrace()
    }

    // MARK: Watching

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.isInBackground else { return }
                self.evaluate()
            }
        }
    }

    /// Re-decides as soon as playback starts or stops (pausing in Picture in
    /// Picture leaves only seconds before iOS suspends the app).
    private func watchPlayback() {
        guard isInBackground else { return }
        lastPlaying = withObservationTracking { isPlaying() } onChange: { [weak self] in
            Task { @MainActor in self?.playbackMayHaveChanged() }
        }
    }

    private func playbackMayHaveChanged() {
        guard isInBackground else { return }
        let was = lastPlaying
        watchPlayback()
        if lastPlaying != was { evaluate() }
    }

    // MARK: Processing task

    /// Asks iOS to run torrents while the device charges on a network.
    static func scheduleProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: AppModel.downloadResumeTaskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.sources.notice("Background downloads: couldn't schedule the processing task: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// iOS started the processing task. Call before the queue starts; `beginProcessing` runs it.
    func adoptProcessingTask(_ task: BGProcessingTask) {
        processing?.setTaskCompleted(success: true)
        processing = task
        nonisolated(unsafe) let adopted = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                if let self { self.processingExpired() } else { adopted.setTaskCompleted(success: false) }
            }
        }
    }

    /// Runs the adopted processing task: torrents download until they're done
    /// or iOS ends it. Does nothing if Bluebox is open or already kept running.
    func beginProcessing() {
        guard processing != nil, manager != nil else { return }
        if UIApplication.shared.applicationState != .background || keepAlive.isRunning {
            finishProcessing(success: true)
            return
        }
        isInBackground = true
        dormant = false; pausing = false
        cancelWindDown()
        startTicker()
        Log.sources.notice("Background downloads: processing task started")
        evaluate()
    }

    private func evaluateProcessing(_ manager: DownloadManager) {
        switch manager.backgroundDecision(isPlaying: false) {
        case .keepAlive, .playbackKeepsAlive:
            resumeTorrents()
        case .stop(.nothingToDownload):
            if !manager.currentConditions.torrentsSuspended { manager.suspendTorrents(true) }
            guard windDown == nil else { return }
            windDown = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))  // time for a "Downloaded" notification
                guard !Task.isCancelled else { return }
                self?.finishProcessing(success: true)
            }
        case .stop:
            pausing = true
            cancelWindDown()
            windDown = Task { [weak self] in
                await manager.setTorrentsSuspended(true)
                self?.pausing = false
                self?.finishProcessing(success: true)
            }
        }
    }

    private func finishProcessing(success: Bool) {
        guard let task = processing else { return }
        processing = nil
        windDown = nil
        task.setTaskCompleted(success: success)
        if isInBackground { dormant = true }
        Log.sources.notice("Background downloads: processing task finished")
    }

    /// iOS ended the processing task: stop torrents now, saving resume data.
    private func processingExpired() {
        guard let task = processing else { return }
        processing = nil
        cancelWindDown()
        if let manager {
            let wereRunning = manager.hasRunningTorrents
            manager.suspendTorrents(true)
            TorrentStreamer.saveResumeData(timeout: 1)
            manager.saveNow()
            if wereRunning && manager.hasActiveTorrents { postPaused(.stopped) }
            if isEnabled && manager.hasActiveTorrents { Self.scheduleProcessingTask() }
        }
        pausing = false
        if isInBackground { dormant = true }
        task.setTaskCompleted(success: false)
        Log.sources.notice("Background downloads: processing task expired")
    }

    // MARK: Notifications

    private func postPaused(_ reason: PauseReason) {
        guard !pausedNotified else { return }
        pausedNotified = true
        let device = UIDevice.current.model  // "iPhone", "iPad"
        let why = switch reason {
        case .waitingForWiFi: "Waiting for Wi‑Fi."
        case .offline: "You're offline."
        case .stopped: "iOS stopped Bluebox in the background."
        }
        let body = "\(why) They continue when you open Bluebox, and may continue while your \(device) charges."
        Task {
            await EpisodeNotifications.post(id: Self.pausedNotificationID, title: "Torrent downloads paused", body: body,
                                            key: nil, series: nil, category: Self.notificationCategory,
                                            thread: Self.notificationCategory, sound: false)
        }
    }
    #endif
}
