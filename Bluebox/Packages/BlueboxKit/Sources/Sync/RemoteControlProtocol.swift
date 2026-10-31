import Domain
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
    /// What the Mac's skip button offers right now ("Skip Intro", "Next Episode"):
    /// the phone shows the same button (`RemoteCommand.Action.acceptSkip`).
    public var skipOffer: String?
    /// Chapter starts, for marks on the phone's timeline.
    public var chapters: [TimeInterval]?
    /// Counts up per publishing device, so a late message can't undo a newer one.
    /// Starts from the clock, so it keeps counting up across the Mac's relaunches.
    public var seq: Int
    /// The player's protocol: 2 and up acknowledge commands (`RemoteMessage.ack`),
    /// so the remote retries them. nil from builds before that, which it mustn't
    /// retry (a repeated Next Episode would skip two).
    public var version: Int?

    public static let currentVersion = 2

    public init(deviceID: String, deviceName: String, title: String, subtitle: String? = nil, position: TimeInterval,
                duration: TimeInterval?, paused: Bool, audioTracks: [RemoteTrack] = [], subtitleTracks: [RemoteTrack] = [],
                audioID: String? = nil, subtitleID: String? = nil, volume: Float = 1, hasNext: Bool = false,
                skipOffer: String? = nil, chapters: [TimeInterval]? = nil, seq: Int = 0,
                version: Int? = RemoteNowPlaying.currentVersion) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.title = title; self.subtitle = subtitle
        self.position = position; self.duration = duration; self.paused = paused
        self.audioTracks = audioTracks; self.subtitleTracks = subtitleTracks; self.audioID = audioID; self.subtitleID = subtitleID
        self.volume = volume; self.hasNext = hasNext; self.skipOffer = skipOffer; self.chapters = chapters
        self.seq = seq; self.version = version
    }

    /// The player acknowledges commands, so they can be retried.
    public var acknowledges: Bool { (version ?? 1) >= 2 }
}

/// "Got it": the player received a command. Sent before it's applied, and
/// again for a retry it has already applied, so the remote stops retrying.
public struct RemoteAck: Codable, Hashable, Sendable {
    public var commandID: UUID
    /// The acknowledging player.
    public var deviceID: String
    /// The player's last published `seq`: only states after it can show the command's effect.
    public var seq: Int

    public init(commandID: UUID, deviceID: String, seq: Int) { self.commandID = commandID; self.deviceID = deviceID; self.seq = seq }
}

/// A direction for the touch pad: moves the highlight on the controlled screen.
public enum RemoteDirection: String, Codable, Hashable, Sendable, CaseIterable { case up, down, left, right }

/// Where the remote asks the controlled device to go. The same for a Mac
/// window now and a focus-based Apple TV app later: each shows it its own way.
public enum RemoteDestination: Hashable, Sendable {
    case home
    /// Search, with this text typed in ("" just opens it).
    case search(String)
    case title(MediaKey)
    case back
}

/// Play this, on the controlled device: what its own Play button would do.
public struct RemotePlay: Codable, Hashable, Sendable {
    public var key: MediaKey
    public var title: String
    public var subtitle: String?
    public var resume: Bool
    /// One chosen release (an `AddonRelease`, as JSON: Sync doesn't know add-ons). nil: the device picks, as Play does.
    public var release: Data?

    public init(key: MediaKey, title: String, subtitle: String? = nil, resume: Bool = true, release: Data? = nil) {
        self.key = key; self.title = title; self.subtitle = subtitle; self.resume = resume; self.release = release
    }
}

/// Two fingers on the pad: scroll what's under the highlight, in points on
/// the controlled screen (positive `dy` shows what's further down). The last
/// one of a gesture carries the finger's speed, so the page coasts on.
public struct RemoteScroll: Codable, Hashable, Sendable {
    public var dx: Double
    public var dy: Double
    /// Points a second when the fingers lifted; nil while they're down.
    public var velocityX: Double?
    public var velocityY: Double?

    public init(dx: Double, dy: Double, velocityX: Double? = nil, velocityY: Double? = nil) {
        self.dx = dx; self.dy = dy; self.velocityX = velocityX; self.velocityY = velocityY
    }

    public var ends: Bool { velocityX != nil || velocityY != nil }
}

/// How far the pad moved the controlled screen's pointer, in points.
public struct RemotePointerMove: Codable, Hashable, Sendable {
    public var dx: Double
    public var dy: Double
    public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }
}

