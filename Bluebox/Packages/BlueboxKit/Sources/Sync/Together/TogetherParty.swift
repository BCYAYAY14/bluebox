import Foundation

// A Watch Party's own pieces, beside playing in step: the chat, reactions,
// the host's settings, the lobby's 3-2-1 and what plays next. Nothing here is
// stored on the server: the room's devices hold it for as long as the party
// lasts, and whoever has been there longest hands it to newcomers.

/// A line in the party's chat.
public struct TogetherChatMessage: Codable, Hashable, Sendable, Identifiable {
    /// The line it answers, quoted as it was so a reply reads without scrolling.
    public struct Reply: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var text: String

        public init(id: String, name: String, text: String) { self.id = id; self.name = name; self.text = text }
    }

    public var id: String
    public var from: String
    /// The sender's name and avatar when they wrote it (they may have left since).
    public var name: String
    public var symbol: String
    public var color: Int
    public var text: String
    public var sentAt: Date
    /// Where the film was, for the time beside the name.
    public var position: TimeInterval?
    public var replyTo: Reply?
    /// Participant IDs named with @.
    public var mentions: [String]

    /// Longer messages are cut to this.
    public static let maxLength = 500

    public init(id: String = UUID().uuidString, from: String, name: String, symbol: String = "person.fill", color: Int = 0,
                text: String, sentAt: Date, position: TimeInterval? = nil, replyTo: Reply? = nil, mentions: [String] = []) {
        self.id = id; self.from = from; self.name = name; self.symbol = symbol; self.color = color
        self.text = String(text.prefix(Self.maxLength)); self.sentAt = sentAt; self.position = position
        self.replyTo = replyTo; self.mentions = mentions
    }

    private enum CodingKeys: String, CodingKey { case id, from, name, symbol, color, text, sentAt, position, replyTo, mentions }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), from: try c.decode(String.self, forKey: .from),
                  name: try c.decode(String.self, forKey: .name),
                  symbol: try c.decodeIfPresent(String.self, forKey: .symbol) ?? "person.fill",
                  color: try c.decodeIfPresent(Int.self, forKey: .color) ?? 0,
                  text: try c.decode(String.self, forKey: .text), sentAt: try c.decode(Date.self, forKey: .sentAt),
                  position: try c.decodeIfPresent(TimeInterval.self, forKey: .position),
                  replyTo: try c.decodeIfPresent(Reply.self, forKey: .replyTo),
                  mentions: try c.decodeIfPresent([String].self, forKey: .mentions) ?? [])
    }

    /// The people `text` names with "@Name", matched against `people`
    /// (longest names first, so "@Sam Lee" isn't taken for "@Sam").
    public static func mentions(in text: String, people: [TogetherParticipant]) -> [String] {
        let lowered = text.lowercased()
        var found: [String] = []
        var taken = Set<String>()
        for p in people.sorted(by: { $0.name.count > $1.name.count }) where !p.name.isEmpty {
            let handle = "@" + p.name.lowercased()
            guard let range = lowered.range(of: handle) else { continue }
            let key = "\(lowered.distance(from: lowered.startIndex, to: range.lowerBound))"
            // A shorter name inside a longer one already matched at the same place.
            guard !taken.contains(key) else { continue }
            taken.insert(key)
            found.append(p.id)
        }
        return found
    }
}

/// A quick reaction: it floats up over everyone's video and adds up on the
/// message it answers.
public struct TogetherReaction: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var from: String
    public var name: String
    public var emoji: String
    public var sentAt: Date
    /// The chat line it answers, when it was sent from one.
    public var onMessage: String?

    /// 😂 😮 😍 😱 👏 🔥, in the bar's order (⌥1–6 on the Mac).
    public static let quick = ["😂", "😮", "😍", "😱", "👏", "🔥"]

    public init(id: String = UUID().uuidString, from: String, name: String, emoji: String, sentAt: Date, onMessage: String? = nil) {
        self.id = id; self.from = from; self.name = name; self.emoji = emoji; self.sentAt = sentAt; self.onMessage = onMessage
    }
}

