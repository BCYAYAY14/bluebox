#if os(macOS)
import AppKit
#endif
@testable import Features
import Foundation
import SwiftUI
import Testing

/// When the AI sheet shows: everything once, then only what an update changed.
@Suite struct AINoticeTests {
    @Test func neverSeenShowsEverything() {
        #expect(AINotice.showing(seen: 0) == .everything)
    }

    @Test func upToDateShowsNothing() {
        #expect(AINotice.showing(seen: AINotice.version) == nil)
        #expect(AINotice.showing(seen: AINotice.version + 1) == nil)
    }

    @Test func anOlderVersionShowsOnlyWhatChangedSince() {
        let changes: [Int: [AINotice.Feature]] = [1: [.generatedSubtitles, .audioSync], 2: [.audioSync], 3: [.generatedSubtitles, .audioSync]]
        #expect(AINotice.showing(seen: 2, current: 3, changes: changes) == .whatsNew([.generatedSubtitles, .audioSync]))
        #expect(AINotice.showing(seen: 1, current: 2, changes: changes) == .whatsNew([.audioSync]))
        // Each feature once, in the order they first changed.
        #expect(AINotice.showing(seen: 1, current: 3, changes: changes) == .whatsNew([.audioSync, .generatedSubtitles]))
    }

    @Test func versionsThatChangedNothingShowNothing() {
        #expect(AINotice.showing(seen: 1, current: 3, changes: [1: [.audioSync]]) == nil)
    }

    @Test func everyFeatureIsInTheFirstVersion() {
        #expect(Set(AINotice.changes[1] ?? []) == Set(AINotice.Feature.allCases))
    }
}

#if os(macOS)
/// Draws each page of the AI sheet offscreen and saves a PNG of each, for
/// design review. Runs only when /tmp/bluebox-ai-shots exists.
@MainActor
@Suite struct AINoticeSnapshotTests {
    nonisolated static let folder = "/tmp/bluebox-ai-shots"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: AINoticeSnapshotTests.folder)))
    func snapshotEveryPage() async throws {
        let app = AppModel.demo()
        await app.bootstrap()
        let pages: [(String, AINotice.Showing, Int)] = [
            ("1-uses", .everything, 0), ("2-on-device", .everything, 1), ("3-choices", .everything, 2),
            ("4-whats-new", .whatsNew([.generatedSubtitles]), 0),
        ]
        for (name, showing, page) in pages {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: AITransparencySheet(showing: showing, startPage: page) {}.environment(app))
            window.contentView = host
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(700))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(Self.folder)/\(name).png"))
            window.orderOut(nil)
        }
    }
}
#endif
