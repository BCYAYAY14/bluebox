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
/// only the signed-in user's changes arrive. The channel is private and per
/// account (`bluebox-sync:<user id>`), so it still works with the project's
/// public channel access turned off (migrations/20261030000000_realtime_private.sql).
///
/// A socket can die without closing (the Mac slept, the phone changed
/// networks), so one that hears nothing, not even heartbeat replies, for
/// `silenceLimit` is dropped and reconnected, as `RemoteChannel` does.
public actor RealtimeListener {
    public enum State: Sendable, Equatable { case stopped, connecting, listening }

    /// Why `onChange` was called: the channel was joined (anything may have
    /// changed while not listening), or a synced row changed.
    public enum Signal: Sendable, Equatable { case joined, change }

    /// Every synced table. The setup SQL adds them all to the
    /// supabase_realtime publication; lists and list_entries came with the
    /// lists migration (20261029100000_lists.sql).
    static let tables = ["watch_progress", "watchlist_entries", "profiles", "account_settings", "lists", "list_entries"]
    /// The tables before lists, for a project whose publication lacks the
    /// list tables: Realtime refuses the whole subscription then, so the
    /// listener joins again with these and lists wait for the next pull.
    static let tablesBeforeLists = ["watch_progress", "watchlist_entries", "profiles", "account_settings"]
    /// Per account, like the remote-control channel; private, so Realtime
    /// checks the user may read it (realtime.messages policies).
    static func topic(userID: String) -> String { "realtime:bluebox-sync:\(userID.lowercased())" }
    static let heartbeatInterval: Duration = .seconds(25)
    /// Two missed heartbeat replies.
    static let silenceLimit: Duration = .seconds(60)
    /// Rejoin with a fresh token this often (access tokens last an hour).
    static let tokenRefreshInterval: Duration = .seconds(40 * 60)

    let config: SupabaseConfig
    let auth: SupabaseAuth
    let session: URLSession
    let onChange: @Sendable (Signal) -> Void
    let onState: @Sendable (State) -> Void

    private var loop: Task<Void, Never>?
    private var ref = 0
    private var lastHeard = ContinuousClock.now
    /// Set once the server refused the list tables; kept for this listener's life.
    private var withoutLists = false

    public init(config: SupabaseConfig, auth: SupabaseAuth, session: URLSession = URLSession(configuration: .ephemeral),
                onChange: @escaping @Sendable (Signal) -> Void, onState: @escaping @Sendable (State) -> Void = { _ in }) {
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
            } catch RealtimeError.refused(let why) where !withoutLists && !Self.isAuthProblem(why) {
                if Task.isCancelled { break }
                // Probably an older project without the list tables in its
                // publication: join again at once without them. Sticky, so it can't loop.
                Log.sync.notice("Realtime: refused (\(why, privacy: .public)), joining without the list tables")
                withoutLists = true
                continue
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
        guard let userID = await auth.currentSession?.userID else { throw SyncError.signedOut }
        let topic = Self.topic(userID: userID)
        let socket = session.webSocketTask(with: Self.socketURL(config))
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        lastHeard = .now
        try await send(socket, Self.joinMessage(topic: topic, token: token, ref: nextRef(),
                                                tables: withoutLists ? Self.tablesBeforeLists : Self.tables))
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let self, !Task.isCancelled else { return }
                await self.keepAlive(socket)
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
            lastHeard = .now
            switch Self.classify(data, topic: topic) {
            case .joined:
                onState(.listening)
                onChange(.joined)  // anything that changed while not listening
            case .change: onChange(.change)
            case .refused(let why): throw RealtimeError.refused(why)
            case .closed(let why): throw RealtimeError.closed(why)
            case .other: break
            }
        }
    }

    /// A heartbeat, and the check that the socket is still alive: a failed
    /// send, or nothing heard for `silenceLimit`, drops it so `run` reconnects
    /// (with the usual backoff).
    private func keepAlive(_ socket: URLSessionWebSocketTask) async {
        guard ContinuousClock.now - lastHeard < Self.silenceLimit else {
            Log.sync.notice("Realtime: silent for too long, reconnecting")
            socket.cancel(with: .goingAway, reason: nil)
            return
        }
        do {
            try await send(socket, Self.heartbeatMessage(ref: nextRef()))
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    /// A refusal about the sign-in, not the tables: joining without the list
    /// tables wouldn't help, so it gets the normal backoff.
    static func isAuthProblem(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return ["token", "jwt", "auth", "unauthorized", "expired", "permission"].contains { r.contains($0) }
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

    static func joinMessage(topic: String, token: String, ref: String, tables: [String] = RealtimeListener.tables) -> [String: Any] {
        let changes = tables.map { ["event": "*", "schema": "public", "table": $0] }
        return [
            "topic": topic, "event": "phx_join", "ref": ref, "join_ref": ref,
            "payload": [
                "config": ["broadcast": ["self": false], "presence": ["key": ""], "postgres_changes": changes,
                           "private": true] as [String: Any],
                "access_token": token,
            ] as [String: Any],
        ]
    }

    static func heartbeatMessage(ref: String) -> [String: Any] {
        ["topic": "phoenix", "event": "heartbeat", "payload": [String: Any](), "ref": ref]
    }

    /// `refused`: the server answered the join with an error, or reported a
    /// subscription problem (a table missing from the publication).
    enum Incoming: Equatable { case joined, change, refused(String), closed(String), other }

    static func classify(_ data: Data, topic: String) -> Incoming {
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
            return .refused(reason)
        case "phx_error", "phx_close":
            return (m["topic"] as? String) == topic ? .closed(event) : .other
        case "system":
            // Realtime reports subscription problems (a table missing from the publication) here.
            if (payload?["status"] as? String) == "error" { return .refused((payload?["message"] as? String) ?? "system error") }
            return .other
        default:
            return .other
        }
    }
}

/// Decides which Realtime signals are worth a sync pass. This device's own
/// pushes come back as `postgres_changes` a moment later, and the join
/// signal lands right after the foreground sync, so following every signal
/// ran each pass twice.
///
/// - A join right after a pass (or during one) is skipped: that pass read
///   everything.
/// - A change during a pass waits for it to end: if the pass pushed
///   anything, the change is taken for our own echo; if it pushed nothing,
///   it can't be, so a pass follows.
/// - A change within `window` after a pass that pushed is taken for the echo too.
///
/// A real change from another device caught in one of those windows isn't
/// lost, only late: the next pull (the poll, a local change, the next
/// foreground) brings it.
public struct RealtimeEchoFilter: Sendable {
    public var window: TimeInterval
    private var running = 0
    private var changedDuringPass = false
    private var roundPushed = false
    private var roundFailed = false
    private var lastFinished: Date?
    private var lastPushed = false

    public init(window: TimeInterval = 5) { self.window = window }

    public mutating func passStarted() { running += 1 }

    /// A pass ended: `pushed` is whether it sent anything, nil if it failed.
    /// True when a change arrived during it that wasn't our echo, so another
    /// pass should follow.
    public mutating func passFinished(at date: Date, pushed: Bool?) -> Bool {
        running = max(0, running - 1)
        if let pushed { roundPushed = roundPushed || pushed } else { roundFailed = true }
        guard running == 0 else { return false }
        defer { changedDuringPass = false; roundPushed = false; roundFailed = false }
        // After a failure nothing is known; the next poll or foreground tries again.
        guard !roundFailed else { return false }
        lastFinished = date
        lastPushed = roundPushed
        return changedDuringPass && !roundPushed
    }

    /// Whether a signal arriving now should start a pass.
    public mutating func shouldSync(_ signal: RealtimeListener.Signal, at date: Date) -> Bool {
        if running > 0 {
            if signal == .change { changedDuringPass = true }
            return false
        }
        guard let last = lastFinished, date >= last, date.timeIntervalSince(last) < window else { return true }
        switch signal {
        case .joined: return false
        case .change: return !lastPushed
        }
    }
}

enum RealtimeError: Error, CustomStringConvertible {
    case closed(String)
    case refused(String)
    var description: String {
        switch self {
        case .closed(let why): "closed: \(why)"
        case .refused(let why): "refused: \(why)"
        }
    }
}