/// What the host decides for everyone. Ordered like titles and commands: a
/// Lamport `seq`, ties to the higher `from`, so two hosts (one leaving, one
/// taking over) settle on the same settings everywhere.
public struct TogetherPartySettings: Codable, Hashable, Sendable {
    public var host: String
    /// Still in the lobby: nobody has pressed Start.
    public var lobby: Bool
    /// "Only I Control Playback": the others' play, pause and seek don't go to the room.
    public var hostOnlyControls: Bool
    /// Locked to newcomers: only `admitted` (who was here when it was locked) stay.
    public var locked: Bool
    public var admitted: [String]
    /// Removed by the host; their messages are ignored for the rest of the party.
    public var removed: [String]
    /// "Up next in the party", after the episode that's playing.
    public var queue: [TogetherQueueItem]
    /// The host ended the party for everyone.
    public var ended: Bool
    public var seq: Int
    public var from: String

    public init(host: String, lobby: Bool = true, hostOnlyControls: Bool = false, locked: Bool = false, admitted: [String] = [],
                removed: [String] = [], queue: [TogetherQueueItem] = [], ended: Bool = false, seq: Int = 0, from: String) {
        self.host = host; self.lobby = lobby; self.hostOnlyControls = hostOnlyControls; self.locked = locked
        self.admitted = admitted; self.removed = removed; self.queue = queue; self.ended = ended; self.seq = seq; self.from = from
    }

    func isNewer(than other: TogetherPartySettings?) -> Bool {
        guard let other else { return true }
        return seq != other.seq ? seq > other.seq : from > other.from
    }
}

/// A title waiting in the party's queue. Its release is chosen when it comes
/// up, by the host's Bluebox, and matched by everyone else's as usual.
public struct TogetherQueueItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// `MediaKey.rawValue`.
    public var key: String
    public var name: String
    /// "S1·E4 · The You You Are".
    public var subtitle: String?

    public init(id: String = UUID().uuidString, key: String, name: String, subtitle: String? = nil) {
        self.id = id; self.key = key; self.name = name; self.subtitle = subtitle
    }
}

/// The lobby's Start: everyone plays from `position` once `seconds` have passed
/// since it arrived (the trip is a fraction of a second; drift correction
/// closes what's left).
public struct TogetherCountdown: Codable, Hashable, Sendable {
    public var position: TimeInterval
    public var seconds: Int
    public var from: String

    public init(position: TimeInterval, seconds: Int = 3, from: String) {
        self.position = position; self.seconds = seconds; self.from = from
    }
}

/// What plays next for everyone (the next episode, or the queue's first).
/// Proposed by the host when the episode ends; each device finds its copy and
/// says so (`TogetherParticipant.upNextReady`). Once everyone has, a ten-second
/// countdown runs that anyone can cancel; Play Now skips it.
public struct TogetherUpNext: Codable, Hashable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        /// Finding copies, then counting down.
        case pending
        /// Somebody pressed Play Now.
        case now
        case cancelled
    }

    public var id: String
    public var item: TogetherQueueItem
    /// Taken from the queue (the host drops it from there when it starts).
    public var fromQueue: Bool
    public var phase: Phase
    /// Who cancelled or pressed Play Now, by name, for "Sam cancelled".
    public var by: String?
    public var from: String

    public static let countdown = 10

    public init(id: String = UUID().uuidString, item: TogetherQueueItem, fromQueue: Bool = false, phase: Phase = .pending,
                by: String? = nil, from: String) {
        self.id = id; self.item = item; self.fromQueue = fromQueue; self.phase = phase; self.by = by; self.from = from
    }
}

/// A line in the chat panel: a message, or something that happened.
public enum TogetherFeedItem: Hashable, Sendable, Identifiable {
    case message(TogetherChatMessage)
    /// "Mia joined", "Alex paused at 1:02:10", "Mia stepped away".
    case event(id: String, text: String, at: Date)

    public var id: String {
        switch self {
        case .message(let m): m.id
        case .event(let id, _, _): id
        }
    }

    public var date: Date {
        switch self {
        case .message(let m): m.sentAt
        case .event(_, _, let at): at
        }
    }
}
