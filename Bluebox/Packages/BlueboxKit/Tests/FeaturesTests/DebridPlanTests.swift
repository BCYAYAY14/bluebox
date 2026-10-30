import Addons
import Domain
@testable import Features
import Foundation
import MediaSources
import Persistence
import Playback
import Testing
import TestingSupport

/// The debrid plan in Settings, its reminder, and the alert a notice clip brings.
@MainActor
@Suite struct DebridPlanTests {
    func makeApp(_ http: FixtureHTTPClient, debrid: DebridProvider) throws -> AppModel {
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                           prefs: PreferencesStore(defaults: UserDefaults(suiteName: "debridplan.\(UUID().uuidString)")!), http: http)
        var settings = app.addonSettings
        settings.debrid = debrid
        app.setAddonSettings(settings)
        app.setDebridKey("FAKE-TEST-KEY")
        return app
    }

    @Test func settingsShowsTheDaysLeft() async throws {
        let http = FixtureHTTPClient()
        let end = Int(Date().addingTimeInterval(12.5 * 86_400).timeIntervalSince1970)
        http.on("v4/user", .init(body: Data(#"{"status":"success","data":{"user":{"username":"viewer","isPremium":true,"premiumUntil":\#(end)}}}"#.utf8)))
        let app = try makeApp(http, debrid: .allDebrid)
        #expect(app.debridLibraryName == "AllDebrid")
        await app.refreshDebridAccount()
        #expect(app.features.debridAccount?.name == "viewer")
        #expect(app.debridPlanSummary == "12 days left")

        // A key that stops working shows no plan rather than a stale one.
        http.on("v4/user", .init(status: 401))
        await app.refreshDebridAccount()
        #expect(app.debridPlanSummary == nil)
    }

    @Test func reminderComesThreeDaysBeforeTheEnd() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let end = now.addingTimeInterval(10 * 86_400)
        let plan = DebridAccount(name: "x", premiumUntil: end, isPremium: true)
        #expect(DebridPlanReminder.fireDate(for: plan, now: now) == end.addingTimeInterval(-3 * 86_400))
        // Already inside the last three days, no plan, or no end date: nothing to schedule.
        let soon = DebridAccount(name: "x", premiumUntil: now.addingTimeInterval(2 * 86_400), isPremium: true)
        #expect(DebridPlanReminder.fireDate(for: soon, now: now) == nil)
        #expect(DebridPlanReminder.fireDate(for: DebridAccount(name: "x", premiumUntil: end, isPremium: false), now: now) == nil)
        #expect(DebridPlanReminder.fireDate(for: DebridAccount(name: "x", premiumUntil: nil, isPremium: true), now: now) == nil)

        #expect(DebridPlanReminder.summary(plan, now: now) == "10 days left")
        #expect(DebridPlanReminder.summary(DebridAccount(name: "x", premiumUntil: now.addingTimeInterval(90_000), isPremium: true), now: now) == "1 day left")
        #expect(DebridPlanReminder.summary(DebridAccount(name: "x", premiumUntil: now.addingTimeInterval(3600), isPremium: true), now: now) == "Ends today")
        #expect(DebridPlanReminder.summary(DebridAccount(name: "x", premiumUntil: nil, isPremium: false), now: now) == "No active plan")
    }

    @Test func reminderSettingIsRemembered() throws {
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "debridplan.\(UUID().uuidString)")!)
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(), prefs: prefs, forceSample: true)
        #expect(app.features.remindBeforeDebridPlanEnds)
        app.setRemindBeforeDebridPlanEnds(false)
        let again = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(), prefs: prefs, forceSample: true)
        #expect(!again.features.remindBeforeDebridPlanEnds)
    }

    @Test func noticeClipAlertLeadsWithTheWayForward() throws {
        let app = try makeApp(FixtureHTTPClient(), debrid: .realDebrid)
        let item = NowPlayingItem(key: .movie(tmdbID: 45745), title: "Sintel")
        let expired = app.debridAlert(DebridLinkError(.planExpired, service: "Real-Debrid"), title: "Couldn't play “Sintel”", item: item)
        #expect(expired.title == "Debrid plan expired")
        #expect(expired.actions.map(\.title) == ["Open Real-Debrid", "Releases…"])
        #expect(expired.message.contains("Real-Debrid plan has expired"))

        // Another release may work: that comes first.
        let notReady = app.debridAlert(DebridLinkError(.notCachedYet, service: "Real-Debrid"), title: "Couldn't play “Sintel”", item: item)
        #expect(notReady.actions.map(\.title) == ["Releases…", "Open Real-Debrid"])
        let failed = app.debridAlert(DebridLinkError(.failed, service: "Real-Debrid"), title: "Couldn't play “Sintel”", item: nil)
        #expect(failed.title == "Couldn't play “Sintel”" && failed.actions.map(\.title) == ["Open Real-Debrid"])

        expired.actions[1].perform()
        #expect(app.releasePickerRequest?.item.key == item.key)
    }
}
