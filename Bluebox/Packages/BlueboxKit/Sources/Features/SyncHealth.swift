import DesignSystem
import Foundation

/// Whether account or Trakt sync has stopped, for the dot on the profile
/// button and the note at the top of its menu (GAPS X5, decision Q4 A).
/// Nothing interrupts: the menu says what's wrong, since when, and the one fix.
struct SyncIssue: Equatable, Identifiable {
    enum Service: Equatable { case account, trakt }
    enum Fix: Equatable {
        /// The session ended: sign in again (Settings › Account).
        case signIn
        /// Trakt was disconnected: connect it again (Settings › Account).
        case reconnectTrakt
        /// Probably passing (offline, server busy): try again now.
        case retry
    }

    let service: Service
    let title: String
    let message: String
    let fix: Fix
    var id: String { "\(service)" }

    var fixTitle: String {
        switch fix {
        case .signIn: "Sign In Again"
        case .reconnectTrakt: "Reconnect Trakt"
        case .retry: "Try Now"
        }
    }

    /// The issues to show, account first. Nothing while a sync is running or
    /// when a service isn't set up (a library only on this device is fine).
    /// - Parameters:
    ///   - account: account sync's status; `signedIn` is false once the session has expired.
    ///   - hadAccount: a server is set up, so a sign-out that wasn't on purpose is a problem.
    ///   - lastSynced: when the account last synced, for "since".
    static func current(account: AccountModel.Status, signedIn: Bool, hadAccount: Bool, lastSynced: Date?,
                        trakt: AccountModel.Status, traktConnected: Bool, traktConfigured: Bool,
                        offline: Bool = false, now: Date = .now) -> [SyncIssue] {
        var out: [SyncIssue] = []
        if hadAccount, case .failed(let reason) = account {
            let since = lastSynced.map { " since \(time($0, now: now))" } ?? ""
            if signedIn {
                out.append(SyncIssue(service: .account, title: "Not syncing\(since)",
                                     message: "\(reason) Progress and My List are saved here and upload when sync works again.",
                                     fix: .retry))
            } else {
                out.append(SyncIssue(service: .account, title: "Not syncing\(since)",
                                     message: "Your sign-in expired. Progress is saved here and uploads when you sign in.",
                                     fix: .signIn))
            }
        }
        if traktConfigured, case .failed(let reason) = trakt {
            out.append(SyncIssue(service: .trakt, title: traktConnected ? "Trakt isn't syncing" : "Trakt was disconnected",
                                 message: traktConnected ? reason : "Bluebox stopped sending what you watch to Trakt. Connect it again to catch up.",
                                 fix: traktConnected ? .retry : .reconnectTrakt))
        }
        // Offline, a failed sync is expected and Home already says so; only
        // what needs you (signing in again) is worth a dot.
        return offline ? out.filter { $0.fix != .retry } : out
    }

    /// "14:02" today, "yesterday", or a date.
    static func time(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

extension AppModel {
    /// Sync problems right now (see `SyncIssue.current`).
    var syncIssues: [SyncIssue] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-simulate-sync-failure") {
            return [SyncIssue(service: .account, title: "Not syncing since 14:02",
                              message: "Your sign-in expired. Progress is saved here and uploads when you sign in.", fix: .signIn)]
        }
        #endif
        return SyncIssue.current(account: account.status, signedIn: account.isSignedIn, hadAccount: account.isConfigured,
                                 lastSynced: account.lastSynced, trakt: trakt.status, traktConnected: trakt.isConnected,
                                 traktConfigured: trakt.isConfigured, offline: settings.isOffline)
    }

    /// Runs an issue's fix: a retry here, or Settings › Account for a sign-in.
    func fix(_ issue: SyncIssue, openSettings: (SettingsPage?) -> Void) {
        switch issue.fix {
        case .signIn, .reconnectTrakt:
            openSettings(.account)
        case .retry:
            Task {
                switch issue.service {
                case .account: await account.syncNow()
                case .trakt: await trakt.syncNow()
                }
            }
        }
    }
}
