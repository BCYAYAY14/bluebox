import Domain
import Foundation
import MediaSources
import Metadata
import Persistence

// WebDAV folders and Plex servers, set up in Settings › Sources. Like
// Jellyfin, the secret (WebDAV password, Plex token) is kept in the Keychain
// under the source's ID and the configuration holds the rest.
extension AppModel {
    /// Lists the WebDAV folder to check the address and login, then adds it.
    public func addWebDAV(server: String, username: String, password: String) async throws {
        let (creds, name) = try await WebDAVSource.connect(server: server, username: username, password: password, http: http)
        let id = SourceID("webdav-\(UUID().uuidString.prefix(8))")
        try secrets.write(creds.password, for: SecretAccount.source(id.rawValue))
        let config = SourceConfiguration(id: id, kind: .webdav, name: name, settings: [
            "server": creds.server.absoluteString, "username": creds.username,
        ])
        await addNetworkSource(config, webDAVSource(config))
    }

    /// Adds a Plex server by address and token.
    public func addPlex(server: String, token: String) async throws {
        let (creds, name) = try await PlexSource.connect(server: server, token: token, http: http, clientID: prefs.deviceID)
        try await addPlex(creds, name: name)
    }

    /// Starts plex.tv sign-in: the user approves the PIN at its `authURL`.
    public func startPlexSignIn() async throws -> PlexSource.PIN {
        try await PlexSource.startPIN(http: http, clientID: prefs.deviceID)
    }

    /// Waits for the PIN to be approved (up to `timeout`), then adds the
    /// account's server. Returns false if it wasn't approved in time.
    public func finishPlexSignIn(_ pin: PlexSource.PIN, timeout: Duration = .seconds(300)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let token = try await PlexSource.checkPIN(pin, http: http, clientID: prefs.deviceID) {
                let (creds, name) = try await PlexSource.discoverServer(accountToken: token, http: http, clientID: prefs.deviceID)
                try await addPlex(creds, name: name)
                return true
            }
            try await Task.sleep(for: .seconds(2))
        }
        return false
    }

    private func addPlex(_ creds: PlexSource.Credentials, name: String) async throws {
        let id = SourceID("plex-\(UUID().uuidString.prefix(8))")
        try secrets.write(creds.token, for: SecretAccount.source(id.rawValue))
        let config = SourceConfiguration(id: id, kind: .plex, name: name, settings: [
            "server": creds.server.absoluteString, "machineID": creds.machineID,
        ])
        await addNetworkSource(config, plexSource(config))
    }

    func webDAVSource(_ config: SourceConfiguration) -> WebDAVSource? {
        guard let server = config.settings["server"].flatMap(URL.init(string:)),
              let password = (try? secrets.read(SecretAccount.source(config.id.rawValue))).flatMap({ $0 }) else { return nil }
        let creds = WebDAVSource.Credentials(server: server, username: config.settings["username"] ?? "", password: password)
        return WebDAVSource(id: config.id, name: config.name, credentials: creds, http: http, matcher: makeMatcher())
    }

    func plexSource(_ config: SourceConfiguration) -> PlexSource? {
        guard let server = config.settings["server"].flatMap(URL.init(string:)),
              let token = (try? secrets.read(SecretAccount.source(config.id.rawValue))).flatMap({ $0 }) else { return nil }
        let creds = PlexSource.Credentials(server: server, token: token, machineID: config.settings["machineID"] ?? "")
        return PlexSource(id: config.id, name: config.name, credentials: creds, http: http, clientID: prefs.deviceID, matcher: makeMatcher())
    }
}
