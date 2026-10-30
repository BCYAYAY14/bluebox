import Domain
import Foundation
import Metadata
import Persistence
@testable import Sync
import Testing

@Suite struct AuthCallbackTests {
    @Test func recognisesOnlyOurURLs() {
        #expect(!AuthCallback.matches(URL(string: "bluebox://title/603")!))
        #expect(!AuthCallback.matches(URL(string: "https://auth-callback.example.com/#access_token=a&refresh_token=b")!))
        #expect(AuthCallback.matches(URL(string: "BLUEBOX://auth-callback/#access_token=a&refresh_token=b")!))
        #expect(AuthCallback.matches(URL(string: "bluebox://auth-callback")!))
        #expect(AuthCallback.redirectURL.absoluteString == "bluebox://auth-callback")
    }
}

@Suite struct SupabaseAuthRetireTests {
    func auth(_ server: FakeSupabase, _ secrets: MemorySecretStore = MemorySecretStore()) -> SupabaseAuth {
        SupabaseAuth(config: FakeSupabase.config, http: server, secrets: secrets)
    }

    @Test func aRetiredClientFinishingASignInDoesNotTouchTheKeychain() async throws {
        let server = FakeSupabase(), secrets = MemorySecretStore()
        let old = auth(server, secrets)
        let notified = Notified()
        await old.observe { _ in notified.hit() }
        old.retire()
        _ = try await old.signIn(username: "brian", password: FakeSupabase.password)
        #expect(try secrets.read(SecretAccount.supabaseSession) == nil)
        #expect(notified.count == 0)
    }

    @Test func offlineIsReportedAsOffline() async {
        let a = SupabaseAuth(config: FakeSupabase.config, http: StubHTTP { _ in throw URLError(.notConnectedToInternet) },
                             secrets: MemorySecretStore())
        await #expect(throws: SyncError.offline) { try await a.signIn(username: "brian", password: "whatever1") }
    }
}
