import Domain
import Downloads
import DownloadsActivity
import Foundation
import Observation
#if os(iOS)
import ActivityKit
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Downloads outside the app's window: the Live Activity on iPhone, the
/// Dock badge on the Mac (the menu bar extra is `MenuBarDownloadsView`).
/// AppModel calls `downloadsChanged()` on every queue change.
@MainActor
final class DownloadsPresence {
    /// The Live Activity switch (FeatureSwitches.liveActivity). Set by AppModel.
    var liveActivityEnabled: () -> Bool = { false }
    /// What the activity shows now; nil when the queue is empty. Set by AppModel.
    var currentState: () -> DownloadsActivityState? = { nil }

    func start() {
        #if os(iOS)
        liveActivity.start(self)
        #endif
        downloadsChanged()
    }

    func downloadsChanged() {
        #if os(iOS)
        liveActivity.refresh(self)
        #elseif os(macOS)
        mac.update(activeCount: currentState()?.activeCount ?? 0)
        #endif
    }

    #if os(iOS)
    private let liveActivity = LiveActivityDriver()
    #elseif os(macOS)
    private let mac = MacDownloadsDock()
    #endif
}

extension DownloadsActivityState {
    /// The queue in one line. nil when nothing is downloading or queued.
    /// Rounded (whole percent, 100 kB/s, whole minutes) so updates only go out
    /// when what's on screen would change.
    static func summary(_ records: [DownloadRecord], live: (String) -> DownloadLiveStats?) -> DownloadsActivityState? {
        let active = records.filter(\.isActive).sorted { $0.sortOrder < $1.sortOrder }
        guard let current = active.first(where: { $0.state == .downloading }) ?? active.first else { return nil }
        let speed = active.reduce(0.0) { $0 + (live($1.id)?.bytesPerSecond ?? 0) }
        var expected: Int64 = 0, received: Int64 = 0, unknownSizes = false
        for r in active {
            guard let e = r.expectedBytes, e > 0 else { unknownSizes = true; continue }
            expected += e
            received += min(r.receivedBytes, e)
        }
        let fraction = expected > 0 ? (Double(received) / Double(expected) * 100).rounded(.down) / 100 : 0
        let remaining = Double(expected - received)
        var secondsLeft: Int?
        if !unknownSizes, speed > 1_000, remaining > 0 {
            let s = remaining / speed
            secondsLeft = s < 60 ? 30 : Int((s / 60).rounded(.up)) * 60
        }
        let subtitle = current.subtitle ?? current.mediaKey?.episodeNumbers.map { "S\($0.season)·E\($0.episode)" }
        return DownloadsActivityState(title: current.title, subtitle: subtitle, activeCount: active.count,
                                      bytesPerSecond: (speed / 100_000).rounded() * 100_000,
                                      secondsLeft: secondsLeft, fraction: fraction)
    }
}

#if os(iOS)
/// Starts the Live Activity as Bluebox leaves the screen with downloads
/// running (ActivityKit only starts one from the foreground), updates it at
/// most every 5 s (`ActivityUpdateThrottle`), and ends it when the queue
/// empties or the switch goes off. It isn't started while Bluebox is open:
/// the Downloads tab already shows the same thing.
@MainActor
private final class LiveActivityDriver {
    private var activity: Activity<DownloadsActivityAttributes>?
    private var throttle = ActivityUpdateThrottle<DownloadsActivityState>(minimumInterval: 5)
    private var deferred: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// Without an update for this long (Bluebox was stopped), the activity shows as stale.
    private static let staleAfter: TimeInterval = 10 * 60

    func start(_ owner: DownloadsPresence) {
        guard observers.isEmpty else { return }
        // One left over from a previous run: carry on with it, end any others.
        let existing = Activity<DownloadsActivityAttributes>.activities
        activity = existing.first
        for extra in existing.dropFirst() {
            nonisolated(unsafe) let extra = extra  // Activity isn't Sendable; ActivityKit serialises its own calls
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        // Still in the foreground at this point, so ActivityKit allows a start.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self, weak owner] _ in
            MainActor.assumeIsolated {
                guard let self, let owner else { return }
                self.refresh(owner, leaving: true)
            }
        })
        observeSwitch(owner)
    }

    /// The switch is read on each change anyway; this ends the activity at once when it's turned off.
    private func observeSwitch(_ owner: DownloadsPresence) {
        withObservationTracking { _ = owner.liveActivityEnabled() } onChange: { [weak self, weak owner] in
            Task { @MainActor in
                guard let self, let owner else { return }
                self.refresh(owner)
                self.observeSwitch(owner)
            }
        }
    }

    func refresh(_ owner: DownloadsPresence, leaving: Bool = false) {
        guard owner.liveActivityEnabled(), let state = owner.currentState() else { end(); return }
        guard let activity else {
            guard leaving, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            request(state)
            return
        }
        guard activity.activityState == .active || activity.activityState == .stale else {
            // Dismissed from the Lock Screen: don't bring it back until the next trip away.
            self.activity = nil
            return
        }
        switch throttle.decide(state, now: Date()) {
        case .unchanged:
            deferred?.cancel(); deferred = nil
        case .sendNow:
            deferred?.cancel(); deferred = nil
            send(state, to: activity)
        case .waitUntil(let due):
            guard deferred == nil else { return }  // the pending send reads the newest state
            deferred = Task { [weak self, weak owner] in
                try? await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 0)))
                guard !Task.isCancelled, let self, let owner else { return }
                self.deferred = nil
                self.refresh(owner)
            }
        }
    }

    private func request(_ state: DownloadsActivityState) {
        do {
            activity = try Activity.request(attributes: DownloadsActivityAttributes(),
                                            content: content(state), pushType: nil)
            throttle.reset()
            throttle.didSend(state, at: Date())
        } catch {
            Log.sources.notice("Live Activity didn't start: \(String(describing: error), privacy: .public)")
        }
    }

    private func send(_ state: DownloadsActivityState, to activity: Activity<DownloadsActivityAttributes>) {
        throttle.didSend(state, at: Date())
        let content = content(state)
        nonisolated(unsafe) let activity = activity
        Task { await activity.update(content) }
    }

    private func content(_ state: DownloadsActivityState) -> ActivityContent<DownloadsActivityState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
    }

    private func end() {
        deferred?.cancel(); deferred = nil
        guard let current = activity else { return }
        nonisolated(unsafe) let ending = current
        activity = nil
        throttle.reset()
        Task { await ending.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif

#if os(macOS)
/// The Dock badge, and an App Nap exemption while downloads run: with the
/// window closed, macOS would otherwise throttle Bluebox's timers and network.
@MainActor
private final class MacDownloadsDock {
    private var shown = 0
    private var activity: NSObjectProtocol?

    func update(activeCount: Int) {
        guard activeCount != shown else { return }
        shown = activeCount
        NSApp?.dockTile.badgeLabel = activeCount > 0 ? "\(activeCount)" : nil
        if activeCount > 0, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Downloading videos")
        } else if activeCount == 0, let running = activity {
            ProcessInfo.processInfo.endActivity(running)
            activity = nil
        }
    }
}
#endif
