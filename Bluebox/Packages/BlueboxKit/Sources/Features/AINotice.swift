import DesignSystem
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The AI sheet: what in Bluebox uses AI, that it runs on the device, and
/// the switches for it. Shown once on first launch (and once to everyone
/// who installed before it existed), then again, as one page of what's new,
/// only when an update adds or changes something that uses AI, so it means
/// something when it appears. Settings › Privacy & Features reopens it.
enum AINotice {
    /// Raise this, and list what changed in `changes`, when an update adds
    /// or changes a feature that uses AI.
    static let version = 1
    /// Int: the version last shown on this device. 0 means never.
    static let seenKey = "bluebox.ai.noticeSeen"

    enum Feature: String, CaseIterable, Sendable {
        case generatedSubtitles, audioSync
    }

    /// What each version added or changed.
    static let changes: [Int: [Feature]] = [1: [.generatedSubtitles, .audioSync]]

    enum Showing: Equatable, Identifiable {
        /// Every page: first launch, or from Settings.
        case everything
        /// One page of what an update added or changed.
        case whatsNew([Feature])
        var id: String {
            switch self {
            case .everything: "everything"
            case .whatsNew(let features): features.map(\.rawValue).joined(separator: ",")
            }
        }
    }

    /// What to show, given the version this device last saw: everything if
    /// it never saw one, what changed since if it saw an older one, nothing
    /// if it's up to date or the versions in between changed nothing.
    static func showing(seen: Int, current: Int = version, changes: [Int: [Feature]] = changes) -> Showing? {
        guard seen < current else { return nil }
        if seen <= 0 { return .everything }
        var new: [Feature] = []
        for v in (seen + 1)...current {
            for feature in changes[v] ?? [] where !new.contains(feature) { new.append(feature) }
        }
        return new.isEmpty ? nil : .whatsNew(new)
    }
}

/// Presents the AI sheet at launch when `AINotice` says so, once nothing
/// else is in front (the Who's Watching gate, the player). UI tests skip it
/// unless `-ai-notice` asks for it.
struct AINoticeHost: ViewModifier {
    /// Who's Watching is up: wait until a profile is picked.
    let isBlocked: Bool
    @Environment(AppModel.self) private var app
    @AppStorage(AINotice.seenKey) private var seen = 0
    @State private var showing: AINotice.Showing?
    @State private var checked = false

    func body(content: Content) -> some View {
        content
            .task(id: isBlocked) {
                guard !isBlocked, !checked else { return }
                let args = ProcessInfo.processInfo.arguments
                guard !args.contains("-ui-testing") || args.contains("-ai-notice") else { return }
                // After the launch intro and the first Home load, not over them.
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled, !isBlocked, app.activePlayer == nil else { return }
                checked = true
                showing = AINotice.showing(seen: args.contains("-ai-notice") ? 0 : seen)
            }
            .sheet(item: $showing, onDismiss: { seen = AINotice.version }) { showing in
                AITransparencySheet(showing: showing) { self.showing = nil }
                    .environment(app)
            }
    }
}

/// The sheet's pages: where Bluebox uses AI, that it stays on the device,
/// and your choices. After an update, one page of what's new instead, with
/// See Everything for the rest.
struct AITransparencySheet: View {
    let showing: AINotice.Showing
    let onDone: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var everything = false
    /// Which way the last page change went, for the slide.
    @State private var forward = true

    init(showing: AINotice.Showing, startPage: Int = 0, onDone: @escaping () -> Void) {
        self.showing = showing; self.onDone = onDone
        _page = State(initialValue: startPage)
    }

    private enum Page { case uses, onDevice, choices, whatsNew([AINotice.Feature]) }

