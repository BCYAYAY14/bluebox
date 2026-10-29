import Domain
import Foundation

/// Listens to Supabase Realtime for changes to the synced tables, so another
/// device's change shows up within a second or two instead of at the next
/// foreground or poll. It only signals; `SyncEngine` still does the reading,
/// with the same merge rules, so a missed or doubled signal is harmless.
///
/// Speaks Realtime's Phoenix protocol over `URLSessionWebSocketTask` (no SDK):
/// join one channel with `postgres_changes` for each table, heartbeat every
/// 25 s, rejoin with a fresh access token before the old one expires, and
/// reconnect with backoff when the socket drops. Row level security applies:
/// only the signed-in user's changes arrive.
public actor RealtimeListener {
    public enum State: Sendable, Equatable { case stopped, connecting, listening }

    static let tables = ["watch_progress", "watchlist_entries", "profiles", "account_settings"]
    static let topic = "realtime:bluebox-sync"
    static let heartbeatInterval: Duration = .seconds(25)
    /// Rejoin with a fresh token this often (access tokens last an hour).
    static let tokenRefreshInterval: Duration = .seconds(40 * 60)

    let config: SupabaseConfig
    let auth: SupabaseAuth
    let session: URLSession
    let onChange: @Sendable () -> Void
    let onState: @Sendable (State) -> Void

    private var loop: Task<Void, Never>?
    private var ref = 0

    public init(config: SupabaseConfig, auth: SupabaseAuth, session: URLSession = URLSession(configuration: .ephemeral),
                onChange: @escaping @Sendable () -> Void, onState: @escaping @Sendable (State) -> Void = { _ in }) {
        self.config = config; self.auth = auth; self.session = session; self.onChange = onChange; self.onState = onState
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    public func stop() {
        loop?.cancel(); loop = nil
        onState(.stopped)
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            onState(.connecting)
            let started = Date()
            do {
                try await connectAndListen()
            } catch {
                if Task.isCancelled { break }
                Log.sync.notice("Realtime: \(String(describing: error), privacy: .public)")
            }
            if Task.isCancelled { break }
            onState(.connecting)
            // A connection that lasted a while was fine: start backing off again from the bottom.
            failures = Date().timeIntervalSince(started) > 120 ? 1 : failures + 1
            let delay = min(60, 2 << min(failures, 5))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// One connection: join, then read until the socket closes, the token is
    /// due for a refresh, or the task is cancelled.
    private func connectAndListen() async throws {
        let token = try await auth.accessToken()
        let socket = session.webSocketTask(with: Self.socketURL(config))
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        try await send(socket, Self.joinMessage(token: token, ref: nextRef()))
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let self, !Task.isCancelled else { return }
                try? await self.send(socket, Self.heartbeatMessage(ref: await self.nextRef()))
            }
        }
        defer { heartbeat.cancel() }
        let refresh = Task {
            try? await Task.sleep(for: Self.tokenRefreshInterval)
            socket.cancel(with: .normalClosure, reason: nil)  // the outer loop reconnects with a new token
        }
        defer { refresh.cancel() }

        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: continue
            }
            switch Self.classify(data) {
            case .joined:
                onState(.listening)
                onChange()  // anything that changed while not listening
            case .change: onChange()
            case .closed(let why): throw RealtimeError.closed(why)
            case .other: break
            }
        }
    }

    private func nextRef() -> String { ref += 1; return String(ref) }

    private func send(_ socket: URLSessionWebSocketTask, _ message: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    // MARK: Protocol

    static func socketURL(_ config: SupabaseConfig) -> URL {
        var c = URLComponents(url: config.endpoint("realtime/v1/websocket"), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.queryItems = [URLQueryItem(name: "apikey", value: config.publishableKey), URLQueryItem(name: "vsn", value: "1.0.0")]
        return c.url!
    }

    static func joinMessage(token: String, ref: String) -> [String: Any] {
        let changes = tables.map { ["event": "*", "schema": "public", "table": $0] }
        return [
            "topic": topic, "event": "phx_join", "ref": ref, "join_ref": ref,
            "payload": [
                "config": ["broadcast": ["self": false], "presence": ["key": ""], "postgres_changes": changes],
                "access_token": token,
            ] as [String: Any],
        ]
    }

    static func heartbeatMessage(ref: String) -> [String: Any] {
        ["topic": "phoenix", "event": "heartbeat", "payload": [String: Any](), "ref": ref]
    }

    enum Incoming: Equatable { case joined, change, closed(String), other }

    static func classify(_ data: Data) -> Incoming {
        guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = m["event"] as? String else { return .other }
        let payload = m["payload"] as? [String: Any]
        switch event {
        case "postgres_changes":
            return .change
        case "phx_reply":
            guard (m["topic"] as? String) == topic else { return .other }
            if (payload?["status"] as? String) == "ok" {
                // The join reply lists the subscriptions; heartbeat replies come on "phoenix".
                return payload?["response"].flatMap { ($0 as? [String: Any])?["postgres_changes"] } != nil ? .joined : .other
            }
            let reason = ((payload?["response"] as? [String: Any])?["reason"] as? String) ?? "join refused"
            return .closed(reason)
        case "phx_error", "phx_close":
            return (m["topic"] as? String) == topic ? .closed(event) : .other
        case "system":
            // Realtime reports subscription problems (a table missing from the publication) here.
            if (payload?["status"] as? String) == "error" { return .closed((payload?["message"] as? String) ?? "system error") }
            return .other
        default:
            return .other
        }
    }
}

enum RealtimeError: Error, CustomStringConvertible {
    case closed(String)
    var description: String {
        switch self { case .closed(let why): "closed: \(why)" }
    }
}
