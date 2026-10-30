@testable import Addons
import Domain
import Foundation
import Testing

/// Answers requests by host, after a delay, and counts them.
final class FakeTransport: AddonTransport, @unchecked Sendable {
    struct Reply { var delay: Double = 0; var status = 200; var body: String; var error: URLError? }
    private let lock = NSLock()
    private var replies: [String: Reply]
    private var log: [URLRequest] = []
    private var gates: [String: Gate] = [:]

    init(_ replies: [String: Reply]) { self.replies = replies }

    var requests: [URLRequest] { lock.withLock { log } }
    func set(_ host: String, _ reply: Reply) { lock.withLock { replies[host] = reply } }
    /// Holds `host`'s answer until the gate opens.
    func hold(_ host: String, until gate: Gate) { lock.withLock { gates[host] = gate } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host ?? ""
        let (reply, gate) = lock.withLock { () -> (Reply?, Gate?) in log.append(request); return (replies[host], gates[host]) }
        guard let reply else { throw URLError(.cannotFindHost) }
        await gate?.wait()
        if reply.delay > 0 { try await Task.sleep(for: .seconds(reply.delay)) }
        if let error = reply.error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (Data(reply.body.utf8), response)
    }
}

@Suite struct AddonSearchTests {
    private func addon(_ host: String) -> ResolvedAddon {
        ResolvedAddon(id: host, name: host, base: URL(string: "https://\(host)/cfg")!, types: ["movie", "series"])
    }

    private let request = StreamRequest(imdbID: "tt1727587")

