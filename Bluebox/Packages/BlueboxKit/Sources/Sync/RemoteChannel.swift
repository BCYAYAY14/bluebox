import Domain
import Foundation

/// The remote-control channel: Supabase Realtime broadcast, one topic per
/// account (`bluebox-remote:<user id>`), so only devices signed in to the
/// same account hear each other. Phoenix over `URLSessionWebSocketTask`, like
/// `RealtimeListener`, which it borrows the socket URL and heartbeat from.
///
/// Broadcast isn't stored: a message sent while nobody listens is gone. The
/// protocol is built for that (state is re-published, commands time out in
/// `RemoteReconciler`), so sends while reconnecting are simply dropped.
public actor RemoteChannel {
    public enum State: Sendable, Equatable { case stopped, connecting, joined }

    static let event = "remote"

    let config: SupabaseConfig
    let auth: SupabaseAuth
    let session: URLSession
    let onMessage: @Sendable (RemoteMessage) -> Void
    let onState: @Sendable (State) -> Void

    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var topic: String?
    private var joined = false
    private var ref = 0

    public init(config: SupabaseConfig, auth: SupabaseAuth, session: URLSession = URLSession(configuration: .ephemeral),
                onMessage: @escaping @Sendable (RemoteMessage) -> Void, onState: @escaping @Sendable (State) -> Void = { _ in }) {
        self.config = config; self.auth = auth; self.session = session; self.onMessage = onMessage; self.onState = onState
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    public func stop() {
        loop?.cancel(); loop = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        joined = false
        onState(.stopped)
    }

    /// Sends when joined; otherwise drops it (see the type's comment).
    public func send(_ message: RemoteMessage) async {
        guard joined, let socket, let topic, let payload = try? message.jsonObject() else { return }
        try? await send(socket, Self.broadcastMessage(topic: topic, payload: payload, ref: nextRef()))
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
                Log.sync.notice("Remote channel: \(String(describing: error), privacy: .public)")
            }
            joined = false; socket = nil
            if Task.isCancelled { break }
            onState(.connecting)
            failures = Date().timeIntervalSince(started) > 120 ? 1 : failures + 1
            try? await Task.sleep(for: .seconds(min(60, 2 << min(failures, 5))))
        }
    }

    private func connectAndListen() async throws {
        let token = try await auth.accessToken()
        guard let userID = await auth.currentSession?.userID else { throw SyncError.signedOut }
        let topic = Self.topic(userID: userID)
        let socket = session.webSocketTask(with: RealtimeListener.socketURL(config))
        socket.resume()
        self.socket = socket; self.topic = topic
        defer { socket.cancel(with: .goingAway, reason: nil) }

        let joinRef = nextRef()
        try await send(socket, Self.joinMessage(topic: topic, token: token, ref: joinRef))
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: RealtimeListener.heartbeatInterval)
                guard let self, !Task.isCancelled else { return }
                try? await self.send(socket, RealtimeListener.heartbeatMessage(ref: await self.nextRef()))
            }
        }
        defer { heartbeat.cancel() }
        let refresh = Task {
            try? await Task.sleep(for: RealtimeListener.tokenRefreshInterval)
            socket.cancel(with: .normalClosure, reason: nil)  // reconnects with a new token
        }
        defer { refresh.cancel() }

        while !Task.isCancelled {
            let data: Data
            switch try await socket.receive() {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: continue
            }
            switch Self.classify(data, topic: topic, joinRef: joinRef) {
            case .joined:
                joined = true
                onState(.joined)
            case .message(let m): onMessage(m)
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

    /// Per account: the user ID is only known to that account's sessions.
    static func topic(userID: String) -> String { "realtime:bluebox-remote:\(userID.lowercased())" }

    static func joinMessage(topic: String, token: String, ref: String) -> [String: Any] {
        [
            "topic": topic, "event": "phx_join", "ref": ref, "join_ref": ref,
            "payload": [
                "config": ["broadcast": ["self": false, "ack": false], "presence": ["key": ""],
                           "postgres_changes": [Any]()] as [String: Any],
                "access_token": token,
            ] as [String: Any],
        ]
    }

    static func broadcastMessage(topic: String, payload: [String: Any], ref: String) -> [String: Any] {
        ["topic": topic, "event": "broadcast", "ref": ref,
         "payload": ["type": "broadcast", "event": event, "payload": payload] as [String: Any]]
    }

    enum Incoming: Equatable { case joined, message(RemoteMessage), closed(String), other }

    static func classify(_ data: Data, topic: String, joinRef: String) -> Incoming {
        guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = m["event"] as? String, (m["topic"] as? String) == topic else { return .other }
        let payload = m["payload"] as? [String: Any]
        switch event {
        case "broadcast":
            guard (payload?["event"] as? String) == Self.event, let body = payload?["payload"],
                  let message = try? RemoteMessage.decode(jsonObject: body) else { return .other }
            return .message(message)
        case "phx_reply":
            guard (m["ref"] as? String) == joinRef else { return .other }
            if (payload?["status"] as? String) == "ok" { return .joined }
            return .closed(((payload?["response"] as? [String: Any])?["reason"] as? String) ?? "join refused")
        case "phx_error", "phx_close":
            return .closed(event)
        case "system":
            if (payload?["status"] as? String) == "error" { return .closed((payload?["message"] as? String) ?? "system error") }
            return .other
        default:
            return .other
        }
    }
}
