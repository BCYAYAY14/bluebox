@testable import Addons
import Domain
import Foundation
import Testing

@Suite struct AddonSettingsMigrationTests {
    /// Settings as earlier versions saved them (`providers`, no `addons`).
    static let saved = #"""
    {"isEnabled":true,"providers":["stremthru","torrentio"],"debrid":"realDebrid","shareKeyWithCommunityHosts":true,
     "stremthruHost":"https://st.example.org","hiddenQualities":["cam","480p"],"sort":"quality","preferredResolution":"720p",
     "maxPeers":50,"streamingPort":9000,"extraTrackers":["udp://t.example:1337/announce"],"streamCacheLimitBytes":10,
     "prefetchReleases":false,"raceWidth":2,"minimumPrebufferMB":5,"maximumPrebufferMB":32}
    """#

    @Test func earlierSettingsCarryOver() throws {
        let s = try JSONDecoder().decode(AddonSettings.self, from: Data(Self.saved.utf8))
        #expect(s.addons.map(\.preset) == [.stremthru, .torrentio])   // same order
        #expect(s.addons.allSatisfy { $0.isEnabled })
        #expect(s.providers == [.stremthru, .torrentio])
        #expect(s.debrid == .realDebrid)
        #expect(s.shareKeyWithCommunityHosts)
        #expect(s.stremthruHost == "https://st.example.org")
        #expect(s.hiddenQualities == [.cam, .sd])
        #expect(s.sort == .quality)
        #expect(s.preferredResolution == "720p")
        #expect(s.maxPeers == 50 && s.streamingPort == 9000 && s.streamCacheLimitBytes == 10)
        #expect(s.extraTrackers == ["udp://t.example:1337/announce"])
        #expect(!s.prefetchReleases && s.raceWidth == 2)
        #expect(s.minimumPrebufferMB == 5 && s.maximumPrebufferMB == 32)
        // New settings get their defaults.
        #expect(s.rememberShowChoices && s.checkDebridCache && s.addonTimeoutSeconds == 10 && s.uploadLimitKBps == nil)
    }

    @Test func oldestSettingsGetDefaults() throws {
        let s = try JSONDecoder().decode(AddonSettings.self, from: Data(#"{"isEnabled":false,"providers":["comet","bogus","comet"]}"#.utf8))
        #expect(!s.isEnabled)
        #expect(s.addons.map(\.preset) == [.comet])
        #expect(s.raceWidth == 3 && s.prefetchReleases && s.hiddenQualities == [.cam, .scr])
        #expect(s.preferredResolution == "1080p")
        let empty = try JSONDecoder().decode(AddonSettings.self, from: Data("{}".utf8))
        #expect(empty == AddonSettings())
    }

    @Test func unknownValuesDontResetTheRest() throws {
        let json = #"{"providers":["torrentio"],"hiddenQualities":["cam","future-thing"],"sort":"newest","maxPeers":"many","raceWidth":4}"#
        let s = try JSONDecoder().decode(AddonSettings.self, from: Data(json.utf8))
        #expect(s.hiddenQualities == [.cam])
        #expect(s.sort == .seeders && s.maxPeers == 80)
        #expect(s.raceWidth == 4)
    }

    @Test func roundTripsAndKeepsWritingProviders() throws {
        var s = AddonSettings()
        s.preferredResolution = nil
        s.uploadLimitKBps = 0
        s.addons.append(InstalledAddon(id: "custom.1", kind: .custom(base: "https://addon.example/cfg"), name: "Example", isEnabled: false))
        s.addons[0].isEnabled = false
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AddonSettings.self, from: data) == s)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["providers"] as? [String] == ["stremthru"])    // for older builds: presets that are on
    }

    @Test func streamSettingsCarryTheKnobs() {
        var s = AddonSettings()
        s.minimumPrebufferMB = 5
        s.maximumPrebufferMB = 2
        s.raceWidth = 9
        s.uploadLimitKBps = 500
        let stream = s.streamSettings
        #expect(stream.minimumPrebufferBytes == 5 * 1024 * 1024)
        #expect(stream.maximumPrebufferBytes == 5 * 1024 * 1024)
        #expect(stream.raceWidth == 5)
        #expect(stream.uploadRateLimit == Int64(512_000))
        #expect(stream.uploadOnExpensiveNetwork)
        s.uploadLimitKBps = nil
        #expect(s.streamSettings.uploadRateLimit == nil)
    }
}

@Suite struct PresetURLTests {
    private func decodeConfig(_ url: URL, after marker: String) throws -> [String: Any] {
        let segment = try #require(url.absoluteString.components(separatedBy: marker).last)
        #expect(!segment.contains("/"))
        let data = try #require(Data(base64Encoded: segment.removingPercentEncoding ?? segment))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func torrentioCarriesSortFiltersAndKey() {
        var s = AddonSettings()
        s.sort = .quality
        s.hiddenQualities = [.scr, .cam]
        s.debrid = .torBox
        let base = AddonPresetURL.base(for: .torrentio, settings: s, debridKey: " KEY ")
        #expect(base?.absoluteString == "https://torrentio.strem.fun/sort=qualitysize%7Cqualityfilter=cam,scr%7Ctorbox=KEY")
        s.debrid = .none
        s.hiddenQualities = []
        #expect(AddonPresetURL.base(for: .torrentio, settings: s, debridKey: "KEY")?.absoluteString
                == "https://torrentio.strem.fun/sort=qualitysize")
    }

    @Test func stremThruPeerToPeerUnlessSharing() throws {
        var s = AddonSettings()
        s.debrid = .realDebrid
        let p2p = try #require(AddonPresetURL.base(for: .stremthru, settings: s, debridKey: "KEY"))
        #expect(p2p.absoluteString.hasPrefix(AddonPreset.defaultStremthruHost + "/stremio/torz/"))
        let config = try decodeConfig(p2p, after: "/torz/")
        let stores = try #require(config["stores"] as? [[String: String]])
        #expect(stores == [["c": "p2p", "t": ""]])
        s.shareKeyWithCommunityHosts = true
        let shared = try decodeConfig(try #require(AddonPresetURL.base(for: .stremthru, settings: s, debridKey: "KEY")), after: "/torz/")
        #expect(shared["stores"] as? [[String: String]] == [["c": "rd", "t": "KEY"]])
    }

    @Test func cometOnlyWithASharedKey() throws {
        var s = AddonSettings()
        s.debrid = .allDebrid
        #expect(AddonPresetURL.base(for: .comet, settings: s, debridKey: "KEY") == nil)
        s.shareKeyWithCommunityHosts = true
        let url = try #require(AddonPresetURL.base(for: .comet, settings: s, debridKey: "KEY"))
        let config = try decodeConfig(url, after: "elfhosted.com/")
        #expect(config["debridService"] as? String == "alldebrid")
        #expect(config["debridApiKey"] as? String == "KEY")
    }

    @Test func base64ConfigsNeverHaveSlashes() {
        // Keys chosen so a plain encoding would contain "/".
        for key in ["???", "a?>b", String(repeating: "?", count: 37), "ÿÿÿ"] {
            let encoded = PathSafeBase64.encode { pad in #"{"k":"# + pad + AddonPresetURL.jsonString(key) + "}" }
            #expect(encoded != nil && !(encoded!.contains("/")))
            let data = Data(base64Encoded: encoded!.removingPercentEncoding!)!
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            #expect(object?["k"] == key)
        }
    }

    @Test func resolvedAddonsFollowYourListAndDropDuplicates() {
        var s = AddonSettings()
        s.addons = [
            InstalledAddon(id: "c1", kind: .custom(base: "https://addon.example/x"), name: "One"),
            .preset(.comet),                                   // no shared key: left out
            .preset(.torrentio, enabled: false),
            InstalledAddon(id: "c2", kind: .custom(base: "https://addon.example/x"), name: "Dup"),
            .preset(.stremthru),
        ]
        let resolved = s.resolvedAddons(debridKey: "")
        #expect(resolved.map(\.id) == ["c1", "preset.stremthru"])
        #expect(s.availablePresets.isEmpty)
        s.addPreset(.torrentio)
        #expect(s.resolvedAddons(debridKey: "").map(\.id) == ["c1", "preset.torrentio", "preset.stremthru"])
    }

    @Test func customAddonsShowOnlyTheirHost() throws {
        let manifest = try JSONDecoder().decode(AddonManifest.self, from: Data(StreamFixtures.torrentioManifest.utf8))
        let addon = InstalledAddon.custom(base: URL(string: "https://torrentio.strem.fun/realdebrid=SECRET")!, manifest: manifest)
        #expect(addon.hostLabel == "torrentio.strem.fun")
        #expect(addon.name == "Torrentio" && addon.types == ["movie", "series"])
        #expect(addon.id.hasPrefix("custom."))
    }
}

@Suite struct AddonHealthTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    @Test func repeatedTimeoutsSkipThenRetryWithLongerBackoff() async {
        let clock = Clock()
        let monitor = AddonHealthMonitor(now: { clock.now })
        for _ in 0..<2 { await monitor.recordFailure("slow", error: AddonError.timedOut, latency: 10) }
        #expect(await monitor.shouldAsk("slow"))
        await monitor.recordFailure("slow", error: AddonError.timedOut, latency: 10)
        #expect(!(await monitor.shouldAsk("slow")))
        #expect(await monitor.health("slow").state(at: clock.now) == .skipped)
        clock.advance(5 * 60 + 1)
        #expect(await monitor.shouldAsk("slow"))                       // one try after the skip
        await monitor.recordFailure("slow", error: URLError(.timedOut), latency: 10)
        clock.advance(9 * 60)
        #expect(!(await monitor.shouldAsk("slow")))                    // skipped for 10 minutes now
        clock.advance(2 * 60)
        #expect(await monitor.shouldAsk("slow"))
        await monitor.recordSuccess("slow", latency: 1, releases: 3)
        let h = await monitor.health("slow")
        #expect(h.state(at: clock.now) == .slow)                        // most answers failed
        #expect(h.consecutiveFailures == 0 && h.skippedUntil == nil)
        #expect(h.successRate == 0.2)
    }

    @Test func httpErrorsDontSkip() async {
        let monitor = AddonHealthMonitor()
        for _ in 0..<5 { await monitor.recordFailure("err", error: AddonError.badStatus(500), latency: 0.2) }
        #expect(await monitor.shouldAsk("err"))
        #expect(await monitor.health("err").state() == .failing)
        #expect(await monitor.health("err").lastError == "HTTP 500")
    }

    @Test func healthyAddonSummary() async {
        let monitor = AddonHealthMonitor()
        await monitor.recordSuccess("ok", latency: 0.8, releases: 12)
        await monitor.recordSuccess("ok", latency: 0.8, releases: 10)
        let h = await monitor.health("ok")
        #expect(h.state() == .healthy)
        #expect(h.summary() == "Healthy · 0.8 s · 2 of 2 answered")
        #expect(AddonHealth(addonID: "new").state() == .unknown)
    }
}
