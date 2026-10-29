import DesignSystem
import SwiftUI
import Sync

/// The fallback for a self-hosted project, or anyone who'd rather not use a
/// token: the dashboard steps, then the project URL and key. Card content for `AccountScreen`.
struct AccountManualConnectView: View {
    @Environment(AppModel.self) private var app
    /// Back to the token setup.
    @Binding var manual: Bool
    @State private var url = ""
    @State private var key = ""
    @State private var revealKey = false
    @State private var working = false
    @State private var failure: SupabaseSetupError?
    @State private var failureText: String?

    var body: some View {
        let urlCheck = SupabaseSetupInput.checkURL(url)
        let keyCheck = SupabaseSetupInput.checkKey(key)
        let ref = urlCheck.ref
        let ready = urlCheck.url != nil && keyCheck.isValid

        AccountTitle(title: "Enter URL and Key",
                     subtitle: Text("For a self-hosted server, or a Supabase project you set up yourself. About ten minutes in the Supabase dashboard."))

        VStack(alignment: .leading, spacing: Spacing.xl) {
            AccountStep(number: 1, title: "Create a project",
                        detail: Text("A free Supabase project holds your list and progress. Only you can see it."),
                        steps: AccountSubSteps(
                            "Sign up at supabase.com (GitHub sign-in is quickest).",
                            "Click **New project**. Name it `Bluebox`, pick the region nearest you, and keep the **Free** plan.",
                            "Make up a database password. Bluebox never needs it.",
                            "Click **Create new project** and wait a minute or two until the dashboard says it's ready.")) {
                DashboardLink("Open Supabase", SupabaseDashboard.projects)
            }
            AccountStep(number: 2, title: "Create Bluebox's tables",
                        detail: Text("One script makes the tables and the rules that keep each account's data private."),
                        steps: AccountSubSteps(
                            "Tap **Copy setup.sql** below.",
                            "Tap **Open SQL Editor** (or in the dashboard: **SQL Editor** › **New query**).",
                            "Paste into the editor and click **Run** at the bottom right.",
                            "You should see **Success. No rows returned**.")) {
                SetupSQLActions(ref: ref)
            }
            AccountStep(number: 3, title: "Turn off confirmation emails",
                        detail: Text("Bluebox signs in with a username and password and never sends email, so new accounts mustn't wait for one."),
                        steps: AccountSubSteps(
                            "Open **Authentication** › **Sign In / Providers** › **Email**.",
                            "Turn off **Confirm email** and click **Save**.")) {
                DashboardLink("Open Sign In / Providers", SupabaseDashboard.url(.providers, ref: ref))
            }
            AccountStep(number: 4, title: "Paste your URL and key",
                        detail: Text("Then fill in the two boxes below and tap Connect."),
                        done: ready,
                        steps: AccountSubSteps(
                            "Open **Project Settings** › **API Keys** (or tap **Open API keys** below).",
                            "Copy the **Project URL** (`https://….supabase.co`) into **Project URL**. If it isn't on that page, it's under **Project Settings** › **Data API**.",
                            "Copy the **Publishable key** (starts `sb_publishable_`), or on older projects the **anon** key, into the second box.",
                            "Never use the **secret** or **service_role** key: Bluebox refuses it.")) {
                DashboardLink("Open API keys", SupabaseDashboard.url(.apiKeys, ref: ref))
            }
        }
        .padding(.bottom, Spacing.xxl)

        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                FloatingField(label: "Project URL", text: $url, error: urlError(urlCheck), contentType: .url, submitLabel: .next) {
                    FieldPasteButton { url = $0 }
                }
                .accessibilityIdentifier("supabaseURLField")
                if case .valid(let u, let ref) = urlCheck {
                    AccountHelperText(text: ref.map { "Hosted project \($0)" } ?? "Self-hosted at \(u.host() ?? u.absoluteString)", ok: true)
                }
            }

            VStack(alignment: .leading, spacing: Spacing.s) {
                FloatingField(label: "Publishable or anon key", text: $key, secure: !revealKey, error: keyError(keyCheck),
                              submitLabel: .go, onSubmit: { if ready { Task { await connect() } } }) {
                    RevealButton(revealed: $revealKey, noun: "Key")
                    FieldPasteButton { key = $0 }
                }
                .accessibilityIdentifier("supabaseKeyField")
                switch keyCheck {
                case .valid(let kind): AccountHelperText(text: kind == .publishable ? "Publishable key" : "Legacy anon key", ok: true)
                case .privileged(let why): AccountDangerBox(text: why).accessibilityIdentifier("supabasePrivilegedKeyWarning")
                default: EmptyView()
                }
            }

            AccountPrimaryButton(title: "Connect", workingTitle: "Checking project…", working: working, disabled: !ready) {
                Task { await connect() }
            }
            .padding(.top, Spacing.s)
            .accessibilityIdentifier("supabaseConnectButton")

            if let failureText {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    AccountErrorText(text: failureText)
                    if failure?.needsSetupSQL == true { WrappingButtons { SetupSQLActions(ref: ref) } }
                }
                .accessibilityIdentifier("supabaseConnectError")
            }

            Text("Bluebox checks the project answers and has its tables, then keeps the URL and key in this device's Keychain. Connect once on each device, or use Add Another Device once you're signed in.")
                .font(.footnote)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                AccountTextButton("Use an access token instead") { manual = false }
                    .accessibilityIdentifier("tokenSetupButton")
                Spacer()
            }
            .padding(.top, Spacing.s)
        }
        .onChange(of: url) { failure = nil; failureText = nil }
        .onChange(of: key) { failure = nil; failureText = nil }
    }

    private func urlError(_ check: SupabaseSetupInput.URLCheck) -> String? {
        if case .invalid(let why) = check { why } else { nil }
    }

    private func keyError(_ check: SupabaseSetupInput.KeyCheck) -> String? {
        if case .invalid(let why) = check { why } else { nil }
    }

    private func connect() async {
        guard !working else { return }
        working = true; failure = nil; failureText = nil
        defer { working = false }
        do {
            try await app.connectSupabase(url: url, key: key)
            app.serverSetup.cancel()
        } catch {
            failure = error as? SupabaseSetupError
            failureText = AccountModel.describe(error)
        }
    }
}
