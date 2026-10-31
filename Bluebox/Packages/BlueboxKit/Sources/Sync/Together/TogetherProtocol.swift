import Foundation

/// Watch Party's message set. Everything goes over a Supabase Realtime room
/// with a join code, as JSON with a `type` field, like the remote control's,
/// so either side can add fields without breaking the other. The party's own
/// pieces (chat, reactions, the host's settings, up next) are in TogetherParty.swift.

/// The exact copy being watched, so another device can find the same one
/// through its own add-ons, debrid service or server. Two copies of a film can
/// differ by seconds (a studio logo, a different cut), so a copy that only
/// shares the title doesn't line up.
public struct TogetherRelease: Codable, Hashable, Sendable {
    /// The torrent's info hash, lowercased; the surest match.
    public var infoHash: String?
    /// The file within the torrent (season packs).
    public var fileIndex: Int?
    /// The add-on's or debrid service's own ID for it (`AddonRelease.id`, a
    /// debrid file ID), for links that carry no info hash.
    public var releaseID: String?
    /// The file name, when known: a second way to recognise the same file.
    public var fileName: String?
    public var sizeBytes: Int64?
    /// Seconds, once the starter's player knows it: a copy of the same length
    /// lines up even when nothing else matches.
    public var duration: TimeInterval?
    /// "1080p · WEB-DL · 4.2 GB", for "Sam is watching …".
    public var label: String

    public init(infoHash: String? = nil, fileIndex: Int? = nil, releaseID: String? = nil, fileName: String? = nil,
                sizeBytes: Int64? = nil, duration: TimeInterval? = nil, label: String) {
        self.infoHash = infoHash?.lowercased(); self.fileIndex = fileIndex; self.releaseID = releaseID
        self.fileName = fileName; self.sizeBytes = sizeBytes; self.duration = duration; self.label = label
    }

    /// How well a copy this device can play matches the one being watched.
    public enum Match: Int, Comparable, Sendable {
        case none
        /// Same length to within `lengthTolerance`: probably the same cut, from somewhere else.
        case sameLength
        /// Same file name and size, or the same add-on release ID.
        case sameFile
        /// Same info hash (and file).
        case exact

        public static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
    }

    /// Two copies whose lengths differ by less than this are taken to be the same cut.
    public static let lengthTolerance: TimeInterval = 1.5

    /// How `candidate` (a copy this device found) matches this one. Its
    /// `duration` is usually unknown before playing, so `.sameLength` is
    /// checked again once the player knows it.
    public func match(_ candidate: TogetherRelease) -> Match {
        if let hash = infoHash, hash == candidate.infoHash {
            // A pack: the same torrent but another episode's file is no match.
            if let mine = fileIndex, let theirs = candidate.fileIndex, mine >= 0, theirs >= 0, mine != theirs { return .none }
            return .exact
        }
        if let id = releaseID, id == candidate.releaseID { return .sameFile }
        if let name = fileName?.lowercased(), name == candidate.fileName?.lowercased(),
           let size = sizeBytes, size == candidate.sizeBytes { return .sameFile }
        if let a = duration, let b = candidate.duration, abs(a - b) < Self.lengthTolerance { return .sameLength }
        return .none
    }
}

/// What the room is watching.
public struct TogetherTitle: Codable, Hashable, Sendable {
    /// `MediaKey.rawValue`: the same on every device (TMDB or IMDb).
    public var key: String
    /// The title as the starter saw it, for "Sam started Dune" (never translated).
    public var name: String
    /// "S1·E2 · Pilot" for an episode.
    public var subtitle: String?
    public var release: TogetherRelease

    public init(key: String, name: String, subtitle: String? = nil, release: TogetherRelease) {
        self.key = key; self.name = name; self.subtitle = subtitle; self.release = release
    }
}

