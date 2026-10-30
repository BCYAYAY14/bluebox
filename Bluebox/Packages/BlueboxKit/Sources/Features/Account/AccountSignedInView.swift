import DesignSystem
import SwiftUI
import Sync

/// Signed in: Netflix-style Account page. Big title, grey section headers,
/// hairline rows, chevrons on actions.
struct AccountOverview: View {
    @Environment(AppModel.self) private var app
    @State private var confirmSignOut = false
    @State private var confirmDisconnect = false

    var body: some View {
        let account = app.account
        Text("Account")
            .font(.largeTitle.weight(.heavy))
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, Spacing.xs)
        Text("Sync keeps My List, watch progress and profiles the same on your iPhone, iPad and Mac.")
            .font(.body).foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        AccountSectionHeader(title: "Membership & Sync")
        Hairline()
        AccountInfoRow(title: account.email.flatMap(BlueboxUsername.username(fromEmail:)) == nil ? "Email" : "Username") {
            Text(account.accountName ?? "").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .accessibilityIdentifier("signedInAccountName")
        }
        AccountInfoRow(title: "Status", detail: statusDetail(account)) {
            statusValue(account).accessibilityIdentifier("syncStatus")
        }
        AccountInfoRow("What syncs",
                       detail: account.syncsKeys
                           ? "My List, watch progress, profiles, add-ons and settings, and your API keys. Downloads and sources stay on each device."
                           : "My List, watch progress, profiles, add-ons and settings. API keys, downloads and sources stay on each device.")
        if case .failed(let why) = app.account.linkEvent {
            AccountErrorText(text: why).padding(.vertical, Spacing.m).accessibilityIdentifier("signInLinkError")
        }
        AccountActionRow(title: "Sync now", working: account.status == .syncing) {
            Task { await account.syncNow() }
        }
        .accessibilityIdentifier("syncNowButton")
        AccountActionRow(title: "Sign out", detail: "Your library stays on this device.") { confirmSignOut = true }
            .accessibilityIdentifier("signOutButton")
            .confirmationDialog("Sign out of sync?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
            } message: {
                Text("Your library stays on this device and in your project. Sign in again to resume syncing.")
            }

        AccountKeySyncRows()
        AccountAddDeviceRows()
        AccountServerRows(confirmDisconnect: $confirmDisconnect)
        TraktRows()
    }

    private func statusDetail(_ account: AccountModel) -> String? {
        if case .failed(let reason) = account.status { return reason }
        return nil
    }

    @ViewBuilder private func statusValue(_ account: AccountModel) -> some View {
        switch account.status {
        case .syncing:
            Text("Syncing…")
        case .synced(let date):
            relative(date)
        case .failed:
            if let last = account.lastSynced { relative(last, prefix: "Last synced ") } else { Text("Not synced") }
        case .idle:
            if let last = account.lastSynced { relative(last) } else { Text("Not synced yet") }
        }
    }

    private func relative(_ date: Date, prefix: String = "Synced ") -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Text(prefix + date.formatted(.relative(presentation: .named, unitsStyle: .wide)))
        }
    }
}

/// Sync API Keys: off by default and per account. Turning it on asks first and
/// says exactly what leaves the Keychain, since the server stores it as plain text.
struct AccountKeySyncRows: View {
    @Environment(AppModel.self) private var app
    @State private var confirmOn = false
    @State private var confirmRemove = false
    @State private var removing = false
    @State private var removeResult: (ok: Bool, text: String)?

    /// What Sync API Keys uploads (AppModel.syncedSecretAccounts, and add-on links).
    static let syncedSecrets = ["TMDB token", "OMDb key", "OpenSubtitles key", "Debrid key",
                                "Links of add-ons added by link (they often hold a debrid key)"]

    var body: some View {
        let account = app.account
        AccountInfoRow(title: "Sync API Keys",
                       detail: account.syncsKeys
                           ? "On for \(account.accountName ?? "this account"). Stored as plain text on your server."
                           : "Off: your API keys and add-on links stay in this device's Keychain. Each account has its own switch.") {
            Toggle("Sync API Keys", isOn: Binding(get: { account.syncsKeys }, set: { on in
                if on { confirmOn = true } else { account.setSyncsKeys(false) }
            }))
            .labelsHidden()
            .tint(Palette.brand)
            .accessibilityIdentifier("syncKeysSwitch")
        }
        .alert("Store Your API Keys on Your Server?", isPresented: $confirmOn) {
            Button("Sync Keys") { account.setSyncsKeys(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These leave this device's Keychain and are saved as plain text in your Supabase project, where anyone with its dashboard or service key can read them:\n\n"
                 + Self.syncedSecrets.joined(separator: "\n"))
        }
        AccountActionRow(title: "Remove keys from server",
                         detail: "Deletes the keys and add-on links stored on your server, including any earlier versions uploaded. No device's Keychain changes.",
                         destructive: true, working: removing) { confirmRemove = true }
            .accessibilityIdentifier("removeKeysButton")
            .confirmationDialog("Remove keys from your server?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove Keys", role: .destructive) {
                    removing = true
                    Task {
                        do {
                            try await account.removeKeysFromServer()
                            removeResult = (true, "Removed. Your keys are still on this device.")
                        } catch {
                            removeResult = (false, AccountModel.describe(error))
                        }
                        removing = false
                    }
                }
            } message: {
                Text("Sync API Keys turns off. Your keys stay in each device's Keychain.")
            }
        if let removeResult {
            Group {
                if removeResult.ok { AccountHelperText(text: removeResult.text, ok: true) } else { AccountErrorText(text: removeResult.text) }
            }
            .padding(.vertical, Spacing.m)
        }
    }
}

