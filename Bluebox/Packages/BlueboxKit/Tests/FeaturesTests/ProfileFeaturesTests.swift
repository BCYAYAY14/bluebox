import Domain
@testable import Features
import Foundation
import Metadata
import Persistence
import Subtitles
import Testing

private func prefs() -> PreferencesStore {
    PreferencesStore(defaults: UserDefaults(suiteName: "profiles.\(UUID().uuidString)")!)
}

// MARK: - Per-profile settings and their migration

@MainActor
@Suite struct ProfileSettingsMigrationTests {
    /// Values from before per-profile settings reach every existing profile, once.
    @Test func sharedValuesAreCopiedIntoEveryProfile() throws {
        let p = prefs()
        let store = ProfileStore(prefs: p)
        store.save(Profile(id: "sam", name: "Sam", updatedAt: .now))
        var style = SubtitleStyle()
        style.preferredLanguage = "es"
        style.relativeSize = 0.06
        p.set("ja", for: PreferenceKey.preferredAudioLanguage)
        p.set(false, for: PreferenceKey.autoplayNextEpisode)
        p.set(style, for: PreferenceKey.subtitleStyle)

        let settings = AppSettings(prefs: p)
        #expect(settings.preferredAudioLanguage == "ja")
        #expect(settings.autoplayNextEpisode == false)
        for id in [Profile.defaultID, "sam"] {
            #expect(p.value(String.self, for: ProfileSettingKey.audioLanguage(id)) == "ja")
            #expect(p.value(Bool.self, for: ProfileSettingKey.autoplayNextEpisode(id)) == false)
            #expect(p.value(SubtitleStyle.self, for: ProfileSettingKey.subtitleStyle(id)) == style)
        }
        #expect(p.value(Bool.self, for: ProfileSettingKey.migrated) == true)

        // A second launch doesn't copy again over what a profile changed since.
        p.set("fr", for: ProfileSettingKey.audioLanguage("sam"))
        _ = AppSettings(prefs: p)
        #expect(p.value(String.self, for: ProfileSettingKey.audioLanguage("sam")) == "fr")
    }

    @Test func eachProfileKeepsItsOwnSettings() async throws {
        let p = prefs()
        p.set("de", for: PreferenceKey.preferredAudioLanguage)
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(), prefs: p, forceSample: true)
        #expect(app.settings.preferredAudioLanguage == "de")  // migrated into the default profile

        let sam = app.addProfile(name: "Sam", symbol: "star.fill", color: 2)
        await app.switchProfile(to: sam.id)
        // Added after the migration: the defaults.
        #expect(app.settings.preferredAudioLanguage == nil)
        #expect(app.settings.autoplayNextEpisode)
        app.settings.preferredAudioLanguage = "ko"
        app.settings.autoplayNextEpisode = false
        app.subtitleStyle.preferredLanguage = "en"

        await app.switchProfile(to: Profile.defaultID)
        #expect(app.settings.preferredAudioLanguage == "de")
        #expect(app.settings.autoplayNextEpisode)
        #expect(app.subtitleStyle.preferredLanguage == nil)

        await app.switchProfile(to: sam.id)
        #expect(app.settings.preferredAudioLanguage == "ko")
        #expect(app.settings.autoplayNextEpisode == false)
        #expect(app.subtitleStyle.preferredLanguage == "en")
        // Shared settings stay shared.
        app.settings.skipBackSeconds = 30
        await app.switchProfile(to: Profile.defaultID)
        #expect(app.settings.skipBackSeconds == 30)
    }

    /// The editor writes another profile's settings without switching to it.
    @Test func editsAnotherProfilesSettings() throws {
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(), prefs: prefs(), forceSample: true)
        let mia = app.addProfile(name: "Mia", symbol: "heart.fill", color: 13)
        var v = app.profileSettings(mia.id)
        v.audioLanguage = "it"
        app.setProfileSettings(v, for: mia.id)
        #expect(app.profileSettings(mia.id).audioLanguage == "it")
        #expect(app.settings.preferredAudioLanguage == nil)
        #expect(app.profileSettingsSummary(mia.id) == "\(SettingsLanguages.name("it")), autoplay on")
    }
}

// MARK: - PIN

