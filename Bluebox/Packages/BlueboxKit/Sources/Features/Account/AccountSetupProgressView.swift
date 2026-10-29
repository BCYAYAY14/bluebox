import DesignSystem
import SwiftUI
import Sync

/// Automatic setup under way, stopped with an error, or waiting for the user
/// to pick a project. Card content for `AccountScreen`.
struct AccountSetupProgressView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let setup = app.serverSetup
        switch setup.phase {
        case .idle:
            EmptyView()
        case .working(let step):
            working(step, since: setup.stepStarted)
        case .failed(let why):
            failed(why)
        case .choosingProject(let reason, let projects):
            choosing(reason, projects)
        }
    }

    // MARK: Working

    /// The four things the user can follow, and which setup steps belong to each.
    private static let stages: [(title: String, steps: [SupabaseAutoSetup.Step])] = [
        ("Check your token", [.checkingToken]),
        ("Create your server", [.creatingServer, .startingServer]),
        ("Create tables and sign-in", [.creatingTables, .configuringSignIn]),
        ("Connect this device", [.connecting]),
    ]

    @ViewBuilder private func working(_ step: SupabaseAutoSetup.Step, since: Date) -> some View {
        let current = Self.stages.firstIndex { $0.steps.contains(step) } ?? 0
        AccountTitle(title: "Setting Up Sync",
                     subtitle: Text("Keep Bluebox open until it's done. If anything stops it, Try Again carries on from where it was."))

        VStack(alignment: .leading, spacing: Spacing.xl) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, stage in
                AccountStep(number: i + 1, title: stage.title,
                            detail: i == current ? detail(step, since: since) : nil,
                            done: i < current, active: i == current)
                    .opacity(i > current ? 0.5 : 1)
            }
        }
        .accessibilityIdentifier("setupProgress")

        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                AccountTextButton("Cancel") { app.serverSetup.cancel() }
                    .accessibilityIdentifier("cancelSetupButton")
                Spacer()
            }
            tokenNote
        }
        .padding(.top, Spacing.xxl)
    }

    private func detail(_ step: SupabaseAutoSetup.Step, since: Date) -> Text {
        switch step {
        case .checkingToken: Text("Looking for your Bluebox project…")
        case .creatingServer: Text("Creating your server… about 2 minutes  \(elapsed(since))")
        case .startingServer: Text("Starting your server… about a minute  \(elapsed(since))")
        case .creatingTables: Text("Creating Bluebox's tables…")
        case .configuringSignIn: Text("Turning on username sign-in…")
        case .connecting: Text("Connecting this device…")
        }
    }

    /// "1:05", counting up while a server starts.
    private func elapsed(_ since: Date) -> Text {
        // Under an hour, so it reads m:ss.
        Text(timerInterval: since...since.addingTimeInterval(59 * 60), countsDown: false).monospacedDigit()
            .foregroundStyle(Palette.textTertiary)
    }

    // MARK: Failed

    @ViewBuilder private func failed(_ why: String) -> some View {
        AccountTitle(title: "Setup Stopped")
        VStack(alignment: .leading, spacing: Spacing.l) {
            AccountErrorText(text: why).accessibilityIdentifier("setupError")
            AccountPrimaryButton(title: "Try Again", workingTitle: "", working: false) { app.serverSetup.retry() }
                .accessibilityIdentifier("retrySetupButton")
            WrappingButtons {
                AccountTextButton("Use a different token") { app.serverSetup.cancel() }
                DashboardLink("Open Supabase", SupabaseDashboard.projects)
            }
            tokenNote
        }
    }

    // MARK: Choosing a project

    @ViewBuilder private func choosing(_ reason: String, _ projects: [ManagedProject]) -> some View {
        AccountTitle(title: "Choose a Project", subtitle: Text(reason))
        VStack(alignment: .leading, spacing: 0) {
            if projects.isEmpty {
                Text("None of your projects is running right now. Pause or delete one at supabase.com, then try again.")
                    .font(.subheadline).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Spacing.l)
            } else {
                Hairline()
                ForEach(projects) { project in
                    AccountActionRow(title: project.name, detail: Self.regionName(project.region)) {
                        app.serverSetup.use(project)
                    }
                }
                Text("Bluebox adds its own tables to the project you choose and turns off its confirmation emails. Nothing else changes.")
                    .font(.footnote).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Spacing.l)
            }
        }
        .accessibilityIdentifier("projectPicker")
        VStack(alignment: .leading, spacing: Spacing.l) {
            AccountPrimaryButton(title: "Try Again", workingTitle: "", working: false) { app.serverSetup.retry() }
            WrappingButtons {
                AccountTextButton("Use a different token") { app.serverSetup.cancel() }
                DashboardLink("Open Supabase", SupabaseDashboard.projects)
            }
            tokenNote
        }
    }

    private var tokenNote: some View {
        Text("Your access token stays in memory while this runs and is forgotten when it ends. It's never saved on this device.")
            .font(.footnote)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "us-east-1" → "US East (North Virginia)", or the code itself.
    static func regionName(_ code: String?) -> String? {
        guard let code else { return nil }
        let names = [
            "us-east-1": "US East (North Virginia)", "us-east-2": "US East (Ohio)", "us-west-1": "US West (North California)",
            "us-west-2": "US West (Oregon)", "ca-central-1": "Canada (Central)", "sa-east-1": "South America (São Paulo)",
            "eu-west-1": "West EU (Ireland)", "eu-west-2": "West EU (London)", "eu-west-3": "West EU (Paris)",
            "eu-central-1": "Central EU (Frankfurt)", "eu-central-2": "Central EU (Zurich)", "eu-north-1": "North EU (Stockholm)",
            "ap-south-1": "South Asia (Mumbai)", "ap-southeast-1": "Southeast Asia (Singapore)",
            "ap-northeast-1": "Northeast Asia (Tokyo)", "ap-northeast-2": "Northeast Asia (Seoul)",
            "ap-east-1": "East Asia (Hong Kong)", "ap-southeast-2": "Oceania (Sydney)",
        ]
        return names[code] ?? code
    }
}
