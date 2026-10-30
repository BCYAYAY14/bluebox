import Domain
import Foundation
@testable import MediaSources
import Testing

/// Watch progress both ways with Jellyfin and Emby, and Emby's differences
/// (its `/emby` path, auth headers and token parameter), against `FakeJellyfin`.
@Suite struct JellyfinProgressTests {
    static let movie = MediaKey.movie(tmdbID: 603)
    static let pilot = MediaKey.episode(seriesID: 1399, season: 1, episode: 1)

    func signedIn(_ server: FakeJellyfin) async throws -> JellyfinSource {
        let (creds, name) = try await JellyfinSource.signIn(server: "media.example.com", username: "brian", password: "secret",
                                                            http: server, deviceID: "dev-1", expecting: server.flavour)
        #expect(creds.flavour == server.flavour)
        return JellyfinSource(id: SourceID("jf"), name: name, credentials: creds, http: server, deviceID: "dev-1", matcher: nil)
    }

    // MARK: Emby

    @Test func embyIsFoundUnderItsPathAndSignsInWithItsHeaders() async throws {
        let server = FakeJellyfin(); server.flavour = .emby; server.onlyUnderEmbyPath = true
        let (creds, name) = try await JellyfinSource.signIn(server: "media.example.com", username: "brian", password: "secret",
                                                            http: server, deviceID: "dev-1")
        #expect(creds.flavour == .emby)  // from its 4.x version, with no product name sent
        #expect(creds.server.absoluteString == "https://media.example.com/emby")
        #expect(name == "Den")

        let source = JellyfinSource(id: SourceID("emby"), name: name, credentials: creds, http: server, deviceID: "dev-1", matcher: nil)
        #expect(source.kind == .emby)
        let movie = try #require(try await source.variants(for: Self.movie).first)
        let url = try await source.resolve(movie).url
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.path == "/emby/Videos/m1/stream.mp4")
        let q = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value!) })
        #expect(q["api_key"] == "tok" && q["ApiKey"] == nil)

        // Once it was found, every request carried Emby's headers and never Jellyfin's
        // (the first look at the root went out before it knew which server it was).
        let afterFinding = server.requests.filter { $0.url!.path.hasPrefix("/emby/") }
        #expect(afterFinding.count == server.requests.count - 1)
        #expect(afterFinding.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(afterFinding.allSatisfy { $0.value(forHTTPHeaderField: "X-Emby-Authorization")?.hasPrefix("MediaBrowser Client=\"Bluebox\"") == true })
        let signedInRequests = server.requests.filter { $0.url!.path.hasSuffix("/Items") }
        #expect(!signedInRequests.isEmpty)
        #expect(signedInRequests.allSatisfy { $0.value(forHTTPHeaderField: "X-Emby-Token") == "tok" })
    }

    @Test func jellyfinKeepsItsOwnHeaderAndParameter() async throws {
        let server = FakeJellyfin()
        let source = try await signedIn(server)
        #expect(source.kind == .jellyfin)
        let url = try await source.resolve(try #require(try await source.variants(for: Self.movie).first)).url
        #expect(url.query()?.contains("ApiKey=tok") == true)
        #expect(server.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Emby-Authorization") == nil })
    }

    @Test func aServerThatDoesntSayIsWhatTheUserPicked() {
        let silent = JellyfinSource.PublicInfo(ServerName: "Box", Version: nil, ProductName: nil)
        #expect(JellyfinSource.flavour(of: silent, otherwise: .emby) == .emby)
        #expect(JellyfinSource.flavour(of: silent, otherwise: .jellyfin) == .jellyfin)
        let named = JellyfinSource.PublicInfo(ServerName: "Box", Version: "4.8.0.0", ProductName: "Jellyfin Server")
        #expect(JellyfinSource.flavour(of: named, otherwise: .emby) == .jellyfin)
    }

    // MARK: The server's watched state

    @Test(arguments: [JellyfinSource.Flavour.jellyfin, .emby])
    func serversWatchedStateBecomesProgress(_ flavour: JellyfinSource.Flavour) async throws {
        let server = FakeJellyfin(); server.flavour = flavour
        server.userData = [
            "m1": ["Played": true, "PlaybackPositionTicks": 0, "LastPlayedDate": "2024-05-01T20:15:03.1234567Z"],
            "e1": ["Played": false, "PlaybackPositionTicks": 6_000_000_000, "LastPlayedDate": "2024-05-02T08:00:00.0000000Z"],
        ]
        let source = try await signedIn(server)
        let handled = Handled()
        await source.setProgressHandler { records in await handled.set(records) }

        let progress = Dictionary(uniqueKeysWithValues: try await source.watchProgress().map { ($0.key, $0) })
        #expect(progress.count == 2)
        let movie = try #require(progress[Self.movie])
        #expect(movie.isCompleted)
        #expect(abs(movie.updatedAt.timeIntervalSince1970 - 1_714_594_503.1234567) < 0.001)
        #expect(movie.position == 8160)  // the whole runtime
        let pilot = try #require(progress[Self.pilot])
        #expect(!pilot.isCompleted && pilot.position == 600)

        // The library load handed the same records to the app.
        try await waitUntil { await handled.records.count == 2 }
        #expect(Set(await handled.records.map(\.key)) == [Self.movie, Self.pilot])
        // The item list asked for user data; the series list didn't need it.
        let items = server.requests.filter { $0.url!.path.hasSuffix("/Items") }.map { $0.url!.query() ?? "" }
        #expect(items.contains { $0.contains("includeItemTypes=Movie") && $0.contains("enableUserData=true") })
        #expect(items.contains { $0.contains("includeItemTypes=Series") && $0.contains("enableUserData=false") })
    }

    @Test func aResumePointWithoutADateIsLeftOut() {
        let undated = JellyfinSource.UserState(position: 300, played: false, lastPlayed: nil)
        #expect(JellyfinSource.progress(undated, key: Self.movie, duration: 6000) == nil)
        // A played item without a date still counts, dated so anything Bluebox knows wins.
        let played = JellyfinSource.UserState(position: 0, played: true, lastPlayed: nil)
        let p = try? #require(JellyfinSource.progress(played, key: Self.movie, duration: 6000))
        #expect(p?.isCompleted == true && p?.updatedAt == Date(timeIntervalSince1970: 0))
    }

    @Test func serverProgressAppliesOnlyWhenNewerAndDifferent() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let local = WatchProgress(key: Self.movie, position: 1200, duration: 6000, updatedAt: t, deviceID: "mac")
        let newerFinished = WatchProgress(key: Self.movie, position: 6000, duration: 6000, isCompleted: true,
                                          updatedAt: t.addingTimeInterval(60), deviceID: "server")
        let olderFinished = WatchProgress(key: Self.movie, position: 6000, duration: 6000, isCompleted: true,
                                          updatedAt: t.addingTimeInterval(-60), deviceID: "server")
        let echo = WatchProgress(key: Self.movie, position: 1203, duration: 6000, updatedAt: t.addingTimeInterval(5), deviceID: "server")
        let further = WatchProgress(key: Self.movie, position: 2400, duration: 6000, updatedAt: t.addingTimeInterval(600), deviceID: "server")
        #expect(JellyfinSource.shouldApply(newerFinished, over: nil))
        #expect(JellyfinSource.shouldApply(newerFinished, over: local))
        #expect(!JellyfinSource.shouldApply(olderFinished, over: local))
        #expect(!JellyfinSource.shouldApply(echo, over: local))  // our own report coming back
        #expect(JellyfinSource.shouldApply(further, over: local))
    }

    @Test(arguments: [JellyfinSource.Flavour.jellyfin, .emby])
    func titlePageRefreshFetchesJustThatTitle(_ flavour: JellyfinSource.Flavour) async throws {
        let server = FakeJellyfin(); server.flavour = flavour
        let source = try await signedIn(server)
        #expect(try await source.watchProgress().isEmpty)
        // Watched on the server's own app since the library loaded.
        server.userData["m1"] = ["Played": true, "LastPlayedDate": "2024-06-01T10:00:00Z"]
        let fresh = await source.refreshWatchProgress(for: Self.movie)
        #expect(fresh.map(\.key) == [Self.movie] && fresh.first?.isCompleted == true)
        #expect(server.requests.last { $0.url!.path.hasSuffix("/Items") }?.url!.query()?.contains("ids=m1") == true)
        #expect(try await source.watchProgress().map(\.key) == [Self.movie])  // kept for the next read
    }

    // MARK: Marking watched

    @Test(arguments: [JellyfinSource.Flavour.jellyfin, .emby])
    func marksPlayedAndUnplayed(_ flavour: JellyfinSource.Flavour) async throws {
        let server = FakeJellyfin(); server.flavour = flavour
        let source = try await signedIn(server)
        await source.setPlayed(Self.movie, true)
        let post = try #require(server.requests.last { $0.url!.path.contains("PlayedItems") })
        #expect(post.httpMethod == "POST" && post.url!.path == "/Users/u1/PlayedItems/m1")
        #expect(server.userData["m1"]?["Played"] as? Bool == true)
        #expect(try await source.watchProgress().first { $0.key == Self.movie }?.isCompleted == true)

        await source.setPlayed(Self.movie, false)
        let delete = try #require(server.requests.last { $0.url!.path.contains("PlayedItems") })
        #expect(delete.httpMethod == "DELETE" && delete.url!.path == "/Users/u1/PlayedItems/m1")
        #expect(server.userData["m1"]?["Played"] as? Bool == false)
        #expect(try await source.watchProgress().allSatisfy { $0.key != Self.movie })
    }

    @Test func jellyfinFallsBackToItsNewerPlayedRoute() async throws {
        let server = FakeJellyfin(); server.onlyNewPlayedRoute = true
        let source = try await signedIn(server)
        await source.setPlayed(Self.pilot, true)
        let req = try #require(server.requests.last { $0.url!.path.contains("PlayedItems") })
        #expect(req.url!.path == "/UserPlayedItems/e1" && req.url!.query() == "userId=u1")
        #expect(server.userData["e1"]?["Played"] as? Bool == true)
    }

    @Test func embyUnplaysByPostWhenDeleteIsTurnedAway() async throws {
        let server = FakeJellyfin(); server.flavour = .emby; server.refusesDelete = true
        server.userData["m1"] = ["Played": true]
        let source = try await signedIn(server)
        await source.setPlayed(Self.movie, false)
        let req = try #require(server.requests.last { $0.url!.path.contains("PlayedItems") })
        #expect(req.httpMethod == "POST" && req.url!.path == "/Users/u1/PlayedItems/m1/Delete")
        #expect(server.userData["m1"]?["Played"] as? Bool == false)
    }

    // MARK: Reporting playback

    @Test(arguments: [JellyfinSource.Flavour.jellyfin, .emby])
    func reportsProgressWhilePlayingThenStopped(_ flavour: JellyfinSource.Flavour) async throws {
        let server = FakeJellyfin(); server.flavour = flavour
        let source = try await signedIn(server)
        _ = try await source.catalog()  // playing from the library, so it's loaded
        await source.reportProgress(itemID: "m1", position: 30, isPaused: false, stopped: false)
        let progress = try #require(server.requests.last { $0.url!.path == "/Sessions/Playing/Progress" })
        let body = try #require(try JSONSerialization.jsonObject(with: progress.httpBody!) as? [String: Any])
        #expect(body["PositionTicks"] as? Int == 300_000_000)
        #expect(body["IsPaused"] as? Bool == false && body["ItemId"] as? String == "m1")
        switch flavour {
        case .jellyfin: #expect(progress.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"tok\"") == true)
        case .emby: #expect(progress.value(forHTTPHeaderField: "X-Emby-Token") == "tok")
        }

        await source.reportProgress(itemID: "m1", position: 95, isPaused: true, stopped: true)
        let stopped = try #require(server.requests.last { $0.url!.path == "/Sessions/Playing/Stopped" })
        let stoppedBody = try #require(try JSONSerialization.jsonObject(with: stopped.httpBody!) as? [String: Any])
        #expect(stoppedBody["PositionTicks"] as? Int == 950_000_000)
        // What Bluebox reported is what the source now holds, so it isn't taken back as news.
        let held = try #require(try await source.watchProgress().first { $0.key == Self.movie })
        #expect(held.position == 95 && !held.isCompleted)
    }

    @Test func parsesDotNetDates() {
        #expect(JellyfinSource.UserState.parseDate("2024-05-01T20:15:03.1234567Z")?.timeIntervalSince1970 ?? 0 > 1_714_594_503.12)
        #expect(JellyfinSource.UserState.parseDate("2024-05-01T20:15:03Z")?.timeIntervalSince1970 == 1_714_594_503)
        #expect(JellyfinSource.UserState.parseDate("2024-05-01T20:15:03.5+00:00")?.timeIntervalSince1970 == 1_714_594_503.5)
        #expect(JellyfinSource.UserState.parseDate("2024-05-01T20:15:03") != nil)  // Emby sometimes leaves the zone off
        #expect(JellyfinSource.UserState.parseDate("yesterday") == nil)
    }
}

private actor Handled {
    var records: [WatchProgress] = []
    func set(_ r: [WatchProgress]) { records = r }
}

private func waitUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}
