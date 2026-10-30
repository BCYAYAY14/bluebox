import Domain
import Foundation

/// What `RemoteControl` talks through: `RemoteChannel`, or an in-memory one in tests.
public protocol RemoteTransport: AnyObject, Sendable {
    func start() async
    func stop() async
    /// True when it went out; false while not joined.
    @discardableResult func send(_ message: RemoteMessage) async -> Bool
    /// Reconnect at once (see `RemoteChannel.reconnect`).
    func reconnect() async
}

/// The remote-control channel: Supabase Realtime broadcast, one private topic
/// per account (`bluebox-remote:<user id>`). Private means Realtime checks the
/// realtime.messages policies (migrations/20261030000000_realtime_private.sql)
/// on join and on every broadcast, so only devices signed in to the same
/// account can hear or send; the user ID in the topic is not the protection. Phoenix over `URLSessionWebSocketTask`, like
/// `RealtimeListener`, which it borrows the socket URL and heartbeat from.
///
/// Broadcast isn't stored: a message sent while nobody listens is gone. The
/// protocol is built for that (state is re-published, commands are
/// acknowledged and retried by `RemoteControl`), so a send while reconnecting
/// is dropped and reported as not sent.
///
/// Staying joined: a socket can die without closing (the Mac slept, the phone
/// changed networks), so one that hears nothing, not even heartbeat replies,
/// for `silenceLimit` is dropped and reconnected. The access token is renewed
/// on the joined channel shortly before it expires, rather than by
/// reconnecting, which used to leave a gap every 40 minutes and lost whatever
/// was sent in it.
public actor RemoteChannel: RemoteTransport {
    public enum State: Sendable, Equatable { case stopped, connecting, joined }

    static let event = "remote"
    /// Two missed heartbeat replies.
    static let silenceLimit: Duration = .seconds(60)

    let config: SupabaseConfig
    let auth: SupabaseAuth
    let session: URLSession
    let onMessage: @Sendable (RemoteMessage) -> Void
    let onState: @Sendable (State) -> Void

    private var loop: Task<Void, Never>?
    private var backoff: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var topic: String?
    private var joined = false
    private var ref = 0
    private var lastHeard = ContinuousClock.now

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
        backoff?.cancel(); backoff = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        joined = false
        onState(.stopped)
    }

    /// Sends when joined; otherwise drops it (see the type's comment). True when it went out.
    @discardableResult
    public func send(_ message: RemoteMessage) async -> Bool {
        guard joined, let socket, let topic, let payload = try? message.jsonObject() else { return false }
        do {
            try await send(socket, Self.broadcastMessage(topic: topic, payload: payload, ref: nextRef()))
            return true
        } catch {
            return false
        }
    }

    /// Connect again now: after waking from sleep, or when the other side
    /// stopped answering. Skips the wait between attempts and drops a socket
    /// that may be dead without knowing it.
    public func reconnect() {
        backoff?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
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
            // A connection that held for a while: try again at once; one that keeps failing, less and less often.
            failures = Date().timeIntervalSince(started) > 120 ? 0 : failures + 1
            guard failures > 0 else { continue }
            let seconds = min(60, 1 << min(failures, 6))
            let wait = Task<Void, Never> { try? await Task.sleep(for: .seconds(seconds)) }
            backoff = wait
            await wait.value
            backoff = nil
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
        lastHeard = .now
        try await send(socket, Self.joinMessage(topic: topic, token: token, ref: joinRef))
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: RealtimeListener.heartbeatInterval)
                guard let self, !Task.isCancelled else { return }
                await self.keepAlive(socket)
            }
        }
        defer { heartbeat.cancel() }
        let refresh = Task { [weak self] in
            while !Task.isCancelled {
                // Until shortly before the token expires; `accessToken()` renews it inside its last minute.
                let expires = await self?.auth.currentSession?.expiresAt ?? Date().addingTimeInterval(40 * 60)
                try? await Task.sleep(for: .seconds(max(expires.timeIntervalSinceNow - 30, 5)))
                guard let self, !Task.isCancelled else { return }
                await self.renewToken(socket, topic: topic)
            }
        }
        defer { refresh.cancel() }

        while !Task.isCancelled {
            let data: Data
            switch try await socket.receive() {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: continue
            }
            lastHeard = .now
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

    /// A heartbeat, and the check that the socket is still alive: a failed
    /// send, or nothing heard for `silenceLimit`, drops it so `run` reconnects.
    private func keepAlive(_ socket: URLSessionWebSocketTask) async {
        guard ContinuousClock.now - lastHeard < Self.silenceLimit else {
            Log.sync.notice("Remote channel: silent for too long, reconnecting")
            socket.cancel(with: .goingAway, reason: nil)
            return
        }
        do {
            try await send(socket, RealtimeListener.heartbeatMessage(ref: nextRef()))
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    /// A fresh token for the joined channel; if that fails, reconnect, which fetches one.
    private func renewToken(_ socket: URLSessionWebSocketTask, topic: String) async {
        do {
            let token = try await auth.accessToken()
            try await send(socket, Self.accessTokenMessage(topic: topic, token: token, ref: nextRef()))
        } catch {
            socket.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func nextRef() -> String { ref += 1; return String(ref) }

    private func send(_ socket: URLSessionWebSocketTask, _ message: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    // MARK: Protocol

    /// Per account; the policies, not the ID, keep other accounts out.
    static func topic(userID: String) -> String { "realtime:bluebox-remote:\(userID.lowercased())" }

    static func joinMessage(topic: String, token: String, ref: String) -> [String: Any] {
        [
            "topic": topic, "event": "phx_join", "ref": ref, "join_ref": ref,
            "payload": [
                "config": ["broadcast": ["self": false, "ack": false], "presence": ["key": ""],
                           "postgres_changes": [Any](), "private": true] as [String: Any],
                "access_token": token,
            ] as [String: Any],
        ]
    }

    /// Realtime's in-place token renewal for a joined channel (what realtime-js sends).
    static func accessTokenMessage(topic: String, token: String, ref: String) -> [String: Any] {
        ["topic": topic, "event": "access_token", "ref": ref, "payload": ["access_token": token]]
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
