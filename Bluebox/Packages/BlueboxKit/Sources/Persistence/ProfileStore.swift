import Domain
import Foundation

/// The profile list, kept in preferences with upload flags for sync.
public final class ProfileStore: @unchecked Sendable {
    struct Record: Codable { var profile: Profile; var needsSync: Bool }
    private let prefs: PreferencesStore
    private let lock = NSLock()
    static let key = "bluebox.profiles"

    public init(prefs: PreferencesStore) {
        self.prefs = prefs
        lock.withLock {
            var records = prefs.value([Record].self, for: Self.key) ?? []
            if !records.contains(where: { $0.profile.isDefault }) {
                records.insert(Record(profile: .makeDefault(), needsSync: false), at: 0)
                prefs.set(records, for: Self.key)
            }
        }
    }

    private var records: [Record] {
        get { prefs.value([Record].self, for: Self.key) ?? [] }
        set { prefs.set(newValue, for: Self.key) }
    }

    /// Profiles that aren't removed, default first, then by name.
    public func active() -> [Profile] {
        lock.withLock {
            records.map(\.profile).filter { !$0.isRemoved }
                .sorted { ($0.isDefault ? 0 : 1, $0.name.localizedLowercase) < ($1.isDefault ? 0 : 1, $1.name.localizedLowercase) }
        }
    }

    /// Every stored profile's ID, removed ones included.
    public func allIDs() -> [String] { lock.withLock { records.map(\.profile.id) } }

    public func profile(_ id: String) -> Profile? { lock.withLock { records.first { $0.profile.id == id }?.profile } }

    /// Adds or updates a profile from a local edit (flagged for upload).
    public func save(_ profile: Profile) {
        var p = profile
        p.updatedAt = Date().millisecondRounded
        lock.withLock {
            var r = records
            if let i = r.firstIndex(where: { $0.profile.id == p.id }) { r[i] = Record(profile: p, needsSync: true) }
            else { r.append(Record(profile: p, needsSync: true)) }
            records = r
        }
    }

    public func remove(_ id: String) {
        guard id != Profile.defaultID, var p = profile(id) else { return }
        p.isRemoved = true
        save(p)
    }

    // MARK: Sync

    public func pendingUploads() -> [Profile] { lock.withLock { records.filter(\.needsSync).map(\.profile) } }

    public func markSynced(ifUpdatedAt dates: [String: Date]) {
        lock.withLock {
            var r = records
            for i in r.indices where dates[r[i].profile.id] == r[i].profile.updatedAt { r[i].needsSync = false }
            records = r
        }
    }

    /// Back to the default profile alone, as on a new device, so the
    /// account's profiles come down and win (after choosing another
    /// account's library).
    public func resetToDefault() {
        lock.withLock { records = [Record(profile: .makeDefault(), needsSync: false)] }
    }

    public func markAllNeedingSync() {
        lock.withLock {
            var r = records
            for i in r.indices { r[i].needsSync = true }
            records = r
        }
    }

    /// Merges profiles from the cloud. Returns how many changed locally.
    @discardableResult
    public func applyRemote(_ incoming: [Profile]) -> Int {
        lock.withLock {
            var r = records
            var changed = 0
            for var p in incoming {
                p.updatedAt = p.updatedAt.millisecondRounded
                if let i = r.firstIndex(where: { $0.profile.id == p.id }) {
                    guard ProfileMerge.incomingWins(p, over: r[i].profile) else { continue }
                    // Maturity, Kids and Allow Unrated aren't synced: keep this device's.
                    p.maturity = r[i].profile.maturity
                    p.isKids = r[i].profile.isKids
                    p.allowsUnrated = r[i].profile.allowsUnrated
                    r[i] = Record(profile: p, needsSync: false)
                } else {
                    r.append(Record(profile: p, needsSync: false))
                }
                changed += 1
            }
            if changed > 0 { records = r }
            return changed
        }
    }
}