@MainActor
@Suite struct ProfileLockTests {
    @Test func storesOnlyASaltedHashInTheSecretStore() throws {
        let secrets = MemorySecretStore()
        let locks = ProfileLockStore(secrets: secrets)
        #expect(!locks.hasPIN("sam"))
        #expect(locks.verify("0000", for: "sam"))  // no PIN: anything opens it
        #expect(throws: ProfileLockError.invalidPIN) { try locks.setPIN("12a4", for: "sam") }
        #expect(throws: ProfileLockError.invalidPIN) { try locks.setPIN("12345", for: "sam") }

        try locks.setPIN("4821", for: "sam")
        #expect(locks.hasPIN("sam"))
        let stored = try #require(try secrets.read("profile.pin.sam"))
        #expect(!stored.contains("4821"))
        #expect(stored.hasPrefix("v1:"))
        #expect(locks.verify("4821", for: "sam"))
        #expect(!locks.verify("4812", for: "sam"))
        #expect(!locks.verify("", for: "sam"))

        // Same PIN, new salt: a different stored value.
        try locks.setPIN("4821", for: "sam")
        #expect(try secrets.read("profile.pin.sam") != stored)
        #expect(locks.verify("4821", for: "sam"))

        try locks.setPIN(nil, for: "sam")
        #expect(!locks.hasPIN("sam"))
    }

    @Test func appModelTracksLocksAndNeverWritesThePINToPreferences() async throws {
        let suite = "profiles.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let secrets = MemorySecretStore()
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: secrets,
                           prefs: PreferencesStore(defaults: defaults), forceSample: true)
        let sam = app.addProfile(name: "Sam", symbol: "star.fill", color: 2)
        try app.setPIN("1357", for: sam.id)
        #expect(app.isLocked(sam.id))
        #expect(app.verifyPIN("1357", for: sam.id))
        #expect(!app.verifyPIN("7531", for: sam.id))
        let plist = defaults.persistentDomain(forName: suite) ?? [:]
        let everything = plist.values.compactMap { ($0 as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ($0 as? String) }
        // No preference is about a PIN, and none holds it as a value (digits alone can
        // turn up inside timestamps and IDs, so look for it quoted or whole).
        #expect(!plist.keys.contains { $0.lowercased().contains("pin") })
        #expect(!everything.contains { $0 == "1357" || $0.contains("\"1357\"") })

        // A new launch reads the lock back from the Keychain.
        let again = AppModel(store: try LibraryStore.make(inMemory: true), secrets: secrets,
                             prefs: PreferencesStore(defaults: defaults), forceSample: true)
        #expect(again.isLocked(sam.id))

        await app.deleteProfile(sam.id)
        #expect(!app.isLocked(sam.id))
        #expect(try secrets.read("profile.pin.\(sam.id)") == nil)
    }
}

// MARK: - Maturity