    @Test func answersAfterAGraceAndFoldsInLateAddons() async throws {
        let transport = FakeTransport([
            "fast": .init(body: StreamFixtures.torrentioMovie),
            "slow": .init(body: StreamFixtures.stremThruMovie),
        ])
        // The slow add-on answers only once the search has: no wall-clock limits,
        // which a busy machine (a full test run, an Xcode build) blows through.
        let slow = Gate()
        transport.hold("slow", until: slow)
        let late = LateBox()
        let outcome = try await AddonSearch.run([addon("fast"), addon("slow")], request: request,
                                                client: AddonClient(transport: transport), health: AddonHealthMonitor(),
                                                timing: SearchTiming(perAddon: 60, grace: 0.2, softDeadline: 3)) { list in
            await late.set(list)
        }
        // Answered without the slow add-on, which is still to come.
        #expect(outcome.pending == 1)
        #expect(outcome.releases.count == 5)
        await slow.open()
        let merged = try await late.next(count: 5 + 3 - 1)
        // StremThru's YTS release is the same torrent as Torrentio's: merged, not repeated.
        #expect(merged.count == 5 + 3 - 1)
        #expect(merged.first { $0.infoHash == "a779fa758f2229586eebc2e5960eb32fe5659596" }?.alsoFrom == ["Slow"] ||
                merged.first { $0.infoHash == "a779fa758f2229586eebc2e5960eb32fe5659596" }?.alsoFrom == ["slow"])
        #expect(transport.requests.first?.url?.absoluteString.hasSuffix("/cfg/stream/movie/tt1727587.json") == true)
    }

    @Test func waitsForEveryoneWhenNobodyHasResults() async throws {
        let transport = FakeTransport([
            "empty": .init(body: #"{"streams":[]}"#),
            "later": .init(delay: 0.5, body: StreamFixtures.stremThruMovie),
        ])
        let outcome = try await AddonSearch.run([addon("empty"), addon("later")], request: request,
                                                client: AddonClient(transport: transport), health: AddonHealthMonitor(),
                                                timing: SearchTiming(perAddon: 5, grace: 0.1, softDeadline: 0.2))
        #expect(outcome.releases.count == 3)
        #expect(outcome.pending == 0)
    }

    @Test func slowAddonsTimeOutAndAreRecorded() async throws {
        let transport = FakeTransport([
            "ok": .init(body: StreamFixtures.torrentioMovie),
            "stuck": .init(delay: 30, body: "{}"),
        ])
        let health = AddonHealthMonitor()
        let outcome = try await AddonSearch.run([addon("stuck"), addon("ok")], request: request,
                                                client: AddonClient(transport: transport), health: health,
                                                timing: SearchTiming(perAddon: 0.4, grace: 2, softDeadline: 2))
        #expect(outcome.releases.count == 5)
        #expect(outcome.errors["stuck"] == "Timed out")
        #expect(await health.health("stuck").timeouts == 1)
        #expect(await health.health("ok").successes == 1)
    }

    @Test func reportsWhyWhenEveryAddonFails() async {
        let transport = FakeTransport([
            "rd": .init(body: StreamFixtures.rejectedKey),
            "down": .init(status: 503, body: ""),
        ])
        await #expect(throws: AddonError.debridRejected) {
            try await AddonSearch.run([self.addon("rd"), self.addon("down")], request: self.request,
                                      client: AddonClient(transport: transport), health: AddonHealthMonitor())
        }
        await #expect(throws: AddonError.badStatus(503)) {
            try await AddonSearch.run([self.addon("down")], request: self.request,
                                      client: AddonClient(transport: transport), health: AddonHealthMonitor())
        }
        await #expect(throws: AddonError.noAddons) {
            try await AddonSearch.run([], request: self.request, client: AddonClient(transport: transport), health: AddonHealthMonitor())
        }
    }

    @Test func skipsAddonsThatDontStreamTheType() async throws {
        let transport = FakeTransport(["movies": .init(body: StreamFixtures.torrentioMovie),
                                       "all": .init(body: StreamFixtures.torrentioEpisode)])
        let moviesOnly = ResolvedAddon(id: "movies", name: "M", base: URL(string: "https://movies/x")!, types: ["movie"])
        let outcome = try await AddonSearch.run([moviesOnly, addon("all")], request: StreamRequest(imdbID: "tt0944947", season: 1, episode: 1),
                                                client: AddonClient(transport: transport), health: AddonHealthMonitor())
        #expect(outcome.releases.count == 4)
        #expect(transport.requests.count == 1)
    }

    @Test func cancellingStopsTheSearch() async {
        let transport = FakeTransport(["slow": .init(delay: 10, body: StreamFixtures.torrentioMovie)])
        let task = Task {
            try await AddonSearch.run([self.addon("slow")], request: self.request,
                                      client: AddonClient(transport: transport), health: AddonHealthMonitor())
        }
        try? await Task.sleep(for: .milliseconds(150))
        let started = Date()
        task.cancel()
        _ = await task.result
        #expect(Date().timeIntervalSince(started) < 1)
    }
}

actor LateBox {
    var value: [AddonRelease] = []
    func set(_ v: [AddonRelease]) { value = v }

    /// The late list once it has `count` releases (or what's there after 30 s).
    func next(count: Int) async throws -> [AddonRelease] {
        let limit = ContinuousClock.now + .seconds(30)
        while value.count < count, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(20)) }
        return value
    }
}

