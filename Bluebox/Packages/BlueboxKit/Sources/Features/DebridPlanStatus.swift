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
