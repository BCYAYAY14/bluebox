import Domain
import Foundation
import Metadata
import Persistence
@testable import Sync
import Testing

/// Holds token refreshes until released, so a test can act while one is in flight.
final class SlowRefresh: HTTPClient, @unchecked Sendable {
    let inner: FakeSupabase
    private let lock = NSLock()
    private var held: [CheckedContinuation<Void, Never>] = []
    private var _waiting = 0
    var waiting: Int { lock.withLock { _waiting } }

    init(_ inner: FakeSupabase) { self.inner = inner }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url!.path.hasSuffix("/auth/v1/token"), request.url!.query?.contains("refresh_token") == true {
            await withCheckedContinuation { c in lock.withLock { held.append(c); _waiting += 1 } }
        }
        return try await inner.send(request)
    }

    func release() { lock.withLock { held.forEach { $0.resume() }; held = []; _waiting = 0 } }

    func waitUntilHeld() async {
        while waiting == 0 { await Task.yield() }
    }
}

@Suite struct AuthRaceTests {
    @Test(.timeLimit(.minutes(1))) func signingOutDuringARefreshStaysSignedOut() async throws {
        let server = FakeSupabase(), secrets = MemorySecretStore()
        let http = SlowRefresh(server)
        let auth = SupabaseAuth(config: FakeSupabase.config, http: http, secrets: secrets)
        _ = try await auth.signIn(username: "brian", password: FakeSupabase.password)
        let refresh = Task { try await auth.refresh() }
        await http.waitUntilHeld()
        await auth.signOut()
        http.release()
        await #expect(throws: SyncError.signedOut) { try await refresh.value }
        #expect(await auth.currentSession == nil)
        #expect(try secrets.read(SecretAccount.supabaseSession) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aRetiredClientDoesNotWriteItsSessionOverTheNewProject() async throws {
        let server = FakeSupabase(), secrets = MemorySecretStore()
        let http = SlowRefresh(server)
        let old = SupabaseAuth(config: FakeSupabase.config, http: http, secrets: secrets)
        _ = try await old.signIn(username: "old", password: FakeSupabase.password)
        let notified = Notified()
        await old.observe { _ in notified.hit() }
        let refresh = Task { try await old.refresh() }
        await http.waitUntilHeld()
        // The app switches projects: the old session is dropped from the Keychain.
        old.retire()
        try secrets.write(nil, for: SecretAccount.supabaseSession)
        http.release()
        _ = try? await refresh.value
        #expect(try secrets.read(SecretAccount.supabaseSession) == nil)
        #expect(notified.count == 0)
    }
}

final class Notified: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func hit() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}
