import Domain
import Foundation

/// A Watch Party room on Supabase Realtime: a private broadcast topic named by the join code
/// (`bluebox-together:<code>`). Its own type rather than `RemoteChannel`'s,
/// because the topic isn't the account's and the guest may be signed in to
/// someone else's project (`TogetherInvite`); it borrows the socket URL and
/// heartbeat from `RealtimeListener` and speaks the same Phoenix protocol.
///
/// Who may join: the realtime.messages policies in
/// migrations/20261031000000_watch_together.sql let any signed-in user (a
/// guest signs in anonymously) read and broadcast on `bluebox-together:` topics,
/// so the code is the key. Nothing is stored: a message sent while nobody
/// listens is gone, which the room is built for (presence and playheads are
/// repeated every couple of seconds).
public actor TogetherRealtimeRoom: TogetherTransport {
    static let event = "together"
    /// Two missed heartbeat replies: the socket is dead even if it didn't close.
    static let silenceLimit: TimeInterval = 60
    /// Renew the token on the joined channel this often (they last an hour).
    static let tokenRenewInterval: Duration = .seconds(30 * 60)

    let config: SupabaseConfig
    let code: TogetherJoinCode
    let session: URLSession
    let token: @Sendable () async throws -> String

    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var joined = false
    private var ref = 0
    private var lastHeard = Date()
    private var onMessage: (@Sendable (TogetherMessage) -> Void)?
    private var onConnection: (@Sendable (TogetherConnection) -> Void)?

    /// `token`: the signed-in user's access token, or a guest's (`SupabaseAuth.signInAnonymously`).
    public init(config: SupabaseConfig, code: TogetherJoinCode, session: URLSession = URLSession(configuration: .ephemeral),
                token: @escaping @Sendable () async throws -> String) {
        self.config = config; self.code = code; self.session = session; self.token = token
    }

    public func start(onMessage: @escaping @Sendable (TogetherMessage) -> Void,
                      onConnection: @escaping @Sendable (TogetherConnection) -> Void) {
        guard loop == nil else { return }
        self.onMessage = onMessage; self.onConnection = onConnection
        loop = Task { await self.run() }
    }

    public func stop() {
        loop?.cancel(); loop = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        joined = false
        onConnection?(.closed)
    }

    @discardableResult
    public func send(_ message: TogetherMessage) async -> Bool {
        guard joined, let socket, let payload = try? message.jsonObject() else { return false }
        do {
            try await send(socket, Self.broadcastMessage(topic: Self.topic(code), payload: payload, ref: nextRef()))
            return true
        } catch {
            return false
        }
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            onConnection?(.connecting)
            let started = Date()
            do {
                try await connectAndListen()
            } catch let refused as Refused {
                // The project said no (policies missing, guests not allowed): retrying won't help.
                onConnection?(.failed(refused.reason))
                return
            } catch {
                if Task.isCancelled { break }
                Log.sync.notice("Together room: \(String(describing: error), privacy: .public)")
            }
            joined = false; socket = nil
            if Task.isCancelled { break }
            failures = Date().timeIntervalSince(started) > 120 ? 1 : failures + 1
            if failures > 6 { onConnection?(.failed("The room couldn't be reached.")); return }
            try? await Task.sleep(for: .seconds(min(30, 1 << min(failures, 5))))
        }
    }

    struct Refused: Error { let reason: String }

    private func connectAndListen() async throws {
        let accessToken: String
        do { accessToken = try await token() } catch { throw Refused(reason: (error as? LocalizedError)?.errorDescription ?? "Couldn't sign in to the room.") }
        let topic = Self.topic(code)
        let socket = session.webSocketTask(with: RealtimeListener.socketURL(config))
        socket.resume()
        self.socket = socket
        lastHeard = Date()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        let joinRef = nextRef()
        try await send(socket, Self.joinMessage(topic: topic, token: accessToken, ref: joinRef))
        let keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: RealtimeListener.heartbeatInterval)
                guard let self, !Task.isCancelled else { return }
                await self.beat(socket)
            }
        }
        defer { keepAlive.cancel() }
        let renew = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tokenRenewInterval)
                guard let self, !Task.isCancelled else { return }
                await self.renewToken(socket, topic: topic)
            }
        }
        defer { renew.cancel() }

        while !Task.isCancelled {
            let data: Data
            switch try await socket.receive() {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: continue
            }
            lastHeard = Date()
            switch Self.classify(data, topic: topic, joinRef: joinRef) {
            case .joined:
                joined = true
                onConnection?(.connected)
            case .message(let m): onMessage?(m)
            case .refused(let why): throw Refused(reason: why)
            case .closed(let why): throw RealtimeError.closed(why)
            case .other: break
            }
        }
    }

    private func beat(_ socket: URLSessionWebSocketTask) async {
        if Date().timeIntervalSince(lastHeard) > Self.silenceLimit {
            socket.cancel(with: .goingAway, reason: nil)  // receive() throws; run() reconnects
            return
        }
        do { try await send(socket, RealtimeListener.heartbeatMessage(ref: nextRef())) } catch { socket.cancel(with: .goingAway, reason: nil) }
    }

    private func renewToken(_ socket: URLSessionWebSocketTask, topic: String) async {
        guard let fresh = try? await token() else { return }
        try? await send(socket, Self.accessTokenMessage(topic: topic, token: fresh, ref: nextRef()))
    }

    private func nextRef() -> String { ref += 1; return String(ref) }

    private func send(_ socket: URLSessionWebSocketTask, _ message: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    // MARK: Protocol

    static func topic(_ code: TogetherJoinCode) -> String { "realtime:bluebox-together:\(code.value.lowercased())" }

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

    static func accessTokenMessage(topic: String, token: String, ref: String) -> [String: Any] {
        ["topic": topic, "event": "access_token", "ref": ref, "payload": ["access_token": token]]
    }

    static func broadcastMessage(topic: String, payload: [String: Any], ref: String) -> [String: Any] {
        ["topic": topic, "event": "broadcast", "ref": ref,
         "payload": ["type": "broadcast", "event": event, "payload": payload] as [String: Any]]
    }

    enum Incoming: Equatable { case joined, message(TogetherMessage), refused(String), closed(String), other }

    static func classify(_ data: Data, topic: String, joinRef: String) -> Incoming {
        guard let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = m["event"] as? String, (m["topic"] as? String) == topic else { return .other }
        let payload = m["payload"] as? [String: Any]
        switch event {
        case "broadcast":
            guard (payload?["event"] as? String) == Self.event, let body = payload?["payload"],
                  let message = try? TogetherMessage.decode(jsonObject: body) else { return .other }
            return .message(message)
        case "phx_reply":
            guard (m["ref"] as? String) == joinRef else { return .other }
            if (payload?["status"] as? String) == "ok" { return .joined }
            let reason = ((payload?["response"] as? [String: Any])?["reason"] as? String) ?? "join refused"
            // An unauthorized join is the policies saying no, not a network blip.
            return reason.localizedCaseInsensitiveContains("unauthorized")
                ? .refused("This Bluebox server isn't set up for Watch Parties yet. Its owner can run the latest setup in Settings › Account.")
                : .closed(reason)
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
