#if os(macOS)
import AppKit
@testable import Features
import Foundation
import SwiftUI
import Testing

/// Renders every Settings page in an offscreen Mac window and saves a PNG of
/// each, for design review without driving the app. Runs only when
/// /tmp/bluebox-settings-shots/mac exists.
@MainActor
@Suite struct SettingsMacSnapshotTests {
    nonisolated static let folder = "/tmp/bluebox-settings-shots/mac"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: SettingsMacSnapshotTests.folder)))
    func snapshotEveryPage() async throws {
        let app = AppModel.demo()
        await app.bootstrap()
        for page in SettingsPage.available {
            UserDefaults.standard.set(page.rawValue, forKey: "bluebox.settingsPage")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1300),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: SettingsView().environment(app))
            window.contentView = host
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(1500))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = rep.representation(using: .png, properties: [:])
            try data?.write(to: URL(fileURLWithPath: "\(Self.folder)/\(page.rawValue).png"))
            window.orderOut(nil)
        }
        // The "You're on mobile data" sheet, drawn as it would sit in its sheet.
        app.settings.mobileData.quality = .automatic
        let prompt = MobileDataPrompt(title: "Harbor Lights", subtitle: "S1·E3", quality: "1080p", bytes: 1_100_000_000,
                                      dataSaverQuality: "720p", dataSaverBytes: 450_000_000, minutes: 52, canDownload: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: MobileDataWarningSheet(prompt: prompt).environment(app))
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(800))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(Self.folder)/zz-mobile-data-sheet.png"))
        }
        window.orderOut(nil)
    }
}
#endif
