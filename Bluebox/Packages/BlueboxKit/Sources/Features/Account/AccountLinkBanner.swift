import DesignSystem
import SwiftUI

extension View {
    /// Shows the result of opening a link from another device
    /// (`bluebox://connect…`, or a refused `bluebox://auth-callback…` sign-in link)
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
        .modifier(AccountChangePrompt())
        .modifier(ConnectLinkPrompt())
    }

    private func banner(_ event: AccountModel.LinkEvent) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            switch event {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting to your server…")
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
            if event != .connecting {
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

/// Signed in to a different account from the one this device last synced
/// with: what happens to the device's library (security review BB-01). Nothing
/// syncs until one is chosen. Choices in design/mockups-security-choices-2026-10-30.html.
struct AccountChangePrompt: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        let change = app.account.accountChange
        content.alert("This device has \(change?.previousName ?? "another account")'s library",
                      isPresented: Binding(get: { app.account.accountChange != nil }, set: { _ in })) {
            if let change {
                Button("Use \(change.newName)'s Library") { Task { await app.account.resolveAccountChange(.useAccountLibrary) } }
                Button("Add This \(Self.device)'s Library to \(change.newName)") {
                    Task { await app.account.resolveAccountChange(.addDeviceLibrary) }
                }
                Button("Sign Out", role: .destructive) { Task { await app.account.resolveAccountChange(.signOut) } }
            }
        } message: {
            if let change { Text(Self.message(change)) }
        }
    }

    static func message(_ c: AccountModel.AccountChange) -> String {
        var on: [String] = []
        if c.myList > 0 { on.append("\(c.myList) in My List") }
        if c.continueWatching > 0 { on.append("\(c.continueWatching) in Continue Watching") }
        if c.profiles > 1 { on.append("\(c.profiles) profiles") }
        let what = on.isEmpty ? "" : " On this \(device): " + on.joined(separator: ", ") + "."
        return "Bluebox last synced this \(device) with \(c.previousName). That library stays in its account either way.\(what)"
            + " Using \(c.newName)'s library removes it from this \(device); adding it copies it into \(c.newName)."
    }

    static var device: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}

/// A `bluebox://connect` link opened on a signed-out device: confirm the
/// server before connecting, since whoever runs it receives the username and
/// password typed next.
struct ConnectLinkPrompt: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        let pending = app.pendingConnect
        content.alert("Connect to \(pending?.host ?? "this server")?",
                      isPresented: Binding(get: { app.pendingConnect != nil }, set: { if !$0 { app.cancelConnect() } })) {
            Button("Connect") { Task { await app.confirmConnect() } }
            Button("Cancel", role: .cancel) { app.cancelConnect() }
        } message: {
            if let pending { Text(Self.message(pending)) }
        }
    }

    static func message(_ p: AppModel.PendingConnect) -> String {
        "Only connect to a server you set up, or one someone you trust gave you: the username and password you enter next go to it, and your library syncs there."
            + (p.replacing.map { " This replaces \($0), the server this device uses now." } ?? "")
    }
}
