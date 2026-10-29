import Addons
import Domain
@testable import Features
import Foundation
import Persistence
import SkipSegments
import Testing

private func freshPrefs() -> PreferencesStore {
    PreferencesStore(defaults: UserDefaults(suiteName: "privacy.\(UUID().uuidString)")!)
}

// MARK: - Feature switches

@MainActor @Suite struct FeatureSwitchesTests {
    @Test func defaults() {
        let s = FeatureSwitches(prefs: freshPrefs())
        #expect(s.statistics)
        #expect(!s.releaseAlerts)
        #expect(!s.spoilerGuard)
        #expect(s.tasteRows)
        #expect(s.liveActivity)
        #expect(!s.allowRemoteControl)
        #expect(s.useAsRemote)
    }

    @Test func everySwitchSurvivesARelaunch() {
        let prefs = freshPrefs()
        let s = FeatureSwitches(prefs: prefs)
        s.statistics = false; s.releaseAlerts = true; s.spoilerGuard = true; s.tasteRows = false
        s.liveActivity = false
        s.allowRemoteControl = true; s.useAsRemote = false
        let again = FeatureSwitches(prefs: prefs)
        #expect(!again.statistics && again.releaseAlerts && again.spoilerGuard && !again.tasteRows)
        #expect(!again.liveActivity)
        #expect(again.allowRemoteControl && !again.useAsRemote)
    }

    @Test func profileSwitchesFollowTheProfile() {
        let prefs = freshPrefs()
        let s = FeatureSwitches(prefs: prefs)
        s.spoilerGuard = true
        s.releaseAlerts = true
        s.loadProfile("sam")
        #expect(!s.spoilerGuard)  // Sam's own, still the default
        #expect(s.releaseAlerts)  // the account's, shared
        s.tasteRows = false
        s.loadProfile(Profile.defaultID)
        #expect(s.spoilerGuard && s.tasteRows)
        #expect(FeatureSwitches(prefs: prefs, profileID: "sam").tasteRows == false)
    }

    @Test func loadingAProfileDoesntWriteDefaults() {
        let prefs = freshPrefs()
        let s = FeatureSwitches(prefs: prefs)
        s.spoilerGuard = true
        s.loadProfile("sam")
        // Sam's key stays unset, so another device's choice for Sam isn't overwritten by settings sync.
        #expect(prefs.rawData(for: FeatureSwitches.Key.profile("sam", FeatureSwitches.Key.spoilerGuard)) == nil)
    }

    @Test func reloadPicksUpAnotherDevicesChange() {
        let prefs = freshPrefs()
        let s = FeatureSwitches(prefs: prefs)
        prefs.set(true, for: FeatureSwitches.Key.releaseAlerts)
        prefs.set(true, for: FeatureSwitches.Key.profile(Profile.defaultID, FeatureSwitches.Key.spoilerGuard))
        s.reloadFromPreferences()
        #expect(s.releaseAlerts && s.spoilerGuard)
    }

    @Test func accountAndProfileSwitchesSyncButDeviceOnesDont() {
        let keys = AppModel.syncedPreferenceKeys
        #expect(keys.contains(FeatureSwitches.Key.releaseAlerts))
        #expect(!keys.contains(FeatureSwitches.Key.allowRemoteControl))
        #expect(!keys.contains(FeatureSwitches.Key.useAsRemote))
        #expect(!keys.contains(FeatureSwitches.Key.liveActivity))
        for suffix in [".statistics", ".spoilerGuard", ".tasteRows", ".showSkipRules"] {
            #expect(AppModel.syncedProfileKeySuffixes.contains(suffix))
        }
    }

    @Test func resetPutsEverythingBack() {
        let s = FeatureSwitches(prefs: freshPrefs())
        s.allowRemoteControl = true; s.statistics = false; s.releaseAlerts = true
        s.resetToDefaults()
        #expect(!s.allowRemoteControl && s.statistics && !s.releaseAlerts)
    }
}

// MARK: - Release alerts

@Suite struct ReleaseAlertRulesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func film(_ id: Int, released daysAgo: Double? = 30) -> Title {
        Title(key: .movie(tmdbID: id), kind: .movie, name: "Film \(id)",
              releaseDate: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
    }

    @Test func runsAtMostEveryTwelveHours() {
        var state = ReleaseAlertState()
        #expect(ReleaseAlertRules.isDue(state, now: now))
        state.lastRun = now.addingTimeInterval(-11 * 3600)
        #expect(!ReleaseAlertRules.isDue(state, now: now))
        state.lastRun = now.addingTimeInterval(-12 * 3600)
        #expect(ReleaseAlertRules.isDue(state, now: now))
        state.lastRun = now.addingTimeInterval(3600)  // clock set back
        #expect(ReleaseAlertRules.isDue(state, now: now))
    }

