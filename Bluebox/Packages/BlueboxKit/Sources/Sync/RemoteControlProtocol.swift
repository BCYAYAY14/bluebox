import Foundation

/// The iPhone-as-a-remote protocol (DECISIONS.md, UI review 17). The Mac
/// player publishes `RemoteNowPlaying` while it plays; a phone answers with
/// `RemoteCommand`s. Both go over one Realtime broadcast channel per account
/// (`RemoteChannel`), as JSON with a `type` field, so either side can add
/// fields without breaking the other.

/// An audio or subtitle track the remote can pick.
public struct RemoteTrack: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

/// What the Mac's player is doing, as of `position`.
public struct RemoteNowPlaying: Codable, Hashable, Sendable {
    /// The publishing device (`RemoteCommand.target`).
    public var deviceID: String
    /// "Brian's MacBook Pro", for "Playing on …".
    public var deviceName: String
    public var title: String
    /// "S1·E2 · Pilot" for an episode.
    public var subtitle: String?
    public var position: TimeInterval
    public var duration: TimeInterval?
    public var paused: Bool
    public var audioTracks: [RemoteTrack]
    public var subtitleTracks: [RemoteTrack]
    public var audioID: String?
    /// nil: subtitles off.
    public var subtitleID: String?
    /// 0…1
    public var volume: Float
    /// An episode with a next one: the remote shows Next Episode.
    public var hasNext: Bool
    /// Counts up per publishing device, so a late message can't undo a newer one.
    public var seq: Int

    public init(deviceID: String, deviceName: String, title: String, subtitle: String? = nil, position: TimeInterval,
                duration: TimeInterval?, paused: Bool, audioTracks: [RemoteTrack] = [], subtitleTracks: [RemoteTrack] = [],
                audioID: String? = nil, subtitleID: String? = nil, volume: Float = 1, hasNext: Bool = false, seq: Int = 0) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.title = title; self.subtitle = subtitle
        self.position = position; self.duration = duration; self.paused = paused
        self.audioTracks = audioTracks; self.subtitleTracks = subtitleTracks; self.audioID = audioID; self.subtitleID = subtitleID
        self.volume = volume; self.hasNext = hasNext; self.seq = seq
    }
}

/// One thing the remote asked the player to do.
public struct RemoteCommand: Codable, Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case setPaused(Bool)
        /// Absolute: ±10 s is worked out on the phone from what it shows, so
        /// repeated taps add up the same way they do on the Mac.
        case seek(TimeInterval)
        case nextEpisode
        case audio(String)
        /// nil turns subtitles off.
        case subtitle(String?)
        case volume(Float)
    }

    public var id: UUID
    /// The Mac it's for (`RemoteNowPlaying.deviceID`).
    public var target: String
    public var action: Action

    public init(id: UUID = UUID(), target: String, action: Action) { self.id = id; self.target = target; self.action = action }
}

extension RemoteCommand.Action: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "setPaused": self = .setPaused(try c.decode(Bool.self, forKey: .value))
        case "seek": self = .seek(try c.decode(TimeInterval.self, forKey: .value))
        case "nextEpisode": self = .nextEpisode
        case "audio": self = .audio(try c.decode(String.self, forKey: .value))
        case "subtitle": self = .subtitle(try c.decodeIfPresent(String.self, forKey: .value))
        case "volume": self = .volume(try c.decode(Float.self, forKey: .value))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown remote action \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setPaused(let p): try c.encode("setPaused", forKey: .kind); try c.encode(p, forKey: .value)
        case .seek(let t): try c.encode("seek", forKey: .kind); try c.encode(t, forKey: .value)
        case .nextEpisode: try c.encode("nextEpisode", forKey: .kind)
        case .audio(let id): try c.encode("audio", forKey: .kind); try c.encode(id, forKey: .value)
        case .subtitle(let id): try c.encode("subtitle", forKey: .kind); try c.encodeIfPresent(id, forKey: .value)
        case .volume(let v): try c.encode("volume", forKey: .kind); try c.encode(v, forKey: .value)
        }
    }
}

/// Everything sent on the remote channel.
public enum RemoteMessage: Hashable, Sendable {
    /// The Mac's player, published every couple of seconds while a remote is listening.
    case state(RemoteNowPlaying)
    case command(RemoteCommand)
    /// A remote opened (or is still open): players publish at once, and more often for a while.
    case hello(from: String)
    /// The player on `deviceID` closed.
    case stopped(deviceID: String)
}