    private var pages: [Page] {
        if !everything, case .whatsNew(let features) = showing { return [.whatsNew(features)] }
        return [.uses, .onDevice, .choices]
    }
    private var isLast: Bool { page >= pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                pageView(pages[min(page, pages.count - 1)])
                    .id(page)
                    .transition(Motion.slide(from: forward ? .trailing : .leading, reduceMotion))
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.xxl)
                    .padding(.bottom, Spacing.l)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .background(Palette.chrome)
        .tint(Palette.brand)
        .contentShape(Rectangle())
        .simultaneousGesture(swipe)
        #if os(macOS)
        .frame(width: 460, height: 600)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .accessibilityIdentifier("aiNotice")
    }

    // MARK: Pages

    @ViewBuilder private func pageView(_ page: Page) -> some View {
        VStack(spacing: 0) {
            switch page {
            case .uses:
                header(symbol: "sparkles", title: "AI in Bluebox",
                       lede: "Only for subtitles. Nothing else in the app uses AI: what you see comes from TMDB, Trakt, your add-ons and your own libraries.")
                points(AINotice.Feature.allCases.map(point))
            case .onDevice:
                header(symbol: "lock", title: stayTitle, lede: "No audio, words or subtitles ever leave it, and nothing is used to train a model.")
                points([
                    Point(symbol: "cpu", title: "Runs on the device",
                          detail: "Apple's speech recognition, and Whisper, an open speech model, for the rest."),
                    Point(symbol: "arrow.down.circle", title: "Downloads only if needed",
                          detail: "Whisper is downloaded the first time a language needs it, with its size shown first. Delete it in Settings."),
                    Point(symbol: "hand.raised", title: "Only when you ask",
                          detail: "Nothing listens until you press Generate or Sync to the Audio."),
                ])
            case .choices:
                header(symbol: "switch.2", title: "Your choices", lede: "Change them any time in Settings › Privacy & Features.")
                AISwitches()
            case .whatsNew(let features):
                header(symbol: "sparkles", title: "What's new with AI",
                       lede: "This update adds or changes something that uses AI. Like the rest, it runs on the device.")
                points(features.map(point))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var stayTitle: LocalizedStringKey {
        #if os(macOS)
        "It stays on your Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "It stays on your iPad" : "It stays on your iPhone"
        #endif
    }

    /// A flat tile in the theme colour, the title and one line under it.
    private func header(symbol: String, title: LocalizedStringKey, lede: LocalizedStringKey) -> some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Palette.brandBright)
                .frame(width: 64, height: 64)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
                .padding(.bottom, Spacing.xs)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(lede)
                .font(.callout)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Spacing.xl)
    }

    private struct Point: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private func point(_ feature: AINotice.Feature) -> Point {
        switch feature {
        case .generatedSubtitles:
            Point(symbol: "captions.bubble", title: "Generated Subtitles",
                  detail: "Written from a video's sound when it has none in your language, and translated with Apple's Translation. Marked Generated, since they can have mistakes.")
        case .audioSync:
            Point(symbol: "waveform", title: "Sync to the Audio",
                  detail: "Listens to a few minutes of speech and lines the subtitles up with it.")
        }
    }

    private func points(_ points: [Point]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ForEach(points) { point in
                HStack(alignment: .top, spacing: Spacing.l) {
                    Image(systemName: point.symbol)
                        .font(.title2)
                        .foregroundStyle(Palette.brandBright)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ui: point.title).font(.subheadline.weight(.semibold))
                        Text(ui: point.detail)
                            .font(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: Spacing.m) {
            if pages.count > 1 {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? Palette.textPrimary : Palette.textTertiary.opacity(0.6))
                            .frame(width: i == page ? 16 : 6, height: 6)
                    }
                }
                .animation(Motion.snappy(reduceMotion), value: page)
                .accessibilityElement()
                .accessibilityLabel(Text("Page \(page + 1) of \(pages.count)"))
            }
            Button(action: next) {
                Text(isLast ? (pages.count == 1 ? "Done" : "Start Watching") : "Continue")
            }
            .buttonStyle(PrimaryButtonStyle(fullWidth: true))
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("aiNotice.next")
            // Skip goes to Your Choices, never past them; See Everything opens every page.
            // Kept in place but hidden on the last page so the button doesn't jump.
            Button(action: secondary) { Text(secondaryTitle) }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.brandBright)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .opacity(hasSecondary ? 1 : 0)
                .disabled(!hasSecondary)
                .accessibilityHidden(!hasSecondary)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.l)
        .padding(.top, Spacing.s)
    }

    private var isWhatsNew: Bool { if case .whatsNew = pages.first { true } else { false } }
    private var hasSecondary: Bool { isWhatsNew || !isLast }
    private var secondaryTitle: LocalizedStringKey { isWhatsNew ? "See Everything" : "Skip" }

    private func next() {
        if isLast { onDone(); return }
        go(to: page + 1)
    }

    private func secondary() {
        if isWhatsNew {
            forward = true
            withAnimation(Motion.standard(reduceMotion)) { everything = true; page = 0 }
        } else {
            go(to: pages.count - 1)
        }
    }

    private func go(to new: Int) {
        let target = max(0, min(new, pages.count - 1))
        guard target != page else { return }
        forward = target > page
        withAnimation(Motion.standard(reduceMotion)) { page = target }
    }

    /// Swiping sideways turns the page, as on Apple's own welcome sheets.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                if value.translation.width < -50 { go(to: page + 1) }
                if value.translation.width > 50 { go(to: page - 1) }
            }
    }
}

/// The three switches, on the sheet's last page.
private struct AISwitches: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        VStack(spacing: 0) {
            row("Offer to Generate Subtitles", detail: "A notice when a video has none in your language", isOn: $settings.offersGeneratedSubtitles)
            Divider().overlay(Palette.separator).padding(.leading, Spacing.l)
            row("Allow Whisper", detail: "For languages Apple's speech recognition doesn't know", isOn: $settings.allowsWhisper)
            Divider().overlay(Palette.separator).padding(.leading, Spacing.l)
            row("Sync to the Audio", detail: "In the player's Timing page", isOn: $settings.offersAudioSync)
        }
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
    }

    private func row(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ui: title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                Text(ui: detail).font(.caption).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .toggleStyle(.switch)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }
}