/// The connected project: where it is, whether it's set up, and how to switch.
struct AccountServerRows: View {
    @Environment(AppModel.self) private var app
    @Binding var confirmDisconnect: Bool

    var body: some View {
        let account = app.account
        if let server = account.server {
            AccountSectionHeader(title: "Server")
            Hairline()
            AccountInfoRow(title: "Supabase project", detail: app.hasCustomServer ? nil : "Built into this copy of Bluebox.") {
                Text(server.host() ?? server.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            AccountActionRow(title: "Check setup", detail: "Reachable, key accepted, tables present.",
                             working: account.setupCheck == .checking) {
                Task { await account.checkSetup() }
            }
            .accessibilityIdentifier("checkSetupButton")
            setupResult(account)
            if app.hasCustomServer {
                AccountActionRow(title: "Change server", detail: "Signs you out on this device.") { confirmDisconnect = true }
                    .accessibilityIdentifier("changeServerButton")
                    .confirmationDialog("Disconnect from this project?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                        Button("Disconnect", role: .destructive) { app.disconnectSupabase() }
                    } message: {
                        Text("You'll be signed out on this device. Your library stays here and in the project, and you can connect to another project.")
                    }
            }
        }
    }

    @ViewBuilder private func setupResult(_ account: AccountModel) -> some View {
        switch account.setupCheck {
        case .idle, .checking:
            EmptyView()
        case .ok(let warnings, let scripts):
            VStack(alignment: .leading, spacing: Spacing.s) {
                if warnings.isEmpty {
                    AccountHelperText(text: "Everything's set up.", ok: true)
                } else {
                    ForEach(warnings, id: \.self) { AccountErrorText(text: $0) }
                    if !scripts.isEmpty {
                        WrappingButtons {
                            ForEach(scripts, id: \.self) { CopyButton("Copy \($0.fileName)", text: $0.sql) }
                            DashboardLink("Open SQL Editor", SupabaseDashboard.url(.sqlEditor, ref: account.projectRef))
                        }
                    }
                }
            }
            .padding(.vertical, Spacing.m)
        case .failed(let why, let needsSQL):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                AccountErrorText(text: why)
                if needsSQL { WrappingButtons { SetupSQLActions(ref: account.projectRef) } }
            }
            .padding(.vertical, Spacing.m)
        }
    }
}

/// Trakt, in the same row style.
struct TraktRows: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var working = false
    @State private var message: String?

    var body: some View {
        let trakt = app.trakt
        if trakt.isConfigured {
            AccountSectionHeader(title: "Trakt")
            Hairline()
            switch trakt.phase {
            case .disconnected:
                AccountActionRow(title: "Connect Trakt",
                                 detail: "Keep My List in step with your Trakt watchlist and send what you finish to your history.",
                                 working: working) {
                    Task { await connect() }
                }
                .accessibilityIdentifier("traktConnectButton")
            case .awaitingApproval(let code):
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Go to \(code.verificationURL.absoluteString) and enter this code:")
                        .font(.subheadline).foregroundStyle(Palette.textSecondary)
                    Text(code.userCode)
                        .font(.title.monospaced().weight(.bold))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("traktUserCode")
                    HStack(spacing: Spacing.l) {
                        AccountTextButton("Open trakt.tv", systemImage: "arrow.up.right", link: true) { openURL(code.verificationURL) }
                        AccountTextButton("Cancel") { trakt.cancelConnect() }
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.vertical, Spacing.l)
                Hairline()
            case .connected(let username):
                AccountInfoRow(title: "Connected as", detail: traktStatus(trakt.status)) { Text(username ?? "Trakt") }
                AccountInfoRow(title: "Sync Lists with Trakt",
                               detail: "Your lists also sync with private Trakt lists of the same name. Deleting a list on either side leaves the other alone.") {
                    Toggle("Sync Lists with Trakt", isOn: Bindable(trakt).syncsLists)
                        .labelsHidden()
                        .tint(Palette.brand)
                        .accessibilityIdentifier("traktSyncListsSwitch")
                }
                .settingsRow("Sync Lists with Trakt")
                AccountActionRow(title: "Sync now", working: trakt.status == .syncing) { Task { await trakt.syncNow() } }
                AccountActionRow(title: "Disconnect Trakt") { Task { await trakt.disconnect() } }
            }
            if let message { AccountErrorText(text: message).padding(.vertical, Spacing.m) }
            if case .failed(let reason) = trakt.status, !trakt.isConnected {
                AccountErrorText(text: reason).padding(.vertical, Spacing.m)
            }
        }
    }

    private func traktStatus(_ status: AccountModel.Status) -> String? {
        switch status {
        case .synced(let date): "Synced \(date.formatted(.relative(presentation: .named)))"
        case .failed(let reason): reason
        default: nil
        }
    }

    private func connect() async {
        working = true; message = nil
        defer { working = false }
        do { try await app.trakt.connect() }
        catch { message = TraktModel.describe(error) }
    }
}
