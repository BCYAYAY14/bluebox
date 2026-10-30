import Domain
@testable import Features
import Foundation
import MediaSources
import Metadata
import Persistence
import Testing

/// A Jellyfin or Emby server holding one film, The Matrix, with this user's state.
private final class OneFilmServer: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _state: [String: Any] = [:]
    var requests: [URLRequest] { lock.withLock { _requests } }
    var state: [String: Any] {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(r) }
        let path = r.url!.path
        var body = Data(), status = 200
        if path.hasSuffix("/Items") {
            let series = r.url!.query()?.contains("includeItemTypes=Series") == true
            let film: [String: Any] = ["Id": "m1", "Name": "The Matrix", "Type": "Movie", "ProviderIds": ["Tmdb": "603"],
                                       "RunTimeTicks": 81_600_000_000, "UserData": state,
                                       "MediaSources": [["Id": "ms1", "Container": "mp4"]]]
            body = try JSONSerialization.data(withJSONObject: ["Items": series ? [] : [film]])
        } else if path.contains("/PlayedItems/") {
            state = ["Played": r.httpMethod == "POST", "PlaybackPositionTicks": 0]
        } else if !path.hasPrefix("/Sessions/Playing") {
            status = 404
        }
        return (body, HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
@Suite struct MediaServerSyncTests {
    static let matrix = MediaKey.movie(tmdbID: 603)

    func model() throws -> AppModel {
        AppModel(store: try LibraryStore.make(inMemory: true), secrets: MemorySecretStore(),
                 prefs: PreferencesStore(defaults: UserDefaults(suiteName: "servers.\(UUID().uuidString)")!), forceSample: true)
    }

    fileprivate func server(_ app: AppModel, _ http: OneFilmServer, _ flavour: JellyfinSource.Flavour) async -> JellyfinSource {
        let creds = JellyfinSource.Credentials(server: URL(string: "https://media.example.com")!, userID: "u1",
                                               accessToken: "not-a-real-token", username: "test", flavour: flavour)
        let source = JellyfinSource(id: SourceID("server-\(flavour.rawValue)"), name: "Test", credentials: creds, http: http,
                                    deviceID: "dev-1", matcher: nil)
        await app.register(source)
        return source
    }

    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test(arguments: [JellyfinSource.Flavour.jellyfin, .emby])
    func watchingOnTheServerComesInWhenItsLibraryLoads(_ flavour: JellyfinSource.Flavour) async throws {
        let app = try model(), http = OneFilmServer()
        http.state = ["Played": true, "LastPlayedDate": "2024-05-01T20:15:03.1234567Z"]
        let source = await server(app, http, flavour)
        _ = try await source.catalog()
        #expect(await eventually { (try? await app.store.progress(for: Self.matrix))?.isCompleted == true })
        #expect(try await app.store.progress(for: Self.matrix)?.duration == 8160)
    }

    @Test func newerWatchingHereIsntOverwrittenByTheServer() async throws {
        let app = try model(), http = OneFilmServer()
        // Resumed here this year; the server last saw it in 2024.
        _ = try await app.store.save(WatchProgress(key: Self.matrix, position: 1200, duration: 8160, updatedAt: .now, deviceID: "mac"))
        http.state = ["Played": false, "PlaybackPositionTicks": 300_000_000, "LastPlayedDate": "2024-05-01T20:15:03Z"]
        let source = await server(app, http, .jellyfin)
        let records = try await source.watchProgress()
        await app.applyServerProgress(records)
        #expect(try await app.store.progress(for: Self.matrix)?.position == 1200)
    }

    @Test(arguments: [JellyfinSource.Flavour.jellyfin, .emby])
    func markingWatchedHereReachesTheServerBothWays(_ flavour: JellyfinSource.Flavour) async throws {
        let app = try model(), http = OneFilmServer()
        _ = await server(app, http, flavour)
        try await app.setWatched(Self.matrix, true)
        #expect(await eventually { http.state["Played"] as? Bool == true })
        #expect(http.requests.last { $0.url!.path.contains("PlayedItems") }?.httpMethod == "POST")

        try await app.setWatched(Self.matrix, false)
        #expect(await eventually { http.state["Played"] as? Bool == false })
        #expect(http.requests.last { $0.url!.path.contains("PlayedItems") }?.httpMethod == "DELETE")
    }

    @Test func aTurnedOffServerIsLeftAlone() async throws {
        let app = try model(), http = OneFilmServer()
        let source = await server(app, http, .jellyfin)
        await app.registry.setEnabled(false, for: source.id)
        try await app.setWatched(Self.matrix, true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!http.requests.contains { $0.url!.path.contains("PlayedItems") })
    }
}
