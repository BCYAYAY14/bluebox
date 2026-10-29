import Domain
import Foundation
import Metadata
import Persistence
@testable import Sync
import Testing

@Suite struct AuthCallbackParsingTests {
    @Test func implicitFlowFragment() {
        let url = URL(string: "bluebox://auth-callback#access_token=AT&expires_at=1900000000&expires_in=3600&refresh_token=RT&token_type=bearer&type=magiclink")!
        #expect(AuthCallback(url: url) == .session(.init(accessToken: "AT", refreshToken: "RT", expiresIn: 3600,
                                                         expiresAt: 1_900_000_000, type: "magiclink")))
    }

    @Test func errorsInTheFragmentOrQuery() {
        let fragment = URL(string: "bluebox://auth-callback#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")!
        #expect(AuthCallback(url: fragment) == .failure(code: "otp_expired", description: "Email link is invalid or has expired"))
        let query = URL(string: "bluebox://auth-callback?error_description=Email%20link%20is%20invalid")!
        #expect(AuthCallback(url: query) == .failure(code: nil, description: "Email link is invalid"))
    }

    @Test func tokenHashAndPKCE() {
        #expect(AuthCallback(url: URL(string: "bluebox://auth-callback?token_hash=pkce_abc&type=signup")!) == .tokenHash("pkce_abc", type: "signup"))
        #expect(AuthCallback(url: URL(string: "bluebox://auth-callback?token_hash=h")!) == .tokenHash("h", type: "email"))
        #expect(AuthCallback(url: URL(string: "bluebox://auth-callback?code=xyz")!) == .pkceCode("xyz"))
    }

    @Test func onlyOurURLs() {
        #expect(AuthCallback(url: URL(string: "bluebox://title/603")!) == nil)
        #expect(AuthCallback(url: URL(string: "https://auth-callback.example.com/#access_token=a&refresh_token=b")!) == nil)
        #expect(AuthCallback(url: URL(string: "BLUEBOX://auth-callback/#access_token=a&refresh_token=b")!) != nil)
        // Ours but empty: an explanation rather than silence.
        guard case .failure = AuthCallback(url: URL(string: "bluebox://auth-callback")!) else {
            Issue.record("empty callback not reported"); return
        }
    }
}

@Suite struct AuthLinkFlowTests {
    func auth(_ server: FakeSupabase, _ secrets: MemorySecretStore = MemorySecretStore()) -> SupabaseAuth {
        SupabaseAuth(config: FakeSupabase.config, http: server, secrets: secrets)
    }

    @Test func implicitLinkSignsIn() async throws {
        let server = FakeSupabase(), secrets = MemorySecretStore()
        let tokens = server.mintLinkTokens(email: "link@example.com")
        let a = auth(server, secrets)
        let url = URL(string: "bluebox://auth-callback#access_token=\(tokens.access)&refresh_token=\(tokens.refresh)&expires_in=3600&type=signup")!
        let session = try await a.completeSignIn(try #require(AuthCallback(url: url)))
        #expect(session.email == "link@example.com")
        #expect(session.userID == "user-link@example.com")
        #expect(await a.currentSession == session)
        #expect(try secrets.read(SecretAccount.supabaseSession) != nil)
        // The stored refresh token is usable.
        #expect(try await a.refresh().email == "link@example.com")
    }

    @Test func linkTokensFromAnotherProjectAreRejected() async throws {
        let server = FakeSupabase(), secrets = MemorySecretStore()
        let url = URL(string: "bluebox://auth-callback#access_token=forged&refresh_token=r")!
        await #expect(throws: SyncError.linkRejected) { try await auth(server, secrets).completeSignIn(AuthCallback(url: url)!) }
        #expect(try secrets.read(SecretAccount.supabaseSession) == nil)
    }

    @Test func tokenHashLinkVerifies() async throws {
        let server = FakeSupabase()
        let a = auth(server)
        let s = try await a.completeSignIn(.tokenHash("hash-abc", type: "magiclink"))
        #expect(s.email == "link@example.com")
        #expect(server.lastTokenHashType == "magiclink")
        await #expect(throws: SyncError.linkExpired) { try await a.completeSignIn(.tokenHash("used", type: "email")) }
    }

    @Test func expiredAndUnsupportedLinks() async {
        let server = FakeSupabase()
        let expired = AuthCallback(url: URL(string: "bluebox://auth-callback#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")!)!
        await #expect(throws: SyncError.linkExpired) { try await auth(server).completeSignIn(expired) }
        await #expect(throws: SyncError.linkFailed("Something else")) {
            try await auth(server).completeSignIn(.failure(code: "server_error", description: "Something else"))
        }
        await #expect(throws: SyncError.linkUnsupported) { try await auth(server).completeSignIn(.pkceCode("c")) }
        #expect(server.count("") == 0)  // none of these reach the server
    }

    @Test func aRetiredClientFinishingALinkDoesNotTouchTheKeychain() async throws {
        let server = FakeSupabase(), secrets = MemorySecretStore()
        let tokens = server.mintLinkTokens(email: "late@example.com")
        let old = auth(server, secrets)
        let notified = Notified()
        await old.observe { _ in notified.hit() }
        old.retire()
        _ = try await old.completeSignIn(.session(.init(accessToken: tokens.access, refreshToken: tokens.refresh)))
        #expect(try secrets.read(SecretAccount.supabaseSession) == nil)
        #expect(notified.count == 0)
    }

    @Test func offlineIsReportedAsOffline() async {
        let a = SupabaseAuth(config: FakeSupabase.config, http: StubHTTP { _ in throw URLError(.notConnectedToInternet) },
                             secrets: MemorySecretStore())
        await #expect(throws: SyncError.offline) { try await a.signIn(username: "brian", password: "whatever1") }
    }
}

extension AuthCallback.Tokens {
    init(accessToken: String, refreshToken: String) {
        self.init(accessToken: accessToken, refreshToken: refreshToken, expiresIn: nil, expiresAt: nil, type: nil)
    }
}