/// A fast swipe: several steps one way, in one message.
public struct RemoteJump: Codable, Hashable, Sendable {
    public var direction: RemoteDirection
    public var count: Int
    public init(_ direction: RemoteDirection, count: Int) { self.direction = direction; self.count = count }
}

/// One thing the remote asked the controlled device to do: its player, or the app around it.
public struct RemoteCommand: Codable, Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case setPaused(Bool)
        /// Absolute: ±10 s is worked out on the phone from what it shows, so
        /// repeated taps add up the same way they do on the Mac. Also ends a scrub.
        case seek(TimeInterval)
        /// Live scrubbing: the picture follows while the finger moves; a `seek` lands it.
        case scrub(TimeInterval)
        case nextEpisode
        case audio(String)
        /// nil turns subtitles off.
        case subtitle(String?)
        case volume(Float)
        case closePlayer
        // The whole app (protocol 3).
        case go(RemoteDestination)
        /// Highlight the item with this ID (`RemoteScreen.focusedID`), e.g. what was tapped on the phone.
        case focus(String)
        case move(RemoteDirection)
        /// Press the highlighted item.
        case select
        case play(RemotePlay)
        // Protocol 4: the better remote (31 Oct 2026).
        case jump(RemoteJump)
        case scroll(RemoteScroll)
        /// Pointer mode on or off: the pad moves a pointer instead of the highlight.
        case setPointer(Bool)
        case pointer(RemotePointerMove)
        /// Click under the pointer.
        case click
        /// Hold: the highlighted item's menu, as a right-click would open it.
        case menu
        /// An item of the open menu (`RemoteScreen.menu`), by its index there.
        case menuPick(Int)
        /// The player's skip button (`RemoteNowPlaying.skipOffer`).
        case acceptSkip
    }

    public var id: UUID
    /// The Mac it's for (`RemoteNowPlaying.deviceID`).
    public var target: String
    public var action: Action
    /// The sending device (`RemoteDevice.id`): the Mac names it on its highlight.
    public var from: String?

    public init(id: UUID = UUID(), target: String, action: Action, from: String? = nil) {
        self.id = id; self.target = target; self.action = action; self.from = from
    }
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
        case "scrub": self = .scrub(try c.decode(TimeInterval.self, forKey: .value))
        case "closePlayer": self = .closePlayer
        case "go": self = .go(try c.decode(RemoteDestination.self, forKey: .value))
        case "focus": self = .focus(try c.decode(String.self, forKey: .value))
        case "move": self = .move(try c.decode(RemoteDirection.self, forKey: .value))
        case "select": self = .select
        case "play": self = .play(try c.decode(RemotePlay.self, forKey: .value))
        case "jump": self = .jump(try c.decode(RemoteJump.self, forKey: .value))
        case "scroll": self = .scroll(try c.decode(RemoteScroll.self, forKey: .value))
        case "setPointer": self = .setPointer(try c.decode(Bool.self, forKey: .value))
        case "pointer": self = .pointer(try c.decode(RemotePointerMove.self, forKey: .value))
        case "click": self = .click
        case "menu": self = .menu
        case "menuPick": self = .menuPick(try c.decode(Int.self, forKey: .value))
        case "acceptSkip": self = .acceptSkip
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
        case .scrub(let t): try c.encode("scrub", forKey: .kind); try c.encode(t, forKey: .value)
        case .closePlayer: try c.encode("closePlayer", forKey: .kind)
        case .go(let d): try c.encode("go", forKey: .kind); try c.encode(d, forKey: .value)
        case .focus(let id): try c.encode("focus", forKey: .kind); try c.encode(id, forKey: .value)
        case .move(let d): try c.encode("move", forKey: .kind); try c.encode(d, forKey: .value)
        case .select: try c.encode("select", forKey: .kind)
        case .play(let p): try c.encode("play", forKey: .kind); try c.encode(p, forKey: .value)
        case .jump(let j): try c.encode("jump", forKey: .kind); try c.encode(j, forKey: .value)
        case .scroll(let s): try c.encode("scroll", forKey: .kind); try c.encode(s, forKey: .value)
        case .setPointer(let on): try c.encode("setPointer", forKey: .kind); try c.encode(on, forKey: .value)
        case .pointer(let m): try c.encode("pointer", forKey: .kind); try c.encode(m, forKey: .value)
        case .click: try c.encode("click", forKey: .kind)
        case .menu: try c.encode("menu", forKey: .kind)
        case .menuPick(let i): try c.encode("menuPick", forKey: .kind); try c.encode(i, forKey: .value)
        case .acceptSkip: try c.encode("acceptSkip", forKey: .kind)
        }
    }

    /// Changes something on screen for each press: never applied twice, and
    /// only sent to a device that takes app commands (`RemoteDevice.version` 3).
    public var isAppCommand: Bool {
        switch self {
        case .go, .focus, .move, .select, .play: true
        case .jump, .scroll, .setPointer, .pointer, .click, .menu, .menuPick, .acceptSkip: true
        default: false
        }
    }

    /// Needs a device on protocol 4 (`RemoteDevice.version`): older Macs don't know it.
    public var needsVersion4: Bool {
        switch self {
        case .jump, .scroll, .setPointer, .pointer, .click, .menu, .menuPick, .acceptSkip: true
        default: false
        }
    }

    /// Sent many times a second while a finger moves (a scroll or the pointer):
    /// not acknowledged or retried, since a lost one only means a little less
    /// movement, and acks would double the traffic. A scroll's last message
    /// (with its speed) is, so the page always coasts.
    public var isContinuous: Bool {
        switch self {
        case .pointer: true
        case .scroll(let s): !s.ends
        default: false
        }
    }
}

