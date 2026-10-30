import Domain
import Foundation
import Metadata
@testable import Persistence
@testable import Sync
import Testing
import TestingSupport

/// In-memory Trakt: device auth, watchlist, watched history.
final class FakeTrakt: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    var approveAfterPolls = 1
    private var polls = 0
    var watchlist: [(type: String, tmdb: Int, title: String)] = []
    var watchedMovies: [Int: String] = [:]
    var watchedEpisodes: [Int: [(season: Int, episode: Int, at: String)]] = [:]
    private(set) var log: [String] = []
    private(set) var historyBodies: [[String: Any]] = []
    var expireAccessToken = false

    static let config = TraktConfig(clientID: "cid", clientSecret: "secret", baseURL: URL(string: "https://trakt.test")!)!

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock { handle(request) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func entries(_ prefix: String) -> [String] { lock.withLock { log.filter { $0.hasPrefix(prefix) } } }

    private func json(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

    private func handle(_ req: URLRequest) -> (Int, Data) {
        let path = req.url!.path, method = req.httpMethod ?? "GET"
        log.append("\(method) \(path)")
        guard req.value(forHTTPHeaderField: "trakt-api-key") == "cid",
              req.value(forHTTPHeaderField: "trakt-api-version") == "2" else { return (403, Data()) }
        let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        switch path {
        case "/oauth/device/code":
            return (200, json(["device_code": "dev", "user_code": "ABCD1234", "verification_url": "https://trakt.tv/activate",
                               "expires_in": 600, "interval": 5]))
        case "/oauth/device/token":
            polls += 1
            guard polls > approveAfterPolls else { return (400, Data()) }
            return (200, json(["access_token": "tok", "refresh_token": "ref", "expires_in": 86400,
                               "created_at": Int(Date().timeIntervalSince1970)]))
        case "/oauth/token":
            guard body["refresh_token"] as? String == "ref" else { return (401, Data()) }
            expireAccessToken = false
            return (200, json(["access_token": "tok2", "refresh_token": "ref", "expires_in": 86400,
                               "created_at": Int(Date().timeIntervalSince1970)]))
        case "/oauth/revoke":
            return (200, Data())
        default: break
        }
        let auth = req.value(forHTTPHeaderField: "Authorization")
        guard auth == "Bearer tok" || auth == "Bearer tok2", !(expireAccessToken && auth == "Bearer tok") else { return (401, Data()) }
        switch (method, path) {
        case ("GET", "/users/settings"):
            return (200, json(["user": ["username": "cinephile"]]))
        case ("GET", "/sync/watchlist/movies"), ("GET", "/sync/watchlist/shows"):
            let type = path.hasSuffix("movies") ? "movie" : "show"
            return (200, json(watchlist.filter { $0.type == type }.map {
                ["type": $0.type, $0.type: ["title": $0.title, "year": 2020, "ids": ["tmdb": $0.tmdb]]]
            }))
        case ("POST", "/sync/watchlist"), ("POST", "/sync/watchlist/remove"):
            let add = path == "/sync/watchlist"
            for (field, type) in [("movies", "movie"), ("shows", "show")] {
                for item in body[field] as? [[String: Any]] ?? [] {
                    guard let id = (item["ids"] as? [String: Any])?["tmdb"] as? Int else { continue }
                    watchlist.removeAll { $0.type == type && $0.tmdb == id }
                    if add { watchlist.append((type, id, "Added \(id)")) }
                }
            }
            return (201, json([:]))
        case ("GET", "/sync/watched/movies"):
            return (200, json(watchedMovies.map { ["plays": 1, "last_watched_at": $0.value, "movie": ["title": "M", "ids": ["tmdb": $0.key]]] }))
        case ("GET", "/sync/watched/shows"):
            return (200, json(watchedEpisodes.map { id, eps in
                let seasons = Dictionary(grouping: eps, by: \.season).map { s, list in
                    ["number": s, "episodes": list.map { ["number": $0.episode, "plays": 1, "last_watched_at": $0.at] }] as [String: Any]
                }
                return ["plays": eps.count, "show": ["title": "S", "ids": ["tmdb": id]], "seasons": seasons] as [String: Any]
            }))
        case ("POST", "/sync/history"):
            historyBodies.append(body)
            for m in body["movies"] as? [[String: Any]] ?? [] {
                if let id = (m["ids"] as? [String: Any])?["tmdb"] as? Int { watchedMovies[id] = m["watched_at"] as? String }
            }
            return (201, json([:]))
        case ("POST", "/sync/history/remove"):
            removalBodies.append(body)
            for m in body["movies"] as? [[String: Any]] ?? [] {
                if let id = (m["ids"] as? [String: Any])?["tmdb"] as? Int { watchedMovies[id] = nil }
            }
            return (200, json([:]))
        case ("GET", "/sync/ratings/movies"):
            return (200, json(movieRatings.map { ["rated_at": $0.value.at, "rating": $0.value.rating, "type": "movie",
                                                  "movie": ["title": "M", "ids": ["tmdb": $0.key]]] }))
        case ("GET", "/sync/ratings/shows"), ("GET", "/sync/ratings/episodes"):
            return (200, json([]))
        case ("POST", "/sync/ratings"), ("POST", "/sync/ratings/remove"):
            let add = path == "/sync/ratings"
            ratingBodies.append(body)
            for m in body["movies"] as? [[String: Any]] ?? [] {
                guard let id = (m["ids"] as? [String: Any])?["tmdb"] as? Int else { continue }
                if add, let r = m["rating"] as? Int { movieRatings[id] = (r, m["rated_at"] as? String ?? "") } else { movieRatings[id] = nil }
            }
            return (201, json([:]))
        case ("GET", "/users/me/lists"):
            return (200, json(customLists.map { ["name": $0.name, "privacy": "private", "ids": ["trakt": $0.id, "slug": "s\($0.id)"]] }))
        case ("POST", "/users/me/lists"):
            let id = (customLists.map(\.id).max() ?? 100) + 1
            customLists.append((id, body["name"] as? String ?? "", []))
            listBodies.append(body)
            return (201, json(["name": body["name"] ?? "", "privacy": body["privacy"] ?? "", "ids": ["trakt": id, "slug": "s\(id)"]]))
        case (_, let p) where p.hasPrefix("/users/me/lists/"):
            let parts = p.split(separator: "/")  // users, me, lists, id, items[, remove]
            guard parts.count >= 5, let id = Int(parts[3]), let i = customLists.firstIndex(where: { $0.id == id }) else { return (404, Data()) }
            if method == "GET" {
                return (200, json(customLists[i].items.map {
                    ["type": $0.type, $0.type: ["title": $0.title, "year": 2020, "ids": ["tmdb": $0.tmdb]]]
                } + [["type": "person", "person": ["name": "Somebody", "ids": ["trakt": 1]]]]))
            }
            let add = parts.count == 5
            for (field, type) in [("movies", "movie"), ("shows", "show")] {
                for item in body[field] as? [[String: Any]] ?? [] {
                    guard let tmdb = (item["ids"] as? [String: Any])?["tmdb"] as? Int else { continue }
                    customLists[i].items.removeAll { $0.type == type && $0.tmdb == tmdb }
                    if add { customLists[i].items.append((type, tmdb, "Added \(tmdb)")) }
                }
            }
            return (201, json([:]))
        case ("POST", let p) where p.hasPrefix("/scrobble/"):
            if failScrobbles { return (503, Data()) }
            scrobbles.append((String(p.dropFirst("/scrobble/".count)), body))
            return (201, json([:]))
        default:
            return (404, Data())
        }
    }

    var movieRatings: [Int: (rating: Int, at: String)] = [:]
    private(set) var ratingBodies: [[String: Any]] = []
    private(set) var removalBodies: [[String: Any]] = []
    private(set) var scrobbles: [(action: String, body: [String: Any])] = []
    var failScrobbles = false
    var customLists: [(id: Int, name: String, items: [(type: String, tmdb: Int, title: String)])] = []
    private(set) var listBodies: [[String: Any]] = []
}

@Suite struct WatchlistReconcileTests {
    let a = MediaKey.movie(tmdbID: 1), b = MediaKey.movie(tmdbID: 2), c = MediaKey.series(tmdbID: 3), d = MediaKey.movie(tmdbID: 4)

    @Test func firstSyncOnlyAdds() {
        let p = WatchlistReconcile.plan(local: [a, b], remote: [b, c], base: nil)
        #expect(p.addRemote == [a])
        #expect(p.addLocal == [c])
        #expect(p.removeLocal.isEmpty && p.removeRemote.isEmpty)
        #expect(p.agreed == [a, b, c])
    }

    @Test func removalsOnEitherSideCarryOver() {
        // Base {a, b, c}. Local removed b and added d; Trakt removed c.
        let p = WatchlistReconcile.plan(local: [a, c, d], remote: [a, b], base: [a, b, c])
        #expect(p.addRemote == [d])
        #expect(p.removeRemote == [b])
        #expect(p.removeLocal == [c])
        #expect(p.addLocal.isEmpty)
        #expect(p.agreed == [a, d])
    }
}

@Suite struct TraktTests {
    static func make(_ server: FakeTrakt, secrets: MemorySecretStore = MemorySecretStore())
        throws -> (TraktClient, TraktSync, LibraryStore, PreferencesStore) {
        let client = TraktClient(config: FakeTrakt.config, http: server, secrets: secrets, sleep: { _ in })
        let store = try LibraryStore.make(inMemory: true)
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "trakt.\(UUID().uuidString)")!)
        return (client, TraktSync(client: client, store: store, prefs: prefs), store, prefs)
    }

    static func connect(_ client: TraktClient) async throws {
        let code = try await client.startDeviceAuth()
        try await client.waitForAuthorization(code)
    }

    @Test func deviceFlowStoresTokensAndUsername() async throws {
        let server = FakeTrakt(), secrets = MemorySecretStore()
        server.approveAfterPolls = 2
        let (client, _, _, _) = try Self.make(server, secrets: secrets)
        let code = try await client.startDeviceAuth()
        #expect(code.userCode == "ABCD1234")
        try await client.waitForAuthorization(code)
        #expect(await client.isConnected)
        #expect(await client.username == "cinephile")
        #expect(server.entries("POST /oauth/device/token").count == 3)
        #expect(try secrets.read(SecretAccount.traktTokens)?.contains("tok") == true)

        await client.disconnect()
        #expect(await !client.isConnected)
        #expect(try secrets.read(SecretAccount.traktTokens) == nil)
    }

    @Test func expiredAccessTokenIsRefreshed() async throws {
        let server = FakeTrakt()
        let (client, sync, _, _) = try Self.make(server)
        try await Self.connect(client)
        server.expireAccessToken = true
        try await sync.sync()
        #expect(server.entries("POST /oauth/token").count == 1)
    }

    @Test func watchlistMergesBothWaysThenCarriesRemovals() async throws {
        let server = FakeTrakt()
        server.watchlist = [("movie", 10, "Remote Movie"), ("show", 20, "Remote Show")]
        let (client, sync, store, _) = try Self.make(server)
        try await Self.connect(client)
        let localOnly = Title(key: .movie(tmdbID: 30), kind: .movie, name: "Local Movie")
        try await store.setWatchlisted(localOnly, true)

        try await sync.sync()
        #expect(Set(try await store.watchlist().map(\.key)) == [.movie(tmdbID: 10), .series(tmdbID: 20), .movie(tmdbID: 30)])
        #expect(Set(server.watchlist.map(\.tmdb)) == [10, 20, 30])
        // The bare title from Trakt was used when nothing better was available.
        #expect(try await store.watchlist().first { $0.key == .movie(tmdbID: 10) }?.name == "Remote Movie")

        // Removed here → removed on Trakt; removed on Trakt → removed here.
        try await store.setWatchlisted(localOnly, false)
        server.watchlist.removeAll { $0.tmdb == 20 }
        try await sync.sync()
        #expect(try await store.watchlist().map(\.key) == [.movie(tmdbID: 10)])
        #expect(server.watchlist.map(\.tmdb) == [10])
    }

    // MARK: Custom lists

    @Test func listsDontSyncUnlessTurnedOn() async throws {
        let server = FakeTrakt()
        let (client, sync, store, _) = try Self.make(server)
        try await Self.connect(client)
        try await store.createList(name: "Halloween")
        try await sync.sync()
        #expect(server.entries("GET /users/me/lists").isEmpty && server.customLists.isEmpty)
    }

    @Test func listsAreCreatedOnTraktThenMergeBothWays() async throws {
        let server = FakeTrakt()
        let (client, sync, store, prefs) = try Self.make(server)
        try await Self.connect(client)
        prefs.set(true, for: TraktSync.syncListsKey)
        let list = try await store.createList(name: "Halloween")
        let local = Title(key: .movie(tmdbID: 30), kind: .movie, name: "Local Movie")
        try await store.setOnList(local, listID: list.id, true)

        try await sync.sync()
        #expect(server.customLists.count == 1 && server.customLists[0].name == "Halloween")
        #expect(server.listBodies.first?["privacy"] as? String == "private")
        #expect(server.customLists[0].items.map(\.tmdb) == [30])

        // Added on Trakt → added here; removed here → removed on Trakt.
        server.customLists[0].items.append(("show", 20, "Remote Show"))
        try await sync.sync()
        #expect(Set(try await store.entries(in: list.id).map(\.key)) == [.movie(tmdbID: 30), .series(tmdbID: 20)])
        #expect(try await store.entries(in: list.id).first { $0.key == .series(tmdbID: 20) }?.title.name == "Remote Show")
        try await store.setOnList(local, listID: list.id, false)
        try await sync.sync()
        #expect(server.customLists[0].items.map(\.tmdb) == [20])

        // Removed on Trakt → removed here. Still the one Trakt list.
        server.customLists[0].items.removeAll()
        try await sync.sync()
        #expect(try await store.entries(in: list.id).isEmpty)
        #expect(server.customLists.count == 1)
    }

    @Test func aListOfTheSameNameOnTraktIsAdoptedAndAddsOnly() async throws {
        let server = FakeTrakt()
        server.customLists = [(5, "Halloween", [("movie", 10, "Remote Movie")])]
        let (client, sync, store, prefs) = try Self.make(server)
        try await Self.connect(client)
        prefs.set(true, for: TraktSync.syncListsKey)
        let list = try await store.createList(name: "Halloween")
        try await store.setOnList(Title(key: .movie(tmdbID: 30), kind: .movie, name: "Local"), listID: list.id, true)

        try await sync.sync()
        #expect(server.listBodies.isEmpty)  // nothing created
        #expect(Set(server.customLists[0].items.map(\.tmdb)) == [10, 30])
        #expect(Set(try await store.entries(in: list.id).map(\.key)) == [.movie(tmdbID: 10), .movie(tmdbID: 30)])
    }

    @Test func deletingAListOnEitherSideNeverDeletesTheOther() async throws {
        let server = FakeTrakt()
        let (client, sync, store, prefs) = try Self.make(server)
        try await Self.connect(client)
        prefs.set(true, for: TraktSync.syncListsKey)
        let kept = try await store.createList(name: "Kept")
        let gone = try await store.createList(name: "Gone Here")
        try await store.setOnList(Title(key: .movie(tmdbID: 30), kind: .movie, name: "Local"), listID: kept.id, true)
        try await sync.sync()
        #expect(server.customLists.count == 2)

        // Deleted on Trakt: made again, and nothing here is removed.
        server.customLists.removeAll { $0.name == "Kept" }
        try await store.removeList(gone.id)
        try await sync.sync()
        #expect(Set(server.customLists.map(\.name)) == ["Kept", "Gone Here"])
        #expect(server.customLists.first { $0.name == "Kept" }?.items.map(\.tmdb) == [30])
        #expect(try await store.entries(in: kept.id).map(\.key) == [.movie(tmdbID: 30)])
    }

    @Test func historyImportsWatchedAndPushesNewlyFinished() async throws {
        let server = FakeTrakt()
        server.watchedMovies = [10: "2026-01-02T03:04:05.000Z"]
        server.watchedEpisodes = [20: [(1, 1, "2026-01-03T00:00:00.000Z"), (1, 2, "2026-01-04T00:00:00.000Z")]]
        let (client, sync, store, _) = try Self.make(server)
        try await Self.connect(client)
        // Finished here, unknown to Trakt.
        try await store.save(WatchProgress(key: .movie(tmdbID: 40), position: 100, duration: 100, isCompleted: true,
                                           updatedAt: Date(timeIntervalSince1970: 1_790_000_000)))
        // In progress here, newer than Trakt's play: the rewatch wins.
        try await store.save(WatchProgress(key: .episode(seriesID: 20, season: 1, episode: 2), position: 50, duration: 1000,
                                           updatedAt: Date(timeIntervalSince1970: 1_795_000_000)))

        let report = try await sync.sync()
        #expect(try await store.progress(for: .movie(tmdbID: 10))?.isCompleted == true)
        #expect(try await store.progress(for: .episode(seriesID: 20, season: 1, episode: 1))?.isCompleted == true)
        #expect(try await store.progress(for: .episode(seriesID: 20, season: 1, episode: 2))?.isCompleted == false)
        #expect(report.applied == 2)
        // Imported items are queued for cloud sync too.
        #expect(try await store.pendingUploads().contains { $0.key == .movie(tmdbID: 10) })

        // Only the locally finished movie went to Trakt.
        #expect(server.historyBodies.count == 1)
        let movies = server.historyBodies[0]["movies"] as? [[String: Any]]
        #expect(movies?.count == 1)
        #expect((movies?.first?["ids"] as? [String: Any])?["tmdb"] as? Int == 40)

        // Nothing new: no second push.
        try await sync.sync()
        #expect(server.historyBodies.count == 1)
    }

    @Test func historyBodyGroupsEpisodesByShowAndSeason() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let body = TraktHistory([
            WatchProgress(key: .episode(seriesID: 5, season: 2, episode: 1), position: 1, duration: 1, isCompleted: true, updatedAt: at),
            WatchProgress(key: .episode(seriesID: 5, season: 1, episode: 3), position: 1, duration: 1, isCompleted: true, updatedAt: at),
            WatchProgress(key: .episode(seriesID: 5, season: 2, episode: 2), position: 1, duration: 1, isCompleted: true, updatedAt: at),
            WatchProgress(key: .movie(tmdbID: 9), position: 1, duration: 1, isCompleted: true, updatedAt: at),
        ])
        #expect(body.movies.map(\.ids.tmdb) == [9])
        #expect(body.shows.count == 1)
        #expect(body.shows[0].seasons.map(\.number) == [1, 2])
        #expect(body.shows[0].seasons[1].episodes.map(\.number) == [1, 2])
        #expect(body.movies[0].watched_at == "2026-09-21T14:13:20.000Z")
    }
}
