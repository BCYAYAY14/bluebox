#if os(macOS)
import AppKit
@testable import Features
import SwiftUI
import Sync
import Testing

/// The remote's view of a real Mac window (`RemoteWindow`): what can be
/// pressed comes from the window's own accessibility tree, presses and
/// clicks land, and scrolling moves the scroll view under the point.
@MainActor
@Suite(.serialized) struct RemoteWindowTests {
    final class Log { var items: [String] = []; var on = false }

    func until(seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func window<V: View>(_ view: V) async throws -> (NSWindow, RemoteWindow) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 600, height: 500))
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(600))
        return (window, RemoteWindow(main: window))
    }

    @Test func findsAndPressesWhatsOnScreen() async throws {
        let log = Log()
        let view = VStack(spacing: 20) {
            Button("More Info") { log.items.append("info") }
            Toggle("Skip intros automatically", isOn: Binding(get: { log.on }, set: { log.on = $0 }))
            HStack { ForEach(0..<3) { i in Button("Card \(i)") { log.items.append("card \(i)") } } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        let (w, remote) = try await window(view)
        defer { w.orderOut(nil) }
        #expect(await until { remote.elements().count >= 5 })
        let elements = remote.elements()
        let labels = elements.map(\.label)
        #expect(labels.contains("More Info"))
        #expect(labels.contains("Card 2"))
        let toggle = try #require(elements.first { $0.label == "Skip intros automatically" })
        #expect(toggle.kind == .toggle && toggle.isOn == false)
        // Frames are in the window, top-left origin: More Info is above the cards.
        let info = try #require(elements.first { $0.label == "More Info" })
        let card = try #require(elements.first { $0.label == "Card 0" })
        #expect(info.frame.minY < card.frame.minY)
        remote.press(info)
        remote.press(toggle)
        remote.click(at: CGPoint(x: card.frame.midX, y: card.frame.midY), right: false)
        #expect(await until { log.items.contains("info") && log.items.contains("card 0") && log.on })
    }

    @Test func scrollsTheScrollViewUnderThePoint() async throws {
        let view = ScrollView {
            VStack(spacing: 0) { ForEach(0..<60) { i in Button("Row \(i)") {}.frame(height: 44) } }.frame(maxWidth: .infinity)
        }
        let (w, remote) = try await window(view)
        defer { w.orderOut(nil) }
        #expect(await until { remote.elements().map(\.label).contains("Row 0") })
        #expect(await until { remote.scroll(at: CGPoint(x: 300, y: 250), dx: 0, dy: 900) })
        #expect(await until { remote.elements().map(\.label).contains("Row 25") })
        #expect(!remote.elements().map(\.label).contains("Row 0"))
        #expect(remote.scrollPage(at: CGPoint(x: 300, y: 250), toward: .up))
    }
}
#endif