@Suite struct MaturityTests {
    @Test func certificationsMapToAges() {
        let ages: [String: Int?] = [
            "G": 0, "PG": 7, "PG-13": 13, "R": 17, "NC-17": 18, "TV-Y": 0, "TV-Y7": 7, "TV-PG": 7, "TV-14": 14,
            "TV-MA": 17, "U": 0, "12A": 12, "15": 15, "18": 18, "FSK 16": 16, "MA15+": 15, " tv-14 ": 14,
            "NR": nil, "": nil, "Unrated": nil,
        ]
        for (cert, age) in ages { #expect(MaturityRating.minimumAge(forCertification: cert) == age, "\(cert)") }
    }

    @Test func filterUsesKnownCertificationsAndKidsGenres() {
        let crime = Title(key: .movie(tmdbID: 1), kind: .movie, name: "Crime", genreIDs: [80])
        let cartoon = Title(key: .movie(tmdbID: 2), kind: .movie, name: "Cartoon", genreIDs: [16, 10751])
        let teen = ContentFilter(maximum: .age13)
        #expect(teen.allows(crime, certification: "PG-13"))
        #expect(!teen.allows(crime, certification: "R"))
        #expect(!teen.allows(crime, certification: "TV-14"))
        #expect(teen.allows(crime, certification: nil))  // unrated: shown, outside Kids
        let kids = ContentFilter(maximum: .age7, familyOnlyWhenUnrated: true)
        #expect(!kids.allows(crime, certification: nil))
        #expect(kids.allows(cartoon, certification: nil))
        #expect(kids.allows(cartoon, certification: "G"))
        #expect(!kids.allows(cartoon, certification: "PG-13"))
        #expect(kids.allows(certification: "TV-Y7") && !kids.allows(certification: "TV-14"))
    }

    @Test func kidsProfilesAreCappedAndOldProfilesDecode() throws {
        var p = Profile(id: "k", name: "Kids", updatedAt: .now, maturity: .age16, isKids: true)
        #expect(p.effectiveMaturity == .age7)
        #expect(p.contentFilter == ContentFilter(maximum: .age7, familyOnlyWhenUnrated: true, blocksUnrated: true))
        p.isKids = false
        #expect(p.contentFilter == ContentFilter(maximum: .age16))
        p.maturity = .all
        #expect(p.contentFilter == nil)
        // Stored before maturity existed.
        let old = #"{"id":"a","name":"Al","symbol":"star.fill","color":3,"isRemoved":false,"updatedAt":0}"#
        let decoded = try JSONDecoder().decode(Profile.self, from: Data(old.utf8))
        #expect(decoded.maturity == .all && !decoded.isKids && decoded.color == 3)
    }

    /// Maturity and Kids aren't synced: a newer profile from the cloud keeps this device's.
    @Test func remoteChangesKeepTheLocalLimit() {
        let store = ProfileStore(prefs: prefs())
        store.save(Profile(id: "k", name: "Kids", updatedAt: .now, maturity: .age7, isKids: true))
        store.applyRemote([Profile(id: "k", name: "Little Ones", updatedAt: .now.addingTimeInterval(60))])
        let p = store.profile("k")
        #expect(p?.name == "Little Ones")
        #expect(p?.maturity == .age7 && p?.isKids == true)
    }

    @Test func catalogueListsAreFilteredForTheProfile() async throws {
        let ok = Title(key: .movie(tmdbID: 1), kind: .movie, name: "Fine", genreIDs: [16])
        let adult = Title(key: .movie(tmdbID: 2), kind: .movie, name: "Grim", genreIDs: [80])
        let unknown = Title(key: .movie(tmdbID: 3), kind: .movie, name: "Unknown", genreIDs: [18])
        let cache = CachedMetadataProvider(StubCatalogue(titles: [ok, adult, unknown], certs: [ok.key: "PG", adult.key: "R"]))
        // Certifications are learnt from title pages.
        _ = try await cache.detail(for: ok.key)
        _ = try await cache.detail(for: adult.key)
        #expect(try await cache.list(.trending, page: 1).items.count == 3)

        cache.contentFilter = ContentFilter(maximum: .age13)
        #expect(try await cache.list(.trending, page: 1).items.map(\.name) == ["Fine", "Unknown"])
        #expect(try await cache.search("x", page: 1).items.map(\.name) == ["Fine", "Unknown"])
        cache.contentFilter = ContentFilter(maximum: .age7, familyOnlyWhenUnrated: true)
        #expect(try await cache.list(.trending, page: 1).items.map(\.name) == ["Fine"])
        cache.contentFilter = nil
        #expect(try await cache.list(.trending, page: 1).items.count == 3)
    }

    @MainActor
    @Test func appAppliesTheCurrentProfilesLimit() async throws {
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(), prefs: prefs(), forceSample: true)
        let cache = try #require(app.metadata as? CachedMetadataProvider)
        #expect(cache.contentFilter == nil)
        let kids = app.addProfile(name: "Kids", symbol: "pawprint.fill", color: 8, isKids: true)
        await app.switchProfile(to: kids.id)
        #expect(cache.contentFilter == ContentFilter(maximum: .age7, familyOnlyWhenUnrated: true, blocksUnrated: true))
        cache.noteCertification("R", for: .movie(tmdbID: 77))
        #expect(app.maturityBlock(for: .movie(tmdbID: 77)) != nil)
        #expect(!app.allowsCertification("R") && app.allowsCertification("G") && !app.allowsCertification(nil))
        await app.switchProfile(to: Profile.defaultID)
        #expect(cache.contentFilter == nil)
        #expect(app.maturityBlock(for: .movie(tmdbID: 77)) == nil)
    }
}

private struct StubCatalogue: MetadataProvider {
    let titles: [Title]
    let certs: [MediaKey: String]
    func list(_ list: CatalogList, page: Int) async throws -> Page<Title> { Page(items: titles, page: 1, totalPages: 1) }
    func search(_ query: String, page: Int) async throws -> Page<Title> { Page(items: titles, page: 1, totalPages: 1) }
    func discover(genre: Genre, kind: TitleKind, page: Int) async throws -> Page<Title> { Page(items: titles, page: 1, totalPages: 1) }
    func genres() async throws -> [Genre] { [] }
    func detail(for key: MediaKey) async throws -> TitleDetail {
        TitleDetail(title: titles.first { $0.key == key }!, certification: certs[key])
    }
    func season(_ number: Int, of seriesKey: MediaKey) async throws -> Season { throw MetadataError.notFound }
    func imageURL(for artwork: Artwork, width: Int) -> URL? { nil }
}