/// Someone in the room.
public struct TogetherParticipant: Codable, Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        /// Finding and opening the title.
        case loading
        case ready
        case buffering
        /// Their sources don't have it; the reason is shown as they wrote it.
        case unavailable(String)
    }

    /// The device, not the account: one person on two devices is two participants.
    public var id: String
    /// "Sam", from the profile name (or what they chose for this party).
    public var name: String
    /// The profile's avatar: an SF Symbol from `Profile.symbols` and a colour index.
    public var symbol: String
    public var color: Int
    /// When they joined, by their clock. The earliest participant still in the
    /// room is the one the others line up with (`TogetherRoom.anchor`).
    public var joinedAt: Date
    public var status: Status
    /// Stepped away: paused just for them, so nobody waits for them or lines up with them.
    public var away: Bool
    /// How well their copy matches the one being watched, once found (the lobby shows "Same-length copy").
    public var match: TogetherRelease.Match?
    /// The up-next proposal (`TogetherUpNext.id`) whose copy they've found.
    public var upNextReady: String?

    public init(id: String, name: String, symbol: String = "person.fill", color: Int = 0, joinedAt: Date,
                status: Status = .loading, away: Bool = false, match: TogetherRelease.Match? = nil, upNextReady: String? = nil) {
        self.id = id; self.name = name; self.symbol = symbol; self.color = color; self.joinedAt = joinedAt
        self.status = status; self.away = away; self.match = match; self.upNextReady = upNextReady
    }

    private enum CodingKeys: String, CodingKey { case id, name, symbol, color, joinedAt, status, away, match, upNextReady }

    // Fields added after the first round are optional, so an older peer's presence still reads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "person.fill"
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? 0
        joinedAt = try c.decode(Date.self, forKey: .joinedAt)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .loading
        away = try c.decodeIfPresent(Bool.self, forKey: .away) ?? false
        match = try c.decodeIfPresent(Int.self, forKey: .match).flatMap(TogetherRelease.Match.init(rawValue:))
        upNextReady = try c.decodeIfPresent(String.self, forKey: .upNextReady)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(symbol, forKey: .symbol); try c.encode(color, forKey: .color)
        try c.encode(joinedAt, forKey: .joinedAt); try c.encode(status, forKey: .status)
        if away { try c.encode(away, forKey: .away) }
        try c.encodeIfPresent(match?.rawValue, forKey: .match)
        try c.encodeIfPresent(upNextReady, forKey: .upNextReady)
    }

    /// Ready, loaded and not stepped away: someone playback can go ahead with.
    public var isWatching: Bool { !away && status == .ready }
}

extension TogetherParticipant.Status: Codable {
    private enum CodingKeys: String, CodingKey { case kind, reason }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "ready": self = .ready
        case "buffering": self = .buffering
        case "unavailable": self = .unavailable(try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        default: self = .loading  // an unknown status from a newer version reads as still loading
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .loading: try c.encode("loading", forKey: .kind)
        case .ready: try c.encode("ready", forKey: .kind)
        case .buffering: try c.encode("buffering", forKey: .kind)
        case .unavailable(let why): try c.encode("unavailable", forKey: .kind); try c.encode(why, forKey: .reason)
        }
    }
}

/// Where a player is, as of `sentAt` on the sender's clock.
public struct TogetherPlayhead: Codable, Hashable, Sendable {
    public var position: TimeInterval
    public var paused: Bool
    public var rate: Float
    public var sentAt: Date

    public init(position: TimeInterval, paused: Bool, rate: Float = 1, sentAt: Date) {
        self.position = position; self.paused = paused; self.rate = rate; self.sentAt = sentAt
    }

    /// The sender's longest believable trip: device clocks are only roughly in
    /// step, so a far-off `sentAt` is not believed beyond this.
    public static let maxTransit: TimeInterval = 2

    /// Where this player is at `now`, run forward from `sentAt` while playing.
    public func position(at now: Date) -> TimeInterval {
        guard !paused else { return position }
        let elapsed = min(max(now.timeIntervalSince(sentAt), 0), Self.maxTransit + 30)
        return position + elapsed * Double(rate)
    }
}

