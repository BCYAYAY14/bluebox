import DesignSystem
import SwiftUI

extension View {
    /// Shows the result of opening a link from another device
    /// (`bluebox://connect…`, or an old `bluebox://auth-callback…` sign-in link)
    /// as a banner along the top edge.
    public func accountLinkBanner() -> some View { modifier(AccountLinkBanner()) }
}

struct AccountLinkBanner: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let event = app.account.linkEvent {
                banner(event)
                    .padding(.top, Spacing.s)
                    .padding(.horizontal, Spacing.l)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.35), value: app.account.linkEvent)
    }

    private func banner(_ event: AccountModel.LinkEvent) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            switch event {
            case .working:
                ProgressView().controlSize(.small)
                Text("Signing in from the link…")
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting to your server…")
            case .signedIn(let name):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signed in").font(.subheadline.weight(.semibold))
                    Text(name).font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
            case .connected(let host):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected").font(.subheadline.weight(.semibold))
                    Text("Sign in to start syncing with \(host).").font(.caption).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .failed(let why):
                Image(systemName: "xmark.circle.fill").foregroundStyle(AccountTheme.error)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The link didn't work").font(.subheadline.weight(.semibold))
                    Text(why).font(.caption).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if event != .working && event != .connecting {
                Spacer(minLength: 0)
                Button { app.account.dismissLinkEvent() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityLabel("Dismiss")
            }
        }
        .font(.subheadline)
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.m)
        .frame(maxWidth: 440, alignment: .leading)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: AccountTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AccountTheme.cardRadius, style: .continuous).strokeBorder(AccountTheme.fieldBorder))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accountLinkBanner")
    }
}
