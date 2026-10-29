import Foundation
import Metadata

/// Sets up a Supabase project for Bluebox from one personal access token:
/// finds (or creates) the project, waits until it's up, creates Bluebox's
/// tables, turns on username sign-in, and fetches the publishable key.
///
/// Every step is safe to repeat, so after a failure or a timeout the whole
/// thing simply runs again: an existing "Bluebox" project is reused, tables
/// that are there are left alone, and the Auth settings are set to the same values.
public struct SupabaseAutoSetup: Sendable {
    public static let projectName = "Bluebox"
    /// Supabase's own default is 6.
    public static let passwordMinLength = 8

    public enum Step: Equatable, Sendable {
        case checkingToken
        /// Creating a new project and waiting for it: about two minutes.
        case creatingServer
        /// An existing project that's starting or waking from a pause.
        case startingServer
        case creatingTables
        case configuringSignIn
        case connecting
    }

    public enum Target: Equatable, Sendable {
        /// Reuse the project named Bluebox, or create it.
        case automatic
        /// A project the user picked (when the free plan has no room for another).
        case existing(ref: String)
    }

    public struct Outcome: Equatable, Sendable {
        public let config: SupabaseConfig
        public let ref: String
        /// Bluebox's own project (not one the user picked), so it may turn off
        /// new sign-ups once the first account exists.
        public let ownsProject: Bool
        /// The project already has user accounts: sign in rather than create one.
        public let hasAccounts: Bool
    }

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case notAToken(String)
        case api(ManagementAPIError)
        /// The free plan's active-project limit: pick one of these instead.
        case projectLimit([ManagedProject])
        /// Every organization is on a paid plan: pick one of these instead.
        case noFreeOrganization([ManagedProject])
        case projectGone
        case projectUnavailable(String)
        /// Still starting after the wait: Try Again carries on waiting.
        case stillStarting
        case foreignProfilesTable
        case tablesHalfSetUp
        case sqlFailed(String)
        case noClientKey

        public var errorDescription: String? {
            switch self {
            case .notAToken(let why): why
            case .api(let e): e.errorDescription
            case .projectLimit:
                "Supabase's free plan allows two active projects, and yours already has two. Use one of them for Bluebox, or pause one at supabase.com and try again."
            case .noFreeOrganization:
                "Your Supabase organizations are all on paid plans, so a new project would cost money. Use an existing project for Bluebox, or create a free organization at supabase.com and try again."
            case .projectGone: "That project isn't there any more. Try again to create a new one."
            case .projectUnavailable(let status):
                "Supabase says your Bluebox project is \(status.lowercased().replacingOccurrences(of: "_", with: " ")). Open Supabase to check on it, then try again."
            case .stillStarting:
                "Your server is taking longer than usual to start. Try again: Bluebox picks up where it left off."
            case .foreignProfilesTable:
                "This project already has a profiles table that isn't Bluebox's, so Bluebox can't set up there. Use a new project."
            case .tablesHalfSetUp:
                "Bluebox's tables are only partly there in this project. Open the SQL Editor in Supabase, check the tables, or use a new project."
            case .sqlFailed(let why): "Creating Bluebox's tables failed: \(why)"
            case .noClientKey:
                "Bluebox couldn't find the project's publishable key. In Supabase, open Project Settings › API Keys, create a publishable key, then try again."
            }
        }