/// Opened once by the test; everyone waiting on it carries on.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@Suite struct DebridCacheCheckTests {
    @Test func torBoxListAndObjectAnswers() {
        let list = #"{"success":true,"data":[{"name":"Sintel","size":1,"hash":"AAAA"},{"hash":"bbbb"}]}"#
        #expect(DebridCacheCheck.parseTorBox(Data(list.utf8)) == ["aaaa", "bbbb"])
        let object = #"{"success":true,"data":{"cccc":{"name":"x","size":2,"hash":"cccc"}}}"#
        #expect(DebridCacheCheck.parseTorBox(Data(object.utf8)) == ["cccc"])
        #expect(DebridCacheCheck.parseTorBox(Data(#"{"success":false,"data":null}"#.utf8)).isEmpty)
    }

    @Test func premiumizeParallelArrays() {
        let json = #"{"status":"success","response":[true,false,true],"filename":["a",null,"c"],"filesize":["1",0,"3"]}"#
        #expect(DebridCacheCheck.parsePremiumize(Data(json.utf8), asked: ["h1", "h2", "h3"]) == ["h1", "h3"])
        #expect(DebridCacheCheck.parsePremiumize(Data(#"{"status":"error"}"#.utf8), asked: ["h1"]).isEmpty)
    }

    @Test func requestsFollowTheDocs() throws {
        let tb = DebridCacheCheck.torBoxRequest(["h1", "h2"], key: "K", timeout: 3)
        #expect(tb.url?.absoluteString == "https://api.torbox.app/v1/api/torrents/checkcached?hash=h1,h2&format=list")
        #expect(tb.value(forHTTPHeaderField: "Authorization") == "Bearer K")
        let pm = DebridCacheCheck.premiumizeRequest(["h1", "h2"], key: "K", timeout: 3)
        #expect(pm.httpMethod == "POST")
        let body = String(decoding: try #require(pm.httpBody), as: UTF8.self)
        #expect(body.contains("items%5B%5D=h1") || body.contains("items[]=h1"))
    }

    @Test func confirmedStateOverridesMarkers() {
        let hashA = String(repeating: "a", count: 40), hashB = String(repeating: "b", count: 40)
        let releases = [Make.link("1", "x.1080p", cache: .uncached, hash: hashA),
                        Make.link("2", "y.1080p", cache: .cached, hash: hashB),
                        Make.link("3", "z.1080p", cache: .unknown)]
        let applied = DebridCacheCheck.apply([hashA], checked: [hashA, hashB], to: releases)
        #expect(applied.map(\.cache) == [.cached, .uncached, .unknown])
    }

    @Test func onlyServicesWithAnEndpointAreAsked() async {
        let transport = FakeTransport([:])
        let result = await DebridCacheCheck.cached(["h"], service: .realDebrid, key: "K", client: AddonClient(transport: transport))
        #expect(result == nil)
        #expect(transport.requests.isEmpty)
        let none = await DebridCacheCheck.cached(["h"], service: .allDebrid, key: "K", client: AddonClient(transport: transport))
        #expect(none == nil && transport.requests.isEmpty)
        #expect(DebridProvider.debridLink.canCheckCache && !DebridProvider.allDebrid.canCheckCache)
    }

    @Test func debridLinkAnswersByHash() async throws {
        let json = #"{"success":true,"value":{"AAAA":{"name":"Sintel","files":[{"name":"Sintel.mkv","size":1}]}}}"#
        #expect(DebridCacheCheck.parseDebridLink(Data(json.utf8)) == ["aaaa"])
        // Nothing cached comes back as an empty list, not an object.
        #expect(DebridCacheCheck.parseDebridLink(Data(#"{"success":true,"value":[]}"#.utf8)).isEmpty)
        #expect(DebridCacheCheck.parseDebridLink(Data(#"{"success":false,"error":"badToken"}"#.utf8)).isEmpty)

        let request = DebridCacheCheck.debridLinkRequest(["h1", "h2"], key: "FAKE-KEY", timeout: 3)
        #expect(request.url?.absoluteString == "https://debrid-link.com/api/v2/seedbox/cached?url=h1,h2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer FAKE-KEY")

        let transport = FakeTransport(["debrid-link.com": .init(body: #"{"success":true,"value":{"aaaa":{"name":"x"}}}"#)])
        let found = await DebridCacheCheck.cached(["AAAA", "bbbb"], service: .debridLink, key: "FAKE-KEY",
                                                  client: AddonClient(transport: transport))
        #expect(found == ["aaaa"])
        #expect(transport.requests.count == 1)
    }
}

@Suite struct StremioSourceTests {
    private func source(_ transport: FakeTransport, settings: AddonSettings? = nil, choices: MemoryShowChoiceStore = .init()) -> StremioSource {
        var s = settings ?? AddonSettings()
        if settings == nil {
            s.addons = [InstalledAddon(id: "one", kind: .custom(base: "https://one/x"), name: "One"),
                        InstalledAddon(id: "two", kind: .custom(base: "https://two/x"), name: "Two")]
            s.customLinks = ["one": "https://one/x", "two": "https://two/x"]
            s.hiddenQualities = []
        }
        return StremioSource(settings: s, debridKey: "", imdbID: { key in key.seriesKey != nil ? "tt0944947" : "tt1727587" },
                             client: AddonClient(transport: transport), choices: choices)
    }

    @Test func playAndThePickerShareOneSearch() async throws {
        let transport = FakeTransport(["one": .init(body: StreamFixtures.torrentioMovie),
                                       "two": .init(body: StreamFixtures.stremThruMovie)])
        let s = source(transport)
        let key = MediaKey.movie(tmdbID: 45745)
        await s.prefetch(key)
        let first = try await s.releases(for: key)
        let again = try await s.releases(for: key)
        #expect(first.map(\.id) == again.map(\.id))
        #expect(transport.requests.count == 2)
        _ = try await s.releases(for: key, refresh: true)
        #expect(transport.requests.count == 4)
    }

    @Test func remembersTheGroupPlayedForAShow() async throws {
        let transport = FakeTransport(["one": .init(body: StreamFixtures.torrentioEpisode), "two": .init(body: #"{"streams":[]}"#)])
        let choices = MemoryShowChoiceStore()
        let s = source(transport, choices: choices)
        let e1 = MediaKey.episode(seriesID: 1399, season: 1, episode: 1)
        let found = try await s.releases(for: e1)
        let ntb = try #require(found.first { $0.group == "NTb" })
        await s.remember(ntb, for: e1)
        let e2 = MediaKey.episode(seriesID: 1399, season: 1, episode: 2)
        let choice = await s.showChoice(for: e2)
        #expect(choice?.group == "NTb")
        #expect(choice?.resolution == "1080p")
        #expect(await s.showChoice(for: .movie(tmdbID: 1)) == nil)
    }

    @Test func settingsChangesStartAFreshSearch() async throws {
        let transport = FakeTransport(["one": .init(body: StreamFixtures.torrentioMovie), "two": .init(body: #"{"streams":[]}"#)])
        var settings = AddonSettings()
        settings.addons = [InstalledAddon(id: "one", kind: .custom(base: "https://one/x"), name: "One")]
        settings.customLinks = ["one": "https://one/x", "two": "https://two/x"]
        let s = source(transport, settings: settings)
        let key = MediaKey.movie(tmdbID: 45745)
        _ = try await s.releases(for: key)
        settings.addons.append(InstalledAddon(id: "two", kind: .custom(base: "https://two/x"), name: "Two"))
        await s.update(settings: settings, debridKey: "")
        _ = try await s.releases(for: key)
        #expect(transport.requests.count == 3)
        // A ranking-only change keeps the cached answer.
        settings.preferredResolution = "720p"
        await s.update(settings: settings, debridKey: "")
        let reranked = try await s.releases(for: key)
        #expect(transport.requests.count == 3)
        #expect(reranked.first?.resolution == "720p")
    }

    @Test func inspectsPastedLinks() async throws {
        let transport = FakeTransport(["addon.example": .init(body: StreamFixtures.torrentioManifest),
                                       "lists.example": .init(body: StreamFixtures.catalogOnlyManifest),
                                       "channels.example": .init(body: StreamFixtures.channelsOnlyManifest),
                                       "broken.example": .init(body: "<html>")])
        let s = source(transport)
        let (base, manifest) = try await s.inspectAddon(link: "stremio://addon.example/cfg/manifest.json")
        #expect(base.absoluteString == "https://addon.example/cfg")
        #expect(manifest.name == "Torrentio")
        #expect(transport.requests.last?.url?.absoluteString == "https://addon.example/cfg/manifest.json")
        #expect(try await s.inspectAddon(link: "https://lists.example/manifest.json").manifest.homeCatalogs.map(\.catalogID) == ["top"])
        await #expect(throws: AddonError.noStreams("Just Channels")) { try await s.inspectAddon(link: "https://channels.example/manifest.json") }
        await #expect(throws: AddonError.invalidManifest) { try await s.inspectAddon(link: "https://broken.example") }
        await #expect(throws: AddonError.invalidAddonURL) { try await s.inspectAddon(link: "hello there") }
    }
}
