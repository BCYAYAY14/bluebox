import Foundation
import Metadata
import Observation
import Sync

/// Automatic setup from a Supabase access token, for Settings › Account & Sync.
///
/// The token is held in memory by this object only while setup runs and, for
/// a new project, until the first account exists (so sign-ups can be closed
/// after it). It is never written anywhere, and it's forgotten on cancel, on
/// sign-in, on disconnect, and when the app quits.
@Observable
@MainActor
public final class ServerSetupModel {
    public enum Phase: Equatable {
        case idle
        case working(SupabaseAutoSetup.Step)
        case failed(String)
        /// The free plan has no room (or no free organization): pick a project.
        case choosingProject(reason: String, projects: [ManagedProject])
    }

    public private(set) var phase: Phase = .idle
    /// When the current step began, for the elapsed time while a server starts.
    public private(set) var stepStarted = Date()
    /// Setup finished on a project with no accounts yet: Account shows
    /// "Create your account" first instead of "Sign in".
    public private(set) var needsFirstAccount = false
    public var isRunning: Bool { phase != .idle }

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var target: SupabaseAutoSetup.Target = .automatic
    /// Bluebox's own project, waiting for its first account before sign-ups close.
    @ObservationIgnored private var closeSignupsFor: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let http: any HTTPClient
    @ObservationIgnored private let makeSetup: @Sendable (String, any HTTPClient) -> SupabaseAutoSetup
    /// Stores and uses the project once its key is known (AppModel.connectSupabase).
    @ObservationIgnored var connect: @MainActor (SupabaseConfig) async throws -> Void = { _ in }
    @ObservationIgnored private let retryDelay: Duration

    init(http: any HTTPClient,
         makeSetup: @escaping @Sendable (String, any HTTPClient) -> SupabaseAutoSetup = { SupabaseAutoSetup(token: $0, http: $1) },
         retryDelay: Duration = .seconds(3)) {
        self.http = http; self.makeSetup = makeSetup; self.retryDelay = retryDelay
    }

    /// Starts setup with a pasted token. Returns why the token can't be used,
    /// without sending it anywhere, or nil once setup is under way.
    @discardableResult
    public func start(token raw: String) -> String? {
        if let why = SupabaseAutoSetup.checkToken(raw) { return why }
        token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        target = .automatic
        run()
        return nil
    }

    /// Runs again with the same token: everything done so far is kept.
    public func retry() {
        guard token != nil else { phase = .idle; return }
        run()
    }

    /// Sets up in a project the user picked from the list.
    public func use(_ project: ManagedProject) {
        guard token != nil else { phase = .idle; return }
        target = .existing(ref: project.ref)
        run()
    }

    /// Stops, and forgets the token. A project already created stays and is reused next time.
    public func cancel() {
        task?.cancel(); task = nil
        forget()
        phase = .idle
    }

    /// Called right after the first account is created: closes sign-ups in
    /// Bluebox's own project, then forgets the token.
    func firstAccountCreated() {
        if let ref = closeSignupsFor, let token {
            let setup = makeSetup(token, http)
            Task { try? await setup.turnOffSignups(ref: ref) }
        }
        forget()
    }

    /// Drops the token and anything waiting on it.
    func forget() {
        token = nil
        closeSignupsFor = nil
        needsFirstAccount = false
    }

    private func run() {
        guard let token else { return }
        task?.cancel()
        let setup = makeSetup(token, http)
        let target = self.target
        show(.checkingToken)
        let report: @Sendable (SupabaseAutoSetup.Step) async -> Void = { [weak self] step in await self?.show(step) }
        task = Task { [weak self] in
            do {
                let outcome = try await setup.run(target, progress: report)
                try Task.checkCancellation()
                guard let self else { return }
                // Set before connecting, so the account page opens on the right form.
                self.needsFirstAccount = !outcome.hasAccounts
                self.closeSignupsFor = outcome.ownsProject && !outcome.hasAccounts ? outcome.ref : nil
                do {
                    try await self.connectWithRetries(outcome.config)
                } catch {
                    self.needsFirstAccount = false
                    self.closeSignupsFor = nil
                    throw error
                }
                // Nothing left to do with the token unless sign-ups close after the first account.
                if self.closeSignupsFor == nil { self.token = nil }
                self.phase = .idle
            } catch is CancellationError {
                return
            } catch let failure as SupabaseAutoSetup.Failure {
                guard let self, !Task.isCancelled else { return }
                if let projects = failure.alternatives {
                    self.phase = .choosingProject(reason: failure.errorDescription ?? "", projects: projects)
                } else {
                    self.phase = .failed(failure.errorDescription ?? "Setup failed.")
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(AccountModel.describe(error))
            }
        }
    }

    private func show(_ step: SupabaseAutoSetup.Step) {
        guard phase != .working(step) else { return }
        phase = .working(step)
        stepStarted = Date()
    }

    /// A brand-new project's address and API can lag its "healthy" status by a
    /// few seconds (DNS, the API's table cache), so connecting gets a few tries.
    private func connectWithRetries(_ config: SupabaseConfig) async throws {
        var attempt = 0
        while true {
            do {
                try await connect(config)
                return
            } catch {
                attempt += 1
                guard attempt <= 5, Self.worthRetrying(error) else { throw error }
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    private static func worthRetrying(_ e: Error) -> Bool {
        switch e as? SupabaseSetupError {
        case .tablesMissing, .tablesOutdated, .notSupabase, .offline, .unreachable, .server: true
        default: false
        }
    }

    #if DEBUG
    /// Screenshots: shows a step or a failure without a Supabase account.
    func preview(_ phase: Phase, needsFirstAccount: Bool = false) {
        self.phase = phase
        self.needsFirstAccount = needsFirstAccount
        stepStarted = Date().addingTimeInterval(-47)
    }
    #endif
}