        /// Projects the user can choose instead, when the failure offers a choice.
        public var alternatives: [ManagedProject]? {
            switch self {
            case .projectLimit(let p), .noFreeOrganization(let p): p
            default: nil
            }
        }
    }

    let api: SupabaseManagementAPI
    let timeZone: TimeZone
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void
    let makePassword: @Sendable () -> String
    /// How long to wait for a project to start before asking the user to try again.
    var startTimeout: TimeInterval = 600
    var pollInterval: Duration = .seconds(5)

    public init(token: String, http: any HTTPClient, timeZone: TimeZone = .current,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                makePassword: @escaping @Sendable () -> String = { SupabaseAutoSetup.databasePassword() }) {
        api = SupabaseManagementAPI(token: token, http: http)
        self.timeZone = timeZone; self.now = now; self.sleep = sleep; self.makePassword = makePassword
    }

    /// Catches pasted keys and blank fields before anything is sent.
    public static func checkToken(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "Paste the access token." }
        if t.hasPrefix("sb_publishable_") || t.hasPrefix("sb_secret_") || t.hasPrefix("eyJ") {
            return "That's a project key, not an access token. Create a token on the Access Tokens page: it starts with sbp_."
        }
        if t.contains(where: \.isWhitespace) { return "That doesn't look like an access token. Copy it again: it starts with sbp_." }
        return nil
    }

    // MARK: Run

    public func run(_ target: Target, progress: @escaping @Sendable (Step) async -> Void) async throws -> Outcome {
        do {
            await progress(.checkingToken)
            let projects = try await api.projects()
            let project: ManagedProject
            let owns: Bool
            var isNew = false
            switch target {
            case .existing(let ref):
                guard let picked = projects.first(where: { $0.ref == ref }) else { throw Failure.projectGone }
                project = picked
                owns = picked.name.caseInsensitiveCompare(Self.projectName) == .orderedSame
            case .automatic:
                if let existing = Self.blueboxProject(in: projects) {
                    project = existing
                } else {
                    await progress(.creatingServer)
                    project = try await createProject(alternatives: projects)
                    isNew = true
                }
                owns = true
            }
            if !project.isHealthy && !isNew { await progress(.startingServer) }
            try await waitUntilReady(project)

            await progress(.creatingTables)
            let state = try await createTables(project.ref)

            await progress(.configuringSignIn)
            try await api.updateAuthConfig(project.ref, Self.authConfig(ownsProject: owns, hasAccounts: state.users > 0))

            await progress(.connecting)
            guard let key = try await api.clientKey(project.ref),
                  let config = SupabaseConfig(url: project.url.absoluteString, publishableKey: key) else {
                throw Failure.noClientKey
            }
            return Outcome(config: config, ref: project.ref, ownsProject: owns, hasAccounts: state.users > 0)
        } catch let e as ManagementAPIError {
            throw Failure.api(e)
        }
    }

    /// Once the first account exists in Bluebox's own project, nobody else
    /// needs to sign up: the connect link other devices use is public by design.
    /// Profiles are rows in that one account, not separate users, so they're unaffected.
    public func turnOffSignups(ref: String) async throws {
        do {
            try await api.updateAuthConfig(ref, AuthConfigUpdate(disableSignup: true))
        } catch let e as ManagementAPIError {
            throw Failure.api(e)
        }
    }

    /// Email provider on (usernames are stored as synthetic addresses), no
    /// confirmation email, ever. Bluebox's own project also gets the redirect
    /// URL, a longer minimum password, and sign-ups on until the first account exists.
    /// A project the user picked keeps its other settings.
    static func authConfig(ownsProject: Bool, hasAccounts: Bool) -> AuthConfigUpdate {
        var update = AuthConfigUpdate(externalEmailEnabled: true, mailerAutoconfirm: true)
        if ownsProject {
            update.siteURL = AuthCallback.redirectURL.absoluteString
            update.uriAllowList = AuthCallback.redirectURL.absoluteString
            update.passwordMinLength = passwordMinLength
            if !hasAccounts { update.disableSignup = false }
        }
        return update
    }

    // MARK: Project

    /// The project named Bluebox that can still be used, preferring a running one.
    static func blueboxProject(in projects: [ManagedProject]) -> ManagedProject? {
        let dead: Set<String> = ["REMOVED", "INIT_FAILED", "RESTORE_FAILED", "PAUSE_FAILED"]
        let named = projects.filter {
            $0.name.caseInsensitiveCompare(projectName) == .orderedSame && !dead.contains($0.status ?? "")
        }
        return named.first(where: \.isHealthy) ?? named.first(where: { !$0.isPaused }) ?? named.first
    }

    private func createProject(alternatives projects: [ManagedProject]) async throws -> ManagedProject {
        let usable = projects.filter(\.isHealthy)
        let org = try await organizationForNewProject(alternatives: usable)
        let region = await region(organizationSlug: org)
        do {
            return try await api.createProject(name: Self.projectName, organizationSlug: org,
                                               databasePassword: makePassword(), region: region)
        } catch let e as ManagementAPIError where Self.isProjectLimit(e) {
            throw Failure.projectLimit(usable)
        }
    }

    /// A free organization to create the project in, or a new one for an account that has none.
    private func organizationForNewProject(alternatives: [ManagedProject]) async throws -> String {
        let orgs = try await api.organizations()
        if orgs.isEmpty { return try await api.createOrganization(name: Self.projectName).slug }
        var unknown: String?
        for org in orgs.prefix(10) {
            switch try? await api.organizationPlan(org.slug) {
            case "free": return org.slug
            case nil: unknown = unknown ?? org.slug
            default: continue
            }
        }
        if let unknown { return unknown }
        throw Failure.noFreeOrganization(alternatives)
    }

    /// Supabase answers a full free plan with a 4xx whose message mentions the limit.
    static func isProjectLimit(_ e: ManagementAPIError) -> Bool {
        let message: String
        switch e {
        case .server(let status, let m) where (400..<500).contains(status): message = m ?? ""
        case .forbidden(let m): message = m ?? ""
        default: return false
        }
        let m = message.lowercased()
        return m.contains("limit") || m.contains("maximum") || m.contains("free project")
    }

    private func region(organizationSlug: String) async -> RegionChoice {
        let continent = SupabaseRegions.continent(for: timeZone)
        if let code = try? await api.recommendedRegion(organizationSlug: organizationSlug, continent: continent) {
            return .specific(code)
        }
        return .specific(SupabaseRegions.fallbackRegion(for: timeZone))
    }

    /// Wakes a paused project, then polls until the project and its Auth,
    /// database and API services are healthy.
    private func waitUntilReady(_ project: ManagedProject) async throws {
        var current = project
        if current.isHealthy, (try? await api.servicesHealthy(current.ref)) == true { return }
        if current.isPaused {
            try await api.restoreProject(current.ref)
        }
        let deadline = now().addingTimeInterval(startTimeout)
        var failures = 0
        while true {
            try Task.checkCancellation()
            do {
                current = try await api.project(current.ref)
                switch current.status ?? "UNKNOWN" {
                case "ACTIVE_HEALTHY":
                    if try await api.servicesHealthy(current.ref) { return }
                case "REMOVED":
                    throw Failure.projectGone
                case "INIT_FAILED", "RESTORE_FAILED", "PAUSE_FAILED", "GOING_DOWN", "PAUSING":
                    throw Failure.projectUnavailable(current.status ?? "")
                default:
                    break  // COMING_UP, RESTORING, RESTARTING, UPGRADING, RESIZING, ACTIVE_UNHEALTHY, UNKNOWN…
                }
                failures = 0
            } catch let e as ManagementAPIError where e.isTransient && failures < 4 {
                failures += 1
            } catch ManagementAPIError.notFound {
                throw Failure.projectGone
            }
            if now() >= deadline { throw Failure.stillStarting }
            try await sleep(pollInterval)
        }
    }

    // MARK: Tables

    struct DatabaseState: Equatable {
        var progress = false, watchlist = false, profiles = false, syncProfiles = false, settings = false, lists = false
        var users = 0

        init(progress: Bool = false, watchlist: Bool = false, profiles: Bool = false, syncProfiles: Bool = false,
             settings: Bool = false, lists: Bool = false, users: Int = 0) {
            self.progress = progress; self.watchlist = watchlist; self.profiles = profiles
            self.syncProfiles = syncProfiles; self.settings = settings; self.lists = lists; self.users = users
        }

        init(row: [String: Any]?) {
            func flag(_ k: String) -> Bool {
                switch row?[k] {
                case let b as Bool: b
                case let n as NSNumber: n.boolValue
                case let s as String: ["t", "true", "1"].contains(s.lowercased())
                default: false
                }
            }
            func int(_ k: String) -> Int {
                switch row?[k] {
                case let n as NSNumber: n.intValue
                case let s as String: Int(s) ?? 0
                default: 0
                }
            }
            self.init(progress: flag("progress"), watchlist: flag("watchlist"), profiles: flag("profiles"),
                      syncProfiles: flag("sync_profiles"), settings: flag("settings"), lists: flag("lists"), users: int("users"))
        }
    }

    /// What's already in the project, in one round trip.
    static let stateQuery = """
        select to_regclass('public.watch_progress') is not null as progress,
               to_regclass('public.watchlist_entries') is not null as watchlist,
               to_regclass('public.profiles') is not null as profiles,
               exists (select 1 from pg_proc where proname = 'sync_profiles'
                       and pronamespace = 'public'::regnamespace) as sync_profiles,
               to_regclass('public.account_settings') is not null as settings,
               to_regclass('public.lists') is not null as lists,
               (select count(*)::int from auth.users) as users;
        """

    enum TablePlan: Equatable { case nothing, everything, profilesOnly, settingsOnly, listsOnly }

    /// setup.sql isn't written to run twice, so Bluebox runs only what's missing.
    static func tablePlan(_ s: DatabaseState) throws -> TablePlan {
        switch (s.progress, s.watchlist, s.profiles, s.syncProfiles, s.settings, s.lists) {
        case (true, true, true, true, true, true): return .nothing
        case (false, false, false, false, false, false): return .everything
        // Set up before lists existed: the fourth migration only.
        case (true, true, true, true, true, false): return .listsOnly
        // Set up before account settings existed: the third and fourth migrations.
        case (true, true, true, true, false, false): return .settingsOnly
        // Set up by hand before profiles existed: the second, third and fourth migrations.
        case (true, true, false, false, false, false): return .profilesOnly
        case (false, false, true, false, _, _): throw Failure.foreignProfilesTable
        default: throw Failure.tablesHalfSetUp
        }
    }

    private func createTables(_ ref: String) async throws -> DatabaseState {
        let before = DatabaseState(row: try await api.runQuery(ref, Self.stateQuery).first)
        let sql: String
        switch try Self.tablePlan(before) {
        case .nothing: return before
        case .everything: sql = SupabaseSetupFiles.setupSQL
        case .profilesOnly:
            sql = [SupabaseSetupFiles.profilesMigrationSQL, SupabaseSetupFiles.accountSettingsMigrationSQL,
                   SupabaseSetupFiles.listsMigrationSQL].joined(separator: "\n")
        case .settingsOnly: sql = SupabaseSetupFiles.accountSettingsMigrationSQL + "\n" + SupabaseSetupFiles.listsMigrationSQL
        case .listsOnly: sql = SupabaseSetupFiles.listsMigrationSQL
        }
        do {
            _ = try await api.runQuery(ref, sql)
        } catch ManagementAPIError.server(let status, let message) where (400..<500).contains(status) {
            throw Failure.sqlFailed(message ?? "error \(status)")
        }
        let after = DatabaseState(row: try await api.runQuery(ref, Self.stateQuery).first)
        guard try Self.tablePlan(after) == .nothing else { throw Failure.sqlFailed("the tables still aren't there.") }
        return after
    }

    // MARK: Database password

    /// A strong random database password. Supabase requires one; Bluebox never
    /// uses it, so it's thrown away (it can be reset in the dashboard).
    public static func databasePassword(length: Int = 32) -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()  // arc4random: cryptographically secure
        return String((0..<length).map { _ in chars.randomElement(using: &rng)! })
    }
}

