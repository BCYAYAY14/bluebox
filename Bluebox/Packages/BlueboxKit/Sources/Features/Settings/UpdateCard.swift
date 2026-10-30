import DesignSystem
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Settings › About › Updates: one card under the version that changes in
/// place through every step: checking, up to date, an update with What's New,
/// downloading with Cancel, checking the download, installing, or what went
/// wrong with Try Again (design/mockups-update-flow-2026-10-30.html).
/// iPhone and iPad only check; the update comes through FlareStore.
struct UpdateCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsNotes = false
    @State private var copied = false
    private var updater: AppUpdater { .shared }

    var body: some View {
        Section {
            card.settingsRow("Check for Updates")
        } footer: {
            #if os(macOS)
            Text("Bluebox checks GitHub once a day. Before installing, it checks the download against GitHub's checksum and the new copy against Bluebox's release certificate.")
            #else
            Text("Bluebox checks GitHub once a day. It can't install updates itself on iPhone and iPad.")
            #endif
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            #if os(macOS)
            HStack(alignment: .center, spacing: Spacing.m) {
                icon
                text
                Spacer(minLength: Spacing.s)
                buttons
            }
            #else
            HStack(alignment: .top, spacing: Spacing.m) {
                icon
                text
                Spacer(minLength: 0)
            }
            buttons.padding(.leading, 30 + Spacing.m)
            #endif
            progress
            steps
            whatsNew
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.edge))
        .padding(.vertical, Spacing.xs)
        .animation(Motion.standard(reduceMotion), value: updater.state)
        .animation(Motion.standard(reduceMotion), value: showsNotes)
        // Seeing it here clears the dot on the profile button and in the sidebar.
        .task(id: updater.update?.version) { updater.markSeen() }
        .onChange(of: updater.update?.version) { showsNotes = false }
    }

    // MARK: Parts

    @ViewBuilder private var icon: some View {
        switch updater.state {
        case .checking, .verifying, .installing:
            ProgressView().controlSize(.small).frame(width: 30, height: 30)
        case .upToDate:
            badge("checkmark", fill: Palette.wash, tint: Palette.brand)
        case .checkFailed, .installFailed:
            badge("exclamationmark", fill: SettingsMetrics.destructive, tint: .white)
        case .available, .downloading:
            badge("arrow.down", fill: Palette.brand, tint: .white)
        case .idle:
            badge("arrow.triangle.2.circlepath", fill: Palette.elevated, tint: Palette.textSecondary)
        }
    }

    private func badge(_ symbol: String, fill: Color, tint: Color) -> some View {
        Circle().fill(fill).frame(width: 30, height: 30)
            .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(tint))
            .accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ui: title).font(.body.weight(.semibold)).foregroundStyle(Palette.textPrimary)
            Text(detail).font(.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: Spacing.s) {
            switch updater.state {
            case .idle:
                button("Check for Updates") { await updater.check(userInitiated: true) }
            case .upToDate:
                button("Check Again") { await updater.check(userInitiated: true) }
            case .checkFailed:
                button("Try Again") { await updater.check(userInitiated: true) }
            case .available(let update):
                #if os(macOS)
                if update.macDMG != nil {
                    button("Install and Relaunch", prominent: true) { await updater.install(update) }
                } else {
                    button("Open GitHub", prominent: true) { openURL(update.page) }
                }
                #else
                button(copied ? "Copied" : "Copy Source Link") {
                    UIPasteboard.general.url = AppUpdater.ipaSource
                    copied = true
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
                #endif
            case .downloading, .verifying:
                button("Cancel") { updater.cancel() }
            case .installFailed(let update, _):
                button("Try Again") { await updater.install(update) }
                Button("GitHub") { openURL(update.page) }
                    .buttonStyle(UpdateLinkStyle())
            case .checking, .installing:
                EmptyView()
            }
        }
        .fixedSize()
    }

    private func button(_ title: String, prominent: Bool = false, action: @escaping @MainActor () async -> Void) -> some View {
        Button(title) { Task { await action() } }
            .buttonStyle(UpdateButtonStyle(prominent: prominent))
    }

    @ViewBuilder private var progress: some View {
        switch updater.state {
        case .downloading(_, let p):
            ProgressView(value: p.fraction ?? 0).progressViewStyle(.linear).tint(Palette.brand)
        case .verifying, .installing:
            ProgressView().progressViewStyle(.linear).tint(Palette.brand)
        default:
            EmptyView()
        }
    }

    /// Download, Check, Install, with the ones done ticked.
    @ViewBuilder private var steps: some View {
        let current: Int? = switch updater.state {
        case .downloading: 0
        case .verifying: 1
        case .installing: 2
        default: nil
        }
        if let current {
            HStack(spacing: 6) {
                ForEach(Array(["Download", "Check", "Install"].enumerated()), id: \.offset) { i, step in
                    HStack(spacing: 3) {
                        if i < current { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                        Text(step)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(i == current ? Palette.textPrimary : i < current ? Palette.textSecondary : Palette.textTertiary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(i == current ? Palette.wash : Palette.elevated))
                }
            }
            .accessibilityHidden(true)  // the title says the step
        }
    }

    /// A What's New row that opens the release's notes in place.
    @ViewBuilder private var whatsNew: some View {
        if case .available(let update) = updater.state {
            let notes = ReleaseNotes(markdown: update.notes)
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Rectangle().fill(SettingsMetrics.hairline).frame(height: 1)
                    Button { showsNotes.toggle() } label: {
                        HStack {
                            Text("What's New in \(update.version)").foregroundStyle(Palette.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.textTertiary)
                                .rotationEffect(.degrees(showsNotes ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 1))
                    .accessibilityValue(showsNotes ? "Shown" : "Hidden")
                    if showsNotes {
                        notesView(notes, page: update.page)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    private func notesView(_ notes: ReleaseNotes, page: URL) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 3) {
                    if let title = section.title {
                        Text(ui: title).font(.caption.weight(.bold)).textCase(.uppercase).tracking(0.5)
                            .foregroundStyle(Palette.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").accessibilityHidden(true)
                            Text((try? AttributedString(markdown: point)) ?? AttributedString(point))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                        .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            Button("Full Notes on GitHub") { openURL(notes.fullNotes ?? page) }
                .buttonStyle(UpdateLinkStyle())
        }
    }

    // MARK: Words

    private var title: String {
        switch updater.state {
        case .idle: "Bluebox \(AppVersion.marketing)"
        case .checking: "Checking for updates…"
        case .upToDate: "Bluebox is up to date"
        case .checkFailed: "Couldn't check for updates"
        case .available(let u): "Bluebox \(u.version) is available"
        case .downloading(let u, _): "Downloading Bluebox \(u.version)"
        case .verifying: "Checking the download"
        case .installing(let u): "Installing Bluebox \(u.version)…"
        case .installFailed(let u, _): "Bluebox \(u.version) wasn't installed"
        }
    }

    private var detail: String {
        let checked = updater.lastChecked.map { Self.checked($0) }
        switch updater.state {
        case .idle:
            return checked.map { "Checked \($0)." } ?? "Not checked yet."
        case .checking:
            return "Looking at the latest release on GitHub."
        case .upToDate:
            return "\(AppVersion.marketing) is the newest version." + (checked.map { " Checked \($0)." } ?? "")
        case .checkFailed(let message):
            return message + (checked.map { " Last checked \($0)." } ?? "")
        case .available(let u):
            #if os(macOS)
            let facts = [u.macDMGSize.map(Self.bytes), u.published.map { "released \($0.formatted(.dateTime.day().month(.wide)))" }]
                .compactMap { $0 }.joined(separator: ", ")
            return "You have \(AppVersion.marketing)." + (facts.isEmpty ? "" : " \(facts.prefix(1).uppercased())\(facts.dropFirst()).")
            #else
            return "You have \(AppVersion.marketing). Update it in FlareStore (or AltStore, SideStore, Feather): it's in their Updates list once the Bluebox source refreshes."
            #endif
        case .downloading(_, let p):
            return Self.downloaded(p)
        case .verifying:
            return "Matching it against the SHA-256 checksum GitHub publishes for this release."
        case .installing:
            return "Checking it's signed with Bluebox's release certificate, then replacing this copy. Bluebox quits and opens again by itself."
        case .installFailed(_, let message):
            return message
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "38.2 MB of 71.4 MB · about 20 seconds left".
    static func downloaded(_ p: DownloadProgress) -> String {
        var text = p.expected.map { "\(bytes(p.received)) of \(bytes($0))" } ?? bytes(p.received)
        if let s = p.secondsLeft {
            text += s < 60 ? " · about \(max(5, Int((s / 5).rounded(.up)) * 5)) seconds left"
                           : " · about \(Int((s / 60).rounded(.up))) minutes left"
        }
        return text
    }

    /// "today at 9:41", "yesterday at 18:02", "28 October at 9:41".
    static func checked(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.wide))) at \(time)"
    }
}

/// The card's buttons: blue for the step forward, grey for the rest.
private struct UpdateButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(prominent ? .bold : .semibold))
            .foregroundStyle(prominent ? Color.white : Palette.textPrimary)
            .padding(.horizontal, 12)
            #if os(macOS)
            .frame(minHeight: 28)
            #else
            .frame(minHeight: 36)
            #endif
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(prominent ? Palette.brand : Palette.elevated))
            .opacity(configuration.isPressed ? 0.7 : isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// "GitHub", "Full Notes on GitHub": blue text that opens the browser.
private struct UpdateLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.label
            Image(systemName: "arrow.up.right").font(.caption2.weight(.bold))
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(Palette.brand)
        .opacity(configuration.isPressed ? 0.6 : 1)
        .contentShape(Rectangle())
    }
}