/// Something someone did that everyone else's player should do too. Each
/// carries the playhead it leaves, so a late or out-of-order copy still puts
/// the player in the right place.
public struct TogetherCommand: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable { case play, pause, seek, rate }

    public var action: Action
    /// The playhead just after the action, on the sender's clock.
    public var playhead: TogetherPlayhead
    /// A Lamport clock: higher wins, so two people tapping at once end up in
    /// the same state on every device (ties: the higher `from`).
    public var seq: Int
    public var from: String
    /// Not a press: the anchor paused for (or resumed after) these people
    /// buffering. Empty on the resume.
    public var waitingFor: [String]?

    public init(action: Action, playhead: TogetherPlayhead, seq: Int, from: String, waitingFor: [String]? = nil) {
        self.action = action; self.playhead = playhead; self.seq = seq; self.from = from; self.waitingFor = waitingFor
    }

    /// True when this command happened after `other` by the room's ordering.
    public func isNewer(than other: (seq: Int, from: String)?) -> Bool {
        guard let other else { return true }
        return seq != other.seq ? seq > other.seq : from > other.from
    }
}

/// Everything sent in a room.
public enum TogetherMessage: Hashable, Sendable {
    /// Someone arrived (or is still here). Everyone answers with their own
    /// `.presence`; whoever is playing also answers with `.title` and `.state`,
    /// the host with `.settings`, and the longest-present with `.history`.
    case hello(TogetherParticipant)
    /// Presence, answered to a hello and repeated with each heartbeat's status changes.
    case presence(TogetherParticipant)
    /// What's playing: sent on starting a title and to each newcomer.
    case title(TogetherTitle, from: String, seq: Int)
    case command(TogetherCommand)
    /// Every couple of seconds from each player, for drift correction.
    case state(from: String, TogetherPlayhead)
    case leave(from: String)
    case chat(TogetherChatMessage)
    case reaction(TogetherReaction)
    /// Typing in the chat (repeated while they type; it lapses on its own).
    case typing(from: String)
    /// The chat so far, for a newcomer (`to`), from whoever has been here longest.
    case history(to: String, from: String, messages: [TogetherChatMessage], reactions: [TogetherReaction])
    /// The host's settings: who's host, locked, removed, the queue.
    case settings(TogetherPartySettings)
    /// The host pressed Start in the lobby: everyone plays from `position` in `seconds`.
    case countdown(TogetherCountdown)
    /// What plays next, for everyone; a cancelled or started one is resent with its state.
    case upNext(TogetherUpNext)
    /// Someone looking at an invite before joining (`TogetherPeek`): everyone
    /// answers as they would a hello, but the asker isn't counted as here.
    /// Older versions can't read it and stay quiet, so the invite falls back to the link's details.
    case peek(from: String)
}