/// Picks a region near the device from its time zone.
public enum SupabaseRegions {
    /// The continent code `available-regions` takes: NA, SA, EU, AF, AS, OC.
    public static func continent(for timeZone: TimeZone) -> String {
        let id = timeZone.identifier
        let area = id.split(separator: "/").first.map(String.init) ?? ""
        switch area {
        case "America":
            return southAmerica.contains(where: { id.contains($0) }) ? "SA" : "NA"
        case "Europe", "Atlantic", "Arctic": return "EU"
        case "Africa": return "AF"
        case "Asia", "Indian": return "AS"
        case "Australia", "Antarctica": return "OC"
        case "Pacific": return id == "Pacific/Honolulu" ? "NA" : "OC"
        default: return "NA"  // US/…, Canada/…, and anything unrecognised
        }
    }

    /// A specific region when Supabase's recommendation isn't available.
    public static func fallbackRegion(for timeZone: TimeZone) -> String {
        let id = timeZone.identifier
        switch continent(for: timeZone) {
        case "SA": return "sa-east-1"
        case "EU":
            if ["London", "Dublin", "Lisbon", "Atlantic/"].contains(where: id.contains) { return "eu-west-2" }
            if id.contains("Paris") || id.contains("Brussels") || id.contains("Madrid") { return "eu-west-3" }
            if ["Stockholm", "Oslo", "Helsinki", "Copenhagen", "Riga", "Tallinn", "Vilnius", "Reykjavik"].contains(where: id.contains) {
                return "eu-north-1"
            }
            if id.contains("Zurich") { return "eu-central-2" }
            return "eu-central-1"
        case "AF": return "eu-west-3"
        case "AS":
            if ["Kolkata", "Calcutta", "Karachi", "Dhaka", "Colombo", "Kathmandu", "Dubai", "Muscat", "Qatar", "Riyadh",
                "Bahrain", "Kuwait", "Indian/"].contains(where: id.contains) { return "ap-south-1" }
            if id.contains("Tokyo") { return "ap-northeast-1" }
            if id.contains("Seoul") { return "ap-northeast-2" }
            if ["Hong_Kong", "Shanghai", "Taipei", "Macau", "Chongqing", "Urumqi"].contains(where: id.contains) { return "ap-east-1" }
            return "ap-southeast-1"
        case "OC": return "ap-southeast-2"
        default:
            if ["Los_Angeles", "Vancouver", "Tijuana", "Phoenix", "Anchorage", "Juneau", "Honolulu", "Boise", "Denver",
                "Edmonton", "Whitehorse", "US/Pacific", "US/Mountain", "US/Alaska"].contains(where: id.contains) {
                return "us-west-1"
            }
            if ["Toronto", "Montreal", "Halifax", "Winnipeg", "Regina", "St_Johns", "Canada/"].contains(where: id.contains) {
                return "ca-central-1"
            }
            return "us-east-1"
        }
    }

    static let southAmerica = [
        "Sao_Paulo", "Argentina", "Buenos_Aires", "Santiago", "Bogota", "Lima", "Caracas", "Montevideo", "Asuncion",
        "La_Paz", "Guayaquil", "Cayenne", "Paramaribo", "Guyana", "Belem", "Fortaleza", "Recife", "Manaus", "Bahia",
        "Cuiaba", "Campo_Grande", "Porto_Velho", "Boa_Vista", "Rio_Branco", "Noronha", "Maceio", "Araguaina",
        "Santarem", "Punta_Arenas", "Eirunepe",
    ]
}
