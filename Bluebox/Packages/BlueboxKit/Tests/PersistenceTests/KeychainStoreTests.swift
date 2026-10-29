import Foundation
import Security
@testable import Persistence
import Testing

/// Runs against the real keychain. `swift test` binaries have no keychain
/// entitlement, like Bluebox's Mac builds, so on the Mac this covers the
/// login-keychain fallback (errSecMissingEntitlement before the fix).
struct KeychainStoreTests {
    @Test func writesReadsAndDeletes() throws {
        let store = KeychainStore(service: "app.bluebox.tests.\(UUID().uuidString)")
        try store.write("first", for: "secret")
        #expect(try store.read("secret") == "first")
        try store.write("second", for: "secret")
        #expect(try store.read("secret") == "second")
        try store.write(nil, for: "secret")
        #expect(try store.read("secret") == nil)
    }

    @Test func cachedCopyReadsEverythingAndWritesThrough() async throws {
        let store = KeychainStore(service: "app.bluebox.tests.\(UUID().uuidString)")
        try store.write("token", for: "a")
        try store.write("key", for: "b")
        let cached = await store.cached()
        #expect(try cached.read("a") == "token")
        #expect(try cached.read("b") == "key")
        #expect(try cached.read("missing") == nil)

        try cached.write("new", for: "a")
        try cached.write(nil, for: "b")
        #expect(try cached.read("a") == "new")
        #expect(try cached.read("b") == nil)
        #expect(try store.read("a") == "new")  // written through to the Keychain
        #expect(try store.read("b") == nil)
        try store.write(nil, for: "a")
    }

    @Test func aFailedLaunchReadStaysFailedUntilWritten() throws {
        let cached = CachedSecretStore(backing: MemorySecretStore(), values: [:],
                                       failures: ["a": KeychainError(status: errSecAuthFailed)])
        #expect(throws: KeychainError.self) { try cached.read("a") }
        try cached.write("fixed", for: "a")
        #expect(try cached.read("a") == "fixed")
    }
}
