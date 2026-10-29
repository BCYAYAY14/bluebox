import DesignSystem
import SwiftUI
import Sync

/// Not connected yet: one Supabase access token sets everything up. Below it,
/// a link from another device, and the URL-and-key fallback for self-hosted
/// projects. Card content for `AccountScreen`.
struct AccountConnectView: View {
    @Environment(AppModel.self) private var app
    /// Shows `AccountManualConnectView` instead.
    @Binding var manual: Bool
    @State private var token = ""
    @State private var revealToken = false
    @State private var tokenError: String?

    var body: some View {
        AccountTitle(title: "Set Up Sync",
                     subtitle: Text("Bluebox keeps My List, watch progress and profiles in step through a free Supabase server that only you control. It takes about three minutes, once."))

        VStack(alignment: .leading, spacing: Spacing.xl) {
            AccountStep(number: 1, title: "Create a Supabase account",
                        detail: Text("It's free. Signing in with GitHub is quickest.")) {
                DashboardLink("Open Supabase", SupabaseDashboard.signUp)
            }
            AccountStep(number: 2, title: "Create an access token",
                        detail: Text("**Generate new token**, name it `Bluebox`, copy it.")) {
                DashboardLink("Open Access Tokens", SupabaseDashboard.accessTokens)
            }
            AccountStep(number: 3, title: "Paste it here",
                        detail: Text("Bluebox creates your server, its tables and sign-in. You won't need the Supabase dashboard again."))
        }
        .padding(.bottom, Spacing.xl)

        VStack(alignment: .leading, spacing: Spacing.l) {
            FloatingField(label: "Access token", text: $token, secure: !revealToken, error: tokenError,
                          submitLabel: .go, onSubmit: start) {
                RevealButton(revealed: $revealToken, noun: "Token")
                FieldPasteButton { pasted in
                    token = pasted
                    // A pasted token starts setup at once: one tap fewer.
                    if pasted.hasPrefix("sbp_") { start() }
                }
            }
            .accessibilityIdentifier("accessTokenField")

            AccountPrimaryButton(title: "Set Up", workingTitle: "Setting up…", working: false,
                                 disabled: token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: start)
                .accessibilityIdentifier("startSetupButton")

            Text("Bluebox uses the token only while it sets up, and keeps it in memory: it's never saved on this device and is sent only to Supabase.")
                .font(.footnote)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: token) { tokenError = nil }

        AccountJoinFromLink()
            .padding(.top, Spacing.xxl)

        HStack {
            AccountTextButton("Enter URL and key instead") { manual = true }
                .accessibilityIdentifier("manualSetupButton")
            Spacer()
        }
        .padding(.top, Spacing.l)
    }

    private func start() {
        tokenError = app.serverSetup.start(token: token)
        // The field doesn't keep the token once setup has it.
        if tokenError == nil { token = ""; revealToken = false }
    }
}

/// "Already set up on another device?": scan its code with the Camera
/// (iPhone, iPad) or paste its `bluebox://connect` link.
struct AccountJoinFromLink: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Hairline()
            Text("Already set up on another device?")
                .font(.headline.weight(.bold))
                .padding(.top, Spacing.m)
            Text(instructions)
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            FloatingField(label: "Link from your other device", text: $text, error: error, contentType: .url,
                          submitLabel: .go, onSubmit: connect) {
                FieldPasteButton { pasted in text = pasted; connect() }
            }
            .accessibilityIdentifier("connectLinkField")
            if working {
                AccountWorkingText(text: "Connecting…")
            } else if !text.isEmpty {
                AccountTextButton("Connect", systemImage: "arrow.right") { connect() }
                    .accessibilityIdentifier("connectLinkButton")
            }
        }
        .onChange(of: text) { error = nil }
    }

    private var instructions: String {
        #if os(iOS)
        "On that device, open Settings › Account and choose Add Another Device. Scan its code with this device's Camera, or paste its link here."
        #else
        "On that device, open Settings › Account and choose Add Another Device. Copy the link there and paste it here."
        #endif
    }

    private func connect() {
        guard !working, !text.isEmpty else { return }
        let link: ConnectLink
        do { link = try ConnectLink.parse(text: text) } catch {
            self.error = AccountModel.describe(error)
            return
        }
        working = true
        Task {
            defer { working = false }
            do {
                try await app.connectSupabase(url: link.config.url.absoluteString, key: link.config.publishableKey)
                app.serverSetup.cancel()
                text = ""
            } catch {
                self.error = AccountModel.describe(error)
            }
        }
    }
}
