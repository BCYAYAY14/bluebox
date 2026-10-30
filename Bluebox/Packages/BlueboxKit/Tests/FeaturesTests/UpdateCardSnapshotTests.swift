#if os(macOS)
import AppKit
@testable import Features
import Foundation
import SwiftUI
import Testing

/// Settings › About with the update card in each state, as PNGs for design
/// review. Runs only when /tmp/bluebox-update-shots exists.
@MainActor
@Suite struct UpdateCardSnapshotTests {
    nonisolated static let folder = "/tmp/bluebox-update-shots"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: UpdateCardSnapshotTests.folder)))
    func snapshotEveryState() async throws {
        let app = AppModel.demo()
        await app.bootstrap()
        let update = AvailableUpdate(
            version: "1.0.15", page: AppUpdater.releasesPage, macDMG: URL(string: "https://example.com/Bluebox-mac.dmg"),
            macDMGDigest: nil, macDMGSize: 74_868_736,
            notes: "### Player\n- Subtitles from OpenSubtitles show in the track list as soon as they're found.\n- Switching subtitles mid-episode no longer rebuffers.\n\n### Security\n- Signing in to a different account asks what happens to this device's library.\n\n[Everything that changed in 1.0.15](https://github.com/BCYAYAY14/bluebox/blob/main/CHANGELOG.md)",
            published: Date(timeIntervalSince1970: 1_793_361_600))
        let checked = Date().addingTimeInterval(-600)
        let states: [(String, AppUpdater.State)] = [
            ("1-idle", .idle), ("2-checking", .checking), ("3-up-to-date", .upToDate),
            ("4-check-failed", .checkFailed("GitHub didn't answer. Check your connection and try again.")),
            ("5-available", .available(update)),
            ("6-downloading", .downloading(update, DownloadProgress(received: 40_000_000, expected: 74_868_736, secondsLeft: 18))),
            ("7-verifying", .verifying(update)), ("8-installing", .installing(update)),
            ("9-install-failed", .installFailed(update, "The new copy isn't signed with Bluebox's release certificate, so it wasn't installed. Nothing was changed.")),
        ]
        UserDefaults.standard.set(SettingsPage.about.rawValue, forKey: "bluebox.settingsPage")
        for (name, state) in states {
            AppUpdater.shared.preview(state, lastChecked: name == "1-idle" ? nil : checked)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: SettingsView().environment(app))
            window.contentView = host
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(900))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(Self.folder)/\(name).png"))
            window.orderOut(nil)
        }
        AppUpdater.shared.preview(.idle)
    }
}
#endif
