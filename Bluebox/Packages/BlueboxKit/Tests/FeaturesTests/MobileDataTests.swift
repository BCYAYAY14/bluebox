import Addons
import Domain
import Downloads
@testable import Features
import Foundation
import Persistence
import Playback
import Testing

@MainActor
@Suite struct MobileDataTests {
    private func prefs() -> PreferencesStore {
        PreferencesStore(defaults: UserDefaults(suiteName: "mobiledata.\(UUID().uuidString)")!)
    }

    private func app(_ p: PreferencesStore? = nil) throws -> AppModel {
        let app = AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                           prefs: p ?? prefs(), forceSample: true)
        app.settings.mobileDataApplies = true
        return app
    }

    private static let cellular = NetworkPathInfo(isOnline: true, isExpensive: true, usesCellular: true)
    private static let wifi = NetworkPathInfo(isOnline: true, usesWiFi: true)
    private static let item = NowPlayingItem(key: .movie(tmdbID: 603), title: "The Matrix")

    private func remote(_ id: String = "https://example.com/movie.mp4", source: SourceID = SourceID("links")) -> MediaVariant {
        MediaVariant(id: id, sourceID: source, mediaKey: Self.item.key, displayName: "Movie", resolution: "1080p",
                     sizeBytes: 1_100_000_000, location: .remote, isDownloadable: true)
    }

    @Test func defaultsFollowTheSpec() {
        let s = MobileDataSettings()
        #expect(s.streaming == .askFirst && s.quality == .dataSaver && s.torrents == .debridOnly && !s.allowUpload)
        let ranking = s.ranking()
        #expect(ranking.maxResolution == "720p" && ranking.preferSmallest && !ranking.allowsTorrents && ranking.allowsDebrid)
        #expect(MobileDataSettings.Quality.automatic.cap == "1080p" && MobileDataSettings.Quality.best.cap == nil)
    }

    @Test func persistsAndDecodesOlderSaves() throws {
        let p = prefs()
        let settings = AppSettings(prefs: p)
        settings.mobileData.quality = .best
        settings.mobileData.torrents = .allow
        #expect(AppSettings(prefs: p).mobileData.quality == .best)
        #expect(AppSettings(prefs: p).mobileData.torrents == .allow)
        // A save missing fields keeps the defaults for them.
        let partial = try JSONDecoder().decode(MobileDataSettings.self, from: Data(#"{"streaming":"allow"}"#.utf8))
        #expect(partial.streaming == .allow && partial.quality == .dataSaver && partial.torrents == .debridOnly)
    }

    @Test func theOldCellularSwitchStaysInStep() {
        let p = prefs()
        p.set(false, for: PreferenceKey.allowCellularStreaming)  // turned off before Mobile Data existed
        let settings = AppSettings(prefs: p)
        #expect(settings.mobileData.streaming == .never)
        settings.mobileData.streaming = .allow
        #expect(settings.allowCellularStreaming)
        #expect(p.value(Bool.self, for: PreferenceKey.allowCellularStreaming) == true)
        settings.allowCellularStreaming = false
        #expect(settings.mobileData.streaming == .never)
    }

    @Test func lowDataModeAndHotspotsCountAsMobileData() {
        #expect(NetworkPathInfo(isOnline: true, isConstrained: true, usesWiFi: true).isMobileData)
        #expect(NetworkPathInfo(isOnline: true, isExpensive: true, usesWiFi: true).isMobileData)
        #expect(Self.cellular.isMobileData)
        #expect(!Self.wifi.isMobileData)
        #expect(!NetworkPathInfo(isOnline: false, isExpensive: true).isMobileData)
    }

    @Test func usageStartsAgainEachMonth() {
        let october = Date(timeIntervalSince1970: 1_793_000_000)  // 2026-10-26
        var usage = MobileDataUsage(now: october)
        usage.streamingBytes = 500
        #expect(usage.current(now: october) == usage)
        let november = october.addingTimeInterval(20 * 86_400)
        #expect(usage.current(now: november).totalBytes == 0)
    }

    @Test func neverBlocksStreamingOnMobileDataOnly() throws {
        let app = try app()
        app.settings.mobileData.streaming = .never
        app.settings.simulateNetwork(Self.cellular)
        #expect(app.settings.streamingBlockedReason(for: remote()) != nil)
        app.settings.simulateNetwork(Self.wifi)
        #expect(app.settings.streamingBlockedReason(for: remote()) == nil)
    }

    @Test func torrentsNeverOrDebridOnlyStopAddonPlay() async throws {
        let app = try app()
        app.settings.mobileData.streaming = .allow
        app.settings.simulateNetwork(Self.cellular)
        let best = remote(StremioSource.bestReleaseID, source: app.addons.id)
        // Debrid Only with no debrid service: nothing can play.
        #expect(await app.mobileDataAllowsPlaying(Self.item, variant: best) == false)
        #expect(app.alert?.title == "Peer-to-peer is off on mobile data")
        app.alert = nil
        app.settings.mobileData.torrents = .never
        #expect(await app.mobileDataAllowsPlaying(Self.item, variant: best) == false)
        app.settings.mobileData.torrents = .allow
        #expect(await app.mobileDataAllowsPlaying(Self.item, variant: best))
        // On Wi‑Fi nothing is asked or refused.
        app.settings.mobileData.torrents = .never
        app.settings.simulateNetwork(Self.wifi)
        #expect(await app.mobileDataAllowsPlaying(Self.item, variant: best))
    }

    @Test func askFirstWaitsForTheSheetAndCanStopAsking() async throws {
        let app = try app()
        app.settings.simulateNetwork(Self.cellular)
        let task = Task { await app.mobileDataAllowsPlaying(Self.item, variant: remote()) }
        for _ in 0..<500 where app.settings.mobileDataPrompt == nil { try await Task.sleep(for: .milliseconds(10)) }
        let prompt = try #require(app.settings.mobileDataPrompt)
        #expect(prompt.title == "The Matrix" && prompt.bytes == 1_100_000_000 && prompt.quality == "1080p")
        app.answerMobileDataPrompt(.playInDataSaver, dontAskAgain: true)
        #expect(await task.value)
        #expect(app.settings.dataSaverForThisPlayback)
        // "Don't ask again for this session".
        #expect(await app.mobileDataAllowsPlaying(Self.item, variant: remote()))
        #expect(app.settings.mobileDataPrompt == nil)
    }

    @Test func cancelStopsPlay() async throws {
        let app = try app()
        app.settings.simulateNetwork(Self.cellular)
        let task = Task { await app.mobileDataAllowsPlaying(Self.item, variant: remote()) }
        for _ in 0..<500 where app.settings.mobileDataPrompt == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(app.settings.mobileDataPrompt != nil)
        app.answerMobileDataPrompt(.cancel)
        #expect(await task.value == false)
    }

    @Test func downloadsOnMobileDataSayTheyWaitForWiFi() throws {
        let app = try app()
        let record = DownloadRecord(id: "links/x", mediaKey: nil, title: "X", subtitle: nil, origin: remote(), state: .queued,
                                    receivedBytes: 0, expectedBytes: nil, createdAt: .now, fileName: nil, subtitleFiles: [])
        #expect(app.mobileDataDownloadNotice(for: record, title: "X") == nil)  // Wi‑Fi (unknown) → no notice
        app.settings.simulateNetwork(Self.cellular)
        let notice = try #require(app.mobileDataDownloadNotice(for: record, title: "X"))
        #expect(notice.title == "Will start on Wi‑Fi" && notice.actionTitle == "Download Now")
        var off = app.downloadSettings
        off.wifiOnly = false
        app.setDownloadSettings(off)
        #expect(app.mobileDataDownloadNotice(for: record, title: "X") == nil)
    }

    @Test func pictureDefaultsMapToVideoAdjustments() {
        var p = PictureDefaults()
        #expect(p.isDefault && p.adjustments.isDefault)
        p.contrast = 1.2
        p.brightness = 5
        #expect(p.adjustments.contrast == 1.2 && p.adjustments.brightness == 1)  // clamped
    }
}

/// Every searchable setting can be scrolled to: its row carries `.settingsRow("<title>")`.
@Suite struct SettingsSearchIndexTests {
    @Test func everyEntryHasARowToScrollTo() throws {
        let features = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Features")
        let files = try FileManager.default.contentsOfDirectory(at: features.appending(path: "Settings"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        // Account & Sync is its own screen; Switch Profile is the Profiles list itself.
        // Storage's cache rows are tagged "Clear \(title)" by one helper.
        let cacheRows: Set = ["Clear Artwork", "Clear Catalog Data", "Clear Downloaded Subtitles"]
        let missing = SettingsSearchIndex.entries
            .filter { $0.page != .account && !cacheRows.contains($0.title) }
            // Tagged from data: profile rows by state, sources by their names.
            .filter { !["Switch Profile", "Edit Profile", "Open Movies"].contains($0.title) }
            .filter { !source.contains(".settingsRow(\"\($0.title)\")") }
        #expect(missing.map(\.title) == [])
        #expect(source.contains(".settingsRow(\"Clear \\(title)\")"))
    }

    @Test func mobileDataIsPhoneAndPadOnly() {
        #if os(macOS)
        #expect(!SettingsPage.available.contains(.mobileData))
        #expect(SettingsSearchIndex.search("data saver").isEmpty)
        #else
        #expect(SettingsSearchIndex.search("data saver").first?.page == .mobileData)
        #endif
        #expect(SettingsSearchIndex.search("brightness").first?.page == .picture)
    }
}
