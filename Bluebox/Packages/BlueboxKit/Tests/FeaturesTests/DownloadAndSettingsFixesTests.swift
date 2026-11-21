import Addons
import Domain
import Downloads
@testable import Features
import Foundation
import MediaSources
import Persistence
import Testing
import TestingSupport

/// What's announced when downloads finish or fail, Try Another Release,
/// checking a debrid key, and Settings search finding every row.
@MainActor
@Suite struct DownloadAndSettingsFixesTests {
    static let hashA = String(repeating: "a", count: 40)
    static let hashB = String(repeating: "b", count: 40)

    func record(_ id: String, _ state: DownloadRecord.State, hash: String? = nil, order: Double = 1) -> DownloadRecord {
        let v = MediaVariant(id: hash.map { "\($0):0" } ?? "https://cdn.example/\(id).mkv", sourceID: SourceID("addons"),
                             mediaKey: .movie(tmdbID: 1), displayName: id, location: .remote, isDownloadable: true)
        return DownloadRecord(id: id, mediaKey: .movie(tmdbID: 1), title: id, subtitle: nil, origin: v, state: state,
                              receivedBytes: 0, expectedBytes: 1_000, createdAt: .now, fileName: nil, subtitleFiles: [], order: order)
    }

    // MARK: Download news

    @Test func finishesAndFailuresOfWorkingDownloadsAreNews() {
        let before: [String: DownloadRecord.State] = ["a": .queued, "b": .downloading, "c": .paused, "d": .completed, "e": .queued]
        let now = [record("a", .completed, order: 1), record("b", .failed("Gone"), order: 2), record("c", .failed("Late"), order: 3),
                   record("d", .completed, order: 4), record("e", .queued, order: 5), record("f", .failed("Full"), order: 6)]
        let news = DownloadNews.changes(from: before, to: now)
        // A queued one that finished counts (a background launch sees queued → completed);
        // a paused one failing late doesn't; a new one failing before the first look does.
        #expect(news.map(\.0.id) == ["a", "b", "f"])
        #expect(news.map(\.1) == [.finished, .failed("Gone"), .failed("Full")])
        // Nothing changed, nothing to say.
        #expect(DownloadNews.changes(from: ["a": .completed], to: [record("a", .completed)]).isEmpty)
    }

    @Test func tryAnotherReleaseSkipsTheSameTorrent() {
        func release(_ id: String, hash: String?, url: URL? = nil) -> AddonRelease {
            AddonRelease(id: id, title: id, name: "Add-on", infoHash: hash, fileIndex: 0, trackers: [], seeders: 20, sizeText: nil,
                         resolution: "1080p", container: "mkv", url: url, filename: id, videoSize: nil)
        }
        let dead = record("dead", .failed("Nobody has shared this release for 15 minutes. Try another release."), hash: Self.hashA)
        let ranked = [
            release("\(Self.hashA):0", hash: Self.hashA),
            // The same torrent through a debrid link is the same release.
            release("https://debrid.example/\(Self.hashA)/file.mkv", hash: nil, url: URL(string: "https://debrid.example/\(Self.hashA)/file.mkv")),
            release("\(Self.hashB):0", hash: Self.hashB),
        ]
        #expect(DownloadNews.otherReleases(ranked, than: dead).map(\.id) == ["\(Self.hashB):0"])
    }

    // MARK: Debrid key

