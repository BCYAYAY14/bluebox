import DesignSystem
import Domain
import SwiftUI

/// What a screen shows for one load, so "nothing here", "couldn't load" and
/// "you're offline" are never confused (GAPS X1–X3, decisions Q1 and Q2):
///
/// - Content already on screen stays. A failed refresh adds a small
///   "Couldn't refresh · Retry" notice (`.stale`); never an error page.
/// - With nothing to show, a failure is a full-page `StateMessage(.failed)`
///   with Try Again, or the offline page when the device is offline.
/// - "Empty" only when the load really answered with nothing.
enum LoadPhase: Equatable {
    case loading
    case content
    /// Content from before, kept after the latest load failed.
    case stale(offline: Bool)
    case empty
    case failed
    case offline

    /// - Parameters:
    ///   - hasContent: something worth showing is on screen (saved or just loaded).
    ///   - isLoading: a load is running and nothing has answered yet.
    ///   - failed: the last load threw.
    ///   - isOffline: the device has no network.
    ///   - needsNetwork: an empty answer can't be trusted offline (the
    ///     screen's data only comes from the internet).
    static func resolve(hasContent: Bool, isLoading: Bool, failed: Bool, isOffline: Bool,
                        needsNetwork: Bool = true) -> LoadPhase {
        if hasContent { return failed ? .stale(offline: isOffline) : .content }
        if isLoading { return .loading }
        if failed { return isOffline ? .offline : .failed }
        if isOffline && needsNetwork { return .offline }
        return .empty
    }

    /// Whether a reload is worth starting by itself when the network comes back.
    var reloadsWhenOnline: Bool {
        switch self {
        case .stale, .failed, .offline: true
        case .loading, .content, .empty: false
        }
    }
}

extension UserFacingError {
    /// True for failures that mean "no connection", whatever layer threw them.
    static func isOffline(_ error: Error) -> Bool {
        if let e = error as? URLError {
            return [.notConnectedToInternet, .dataNotAllowed, .networkConnectionLost, .internationalRoamingOff].contains(e.code)
        }
        if let e = error as? MetadataError, case .offline = e { return true }
        return false
    }
}

// MARK: - Views

/// The full-page message for a screen with nothing to show, by phase.
/// Nil for phases that show content or skeletons.
struct LoadFailureMessage: View {
    @Environment(\.selectTab) private var selectTab
    let phase: LoadPhase
    /// "Couldn't load Coming Soon".
    let failedTitle: String
    var error: Error?
    /// What this screen needs the internet for: "Search needs the internet."
    var offlineReason: String = "This page needs the internet."
    var context: UserFacingError.Context = .catalog
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .failed:
            StateMessage(.failed, title: failedTitle,
                         message: error.map { UserFacingError.message(for: $0, context: context) }
                             ?? "Check your connection, then try again.",
                         actionTitle: "Try Again", action: retry)
        case .offline:
            OfflineMessage(reason: offlineReason, retry: retry)
        default:
            EmptyView()
        }
    }
}

/// "You're offline": the page for screens that need the network, pointing to
/// Downloads (which still play), with Try Again as the second choice.
struct OfflineMessage: View {
    @Environment(\.selectTab) private var selectTab
    var reason: String = "This page needs the internet."
    var retry: (() -> Void)?

    var body: some View {
        StateMessage(.offline, title: "You're offline", message: "\(reason) Your downloads still play.",
                     actionTitle: "Go to Downloads", action: { selectTab(.downloads) },
                     secondaryActionTitle: retry == nil ? nil : "Try Again", secondaryAction: retry)
    }
}

/// "Couldn't refresh · Retry", or "Offline · showing what was saved", over
/// content kept from an earlier load.
struct StaleNotice: View {
    let offline: Bool
    let retry: () -> Void

    var body: some View {
        if offline {
            InlineNotice(systemImage: "wifi.slash", "Offline · showing what was saved")
        } else {
            InlineNotice("Couldn't refresh", actionTitle: "Retry", action: retry)
        }
    }
}

/// Home's slim offline card: "You're offline · 3 downloads ready to watch",
/// with a Downloads button. Home keeps everything it has saved under it.
struct OfflineBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(\.selectTab) private var selectTab

    var body: some View {
        let ready = app.downloads.all().filter { $0.state == .completed }.count
        HStack(spacing: Spacing.m) {
            Image(systemName: "wifi.slash")
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're offline").font(Typography.cardTitle).foregroundStyle(Palette.textPrimary)
                Text(Self.detail(ready: ready)).font(.caption).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: Spacing.s)
            Button { selectTab(.downloads) } label: {
                Text("Downloads")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Spacing.m)
                    .frame(minHeight: 32)
                    .background(Palette.elevated, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .fixedSize()
                .accessibilityIdentifier("offlineBanner.downloads")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous).strokeBorder(Palette.edge))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("offlineBanner")
    }

    static func detail(ready: Int) -> String {
        switch ready {
        case 0: "Nothing is downloaded yet. Saved rows still show."
        case 1: "1 download ready to watch"
        default: "\(ready) downloads ready to watch"
        }
    }
}

extension View {
    /// Runs `reload` when the network comes back (or the app returns to the
    /// front) while `pending` is true: a failed or offline screen recovers by
    /// itself instead of staying failed until you leave it (GAPS X4).
    func reloadsWhenBackOnline(_ pending: Bool, reload: @escaping @MainActor () async -> Void) -> some View {
        modifier(BackOnlineReload(pending: pending, reload: reload))
    }
}

private struct BackOnlineReload: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    let pending: Bool
    let reload: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: app.settings.network.isOnline) { _, online in
                if online, pending { Task { await reload() } }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, pending, app.settings.network.isOnline { Task { await reload() } }
            }
    }
}