// MARK: - Shortcuts and row titles

@MainActor
@Suite struct ProfileShortcutTests {
    @Test func digitsMapToThePickerOrder() {
        let ps = [Profile.makeDefault(name: "Brian"),
                  Profile(id: "gone", name: "Gone", isRemoved: true, updatedAt: .now),
                  Profile(id: "mia", name: "Mia", updatedAt: .now),
                  Profile(id: "sam", name: "Sam", updatedAt: .now),
                  Profile(id: "kids", name: "Kids", updatedAt: .now),
                  Profile(id: "zed", name: "Zed", updatedAt: .now)]
        #expect(ProfileShortcuts.profile(forDigit: 1, in: ps)?.name == "Brian")
        #expect(ProfileShortcuts.profile(forDigit: 2, in: ps)?.name == "Mia")  // removed ones don't count
        #expect(ProfileShortcuts.profile(forDigit: 4, in: ps)?.name == "Kids")
        #expect(ProfileShortcuts.profile(forDigit: 5, in: ps) == nil)  // only ⌃⌘1–4
        #expect(ProfileShortcuts.profile(forDigit: 0, in: ps) == nil)
        #expect(ProfileShortcuts.profile(forDigit: 3, in: Array(ps.prefix(2))) == nil)
        #expect(ProfileShortcuts.digit(for: "sam", in: ps) == 3)
        #expect(ProfileShortcuts.digit(for: "zed", in: ps) == nil)
        #expect(ProfileShortcuts.digit(for: "gone", in: ps) == nil)
    }

    @Test func shortcutsRequestASwitchThroughRootView() throws {
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(), prefs: prefs(), forceSample: true)
        let sam = app.addProfile(name: "Sam", symbol: "star.fill", color: 2)
        app.requestProfileSwitch(digit: 1)  // already watching: nothing
        #expect(app.profileSwitchRequest == nil)
        app.requestProfileSwitch(digit: 2)
        #expect(app.profileSwitchRequest?.profileID == sam.id)
        app.profileSwitchRequest = nil
        app.requestProfileSwitch(digit: 3)
        #expect(app.profileSwitchRequest == nil)
    }

    @Test func personalRowsNameTheProfileOnlyWhenThereAreSeveral() async throws {
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(), prefs: prefs(), forceSample: true)
        #expect(app.continueWatchingTitle == "Continue Watching")
        #expect(app.myListTitle == "My List")
        #expect(!app.showsSharedTags)
        let sam = app.addProfile(name: "Sam", symbol: "star.fill", color: 2)
        await app.switchProfile(to: sam.id)
        #expect(app.continueWatchingTitle == "Continue Watching for Sam")
        #expect(app.myListTitle == "My List")  // a list's name, the same everywhere
        #expect(app.showsSharedTags)
    }
}

// MARK: - Restricted profiles