extension TogetherMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, participant, title, command, playhead, from, seq, chat, reaction, to, messages, reactions, settings,
             countdown, upNext
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello": self = .hello(try c.decode(TogetherParticipant.self, forKey: .participant))
        case "presence": self = .presence(try c.decode(TogetherParticipant.self, forKey: .participant))
        case "title":
            self = .title(try c.decode(TogetherTitle.self, forKey: .title), from: try c.decode(String.self, forKey: .from),
                          seq: try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0)
        case "command": self = .command(try c.decode(TogetherCommand.self, forKey: .command))
        case "state": self = .state(from: try c.decode(String.self, forKey: .from), try c.decode(TogetherPlayhead.self, forKey: .playhead))
        case "leave": self = .leave(from: try c.decode(String.self, forKey: .from))
        case "chat": self = .chat(try c.decode(TogetherChatMessage.self, forKey: .chat))
        case "reaction": self = .reaction(try c.decode(TogetherReaction.self, forKey: .reaction))
        case "typing": self = .typing(from: try c.decode(String.self, forKey: .from))
        case "history":
            self = .history(to: try c.decode(String.self, forKey: .to), from: try c.decode(String.self, forKey: .from),
                            messages: try c.decode([TogetherChatMessage].self, forKey: .messages),
                            reactions: try c.decodeIfPresent([TogetherReaction].self, forKey: .reactions) ?? [])
        case "settings": self = .settings(try c.decode(TogetherPartySettings.self, forKey: .settings))
        case "countdown": self = .countdown(try c.decode(TogetherCountdown.self, forKey: .countdown))
        case "upNext": self = .upNext(try c.decode(TogetherUpNext.self, forKey: .upNext))
        case "peek": self = .peek(from: try c.decode(String.self, forKey: .from))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown together message \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let p): try c.encode("hello", forKey: .type); try c.encode(p, forKey: .participant)
        case .presence(let p): try c.encode("presence", forKey: .type); try c.encode(p, forKey: .participant)
        case .title(let t, let from, let seq):
            try c.encode("title", forKey: .type); try c.encode(t, forKey: .title)
            try c.encode(from, forKey: .from); try c.encode(seq, forKey: .seq)
        case .command(let cmd): try c.encode("command", forKey: .type); try c.encode(cmd, forKey: .command)
        case .state(let from, let p): try c.encode("state", forKey: .type); try c.encode(from, forKey: .from); try c.encode(p, forKey: .playhead)
        case .leave(let from): try c.encode("leave", forKey: .type); try c.encode(from, forKey: .from)
        case .chat(let m): try c.encode("chat", forKey: .type); try c.encode(m, forKey: .chat)
        case .reaction(let r): try c.encode("reaction", forKey: .type); try c.encode(r, forKey: .reaction)
        case .typing(let from): try c.encode("typing", forKey: .type); try c.encode(from, forKey: .from)
        case .history(let to, let from, let messages, let reactions):
            try c.encode("history", forKey: .type); try c.encode(to, forKey: .to); try c.encode(from, forKey: .from)
            try c.encode(messages, forKey: .messages); try c.encode(reactions, forKey: .reactions)
        case .settings(let s): try c.encode("settings", forKey: .type); try c.encode(s, forKey: .settings)
        case .countdown(let d): try c.encode("countdown", forKey: .type); try c.encode(d, forKey: .countdown)
        case .upNext(let u): try c.encode("upNext", forKey: .type); try c.encode(u, forKey: .upNext)
        case .peek(let from): try c.encode("peek", forKey: .type); try c.encode(from, forKey: .from)
        }
    }

    /// Dates as milliseconds since 1970, the same on every platform.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d
    }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }
    public static func decode(_ data: Data) throws -> TogetherMessage { try decoder.decode(TogetherMessage.self, from: data) }

    public func jsonObject() throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: encoded()) as? [String: Any]) ?? [:]
    }

    public static func decode(jsonObject: Any) throws -> TogetherMessage {
        try decode(JSONSerialization.data(withJSONObject: jsonObject))
    }

    /// Who sent it.
    public var sender: String {
        switch self {
        case .hello(let p), .presence(let p): p.id
        case .title(_, let from, _), .state(let from, _), .leave(let from), .typing(let from), .history(_, let from, _, _),
             .peek(let from): from
        case .command(let c): c.from
        case .chat(let m): m.from
        case .reaction(let r): r.from
        case .settings(let s): s.from
        case .countdown(let d): d.from
        case .upNext(let u): u.from
        }
    }
}

/// A room's code: eight letters and digits a person can read out ("K7QM-2XDP"),
/// with the look-alikes (0/O, 1/I/L, U/V) left out. About 5·10¹¹ codes, so
/// guessing one that's in use isn't practical.
public struct TogetherJoinCode: Hashable, Sendable, CustomStringConvertible {
    public static let alphabet = Array("ABCDEFGHJKMNPQRSTWXYZ23456789")
    public static let length = 8

    /// Upper case, no dash.
    public let value: String

    /// Reads what someone typed: any case, spaces and dashes ignored.
    public init?(_ typed: String) {
        let cleaned = typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard cleaned.count == Self.length, cleaned.allSatisfy(Self.alphabet.contains) else { return nil }
        value = String(cleaned)
    }

    public static func random() -> TogetherJoinCode {
        var g = SystemRandomNumberGenerator()
        return random(using: &g)
    }

    public static func random<G: RandomNumberGenerator>(using g: inout G) -> TogetherJoinCode {
        TogetherJoinCode(String((0..<length).map { _ in alphabet.randomElement(using: &g)! }))!
    }

    /// "K7QM-2XDP"
    public var description: String { "\(value.prefix(4))-\(value.suffix(4))" }
}

