import Foundation
import Security

/// Secret storage. Tokens and passwords never go to UserDefaults or files.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> String?
    func write(_ value: String?, for account: String) throws
}

public enum SecretAccount {
    public static let tmdb = "tmdb.credential"
    public static let debrid = "debrid.apiKey"
    public static let omdb = "omdb.apiKey"
    public static let openSubtitles = "opensubtitles.apiKey"
    public static let openSubtitlesSession = "opensubtitles.session"
    public static let subdl = "subdl.apiKey"
    public static func source(_ id: String) -> String { "source.\(id)" }
    /// An add-on added by link: the whole link, which holds its configuration
    /// (often a debrid key). Preferences keep only its origin.
    public static let addonLinkPrefix = "addon."
    public static func addonLink(_ addonID: String) -> String { addonLinkPrefix + addonID }
}

public struct KeychainError: Error, Equatable, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? { "Keychain error \(status)" }
}

public struct KeychainStore: SecretStore {
    let service: String
    public init(service: String = "app.bluebox") { self.service = service }

    /// The data-protection keychain needs a signed keychain-access-groups
    /// entitlement (a development team). Bluebox's Mac builds are signed
    /// without one, where it answers errSecMissingEntitlement (-34018); there
    /// the login keychain is used instead. iOS always has the former.
    private static var useDataProtection: Bool {
        #if os(macOS)
        return DataProtectionProbe.available
        #else
        return true
        #endif
    }

    private func base(_ account: String, dataProtection: Bool = KeychainStore.useDataProtection) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    public func read(_ account: String) throws -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String?, for account: String) throws {
        let q = base(account)
        guard let value else {
            let s = SecItemDelete(q as CFDictionary)
            guard s == errSecSuccess || s == errSecItemNotFound else { throw KeychainError(status: s) }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw KeychainError(status: s) }
        } else if update != errSecSuccess {
            throw KeychainError(status: update)
        }
    }
}

extension KeychainStore {
    /// Every account saved under this service. Attributes only, so macOS never
    /// asks for permission to list them.
    func accounts() -> [String] {
        var q = base("")
        q.removeValue(forKey: kSecAttrAccount as String)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Deletes every secret saved under this service (Erase All Data).
    public func deleteAll() {
        for account in accounts() { try? write(nil, for: account) }
    }

    /// The one item every secret lives in (a JSON object of account → value),
    /// so a Mac asks for Keychain access once, not once per secret.
    static let bundleAccount = "secrets.v1"

    /// Every secret, from the one bundled item, read off the main thread (a
    /// Mac's Keychain prompt can wait there). Secrets saved one per item by
    /// earlier versions are moved into it, then deleted.
    public func cachedBundle() async -> CachedSecretStore {
        let store = self
        return await Task.detached(priority: .userInitiated) {
            let bundle = BundledSecretStore(keychain: store)
            var values: [String: String] = [:]
            do {
                if let json = try store.read(Self.bundleAccount) {
                    values = (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
                }
            } catch let e as KeychainError {
                // Couldn't read it (access denied): don't overwrite it with less.
                bundle.blocked = e
                return CachedSecretStore(backing: bundle, values: [:], failures: [:], everything: e)
            } catch {}
            let legacy = store.accounts().filter { $0 != Self.bundleAccount }
            for account in legacy {
                if values[account] == nil, let value = try? store.read(account) { values[account] = value }
            }
            bundle.values = values
            if !legacy.isEmpty {
                do {
                    try bundle.save()
                    for account in legacy { try? store.write(nil, for: account) }
                } catch {}
            }
            return CachedSecretStore(backing: bundle, values: values, failures: [:])
        }.value
    }

    /// Reads every secret off the main thread. On a Mac the first read after a
    /// new build can wait on a "wants to use your confidential information"
    /// prompt; read on the main thread, that froze the app with no window.
    public func cached() async -> CachedSecretStore {
        let store = self
        return await Task.detached(priority: .userInitiated) {
            var values: [String: String] = [:]
            var failures: [String: KeychainError] = [:]
            for account in store.accounts() {
                do { values[account] = try store.read(account) } catch let e as KeychainError { failures[account] = e } catch {}
            }
            return CachedSecretStore(backing: store, values: values, failures: failures)
        }.value
    }
}

/// The Keychain's secrets read once at launch (`KeychainStore.cached()`), so
/// reads never touch the Keychain on the main thread. Writes go to the
/// Keychain as before and update the copy.
public final class CachedSecretStore: SecretStore, @unchecked Sendable {
    private let backing: any SecretStore
    private let lock = NSLock()
    private var values: [String: String]
    /// Accounts whose read failed at launch (access denied, say); reading them
    /// fails the same way until they're written again.
    private var failures: [String: KeychainError]
    /// The bundled item couldn't be read: every read fails like it.
    private let everything: KeychainError?

    init(backing: any SecretStore, values: [String: String], failures: [String: KeychainError], everything: KeychainError? = nil) {
        self.backing = backing; self.values = values; self.failures = failures; self.everything = everything
    }

    public func read(_ account: String) throws -> String? {
        try lock.withLock {
            if let everything { throw everything }
            if let failure = failures[account] { throw failure }
            return values[account]
        }
    }

    public func write(_ value: String?, for account: String) throws {
        try backing.write(value, for: account)
        lock.withLock {
            values[account] = value
            failures[account] = nil
        }
    }
}

/// Writes the whole set of secrets back to the one Keychain item.
final class BundledSecretStore: SecretStore, @unchecked Sendable {
    private let keychain: KeychainStore
    private let lock = NSLock()
    var values: [String: String] = [:]
    /// Set when the item couldn't be read: writing would lose what's in it.
    var blocked: KeychainError?

    init(keychain: KeychainStore) { self.keychain = keychain }

    func read(_ account: String) throws -> String? { lock.withLock { values[account] } }

    func write(_ value: String?, for account: String) throws {
        try lock.withLock {
            if let blocked { throw blocked }
            values[account] = value
            try saveLocked()
        }
    }

    func save() throws { try lock.withLock { try saveLocked() } }

    private func saveLocked() throws {
        let json = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        try keychain.write(values.isEmpty ? nil : json, for: KeychainStore.bundleAccount)
    }
}

#if os(macOS)
/// Asks once per launch whether this build may use the data-protection keychain.
private enum DataProtectionProbe {
    static let available: Bool = {
        // Reads can answer "not found" without the entitlement; only a write tells.
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "app.bluebox.probe",
                                kSecAttrAccount as String: "probe",
                                kSecUseDataProtectionKeychain as String: true]
        var add = q
        add[kSecValueData as String] = Data()
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { SecItemDelete(q as CFDictionary) }
        return status != errSecMissingEntitlement
    }()
}
#endif

/// In-memory secret store for tests, previews, and environments without a
/// keychain entitlement.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func read(_ account: String) throws -> String? { lock.withLock { values[account] } }
    public func write(_ value: String?, for account: String) throws { lock.withLock { values[account] = value } }
}
