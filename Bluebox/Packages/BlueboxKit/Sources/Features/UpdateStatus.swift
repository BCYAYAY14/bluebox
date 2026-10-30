import DesignSystem
import SwiftUI

extension View {
    /// The daily update check, and the capsule over the main window while an
    /// update downloads and installs. Nothing pops up: an update the check
    /// finds shows as a dot on the profile button (`ProfileMenu`), and
    /// everything else happens on Settings › About (`UpdateCard`).
    public func updateStatus() -> some View { modifier(UpdateStatusModifier()) }
}

private struct UpdateStatusModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) { UpdateProgressCapsule() }
            .task { await AppUpdater.shared.checkIfDue() }
    }
}

#if os(macOS)
extension AppUpdater {
    /// Settings on About, where the card is (the window comes forward, or
    /// switches page if it's already open).
    @MainActor static func showAbout(_ openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(SettingsPage.about.rawValue, forKey: "bluebox.settingsPage")
        openSettings()
    }

    /// Bluebox › Check for Updates…: Settings on About, checking there.
    @MainActor public static func showAboutAndCheck(_ openSettings: OpenSettingsAction) {
        showAbout(openSettings)
        Task { await shared.check(userInitiated: true) }
    }
}
#endif

/// Over the main window while an update downloads, is checked and installs,
/// whether or not Settings is open. Clicking it opens Settings › About.
private struct UpdateProgressCapsule: View {
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var updater: AppUpdater { .shared }

    var body: some View {
        Group {
            switch updater.state {
            case .downloading(let update, let progress):
                capsule("Downloading Bluebox \(update.version)", fraction: progress.fraction ?? 0)
            case .verifying(let update):
                capsule("Checking Bluebox \(update.version)", fraction: nil)
            case .installing(let update):
                capsule("Installing Bluebox \(update.version)", fraction: nil)
            default:
                EmptyView()
            }
        }
        .animation(Motion.standard(reduceMotion), value: updater.state)
    }

    private func capsule(_ title: String, fraction: Double?) -> some View {
        Button {
            #if os(macOS)
            AppUpdater.showAbout(openSettings)
            #endif
        } label: {
            HStack(spacing: 12) {
                Text(ui: title).font(.callout.weight(.medium)).foregroundStyle(Palette.textPrimary)
                if let fraction {
                    ProgressView(value: fraction).tint(Palette.brand).frame(width: 120)
                    Text("\(Int(fraction * 100))%").font(.callout).monospacedDigit().foregroundStyle(Palette.textSecondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 1))
        .padding(.bottom, 24)
        .transition(Motion.slide(from: .bottom, reduceMotion))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the update in Settings › About")
    }
}
