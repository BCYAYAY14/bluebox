import Domain
import Foundation
import Metadata
import Observation
import Persistence
import Sync

/// Trakt connection and sync status for Settings. Inert when the build has no
/// Trakt app credentials.
@Observable
@MainActor
public final class TraktModel {
    public enum Phase: Equatable {
        case disconnected
        case awaitingApproval(TraktDeviceCode)
        case connected(username: String?)
    }

    public private(set) var phase: Phase = .disconnected
    public private(set) var status: AccountModel.Status = .idle
    public var isConfigured: Bool { client != nil }
    public var isConnected: Bool { if case .connected = phase { true } else { false } }

    @ObservationIgnored private let client: TraktClient?
    @ObservationIgnored private let engine: TraktSync?
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored var onRemoteChanges: @MainActor () -> Void = {}
    /// Your ratings (1–10). Kept on this device with or without Trakt; synced when connected.
    @ObservationIgnored private let ratings: TraktRatingsStore
    @ObservationIgnored private let prefs: PreferencesStore
    /// Bumped when a rating changes, so views showing one refresh.
    public private(set) var ratingsRevision = 0

    /// Settings › Trakt › Scrobble: tell Trakt what's playing (default on).
    public var scrobbles: Bool {
        didSet { prefs.set(scrobbles, for: Self.scrobbleKey) }
    }
    static let scrobbleKey = "bluebox.trakt.scrobble"

    init(config: TraktConfig?, http: any HTTPClient, secrets: any SecretStore, store: LibraryStore, prefs: PreferencesStore,
         resolveTitle: @escaping @Sendable (MediaKey) async -> Title?) {
        self.prefs = prefs
        ratings = TraktRatingsStore(prefs: prefs)
        scrobbles = prefs.value(Bool.self, for: Self.scrobbleKey) ?? true
        guard let config else { client = nil; engine = nil; return }
        let client = TraktClient(config: config, http: http, secrets: secrets)
        self.client = client
        engine = TraktSync(client: client, store: store, prefs: prefs, resolveTitle: resolveTitle)
        Task { [weak self] in
            if await client.isConnected { self?.phase = .connected(username: await client.username) }
        }
    }

    // MARK: Ratings

    /// Your rating of a movie, show or episode, 1–10.
    public func rating(for key: MediaKey) -> Int? {
        _ = ratingsRevision
        return ratings.all()[key]?.rating
    }

    /// Every rating with when it was given (Home's Top Picks weigh them).
    public func allRatings() -> [MediaKey: (rating: Int, date: Date)] {
        _ = ratingsRevision
        return ratings.all().reduce(into: [:]) { out, entry in
            if let r = entry.value.rating { out[entry.key] = (r, entry.value.updatedAt) }
        }
    }

    /// Rates (1–10) or clears a rating; synced to Trakt shortly after.
    public func setRating(_ rating: Int?, for key: MediaKey) {
        ratings.set(rating.map { min(max($0, 1), 10) }, for: key, at: .now)
        ratingsRevision += 1
        scheduleSync()
    }

    // MARK: Scrobbling

    /// Sends a scrobble (start, pause or stop with progress in percent) when
    /// connected and scrobbling is on. Called by `ScrobbleObserver`.
    func scrobble(_ action: TraktSync.ScrobbleAction, key: MediaKey, progress: Double) {
        guard let engine, isConnected, scrobbles else { return }
        Task { await engine.scrobble(action, key: key, progress: progress) }
    }

    /// Starts the device sign-in. The UI shows the code from `phase` while
    /// Bluebox waits for the user to approve it on trakt.tv.
    public func connect() async throws {
        guard let client, let engine else { throw TraktError.notConfigured }
        connecting?.cancel()
        let code = try await client.startDeviceAuth()
        phase = .awaitingApproval(code)
        connecting = Task { [weak self] in
            do {
                try await client.waitForAuthorization(code)
                await engine.resetState()
                self?.phase = .connected(username: await client.username)
                await self?.syncNow()
            } catch is CancellationError {
            } catch {
                guard let self, case .awaitingApproval = self.phase else { return }
                self.phase = .disconnected
                self.status = .failed(Self.describe(error))
            }
        }
    }

    public func cancelConnect() {
        connecting?.cancel(); connecting = nil
        if case .awaitingApproval = phase { phase = .disconnected }
    }

    public func disconnect() async {
        pending?.cancel()
        await client?.disconnect()
        await engine?.resetState()
        phase = .disconnected
        status = .idle
    }

    public func syncNow() async {
        pending?.cancel(); pending = nil
        await run()
    }

    public func scheduleSync(after delay: Duration = .seconds(5)) {
        guard isConnected else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    private func run() async {
        guard let engine, isConnected else { return }
        status = .syncing
        do {
            let report = try await engine.sync()
            status = .synced(.now)
            if report.applied > 0 { onRemoteChanges(); ratingsRevision += 1 }
        } catch TraktError.notConnected {
            phase = .disconnected
            status = .failed(TraktError.notConnected.localizedDescription)
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