    func makeApp(_ http: FixtureHTTPClient, debrid: DebridProvider = .torBox) throws -> AppModel {
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                           prefs: PreferencesStore(defaults: UserDefaults(suiteName: "fixes.\(UUID().uuidString)")!), http: http)
        var settings = app.addonSettings
        settings.debrid = debrid
        app.setAddonSettings(settings)
        return app
    }

    @Test func aKeyTheServiceRefusesIsNotSaved() async throws {
        let http = FixtureHTTPClient()
        http.on("user/me", .init(status: 401))
        let app = try makeApp(http)
        let check = await app.checkAndSaveDebridKey("  FAKE-WRONG-KEY ")
        #expect(check == .rejected)
        #expect(app.debridKey.isEmpty)
        #expect(check.fieldError(service: "TorBox", hint: "torbox.app/settings") == "TorBox didn't accept this key. Copy it again from torbox.app/settings.")
    }

    @Test func aKeyTheServiceKnowsIsSavedWithItsPlan() async throws {
        let http = FixtureHTTPClient()
        http.on("user/me", .init(body: Data(#"{"success":true,"data":{"email":"viewer@example.com","plan":2,"premium_expires_at":"2099-01-01T00:00:00Z"}}"#.utf8)))
        let app = try makeApp(http)
        let check = await app.checkAndSaveDebridKey("FAKE-GOOD-KEY")
        guard case .accepted = check else { Issue.record("expected accepted, got \(check)"); return }
        #expect(app.debridKey == "FAKE-GOOD-KEY")
        #expect(app.features.debridAccount?.isPremium == true)
        #expect(check.fieldError(service: "TorBox", hint: nil) == nil)
    }

    @Test func aKeyThatCantBeCheckedIsSavedAndSaysSo() async throws {
        let http = FixtureHTTPClient()
        http.error = URLError(.notConnectedToInternet)
        let app = try makeApp(http)
        let check = await app.checkAndSaveDebridKey("FAKE-OFFLINE-KEY")
        guard case .unreachable = check else { Issue.record("expected unreachable, got \(check)"); return }
        #expect(app.debridKey == "FAKE-OFFLINE-KEY")
    }

    @Test func readinessSaysWhatStandsInPlaysWay() {
        var s = AddonSettings()
        s.debrid = .none
        #expect(DebridReadiness.status(settings: s, debridKey: "k", account: nil) == nil)

        s.debrid = .torBox
        #expect(DebridReadiness.status(settings: s, debridKey: "", account: nil)?.message.contains("Add your TorBox API key") == true)

        s.isEnabled = false
        #expect(DebridReadiness.status(settings: s, debridKey: "k", account: nil)?.message.contains("Find Releases with Add-ons") == true)

        s.isEnabled = true
        s.addons = s.addons.map { var a = $0; a.isEnabled = false; return a }
        #expect(DebridReadiness.status(settings: s, debridKey: "k", account: nil)?.ok == false)

        // Comet alone, without sharing the key, is dropped from every search.
        s.addons = [.preset(.comet)]
        s.shareKeyWithCommunityHosts = false
        let comet = DebridReadiness.status(settings: s, debridKey: "k", account: nil)
        #expect(comet?.ok == false && comet?.message.contains("Comet") == true)

        s.shareKeyWithCommunityHosts = true
        #expect(DebridReadiness.status(settings: s, debridKey: "k", account: nil)?.ok == true)

        // A known account with no plan won't play.
        s.addons = [.preset(.torrentio)]
        let expired = DebridAccount(name: "x", premiumUntil: nil, isPremium: false)
        #expect(DebridReadiness.status(settings: s, debridKey: "k", account: expired)?.ok == false)
        let ready = DebridReadiness.status(settings: s, debridKey: "k", account: DebridAccount(name: "x", premiumUntil: nil, isPremium: true))
        #expect(ready?.ok == true && ready?.message.contains("Torrentio") == true)
    }

    @Test func typingDoesntSaveAKeyButPastingDoes() {
        #expect(SettingsKeyField.looksPasted(old: "", new: "abcd1234"))
        #expect(!SettingsKeyField.looksPasted(old: "", new: "abc"))
        // Autocorrect adding a word to what's being typed isn't a paste.
        #expect(!SettingsKeyField.looksPasted(old: "abc", new: "abcdefghijk"))
    }

    // MARK: Undo after quitting

    @Test func aDeleteLeftWaitingIsFinishedNextLaunch() {
        let defaults = UserDefaults(suiteName: "pending.\(UUID().uuidString)")!
        defaults.set(["one", "two"], forKey: PendingDownloadDeletes.savedKey)
        let pending = PendingDownloadDeletes()
        pending.defaults = defaults
        #expect(Set(pending.takeLeftovers()) == ["one", "two"])
        // Read once: the next launch has nothing left to finish.
        #expect(pending.takeLeftovers().isEmpty)
    }

    // MARK: Settings search

    /// Every literal `.settingsRow("…")` and `.accountRow("…")` in the app has
    /// a line in the search index, so search can find (and flash) it.
    @Test func everyNamedRowIsInTheSearchIndex() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/Features")
        let pattern = try Regex(#"\.(settingsRow|accountRow)\("([^"\\]*)"\)"#)
        var named: Set<String> = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for match in text.matches(of: pattern) {
                if let name = match.output[2].substring { named.insert(String(name)) }
            }
        }
        #expect(named.count > 100)
        let indexed = Set(SettingsSearchIndex.entries.map(\.title))
        // Rows named after something that changes (a hidden title, an empty list) aren't settings.
        let notSettings: Set = ["No Hidden Titles"]
        let missing = named.subtracting(indexed).subtracting(notSettings)
        #expect(missing.isEmpty, "Rows with no search index line: \(missing.sorted())")
    }

    @Test func searchFindsWhatItUsedToMiss() {
        #expect(SettingsSearchIndex.search("sync now").first?.title == "Sync Now")
        #expect(SettingsSearchIndex.search("switch profile").first?.title == "Switch Profile")
        #expect(SettingsSearchIndex.search("sync api keys").first?.title == "Sync API Keys")
        #expect(SettingsSearchIndex.search("community times").first?.title == "Shows Ignoring Community Times")
        // "Wi‑Fi" is written with a non-breaking hyphen; typing a plain one finds it.
        #expect(SettingsSearchIndex.search("wi-fi only").first?.title == "Downloads on Wi‑Fi Only"
                || !SettingsSearchIndex.isAvailable(SettingsSearchIndex.entries.first { $0.title == "Downloads on Wi‑Fi Only" }!))
        #expect(SettingsSearchIndex.folded("Wi\u{2011}Fi") == "wi-fi")
        // One entry for streaming on mobile data, not two.
        #expect(!SettingsSearchIndex.entries.contains { $0.title == "Stream over Cellular" })
        // The profile's switches are on the profile's own page.
        #expect(SettingsSearchIndex.search("spoiler").first?.page == .profileFeatures)
        #expect(SettingsSearchIndex.search("audio language").first?.page == .languages)
        #expect(SettingsPage.profileGroup.contains(.languages) && SettingsPage.profileGroup.contains(.profileFeatures))
    }
}
