import Foundation
@testable import Persistence
import Testing

/// A Keychain that can't be read, like a locked or damaged login keychain.
private struct BrokenSecretStore: SecretStore {
    struct Failure: Error {}
    func read(_ account: String) throws -> String? { throw Failure() }
    func write(_ value: String?, for account: String) throws { throw Failure() }
}

struct ProfileLockStoreTests {
    /// A read error counts as locked: no PIN opens it, rather than every PIN.
    @Test func keychainErrorsCountAsLocked() {
        let locks = ProfileLockStore(secrets: BrokenSecretStore())
        #expect(locks.hasPIN("kids"))
        #expect(!locks.verify("0000", for: "kids"))
        #expect(!locks.verify("", for: "kids"))
    }

    @Test func noPINStillOpensAndAStoredOneChecks() throws {
        let secrets = MemorySecretStore()
        let locks = ProfileLockStore(secrets: secrets)
        #expect(!locks.hasPIN("sam"))
        #expect(locks.verify("1234", for: "sam"))
        try locks.setPIN("2468", for: "sam")
        #expect(locks.hasPIN("sam"))
        #expect(locks.verify("2468", for: "sam") && !locks.verify("1234", for: "sam"))
        // A stored value Bluebox didn't write doesn't open it either.
        try secrets.write("garbage", for: "profile.pin.sam")
        #expect(!locks.verify("2468", for: "sam"))
    }
}
