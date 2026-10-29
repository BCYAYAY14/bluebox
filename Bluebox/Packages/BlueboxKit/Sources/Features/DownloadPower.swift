import Downloads
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit.ps
#endif

/// Feeds the download window (Settings › Downloads › Download Window) what
/// it needs: whether the device is on power, and the clock, so overnight
/// downloads start at 1 am. iOS reads the battery state and hears when it
/// changes; the Mac reads its power source. Both look again every minute.
@MainActor
final class DownloadPowerMonitor {
    static let shared = DownloadPowerMonitor()
    private var ticker: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    func start(manager: DownloadManager) {
        guard ticker == nil else { return }
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        observer = NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { manager.setCharging(Self.isCharging) }
        }
        #endif
        manager.setCharging(Self.isCharging)
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                manager.setCharging(Self.isCharging)
                manager.refreshWindow()
            }
        }
    }

    /// On mains power. A device that can't tell (a desktop Mac) counts as charging.
    static var isCharging: Bool {
        #if os(iOS)
        switch UIDevice.current.batteryState {
        case .charging, .full: true
        case .unplugged: false
        case .unknown: true  // the simulator
        @unknown default: true
        }
        #elseif os(macOS)
        IOPSGetTimeRemainingEstimate() == kIOPSTimeRemainingUnlimited
        #else
        true
        #endif
    }
}
