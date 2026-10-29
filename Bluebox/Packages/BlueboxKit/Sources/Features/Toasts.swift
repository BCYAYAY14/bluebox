import DesignSystem
import Domain
import SwiftUI

/// A short message that doesn't block anything: a download finished, a play
/// failed and can be retried. Errors that need a decision stay alerts.
public struct AppToast: Identifiable, Equatable {
    public enum Style: Sendable { case info, success, error }

    public let id = UUID()
    public let title: String
    public let message: String?
    public let style: Style
    public let actionTitle: String?
    let action: (@MainActor () -> Void)?

    public init(_ title: String, message: String? = nil, style: Style = .info,
                actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        self.title = title
        self.message = message
        self.style = style
        self.actionTitle = action == nil ? nil : actionTitle
        self.action = action
    }

    /// Longer for errors and anything with a button, so there's time to read and tap.
    var duration: Duration {
        if action != nil { return .seconds(8) }
        return style == .error ? .seconds(6) : .seconds(3.5)
    }

    public static func == (a: AppToast, b: AppToast) -> Bool { a.id == b.id }
}

extension AppModel {
    /// Shows a toast, replacing any on screen.
    public func showToast(_ toast: AppToast) {
        self.toast = toast
    }

    /// Logs a failure and shows it as a toast in words the user can act on,
    /// with Try Again when retrying may help.
    func report(_ error: Error, title: String, context: UserFacingError.Context = .general,
                retry: (@MainActor () async -> Void)? = nil) {
        let message = UserFacingError.message(for: error, context: context)
        let logger = switch context {
        case .playback, .addons: Log.playback
        case .download, .general: Log.sources
        case .catalog: Log.metadata
        }
        logger.error("\(title, privacy: .public): \(String(describing: error), privacy: .public)")
        var action: (@MainActor () -> Void)?
        if let retry, UserFacingError.isRetryable(error) {
            action = { Task { await retry() } }
        }
        showToast(AppToast(title, message: message, style: .error, actionTitle: "Try Again", action: action))
    }
}

/// Draws `AppModel.toast` over the app, at the bottom, and dismisses it after a while.
public struct ToastHost: ViewModifier {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast) { dismiss(toast) }
                    .padding(.horizontal, Spacing.l)
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: 560)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        AccessibilityNotification.Announcement("\(toast.title). \(toast.message ?? "")").post()
                        try? await Task.sleep(for: toast.duration)
                        dismiss(toast)
                    }
                    .zIndex(10)
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
    }

    private var bottomInset: CGFloat {
        #if os(iOS)
        64  // above the tab bar
        #else
        28
        #endif
    }

    private func dismiss(_ toast: AppToast) {
        if model.toast == toast { model.toast = nil }
    }
}

private struct ToastView: View {
    let toast: AppToast
    let close: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                if let message = toast.message {
                    Text(message).font(.footnote).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    close()
                    action()
                }
                .buttonStyle(TextActionStyle())
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Palette.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.xs)
        .padding(.vertical, Spacing.s)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch toast.style {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch toast.style {
        case .info, .success: Palette.brandBright
        case .error: .orange
        }
    }
}
