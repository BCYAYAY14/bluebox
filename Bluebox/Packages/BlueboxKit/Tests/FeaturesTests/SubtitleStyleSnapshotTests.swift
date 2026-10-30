#if os(macOS)
import AppKit
@testable import Features
import Foundation
import Playback
import Subtitles
import SwiftUI
import Testing

/// The player's Subtitle Style page in its card, as PNGs for design review.
/// Runs only when /tmp/bluebox-subtitle-shots exists.
@MainActor
@Suite struct SubtitleStyleSnapshotTests {
    nonisolated static let folder = "/tmp/bluebox-subtitle-shots"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: SubtitleStyleSnapshotTests.folder)))
    func snapshotStylePage() async throws {
        let app = AppModel.demo()
        await app.bootstrap()
        let session = PlayerSession(engine: AVPlayerEngine(), progress: app.store, deviceID: "snapshot")
        let inspector = StyleHost(session: session)
            .frame(height: 900)
            .background(Color(white: 0.1))
            .environment(app)
        try write(inspector, size: NSSize(width: SubtitleStyleInspector.width, height: 900), name: "style-inspector")
        UserDefaults.standard.set(SettingsPage.subtitles.rawValue, forKey: "bluebox.settingsPage")
        for (name, look) in [("settings-subtitles-dark", NSAppearance.Name.darkAqua), ("settings-subtitles-light", .aqua)] {
            try write(SettingsView().environment(app), size: NSSize(width: 900, height: 1100), name: name, appearance: look)
        }
        let skip = SkipController()
        for page in [nil] + ToolsPage.allCases.map(Optional.some) {
            let card = ScrollView {
                ToolsPanel(session: session, skip: skip, columns: 3, statsShown: false, initialPage: page,
                           onToggleStats: {}, onLoop: {}, onSnapshot: {}, onJump: {})
                    .padding(PlayerCardMetrics.padding)
            }
            .frame(width: 320, height: 640).playerCardSurface().padding(30).background(Color(white: 0.1)).environment(app)
            try write(card, size: NSSize(width: 380, height: 700), name: "tools-\(page?.rawValue ?? "grid")")
        }
        for page in [nil, TracksPage.timing, .lines, .secondLine] {
            let card = ScrollView {
                TracksPanel(session: session, width: 340, canSearch: true, initialPage: page, onAddFile: {}, onSearch: {}, onStyle: {})
                    .padding(PlayerCardMetrics.padding)
            }
            .frame(width: 360, height: 640).playerCardSurface().padding(30).background(Color(white: 0.1)).environment(app)
            try write(card, size: NSSize(width: 420, height: 700), name: "tracks-\(page?.rawValue ?? "main")")
        }
        let speed = ScrollView { SpeedPanel(rate: 1, remaining: 3000) { _ in }.padding(PlayerCardMetrics.padding) }
            .frame(width: 300, height: 400).playerCardSurface().padding(30).background(Color(white: 0.1)).environment(app)
        try write(speed, size: NSSize(width: 360, height: 460), name: "speed")
    }

    private struct StyleHost: View {
        @Environment(AppModel.self) private var app
        let session: PlayerSession
        var body: some View {
            @Bindable var app = app
            SubtitleStyleInspector(style: $app.subtitleStyle, session: session, onClose: {})
        }
    }

    private func write(_ view: some View, size: NSSize, name: String, appearance: NSAppearance.Name = .darkAqua) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(Self.folder)/\(name).png"))
        window.orderOut(nil)
    }
}
#endif