    @Test func looksAtAFewFilmsLongestUncheckedFirst() {
        var state = ReleaseAlertState()
        let list = (1...10).map { film($0) }
        for t in list.prefix(4) {
            state.titles[t.key.rawValue] = .init(availability: .unavailable, checkedAt: now.addingTimeInterval(-Double(t.key.tmdbID!) * 3600))
        }
        let picked = ReleaseAlertRules.candidates(watchlist: list, state: state, hasDebrid: false, now: now)
        #expect(picked.count == ReleaseAlertRules.perRun)
        // Never checked (5…10) come first, then the oldest check (4, then 3).
        #expect(picked.prefix(6).allSatisfy { $0.key.tmdbID! >= 5 })
        let more = ReleaseAlertRules.candidates(watchlist: list, state: state, hasDebrid: false, now: now, limit: 8)
        #expect(more.suffix(2).map { $0.key.tmdbID! } == [4, 3])
    }

    @Test func skipsShowsFarOffFilmsAndOnesAlreadyAvailable() {
        var state = ReleaseAlertState()
        let streaming = film(1), cached = film(2), future = film(3, released: -60), soon = film(4, released: -7)
        let show = Title(key: .series(tmdbID: 5), kind: .series, name: "Show")
        state.titles[streaming.key.rawValue] = .init(availability: .streams, checkedAt: now)
        state.titles[cached.key.rawValue] = .init(availability: .cached, checkedAt: now)
        let list = [streaming, cached, future, soon, show]
        let noDebrid = ReleaseAlertRules.candidates(watchlist: list, state: state, hasDebrid: false, now: now)
        #expect(noDebrid.map(\.key) == [soon.key])
        // With a debrid service, a streaming film is still waiting for a cached release.
        let debrid = ReleaseAlertRules.candidates(watchlist: list, state: state, hasDebrid: true, now: now)
        #expect(Set(debrid.map(\.key)) == [soon.key, streaming.key])
    }

    @Test func onlyAnImprovementIsNews() {
        #expect(ReleaseAlertRules.alert(previous: nil, now: .streams) == nil)  // first look: the baseline
        #expect(ReleaseAlertRules.alert(previous: nil, now: .cached) == nil)
        #expect(ReleaseAlertRules.alert(previous: .unavailable, now: .streams) == .available)
        #expect(ReleaseAlertRules.alert(previous: .unavailable, now: .cached) == .cached)
        #expect(ReleaseAlertRules.alert(previous: .streams, now: .cached) == .cached)
        #expect(ReleaseAlertRules.alert(previous: .streams, now: .unavailable) == nil)
        #expect(ReleaseAlertRules.alert(previous: .unavailable, now: .unavailable) == nil)
    }

    @Test func availabilityFromReleases() {
        func release(_ id: String, url: URL?, cache: CacheState) -> AddonRelease {
            var r = AddonRelease(id: id, title: id, name: id, infoHash: url == nil ? String(repeating: "a", count: 40) : nil,
                                 fileIndex: nil, trackers: [], seeders: 3, sizeText: nil, resolution: "1080p",
                                 container: "mkv", url: url, filename: nil)
            r.cache = cache
            return r
        }
        #expect(ReleaseAlertRules.availability([]) == .unavailable)
        #expect(ReleaseAlertRules.availability([release("t", url: nil, cache: .unknown)]) == .streams)
        #expect(ReleaseAlertRules.availability([release("d", url: URL(string: "https://x.test/a.mkv"), cache: .uncached)]) == .streams)
        #expect(ReleaseAlertRules.availability([release("c", url: URL(string: "https://x.test/b.mkv"), cache: .cached)]) == .cached)
    }

    @Test func prunesFilmsLeftMyList() {
        var state = ReleaseAlertState()
        state.titles = ["tmdb:movie:1": .init(availability: .unavailable, checkedAt: now), "tmdb:movie:2": .init(availability: .unavailable, checkedAt: now)]
        #expect(ReleaseAlertRules.pruned(state, keeping: ["tmdb:movie:2"]).titles.keys.sorted() == ["tmdb:movie:2"])
    }

    @MainActor @Test func offMeansNoRequests() async {
        let app = AppModel.demo()
        #expect(!app.featureSwitches.releaseAlerts)
        #expect(await app.checkReleaseAlerts(force: true) == 0)
        #expect(app.insights.releaseState.lastRun == nil)
    }
}