extension RemoteDestination: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "home": self = .home
        case "search": self = .search(try c.decode(String.self, forKey: .value))
        case "title": self = .title(try c.decode(MediaKey.self, forKey: .value))
        case "back": self = .back
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown destination \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .home: try c.encode("home", forKey: .kind)
        case .search(let q): try c.encode("search", forKey: .kind); try c.encode(q, forKey: .value)
        case .title(let key): try c.encode("title", forKey: .kind); try c.encode(key, forKey: .value)
        case .back: try c.encode("back", forKey: .kind)
        }
    }
}

/// A device on the account's remote channel, announced on joining, on a
/// hello and every `RemoteDevice.announceInterval`: the "Play on" list.
public struct RemoteDevice: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case mac, iPhone, iPad, appleTV }
    public var id: String
    public var name: String
    public var kind: Kind
    /// Allow Remote Control is on: it takes commands.
    public var controllable: Bool
    /// What it's playing, if anything.
    public var playing: String?
    /// 3: takes app commands (go, focus, move, select, play) as well as the player's.
    /// 4: also jumps, scrolls, the pointer, menus and the skip button.
    public var version: Int

    public static let announceInterval: TimeInterval = 20
    /// Not heard from for this long: off the list.
    public static let goneAfter: TimeInterval = 50

    public static let currentVersion = 4

    public init(id: String, name: String, kind: Kind, controllable: Bool, playing: String? = nil, version: Int = RemoteDevice.currentVersion) {
        self.id = id; self.name = name; self.kind = kind; self.controllable = controllable; self.playing = playing; self.version = version
    }
}

/// One item on the controlled screen, as the phone draws it beside the highlight.
public struct RemoteScreenItem: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case poster, button, toggle, field, row, other }
    public var label: String
    public var kind: Kind
    /// A poster's picture.
    public var image: URL?
    /// A switch's state.
    public var isOn: Bool?

    public init(label: String, kind: Kind = .button, image: URL? = nil, isOn: Bool? = nil) {
        self.label = label; self.kind = kind; self.image = image; self.isOn = isOn
    }
}

/// A Bluebox menu open on the controlled screen: the phone shows the same items.
public struct RemoteMenu: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable {
        /// Its index in the menu (`RemoteCommand.Action.menuPick`).
        public var index: Int
        public var title: String
        public var subtitle: String?
        public var systemImage: String?
        public var checked: Bool
        public var disabled: Bool
        public var destructive: Bool

        public init(index: Int, title: String, subtitle: String? = nil, systemImage: String? = nil,
                    checked: Bool = false, disabled: Bool = false, destructive: Bool = false) {
            self.index = index; self.title = title; self.subtitle = subtitle; self.systemImage = systemImage
            self.checked = checked; self.disabled = disabled; self.destructive = destructive
        }
    }

    public var title: String
    public var items: [Item]
    /// The item highlighted on the controlled screen.
    public var highlighted: Int?

    public init(title: String, items: [Item], highlighted: Int? = nil) {
        self.title = title; self.items = items; self.highlighted = highlighted
    }
}

