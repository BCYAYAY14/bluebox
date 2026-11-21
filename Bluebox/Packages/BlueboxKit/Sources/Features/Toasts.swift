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
    /// The parts that are a film, show, list or folder name: shown as they
    /// are, never looked up in the translations (a film called "Settings").
    public let verbatim: Verbatim
    let action: (@MainActor () -> Void)?

    public struct Verbatim: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let title = Verbatim(rawValue: 1)
        public static let message = Verbatim(rawValue: 2)
    }

    public init(_ title: String, message: String? = nil, style: Style = .info, verbatim: Verbatim = [],
                actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        self.title = title
        self.message = message
        self.style = style
        self.verbatim = verbatim
        self.actionTitle = action == nil ? nil : actionTitle
        self.action = action
    }

    /// A toast whose message names something (“Dune · 1080p”): the title is
    /// translated as usual, the message is drawn exactly as given. Translate
    /// any fixed words in it first, with `AppToast.translated(_:)`.
    public init(_ title: String, verbatimMessage: String, style: Style = .info,
                actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        self.title = title
        self.message = verbatimMessage
        self.style = style
        self.verbatim = .message
        self.actionTitle = action == nil ? nil : actionTitle
        self.action = action
    }

    /// A fixed English UI string (a download's failure reason) in the app's
    /// language, for building a verbatim message around a name.
    public static func translated(_ english: String) -> String {
        english.contains("%") ? english : Bundle.main.localizedString(forKey: english, value: english, table: nil)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AppModel) { self.model = model }

    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast) { dismiss(toast) }
                    .padding(.horizontal, Spacing.l)
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: 560)
                    .transition(Motion.slide(from: .bottom, reduceMotion))
                    .task(id: toast.id) {
                        AccessibilityNotification.Announcement("\(toast.title). \(toast.message ?? "")").post()
                        try? await Task.sleep(for: toast.duration)
                        dismiss(toast)
                    }
                    .zIndex(10)
            }
        }
        .animation(Motion.standard(reduceMotion), value: model.toast)
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var bottomInset: CGFloat {
        #if os(iOS)
        // Above the tab bar on iPhone; iPad has the top bar instead, so only the margin.
        sizeClass == .compact ? 64 : 28
        #else
        28
        #endif
    }

    private func dismiss(_ toast: AppToast) {
        if model.toast == toast { model.toast = nil }
    }
}

/// A toast's words: a name as it is, anything else through the translations.
private struct ToastText: View {
    let text: String
    let verbatim: Bool
    init(_ text: String, verbatim: Bool) { self.text = text; self.verbatim = verbatim }

    var body: some View {
        if verbatim { Text(verbatim: text) } else { Text(ui: text) }
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
                ToastText(toast.title, verbatim: toast.verbatim.contains(.title))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                if let message = toast.message {
                    ToastText(message, verbatim: toast.verbatim.contains(.message))
                        .font(.footnote).foregroundStyle(Palette.textSecondary)
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