extension RemoteMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, state, command, device }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "state": self = .state(try c.decode(RemoteNowPlaying.self, forKey: .state))
        case "command": self = .command(try c.decode(RemoteCommand.self, forKey: .command))
        case "hello": self = .hello(from: try c.decode(String.self, forKey: .device))
        case "stopped": self = .stopped(deviceID: try c.decode(String.self, forKey: .device))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown remote message \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .state(let s): try c.encode("state", forKey: .type); try c.encode(s, forKey: .state)
        case .command(let cmd): try c.encode("command", forKey: .type); try c.encode(cmd, forKey: .command)
        case .hello(let device): try c.encode("hello", forKey: .type); try c.encode(device, forKey: .device)
        case .stopped(let device): try c.encode("stopped", forKey: .type); try c.encode(device, forKey: .device)
        }
    }

    public func jsonObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    public static func decode(jsonObject: Any) throws -> RemoteMessage {
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        return try JSONDecoder().decode(RemoteMessage.self, from: data)
    }
}

/// What the remote shows: the Mac's last published state, run forward while
/// it plays, with the remote's own commands drawn at once on top (optimistic)
/// until a published state agrees or `timeout` passes. Then the Mac's word
/// wins, so a lost command can't leave the remote showing something false.
public struct RemoteReconciler: Sendable {
    public var timeout: TimeInterval
    /// No state for this long: the Mac is gone (closed, asleep, offline).
    public var staleAfter: TimeInterval
    public private(set) var published: RemoteNowPlaying?
    public private(set) var receivedAt: Date?
    private var pending: [(action: RemoteCommand.Action, at: Date)] = []

    public init(timeout: TimeInterval = 4, staleAfter: TimeInterval = 30) {
        self.timeout = timeout; self.staleAfter = staleAfter
    }

    /// A state from the Mac. Older than the one held (same device, lower seq): ignored.
    public mutating func receive(_ state: RemoteNowPlaying, at now: Date) {
        if let published, published.deviceID == state.deviceID, state.seq < published.seq { return }
        if let published, published.deviceID != state.deviceID { pending.removeAll() }
        published = state
        receivedAt = now
        pending.removeAll { Self.confirms(state, $0.action) || now.timeIntervalSince($0.at) > timeout }
    }

    /// The remote sent `action`: show it straight away. A newer one of the same kind replaces it.
    public mutating func apply(_ action: RemoteCommand.Action, at now: Date) {
        pending.removeAll { Self.kind($0.action) == Self.kind(action) }
        if case .nextEpisode = action { return }  // nothing to draw until the next episode publishes
        pending.append((action, now))
    }

    /// The player on that device closed.
    public mutating func stopped(deviceID: String) {
        guard published?.deviceID == deviceID else { return }
        clear()
    }

    public mutating func clear() { published = nil; receivedAt = nil; pending.removeAll() }

    public func isStale(at now: Date) -> Bool {
        receivedAt.map { now.timeIntervalSince($0) > staleAfter } ?? true
    }

    /// The state to draw at `now`.
    public func displayed(at now: Date) -> RemoteNowPlaying? {
        guard var s = published, let receivedAt, !isStale(at: now) else { return nil }
        let live = pending.filter { now.timeIntervalSince($0.at) <= timeout }
        // Run the clock forward from the last fix: the published position, or a seek sent since.
        var fix = (position: s.position, at: receivedAt)
        var playing = !s.paused
        for p in live {
            switch p.action {
            case .seek(let t): fix = (t, p.at)
            case .setPaused(let paused):
                // Advance to the moment of the tap, then hold (pause) or start counting (play).
                if playing { fix = (fix.position + max(p.at.timeIntervalSince(fix.at), 0), p.at) } else { fix.at = p.at }
                playing = !paused
                s.paused = paused
            case .audio(let id): s.audioID = id
            case .subtitle(let id): s.subtitleID = id
            case .volume(let v): s.volume = v
            case .nextEpisode: break
            }
        }
        var position = fix.position + (playing ? max(now.timeIntervalSince(fix.at), 0) : 0)
        if let d = s.duration { position = min(position, d) }
        s.position = max(position, 0)
        return s
    }

    static func kind(_ a: RemoteCommand.Action) -> Int {
        switch a {
        case .setPaused: 0
        case .seek: 1
        case .nextEpisode: 2
        case .audio: 3
        case .subtitle: 4
        case .volume: 5
        }
    }

    /// A published state that shows the command took effect.
    static func confirms(_ s: RemoteNowPlaying, _ a: RemoteCommand.Action) -> Bool {
        switch a {
        case .setPaused(let p): s.paused == p
        case .seek(let t): abs(s.position - t) < 3
        case .nextEpisode: true
        case .audio(let id): s.audioID == id
        case .subtitle(let id): s.subtitleID == id
        case .volume(let v): abs(s.volume - v) < 0.02
        }
    }
}