/// Where the controlled device is in the app, and what's highlighted on it:
/// the phone's Touch pad shows it, so you can drive without looking up.
public struct RemoteScreen: Codable, Hashable, Sendable {
    public var deviceID: String
    /// "Home", "Severance", "Search", "Releases", "Player".
    public var title: String
    /// The highlighted item's ID and what it says ("3 · In Perpetuity").
    public var focusedID: String?
    public var focusedLabel: String?
    // Protocol 4.
    /// The highlighted item as the phone draws it, and the ones either side of it.
    public var focused: RemoteScreenItem?
    public var before: RemoteScreenItem?
    public var after: RemoteScreenItem?
    /// The neighbours are left and right (a row of posters) rather than above and below (a list).
    public var horizontal: Bool?
    /// The row or section it's in ("Continue Watching").
    public var section: String?
    /// The pad drives a pointer (`RemoteCommand.Action.setPointer`), e.g. on a page with nothing to highlight.
    public var pointer: Bool?
    /// Counts the moves that hit the end of a row: the phone bumps when it goes up.
    public var bumps: Int?
    public var menu: RemoteMenu?

    public init(deviceID: String, title: String, focusedID: String? = nil, focusedLabel: String? = nil,
                focused: RemoteScreenItem? = nil, before: RemoteScreenItem? = nil, after: RemoteScreenItem? = nil,
                horizontal: Bool? = nil, section: String? = nil, pointer: Bool? = nil, bumps: Int? = nil, menu: RemoteMenu? = nil) {
        self.deviceID = deviceID; self.title = title; self.focusedID = focusedID; self.focusedLabel = focusedLabel
        self.focused = focused; self.before = before; self.after = after; self.horizontal = horizontal
        self.section = section; self.pointer = pointer; self.bumps = bumps; self.menu = menu
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
    /// The player received a command (`RemoteAck`).
    case ack(RemoteAck)
    /// A device announcing itself (the "Play on" list).
    case device(RemoteDevice)
    /// Where the controlled device is, and what's highlighted.
    case screen(RemoteScreen)
}

extension RemoteMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, state, command, device, ack, info, screen }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "state": self = .state(try c.decode(RemoteNowPlaying.self, forKey: .state))
        case "command": self = .command(try c.decode(RemoteCommand.self, forKey: .command))
        case "hello": self = .hello(from: try c.decode(String.self, forKey: .device))
        case "stopped": self = .stopped(deviceID: try c.decode(String.self, forKey: .device))
        case "ack": self = .ack(try c.decode(RemoteAck.self, forKey: .ack))
        case "device": self = .device(try c.decode(RemoteDevice.self, forKey: .info))
        case "screen": self = .screen(try c.decode(RemoteScreen.self, forKey: .screen))
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
        case .ack(let ack): try c.encode("ack", forKey: .type); try c.encode(ack, forKey: .ack)
        case .device(let d): try c.encode("device", forKey: .type); try c.encode(d, forKey: .info)
        case .screen(let s): try c.encode("screen", forKey: .type); try c.encode(s, forKey: .screen)
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
/// until a published state agrees or its deadline passes. Then the Mac's word
/// wins, so a lost command can't leave the remote showing something false.
///
/// With a player that acknowledges (`RemoteNowPlaying.acknowledges`), only a
/// state published after the ack can confirm a command: one sent before the
/// Mac had it may agree by chance (a seek 2 s ahead) and would end the
/// overlay early. An acknowledged command also waits longer (`ackedTimeout`),
/// since the Mac has it and a seek on a slow stream takes a few seconds to land.
public struct RemoteReconciler: Sendable {
    /// How long an unacknowledged command is drawn.
    public var timeout: TimeInterval
    /// How long an acknowledged one is: a seek, and anything else.
    public var ackedTimeout: (seek: TimeInterval, other: TimeInterval)
    /// No state for this long: the Mac is gone (closed, asleep, offline).
    public var staleAfter: TimeInterval
    public private(set) var published: RemoteNowPlaying?
    public private(set) var receivedAt: Date?

    struct Pending: Sendable {
        var id: UUID?
        var action: RemoteCommand.Action
        var at: Date
        var deadline: Date
        /// The Mac's seq when it acknowledged.
        var ackSeq: Int?
    }
    private var pending: [Pending] = []

    public init(timeout: TimeInterval = 4, ackedTimeout: (seek: TimeInterval, other: TimeInterval) = (15, 8), staleAfter: TimeInterval = 30) {
        self.timeout = timeout; self.ackedTimeout = ackedTimeout; self.staleAfter = staleAfter
    }