// MARK: - Skipping for a whole show

@MainActor @Suite struct ShowSkipSettingsTests {
    let episode = MediaKey.episode(seriesID: 1396, season: 2, episode: 3)
    let sameShow = MediaKey.episode(seriesID: 1396, season: 4, episode: 1)

    @Test func alwaysSkipIsPerShowPerProfileAndPersists() {
        let prefs = freshPrefs()
        let settings = AppSettings(prefs: prefs)
        settings.setAlwaysSkip(true, .intro, for: episode)
        #expect(settings.skipModes(for: sameShow).intro == .automatic)
        #expect(settings.skipModes(for: sameShow).recap == .button)
        #expect(AppSettings(prefs: prefs).alwaysSkips(.intro, for: sameShow))
        settings.loadProfile("sam")
        #expect(!settings.alwaysSkips(.intro, for: episode))
        settings.loadProfile(Profile.defaultID)
        #expect(settings.alwaysSkips(.intro, for: episode))
    }

    @Test func alwaysSkipTurnsSkippingBackOnForTheShow() {
        let settings = AppSettings(prefs: freshPrefs())
        settings.setSkipsAllowed(false, for: episode)
        settings.setAlwaysSkip(true, .credits, for: episode)
        #expect(settings.skipsAllowed(for: sameShow))
    }

    @Test func recapModeStartsAsTheIntroMode() {
        let prefs = freshPrefs()
        prefs.set(SkipSegmentPlanner.Mode.automatic, for: PlayerFeatureKey.skipIntro)
        #expect(AppSettings(prefs: prefs).skipRecapMode == .automatic)
    }

    @Test func pillOffersAlwaysOnceThenSkipsWithoutAsking() {
        let settings = AppSettings(prefs: freshPrefs())
        let c = SkipController()
        c.setResultForTesting(SkipSegmentResolver.Result(segments: [SkipSegment(kind: .intro, start: 60, end: 120, source: .chapters)],
                                                         sources: [.chapters]))
        func step(_ t: TimeInterval) -> SkipController.Action? {
            c.update(position: t, duration: 1400, modes: settings.skipModes(for: episode), hasNext: true, autoplayNext: true,
                     enabled: true, isScrubbing: false, offerAlways: { part in
                         guard settings.offersAlwaysSkip(part, for: episode) else { return false }
                         settings.markAlwaysSkipOffered(part, for: episode)
                         return true
                     })
        }
        #expect(step(61) == nil)
        #expect(c.alwaysPart == .intro)
        settings.setAlwaysSkip(true, .intro, for: episode)
        #expect(c.accept() == .seek(120))
        // Next episode: the show's rule skips it without a button.
        c.reset()
        c.setResultForTesting(SkipSegmentResolver.Result(segments: [SkipSegment(kind: .intro, start: 60, end: 120, source: .chapters)],
                                                         sources: [.chapters]))
        #expect(step(61) == .seek(120))
        #expect(c.alwaysPart == nil)
    }

    @Test func alwaysIsntOfferedForCreditsWithAutoplayOff() {
        let c = SkipController()
        c.setResultForTesting(SkipSegmentResolver.Result(segments: [SkipSegment(kind: .credits, start: 1300, end: nil, source: .chapters)],
                                                         sources: [.chapters]))
        _ = c.update(position: 1305, duration: 1400, modes: .init(intro: .button, recap: .button, credits: .automatic),
                     hasNext: true, autoplayNext: false, enabled: true, isScrubbing: false, offerAlways: { _ in true })
        #expect(c.offer == .nextEpisode)
        #expect(c.countdown == nil)  // Autoplay off: no automatic move on
        #expect(c.alwaysPart == nil)
    }
}

// MARK: - Taste rows

@Suite struct TasteRowsSwitchTests {
    @Test func offMeansNoPersonalRowsAndADifferentFingerprint() {
        let now = Date()
        let records = (1...4).map {
            WatchProgress(key: .movie(tmdbID: $0), position: 5400, duration: 5400, isCompleted: true, updatedAt: now)
        }
        let on = HomeHistory(records: records, ratings: [:])
        let off = HomeHistory(records: records, ratings: [:], tasteRows: false)
        #expect(on.allowsPersonalRows)
        #expect(!off.allowsPersonalRows)
        #expect(on.fingerprint(.all) != off.fingerprint(.all))
        // Discovery rows still leave out what you've watched.
        #expect(off.discoveryExcluded == on.discoveryExcluded)
    }
}
