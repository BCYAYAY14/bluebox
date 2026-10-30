import Foundation
import Persistence

/// API keys, add-ons and settings that follow the account to every device
/// (Supabase `account_settings`, one row per key; newest change wins).
///
/// It watches local writes (`PreferencesStore.onSet`, `RecordingSecretStore`)
/// and stamps each synced key with the time it changed. `SyncEngine` pushes
/// stamped keys and hands back what other devices changed; applying those
/// writes the values here without stamping them again.
///
/// Values already on a device the first time it syncs are stamped with the
/// epoch, so an account's settings win over a fresh device's, and a device's
/// own keys reach an account that has none yet.
///
/// Keychain values (API keys, add-on links) sync only for an account that has
/// Sync API Keys on (`keysEnabled(for:)`, off by default and per account, so a
/// different account never receives them without its own yes). While it's off
/// their changes are still stamped, so turning it on uploads the newest.
public final class SettingsSync: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        var updatedAt: Date
        var needsSync: Bool
    }

    /// Preference keys that sync (everything else, like data usage or the last
    /// tab, stays on the device).
    let preferenceKeys: Set<String>
    /// Per-profile preference keys sync when they start with `bluebox.profile.`
    /// and end with one of these.
    let profileKeySuffixes: [String]
    /// Keychain accounts that sync, as `secret.<account>` rows.
    let secretAccounts: Set<String>
    /// Keychain account prefixes that sync too (add-on links, `addon.<id>`).
    let secretAccountPrefixes: [String]
    /// The accounts under those prefixes that exist now, for `adoptExisting`
    /// (the Keychain can't be listed).
    public var currentPrefixedSecretAccounts: (@Sendable () -> [String])?

    private let prefs: PreferencesStore
    private let secrets: any SecretStore
    private let lock = NSLock()
    private var entries: [String: Entry]
    private var suppressed = 0
    /// The account being synced (`SyncEngine` sets it each pass).
    private var user: String?
    private let now: @Sendable () -> Date

    /// A local change was recorded: sync soon.
    public var onLocalChange: (@Sendable () -> Void)?

    static let ledgerKey = "bluebox.settingsSync.ledger"
    static let secretPrefix = "secret."
    static let profilePrefix = "bluebox.profile."

    public init(prefs: PreferencesStore, secrets: any SecretStore, preferenceKeys: Set<String>,
                profileKeySuffixes: [String], secretAccounts: Set<String>, secretAccountPrefixes: [String] = [],
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.prefs = prefs; self.secrets = secrets; self.now = now
        self.preferenceKeys = preferenceKeys; self.profileKeySuffixes = profileKeySuffixes; self.secretAccounts = secretAccounts
        self.secretAccountPrefixes = secretAccountPrefixes
        entries = prefs.value([String: Entry].self, for: Self.ledgerKey) ?? [:]
    }

    // MARK: Sync API Keys

    static func keysEnabledKey(_ user: String) -> String { "bluebox.settingsSync.keys.\(user.lowercased())" }

    /// Whether this account has Sync API Keys on. Off until turned on for it.
    public func keysEnabled(for user: String) -> Bool {
        prefs.value(Bool.self, for: Self.keysEnabledKey(user)) ?? false
    }

    public func setKeysEnabled(_ on: Bool, for user: String) {
        prefs.set(on, for: Self.keysEnabledKey(user))
        if on { onLocalChange?() }
    }

    /// Called by `SyncEngine` at the start of each settings pass.
    func begin(user: String) { lock.withLock { self.user = user } }

    private var keysEnabledNow: Bool {
        guard let user = lock.withLock({ user }) else { return false }
        return keysEnabled(for: user)
    }

    /// Forgets when each Keychain value was stamped, after they were removed
    /// from the server, so turning Sync API Keys on later uploads them again.
    func forgetSecretStamps() {
        lock.withLock {
            entries = entries.filter { !$0.key.hasPrefix(Self.secretPrefix) }
            saveLocked()
        }
    }

    // MARK: Which keys

    func syncsPreference(_ key: String) -> Bool {
        if preferenceKeys.contains(key) { return true }
        guard key.hasPrefix(Self.profilePrefix) else { return false }
        return profileKeySuffixes.contains { key.hasSuffix($0) }
    }

    func syncsSecret(_ account: String) -> Bool {
        secretAccounts.contains(account) || secretAccountPrefixes.contains { account.hasPrefix($0) && account.count > $0.count }
    }

    /// The row key for a Keychain account, or nil if it doesn't sync.
    func remoteKey(secret account: String) -> String? {
        syncsSecret(account) ? Self.secretPrefix + account : nil
    }

    private func isSynced(_ remoteKey: String) -> Bool {
        if remoteKey.hasPrefix(Self.secretPrefix) {
            return keysEnabledNow && syncsSecret(String(remoteKey.dropFirst(Self.secretPrefix.count)))
        }
        return syncsPreference(remoteKey)
    }

    // MARK: Local changes

    /// A preference was written on this device.
    public func preferenceChanged(_ key: String) {
        guard syncsPreference(key) else { return }
        record(key)
    }

    /// A Keychain account was written on this device.
    public func secretChanged(_ account: String) {
        guard let key = remoteKey(secret: account) else { return }
        record(key)
    }

    private func record(_ key: String) {
        let recorded = lock.withLock { () -> Bool in
            guard suppressed == 0 else { return false }
            entries[key] = Entry(updatedAt: now(), needsSync: true)
            saveLocked()
            return true
        }
        if recorded { onLocalChange?() }
    }

    /// Runs `body` without recording its writes: applying what another device
    /// changed, and the settings reload that follows.
    public func withoutRecording<T>(_ body: () throws -> T) rethrows -> T {
        lock.withLock { suppressed += 1 }
        defer { lock.withLock { suppressed -= 1 } }
        return try body()
    }

    // MARK: Values

    func localValue(_ key: String) -> String? {
        if key.hasPrefix(Self.secretPrefix) {
            let account = String(key.dropFirst(Self.secretPrefix.count))
            return (try? secrets.read(account)).flatMap { $0 }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return prefs.rawData(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func writeLocal(_ key: String, _ value: String?) {
        if key.hasPrefix(Self.secretPrefix) {
            try? secrets.write(value, for: String(key.dropFirst(Self.secretPrefix.count)))
        } else {
            prefs.setRawData(value.map { Data($0.utf8) }, for: key)
        }
    }

    // MARK: Sync

    /// Stamps values that were on this device before it synced settings (epoch, so the account's win).
    func adoptExisting() {
        var keys = Set(preferenceKeys).union(prefs.keys(withPrefix: Self.profilePrefix).filter(syncsPreference))
        if keysEnabledNow {
            let accounts = secretAccounts.union((currentPrefixedSecretAccounts?() ?? []).filter(syncsSecret))
            keys.formUnion(accounts.map { Self.secretPrefix + $0 })
        }
        lock.withLock {
            var changed = false
            for key in keys where entries[key] == nil {
                guard localValue(key) != nil else { continue }
                entries[key] = Entry(updatedAt: Date(timeIntervalSince1970: 0), needsSync: true)
                changed = true
            }
            if changed { saveLocked() }
        }
    }

    /// Keys waiting to upload, with their current values (nil: removed).
    /// Keychain values only while this account has Sync API Keys on.
    func pending() -> [SettingRow] {
        let keys = keysEnabledNow
        let waiting = lock.withLock { entries.filter { $0.value.needsSync && (keys || !$0.key.hasPrefix(Self.secretPrefix)) } }
        return waiting.map { key, entry in
            let value = localValue(key)
            return SettingRow(key: key, value: value, is_removed: value == nil, updated_at: SyncTimestamp(entry.updatedAt).iso)
        }.sorted { $0.key < $1.key }
    }

    /// Clears the upload flag for keys that didn't change while they were uploading.
    func markSynced(_ rows: [SettingRow]) {
        lock.withLock {
            for row in rows {
                guard let ts = SyncTimestamp(iso: row.updated_at), var e = entries[row.key],
                      SyncTimestamp(e.updatedAt) == ts else { continue }
                e.needsSync = false
                entries[row.key] = e
            }
            saveLocked()
        }
    }

    /// Applies rows from the server. The server's row wins when it's newer, or
    /// on a tie (the server has already picked one). Returns the keys whose
    /// local value changed.
    @discardableResult
    func applyRemote(_ rows: [SettingRow]) -> [String] {
        var changed: [String] = []
        withoutRecording {
            for row in rows where isSynced(row.key) {
                guard let ts = SyncTimestamp(iso: row.updated_at) else { continue }
                let remoteDate = ts.date
                let local = lock.withLock { entries[row.key] }
                let value = row.is_removed ? nil : row.value
                if let local {
                    let localTS = SyncTimestamp(local.updatedAt)
                    if localTS > ts { continue }
                    if localTS == ts, localValue(row.key) == value {
                        lock.withLock { entries[row.key]?.needsSync = false }
                        continue
                    }
                }
                if localValue(row.key) != value {
                    writeLocal(row.key, value)
                    changed.append(row.key)
                }
                lock.withLock { entries[row.key] = Entry(updatedAt: remoteDate, needsSync: false) }
            }
            lock.withLock { saveLocked() }
        }
        return changed
    }

    private func saveLocked() { prefs.setRawData(try? JSONEncoder().encode(entries), for: Self.ledgerKey) }
}

/// One `account_settings` row.
struct SettingRow: Codable, PulledRow, Equatable {
    static let columns = "key,value,is_removed,updated_at,server_updated_at"
    var key: String
    var value: String?
    var is_removed: Bool
    var updated_at: String
    var server_updated_at: String?

    var mediaKey: String { key }
    var serverUpdatedAt: String { server_updated_at ?? "" }
}

/// A Keychain wrapper that tells `SettingsSync` about every write.
public struct RecordingSecretStore: SecretStore {
    let base: any SecretStore
    let sync: SettingsSync

    public init(_ base: any SecretStore, sync: SettingsSync) { self.base = base; self.sync = sync }

    public func read(_ account: String) throws -> String? { try base.read(account) }

    public func write(_ value: String?, for account: String) throws {
        let before = try? base.read(account)
        try base.write(value, for: account)
        if before.flatMap({ $0 }) != value { sync.secretChanged(account) }
    }
}
