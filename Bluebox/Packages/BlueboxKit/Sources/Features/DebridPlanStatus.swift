import Addons
import Domain
import Foundation
import MediaSources
import UserNotifications

// The debrid plan: how many days are left (Settings › Torrents & Debrid), and
// a local notification three days before it ends, so an expired plan doesn't
// first show up as a notice clip in place of a film.

extension AppModel {
    /// Reads the account's plan and moves the reminder to match. Called when
    /// the service or key changes, and when Settings opens.
    func refreshDebridAccount() async {
        guard let service = debridLibraryService else {
            if features.debridAccount != nil {
                features.debridAccount = nil
                await DebridPlanReminder.cancel()
            }
            return
        }
        let key = debridKey
        let account = try? await DebridAPIs.make(service, key: key, http: http).accountInfo()
        // The service or key may have changed while it answered.
        guard debridLibraryService == service, debridKey == key else { return }
        // A key that doesn't work (or no connection) shows no plan; a reminder already set stays.
        guard let account else { features.debridAccount = nil; return }
        guard account != features.debridAccount else { return }
        features.debridAccount = account
        await DebridPlanReminder.update(account: account, service: service.title,
                                        enabled: features.remindBeforeDebridPlanEnds)
    }

    /// Saves a debrid key once the service has said it knows it (its account
    /// answers). A key it refuses isn't saved; one that can't be checked
    /// right now (no connection) is saved, and the result says so.
    func checkAndSaveDebridKey(_ raw: String) async -> DebridKeyCheck {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let service = DebridService(addonSettings.debrid) else { return .unreachable("") }
        let check: DebridKeyCheck
        do {
            check = .accepted(try await DebridAPIs.make(service, key: key, http: http).accountInfo())
        } catch {
            check = DebridKeyCheck(error)
        }
        guard check != .rejected else { return check }
        setDebridKey(key)
        if case .accepted(let account) = check, account != features.debridAccount {
            features.debridAccount = account
            await DebridPlanReminder.update(account: account, service: service.title, enabled: features.remindBeforeDebridPlanEnds)
        }
        return check
    }

    /// Settings › Remind Before the Plan Ends. Turning it on asks for permission.
    public func setRemindBeforeDebridPlanEnds(_ on: Bool) {
        features.remindBeforeDebridPlanEnds = on
        Task {
            if on, DebridPlanReminder.canNotify { _ = await EpisodeNotifications.requestPermission() }
            guard let account = features.debridAccount, let service = debridLibraryService else { return }
            await DebridPlanReminder.update(account: account, service: service.title, enabled: on)
        }
    }

    /// "12 days left" and the like, for Settings; nil until the account has been read.
    public var debridPlanSummary: String? {
        features.debridAccount.map { DebridPlanReminder.summary($0) }
    }
}

enum DebridPlanReminder {
    static let id = "bluebox.debridPlan"
    static let leadDays = 3

    /// When to remind: `leadDays` before the plan ends, if that's still ahead.
    static func fireDate(for account: DebridAccount, now: Date = Date()) -> Date? {
        guard account.isPremium, let end = account.premiumUntil else { return nil }
        let date = end.addingTimeInterval(-Double(leadDays) * 86_400)
        return date > now ? date : nil
    }

    static func summary(_ account: DebridAccount, now: Date = Date()) -> String {
        guard account.isPremium else { return "No active plan" }
        guard let days = account.daysLeft(now: now) else { return "Active" }
        return switch days {
        case 0: "Ends today"
        case 1: "1 day left"
        default: "\(days) days left"
        }
    }

    /// Replaces any pending reminder with one for this plan. Asks nothing:
    /// without permission there's no reminder.
    static func update(account: DebridAccount, service: String, enabled: Bool, now: Date = Date()) async {
        guard canNotify else { return }
        await cancel()
        guard enabled, let date = fireDate(for: account, now: now), await EpisodeNotifications.isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(service) plan ends in \(leadDays) days"
        content.body = "Renew it to keep streaming. After it ends, debrid releases won't play."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSince(now), repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel() async {
        guard canNotify else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// The notification center needs an app bundle; `swift test` has none and would crash.
    static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }
}

/// What the service said about a debrid key as it was saved.
enum DebridKeyCheck: Equatable {
    /// Its account answered.
    case accepted(DebridAccount)
    /// The service doesn't know the key (401): it isn't saved.
    case rejected
    /// A known account that may not stream (403: expired, free, locked). Saved.
    case planEnded
    /// No answer (offline, the service down). Saved; Play will try it.
    case unreachable(String)

    init(_ error: Error) {
        switch error {
        case SourceError.unauthorized: self = .rejected
        case is DebridLinkError: self = .planEnded
        default: self = .unreachable((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The red line under the key field, for a key that wasn't saved.
    func fieldError(service: String, hint: String?) -> String? {
        guard self == .rejected else { return nil }
        return hint.map { "\(service) didn't accept this key. Copy it again from \($0)." } ?? "\(service) didn't accept this key."
    }
}

/// Whether Play will use the debrid service, or the one thing in the way:
/// the status row under the debrid key. Pure, so it's tested directly.
enum DebridReadiness {
    struct Status: Equatable {
        let ok: Bool
        let message: String
    }

    /// nil when no debrid service is chosen.
    static func status(settings: AddonSettings, debridKey: String, account: DebridAccount?) -> Status? {
        guard settings.debrid.requiresKey else { return nil }
        let service = settings.debrid.title
        guard !debridKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Status(ok: false, message: "Add your \(service) API key and Play can use it.")
        }
        guard settings.isEnabled else {
            return Status(ok: false, message: "Play won't use \(service) until Find Releases with Add-ons is on.")
        }
        let on = settings.addons.filter { $0.isEnabled && $0.catalogsOnly != true }
        guard !on.isEmpty else {
            return Status(ok: false, message: "Turn on an add-on (Torrentio, StremThru or Comet) so Play can find \(service) releases.")
        }
        if let account, !account.isPremium {
            return Status(ok: false, message: "\(service) says this account has no active plan, so its links won't play.")
        }
        let share = settings.shareKeyWithCommunityHosts
        var using: [String] = []
        var custom = false
        for addon in on {
            switch addon.kind {
            case .preset(.torrentio): using.append(addon.name)
            case .preset(.stremthru), .preset(.comet): if share { using.append(addon.name) }
            case .custom: custom = true
            }
        }
        guard !using.isEmpty else {
            if custom {
                return Status(ok: true, message: "Play is ready if your add-ons' own links carry your \(service) key.")
            }
            let comet = on.contains { $0.kind == .preset(.comet) }
            return Status(ok: false, message: comet
                ? "Comet only works with Share Key with Community Add-ons on, so it's skipped. Turn that on, or turn on Torrentio."
                : "StremThru only uses \(service) with Share Key with Community Add-ons on. Turn that on, or turn on Torrentio.")
        }
        return Status(ok: true, message: "Play is ready: \(using.joined(separator: ", ")) find\(using.count == 1 ? "s" : "") \(service) releases.")
    }
}

extension DebridService {
    /// The library API for the service chosen in Settings; nil for none.
    init?(_ provider: DebridProvider) {
        switch provider {
        case .realDebrid: self = .realDebrid
        case .premiumize: self = .premiumize
        case .torBox: self = .torBox
        case .allDebrid: self = .allDebrid
        case .debridLink: self = .debridLink
        case .none: return nil
        }
    }
}