/// Everything needed to reach a room from another person's Bluebox. Each
/// person's Bluebox talks to their own Supabase project, so the code alone
/// only works between devices on the same project; the invite link also
/// carries the host's project address and publishable key (which is public by
/// design: it lets an app ask, and the project's policies decide).
public struct TogetherInvite: Hashable, Sendable {
    public var code: TogetherJoinCode
    public var projectURL: URL
    public var publishableKey: String

    public init(code: TogetherJoinCode, projectURL: URL, publishableKey: String) {
        self.code = code; self.projectURL = projectURL; self.publishableKey = publishableKey
    }

    /// bluebox://party/K7QM2XDP?p=<project host>&k=<key>
    public var url: URL {
        var c = URLComponents()
        c.scheme = "bluebox"; c.host = "party"; c.path = "/" + code.value
        c.queryItems = [URLQueryItem(name: "p", value: projectURL.host() ?? projectURL.absoluteString),
                        URLQueryItem(name: "k", value: publishableKey)]
        return c.url!
    }

    /// The join page on Bluebox's GitHub Pages, which every chat app makes
    /// tappable: https://bcyayay14.github.io/bluebox/party.html#K7QM2XDP&p=<host>&k=<key>.
    /// The page shows the invitation with Open in Bluebox (`url`) and Get Bluebox.
    /// Everything after the # stays in the browser, so GitHub never sees the server or key.
    public var webURL: URL { webURL() }

    /// The join page's link, with who's inviting and what's on for the page to
    /// say ("Sam invited you to watch Dune"); the app ignores them.
    public func webURL(from inviter: String? = nil, watching title: String? = nil) -> URL {
        var c = URLComponents()
        c.scheme = "https"; c.host = Self.webHost; c.path = Self.webPath
        let fields: [(String, String?)] = [("p", projectURL.host() ?? projectURL.absoluteString), ("k", publishableKey),
                                           ("n", inviter.map { String($0.prefix(40)) }), ("t", title.map { String($0.prefix(120)) })]
        // & = + # are encoded inside a value (URLComponents would leave them), so "Tom & Jerry" can't add a field.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        let query = fields.compactMap { name, value -> String? in
            guard let value, !value.isEmpty, let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return name + "=" + encoded
        }
        c.percentEncodedFragment = ([code.value] + query).joined(separator: "&")
        return c.url!
    }

    static let webHost = "bcyayay14.github.io"
    static let webPath = "/bluebox/party.html"

    /// Reads a bluebox://party link or the join page's web link.
    public init?(url: URL) {
        let code: TogetherJoinCode?, query: String?
        switch url.scheme?.lowercased() {
        case "bluebox":
            // "together" was the first round's name; its links still open.
            guard url.host() == "party" || url.host() == "together" else { return nil }
            code = TogetherJoinCode(url.lastPathComponent)
            query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        case "https":
            // The join page, with or without .html (GitHub Pages serves both).
            guard url.host()?.lowercased() == Self.webHost, url.path == Self.webPath || url.path + ".html" == Self.webPath,
                  let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment else { return nil }
            let parts = fragment.split(separator: "&", maxSplits: 1).map(String.init)
            code = parts.first.flatMap { TogetherJoinCode($0) }
            query = parts.count > 1 ? parts[1] : nil
        default:
            return nil
        }
        var q = URLComponents()
        q.percentEncodedQuery = query
        let items = q.queryItems ?? []
        guard let code,
              let host = items.first(where: { $0.name == "p" })?.value, !host.isEmpty, !host.contains("/"),
              let key = items.first(where: { $0.name == "k" })?.value, !key.isEmpty,
              let project = URL(string: "https://\(host)") else { return nil }
        self.init(code: code, projectURL: project, publishableKey: key)
    }

    /// An invite link anywhere in some pasted text ("Join my Watch Party… https://…").
    public init?(text: String) {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" })
        guard let invite = words.lazy.compactMap({ URL(string: String($0)).flatMap(TogetherInvite.init(url:)) }).first else { return nil }
        self = invite
    }
}