@MainActor
@Suite struct RestrictedProfileTests {
    private func makeApp() throws -> AppModel {
        AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(), prefs: prefs(), forceSample: true)
    }

    @Test func settingsAsksForTheRestrictedProfilesOwnPIN() async throws {
        let app = try makeApp()
        let teen = app.addProfile(name: "Sam", symbol: "star.fill", color: 2, maturity: .age13)
        try app.setPIN("1357", for: teen.id)
        #expect(!app.settingsNeedsPIN)  // the default profile has no limit
        await app.switchProfile(to: teen.id)
        #expect(app.settingsNeedsPIN)
        #expect(app.settingsPINProfiles.map(\.id) == [teen.id])
        #expect(!app.unlockSettings(pin: "0000"))
        #expect(app.settingsNeedsPIN)
        #expect(app.unlockSettings(pin: "1357"))
        #expect(!app.settingsNeedsPIN)
        // Background locks it again; so does changing profile.
        app.lockSettings()
        #expect(app.settingsNeedsPIN)
        #expect(app.unlockSettings(pin: "1357"))
        await app.switchProfile(to: Profile.defaultID)
        await app.switchProfile(to: teen.id)
        #expect(app.settingsNeedsPIN)
    }

    @Test func aLimitWithoutAPINDoesntAsk() async throws {
        let app = try makeApp()
        let teen = app.addProfile(name: "Sam", symbol: "star.fill", color: 2, maturity: .age13)
        await app.switchProfile(to: teen.id)
        #expect(!app.settingsNeedsPIN)
    }

    /// A Kids profile without its own PIN takes a grown-up's.
    @Test func kidsProfilesTakeAGrownUpsPIN() async throws {
        let app = try makeApp()
        let kids = app.addProfile(name: "Kids", symbol: "pawprint.fill", color: 8, isKids: true)
        await app.switchProfile(to: kids.id)
        #expect(!app.settingsNeedsPIN)  // no PIN anywhere: nothing to ask for
        try app.setPIN("8642", for: Profile.defaultID)
        #expect(app.settingsNeedsPIN)
        #expect(!app.unlockSettings(pin: "1111"))
        #expect(app.unlockSettings(pin: "8642"))
        // Its own PIN, once it has one, is the one asked for.
        try app.setPIN("1111", for: kids.id)
        app.lockSettings()
        #expect(app.settingsPINProfiles.map(\.id) == [kids.id])
        #expect(!app.unlockSettings(pin: "8642"))
        #expect(app.unlockSettings(pin: "1111"))
    }

    /// Turning Kids on for the watching profile from inside Settings doesn't lock you out mid-edit.
    @Test func restrictingTheWatchingProfileKeepsSettingsOpen() async throws {
        let app = try makeApp()
        try app.setPIN("2222", for: Profile.defaultID)
        var me = app.currentProfile
        me.isKids = true
        app.updateProfile(me)
        #expect(!app.settingsNeedsPIN)
        app.lockSettings()
        #expect(app.settingsNeedsPIN)
    }

    @Test func unratedTitlesAreBlockedOnKidsUnlessAllowed() async throws {
        let app = try makeApp()
        let cache = try #require(app.metadata as? CachedMetadataProvider)
        let kids = app.addProfile(name: "Kids", symbol: "pawprint.fill", color: 8, isKids: true)
        await app.switchProfile(to: kids.id)
        #expect(cache.contentFilter?.blocksUnrated == true)
        #expect(!app.allowsCertification(nil) && !app.allowsCertification("NR"))
        let unrated = MediaKey.movie(tmdbID: 9_999_001)
        let block = try #require(app.maturityBlock(for: unrated))
        #expect(!block.contains("Manage Profiles"))
        cache.noteCertification("G", for: unrated)
        #expect(app.maturityBlock(for: unrated) == nil)

        var p = app.currentProfile
        p.allowsUnrated = true
        app.updateProfile(p)
        #expect(cache.contentFilter?.blocksUnrated == false)
        #expect(app.allowsCertification(nil))
        #expect(app.maturityBlock(for: .movie(tmdbID: 9_999_002)) == nil)
        #expect(SettingsSearchIndex.search("unrated").first?.title == "Allow Unrated Titles")
    }

    @Test func blockMessagesDontSayHowToChangeTheLimit() async throws {
        let app = try makeApp()
        let cache = try #require(app.metadata as? CachedMetadataProvider)
        let teen = app.addProfile(name: "Sam", symbol: "star.fill", color: 2, maturity: .age13)
        await app.switchProfile(to: teen.id)
        cache.noteCertification("R", for: .movie(tmdbID: 9_999_003))
        let block = try #require(app.maturityBlock(for: .movie(tmdbID: 9_999_003)))
        #expect(block.contains("R") && !block.contains("Manage Profiles") && !block.contains("Change"))
        #expect(app.maturityBlock(for: .movie(tmdbID: 9_999_004)) == nil)  // unrated plays outside Kids by default
    }

    @Test func allowUnratedDefaultsAndDecodes() throws {
        #expect(!Profile(id: "k", name: "K", updatedAt: .now, isKids: true).effectiveAllowsUnrated)
        #expect(Profile(id: "t", name: "T", updatedAt: .now, maturity: .age13).effectiveAllowsUnrated)
        #expect(Profile(id: "t", name: "T", updatedAt: .now, maturity: .age13, allowsUnrated: false).contentFilter?.blocksUnrated == true)
        let old = #"{"id":"a","name":"Al","updatedAt":0,"isKids":true}"#
        let decoded = try JSONDecoder().decode(Profile.self, from: Data(old.utf8))
        #expect(decoded.allowsUnrated == nil && decoded.contentFilter?.blocksUnrated == true)
        // Not synced: a newer profile from the cloud keeps this device's choice.
        let store = ProfileStore(prefs: prefs())
        store.save(Profile(id: "k", name: "Kids", updatedAt: .now, isKids: true, allowsUnrated: true))
        store.applyRemote([Profile(id: "k", name: "Kids", updatedAt: .now.addingTimeInterval(60))])
        #expect(store.profile("k")?.allowsUnrated == true)
    }
}