    /// A state from the Mac. Older than the one held (same device, lower seq): ignored,
    /// unless the one held has gone stale (the Mac was away, and may have restarted).
    public mutating func receive(_ state: RemoteNowPlaying, at now: Date) {
        if let published, published.deviceID == state.deviceID, state.seq < published.seq, !isStale(at: now) { return }
        if let published, published.deviceID != state.deviceID { pending.removeAll() }
        published = state
        receivedAt = now
        pending.removeAll { p in
            if now > p.deadline { return true }
            guard Self.confirms(state, p.action) else { return false }
            if let ackSeq = p.ackSeq { return state.seq > ackSeq }
            return p.id == nil || !state.acknowledges
        }
    }

    /// The remote sent `action`: show it straight away. A newer one of the same kind replaces it.
    public mutating func apply(_ action: RemoteCommand.Action, id: UUID? = nil, at now: Date) {
        pending.removeAll { Self.kind($0.action) == Self.kind(action) }
        switch action {
        case .nextEpisode, .closePlayer, .go, .focus, .move, .select, .play, .jump, .scroll, .setPointer, .pointer,
             .click, .menu, .menuPick, .acceptSkip: return  // nothing to draw on the player
        default: break
        }
        pending.append(Pending(id: id, action: action, at: now, deadline: now.addingTimeInterval(timeout)))
    }

    /// The Mac has the command: keep drawing it until a later state shows it, or for longer.
    public mutating func acknowledged(_ ack: RemoteAck, at now: Date) {
        guard let i = pending.firstIndex(where: { $0.id == ack.commandID }) else { return }
        pending[i].ackSeq = ack.seq
        let wait = if case .seek = pending[i].action { ackedTimeout.seek } else { ackedTimeout.other }
        pending[i].deadline = max(pending[i].deadline, now.addingTimeInterval(wait))
    }

    /// The Mac never answered: stop drawing the command.
    public mutating func abandon(_ id: UUID) { pending.removeAll { $0.id == id } }

    /// Whether the command is still drawn (not confirmed, replaced or timed out).
    public func isPending(_ id: UUID) -> Bool { pending.contains { $0.id == id } }

    /// The kinds (`kind(_:)`) drawn but not yet confirmed at `now`: the remote shows a ring on them.
    public func pendingKinds(at now: Date) -> Set<Int> { Set(pending.filter { now <= $0.deadline }.map { Self.kind($0.action) }) }

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
        let live = pending.filter { now <= $0.deadline }
        // Run the clock forward from the last fix: the published position, or a seek sent since.
        var fix = (position: s.position, at: receivedAt)
        var playing = !s.paused
        for p in live {
            switch p.action {
            case .seek(let t): fix = (t, p.at)
            case .scrub(let t):
                // Held where the finger is: the Mac pauses underneath while scrubbing.
                fix = (t, now); playing = false
            case .setPaused(let paused):
                // Advance to the moment of the tap, then hold (pause) or start counting (play).
                if playing { fix = (fix.position + max(p.at.timeIntervalSince(fix.at), 0), p.at) } else { fix.at = p.at }
                playing = !paused
                s.paused = paused
            case .audio(let id): s.audioID = id
            case .subtitle(let id): s.subtitleID = id
            case .volume(let v): s.volume = v
            case .nextEpisode, .closePlayer, .go, .focus, .move, .select, .play, .jump, .scroll, .setPointer, .pointer,
                 .click, .menu, .menuPick, .acceptSkip: break
            }
        }
        var position = fix.position + (playing ? max(now.timeIntervalSince(fix.at), 0) : 0)
        if let d = s.duration { position = min(position, d) }
        s.position = max(position, 0)
        return s
    }

    public static func kind(_ a: RemoteCommand.Action) -> Int {
        switch a {
        case .setPaused: 0
        case .seek, .scrub: 1
        case .nextEpisode: 2
        case .audio: 3
        case .subtitle: 4
        case .volume: 5
        case .closePlayer: 6
        // Each press counts: never replaced by the next one.
        case .go, .focus, .move, .select, .play, .jump, .scroll, .setPointer, .pointer, .click, .menu, .menuPick, .acceptSkip: 100
        }
    }

    /// A published state that shows the command took effect.
    static func confirms(_ s: RemoteNowPlaying, _ a: RemoteCommand.Action) -> Bool {
        switch a {
        case .setPaused(let p): s.paused == p
        case .seek(let t), .scrub(let t): abs(s.position - t) < 3
        case .nextEpisode, .closePlayer, .go, .focus, .move, .select, .play, .jump, .scroll, .setPointer, .pointer,
             .click, .menu, .menuPick, .acceptSkip: true
        case .audio(let id): s.audioID == id
        case .subtitle(let id): s.subtitleID == id
        case .volume(let v): abs(s.volume - v) < 0.02
        }
    }
}
