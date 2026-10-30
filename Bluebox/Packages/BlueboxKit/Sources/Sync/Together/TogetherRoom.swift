import Foundation
import Observation

/// How a room's messages travel: a Supabase Realtime room, or an in-memory hub in tests.
public protocol TogetherTransport: AnyObject, Sendable {
    /// Starts delivering messages from everyone else (never your own), in order.
    func start(onMessage: @escaping @Sendable (TogetherMessage) -> Void,
               onConnection: @escaping @Sendable (TogetherConnection) -> Void) async
    /// True when it went out.
    @discardableResult func send(_ message: TogetherMessage) async -> Bool
    func stop() async
}

public enum TogetherConnection: Sendable, Equatable {
    case connecting
    case connected
    /// Gave up; the reason is shown.
    case failed(String)
    case closed
}

/// One person's side of a Watch Party: who's here, what's playing, the
/// commands to apply, how far this player has drifted from the room, and the
/// party around it (chat, reactions, the host's settings, the lobby, up next).
/// It knows nothing about players; `TogetherPlayback` (Features) joins it to
/// one. Everything happens on the main actor, in the order messages arrive.
///
/// Ordering: commands, titles and the host's settings carry a Lamport clock,
/// so when two people press pause and play at once every device ends up
/// obeying the same one. Drift: everyone lines up with the anchor, the
/// longest-present participant who can play the title and hasn't stepped
/// away; when they leave, the next one is.
@MainActor @Observable
public final class TogetherRoom {
    public private(set) var me: TogetherParticipant
    /// Everyone else, by device ID.
    public private(set) var others: [String: TogetherParticipant] = [:]
    public private(set) var title: TogetherTitle?
    public private(set) var connection: TogetherConnection = .connecting
    /// Each participant's last known playhead (yours too).
    public private(set) var playheads: [String: TogetherPlayhead] = [:]

    // The party
    /// The chat and what happened, oldest first.
    public private(set) var feed: [TogetherFeedItem] = []
    /// Every reaction this party, oldest first (counts on messages, and late joiners get them).
    public private(set) var reactions: [TogetherReaction] = []
    /// The host's settings; nil until the host's arrive (or you start the party).
    public private(set) var settings: TogetherPartySettings?
    /// When the lobby's 3, 2, 1 reaches zero, on this device's clock.
    public private(set) var countdownEndsAt: Date?
    /// What plays next, while it's being found or counted down.
    public private(set) var upNext: TogetherUpNext?
    /// When up next starts, once everyone's copy is found.
    public private(set) var upNextEndsAt: Date?
    /// Why the party ended for you (removed, locked out, ended by the host).
    public private(set) var endedReason: String?
    @ObservationIgnored private var typingAt: [String: Date] = [:]
    /// Bumped by typing, so the "typing…" line is redrawn (`typingNames` reads the clock).
    public private(set) var typingRevision = 0

    /// A command from someone else for this player to apply.
    @ObservationIgnored public var onCommand: (@MainActor (TogetherCommand) -> Void)?
    /// Someone started a title (or you joined a room already watching one).
    @ObservationIgnored public var onTitle: (@MainActor (TogetherTitle) -> Void)?
    /// A chat message from someone else, as it arrives (not history).
    @ObservationIgnored public var onMessage: (@MainActor (TogetherChatMessage) -> Void)?
    /// A reaction from anyone, yours too: it floats over the video.
    @ObservationIgnored public var onReaction: (@MainActor (TogetherReaction) -> Void)?
    /// The lobby's Start: play from `position` when `countdownEndsAt` comes.
    @ObservationIgnored public var onCountdown: (@MainActor (TogetherCountdown) -> Void)?
    /// Something new is up next: find its copy, then `upNextFound`.
    @ObservationIgnored public var onUpNext: (@MainActor (TogetherUpNext) -> Void)?
    /// Up next is due (counted down, or Play Now). Only the host's Bluebox
    /// starts it (`start`), with the release it found; the others follow its title.
    @ObservationIgnored public var onUpNextDue: (@MainActor (TogetherUpNext) -> Void)?
    /// The party ended for you; the room has already left.
    @ObservationIgnored public var onEnded: (@MainActor (String) -> Void)?

    /// Not heard from for this long: gone (closed the app, lost the network).
    public static let goneAfter: TimeInterval = 15
    /// Drift isn't corrected this soon after a command: players are still getting there.
    public static let settleAfterCommand: TimeInterval = 2
    /// A pause or play that didn't arrive is put right after this long.
    public static let adoptAfter: TimeInterval = 4
    /// "Sam is typing…" lasts this long after their last keystroke message.
    public static let typingLasts: TimeInterval = 5
    /// Each person may send this many messages (and reactions) in `floodWindow`; more are dropped.
    public static let floodLimit = 6
    public static let floodWindow: TimeInterval = 5
    /// The feed and reactions kept on the device, and what a newcomer is sent.
    public static let keepMessages = 500
    public static let historyMessages = 200

    let transport: any TogetherTransport
    let now: @MainActor () -> Date
    @ObservationIgnored private var clock = 0
    @ObservationIgnored private var titleOrder: (seq: Int, from: String)?
    @ObservationIgnored private var lastCommand: (seq: Int, from: String)?
    @ObservationIgnored private var lastCommandAt: Date?
    @ObservationIgnored private var heard: [String: Date] = [:]
    @ObservationIgnored private var mismatchSince: Date?
    @ObservationIgnored private var drift = DriftCorrector()
    @ObservationIgnored private var recent: [String: [Date]] = [:]
    @ObservationIgnored private var lastTypingSent: Date?
    @ObservationIgnored private var gotHistory = false
    @ObservationIgnored private var dueSent: String?
    @ObservationIgnored private var inbox: Task<Void, Never>?
    @ObservationIgnored private var outbox: Task<Void, Never>?
    @ObservationIgnored private let outgoing: AsyncStream<TogetherMessage>.Continuation
    @ObservationIgnored private let outgoingStream: AsyncStream<TogetherMessage>

    public init(me: TogetherParticipant, transport: any TogetherTransport, now: @escaping @MainActor () -> Date = Date.init) {
        self.me = me; self.transport = transport; self.now = now
        (outgoingStream, outgoing) = AsyncStream<TogetherMessage>.makeStream()
    }

    // MARK: Joining and leaving

    /// Starts a party you host: you're its host, in the lobby (or watching straight away).
    public func host(lobby: Bool = true) {
        clock += 1
        settings = TogetherPartySettings(host: me.id, lobby: lobby, seq: clock, from: me.id)
        gotHistory = true
    }

    public func join() async {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        // One sender, so messages leave in the order they were made.
        let transport = transport, outgoingStream = outgoingStream
        outbox = Task { for await m in outgoingStream { await transport.send(m) } }
        inbox = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .message(let m): self.receive(m)
                case .connection(let c): self.connectionChanged(c)
                }
            }
        }
        await transport.start(onMessage: { continuation.yield(.message($0)) },
                              onConnection: { continuation.yield(.connection($0)) })
    }

    public func leave() async {
        // The host hands the party on rather than leaving it without one.
        if isHost, let next = successor(excluding: me.id), settings?.ended != true {
            updateSettings { $0.host = next.id }
        }
        outgoing.finish()
        await outbox?.value
        await transport.send(.leave(from: me.id))
        await transport.stop()
        inbox?.cancel(); inbox = nil; outbox = nil
        others.removeAll(); connection = .closed
    }

    private enum Event: Sendable { case message(TogetherMessage), connection(TogetherConnection) }

    private func connectionChanged(_ c: TogetherConnection) {
        connection = c
        // Say hello on every (re)connect: the others may have dropped us meanwhile.
        if c == .connected {
            send(.hello(me))
            if let settings, isHost { send(.settings(settings)) }
        }
    }

    // MARK: Incoming

    func receive(_ message: TogetherMessage) {
        let from = message.sender
        guard from != me.id, endedReason == nil else { return }
        // Removed by the host: nothing they send counts.
        if settings?.removed.contains(from) == true { return }
        let t = now()
        if case .leave = message {} else { heard[from] = t }
        switch message {
        case .hello(let p):
            guard admits(p.id) else {
                // Locked: the host's settings tell the newcomer so.
                if let settings, isHost { send(.settings(settings)) }
                return
            }
            let isNew = others[p.id] == nil
            others[p.id] = p
            if isNew { note("\(p.name) joined") }
            send(.presence(me))
            if let title, let titleOrder { send(.title(title, from: titleOrder.from, seq: titleOrder.seq)) }
            if let mine = playheads[me.id] { send(.state(from: me.id, mine)) }
            if let settings, isHost { send(.settings(settings)) }
            if let upNext, isHost { send(.upNext(upNext)) }
            // Whoever has been here longest hands the newcomer the chat so far.
            if gotHistory, successor(excluding: p.id)?.id == me.id {
                let messages = feed.compactMap { if case .message(let m) = $0 { m } else { nil } }.suffix(Self.historyMessages)
                let ids = Set(messages.map(\.id))
                send(.history(to: p.id, from: me.id, messages: Array(messages),
                              reactions: reactions.filter { $0.onMessage.map(ids.contains) ?? false }))
            }
        case .presence(let p):
            guard admits(p.id) else { return }
            if let was = others[p.id], was.away != p.away { note(p.away ? "\(p.name) stepped away" : "\(p.name) is back") }
            if others[p.id] == nil { note("\(p.name) joined") }
            others[p.id] = p
            checkUpNextReady()
        case .title(let newTitle, let starter, let seq):
            clock = max(clock, seq)
            guard isNewer(seq, starter, than: titleOrder) else { return }
            let changed = newTitle.key != title?.key || newTitle.release != title?.release
            titleOrder = (seq, starter); title = newTitle
            if changed {
                playheads.removeAll(); drift.reset(); lastCommand = nil
                upNext = nil; upNextEndsAt = nil
                onTitle?(newTitle)
            }
        case .command(let c):
            clock = max(clock, c.seq)
            playheads[c.from] = c.playhead
            // "Only I Control Playback": the others' presses don't count (waiting for a buffer does).
            if let settings, settings.hostOnlyControls, c.from != settings.host, c.waitingFor == nil { return }
            guard c.isNewer(than: lastCommand) else { return }
            lastCommand = (c.seq, c.from); lastCommandAt = t
            drift.reset(); mismatchSince = nil
            noteCommand(c, by: others[c.from]?.name)
            // Stepped away: the room moves on without you; Catch Up finds it.
            guard !me.away else { return }
            onCommand?(c)
        case .state(_, let p):
            playheads[from] = p
        case .leave:
            if let p = others[from] { note("\(p.name) left") }
            others[from] = nil; playheads[from] = nil; heard[from] = nil; typingAt[from] = nil
            settleHost()
            checkUpNextReady()
        case .chat(let m):
            guard allowed(from, at: t), !contains(m.id) else { return }
            typingAt[from] = nil
            typingRevision &+= 1
            append(.message(m))
            onMessage?(m)
        case .reaction(let r):
            guard allowed(from, at: t) else { return }
            addReaction(r)
            onReaction?(r)
        case .typing:
            typingAt[from] = t
            typingRevision &+= 1
        case .history(let to, _, let messages, let rx):
            guard to == me.id, !gotHistory else { return }
            gotHistory = true
            for m in messages where !contains(m.id) { feed.append(.message(m)) }
            feed.sort { $0.date < $1.date }
            let known = Set(reactions.map(\.id))
            reactions = (rx.filter { !known.contains($0.id) } + reactions).sorted { $0.sentAt < $1.sentAt }
        case .settings(let s):
            clock = max(clock, s.seq)
            guard s.isNewer(than: settings) else { return }
            apply(s)
        case .countdown(let d):
            countdownEndsAt = t.addingTimeInterval(TimeInterval(d.seconds))
            if settings?.lobby == true { settings?.lobby = false }
            onCountdown?(d)
        case .upNext(let u):
            receiveUpNext(u)
        }
    }

    private func isNewer(_ seq: Int, _ from: String, than other: (seq: Int, from: String)?) -> Bool {
        guard let other else { return true }
        return seq != other.seq ? seq > other.seq : from > other.from
    }

    /// Locked to newcomers: only those admitted when it was locked are let in.
    private func admits(_ id: String) -> Bool {
        guard let settings, settings.locked else { return true }
        return settings.admitted.contains(id) || others[id] != nil
    }

    private func allowed(_ from: String, at t: Date) -> Bool {
        let window = (recent[from] ?? []).filter { t.timeIntervalSince($0) < Self.floodWindow }
        guard window.count < Self.floodLimit else { recent[from] = window; return false }
        recent[from] = window + [t]
        return true
    }

    private func contains(_ messageID: String) -> Bool {
        feed.contains { $0.id == messageID }
    }

    private func append(_ item: TogetherFeedItem) {
        feed.append(item)
        if feed.count > Self.keepMessages { feed.removeFirst(feed.count - Self.keepMessages) }
    }

    private func addReaction(_ r: TogetherReaction) {
        guard !reactions.contains(where: { $0.id == r.id }) else { return }
        reactions.append(r)
        if reactions.count > Self.keepMessages { reactions.removeFirst(reactions.count - Self.keepMessages) }
    }

    private func note(_ text: String) {
        append(.event(id: UUID().uuidString, text: text, at: now()))
    }

    private func noteCommand(_ c: TogetherCommand, by name: String?) {
        let who = name ?? "Someone"
        if let waiting = c.waitingFor {
            if c.action == .pause, !waiting.isEmpty { note("Waiting for \(ListFormatter.localizedString(byJoining: waiting))") }
            return
        }
        switch c.action {
        case .pause: note("\(who) paused at \(Self.timecode(c.playhead.position))")
        case .seek: note("\(who) skipped to \(Self.timecode(c.playhead.position))")
        case .play, .rate: break
        }
    }

    /// "1:02:10", "4:05".
    public static func timecode(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Outgoing

    /// You started a title: everyone else finds and opens it.
    public func start(_ newTitle: TogetherTitle) {
        clock += 1
        titleOrder = (clock, me.id); title = newTitle
        playheads.removeAll(); drift.reset(); lastCommand = nil
        upNext = nil; upNextEndsAt = nil
        send(.title(newTitle, from: me.id, seq: clock))
    }

    /// May you play, pause and seek for everyone? Not while the host has the remote.
    public var canControl: Bool {
        guard let settings, settings.hostOnlyControls else { return true }
        return settings.host == me.id
    }

    /// You played, paused, seeked or changed speed: everyone else does too.
    /// Not for commands being applied from the room (that would echo). Nil
    /// when it stays on this device: you've stepped away, or the host has the remote.
    @discardableResult
    public func perform(_ action: TogetherCommand.Action, playhead: TogetherPlayhead,
                        waitingFor: [String]? = nil) -> TogetherCommand? {
        guard !me.away, canControl || waitingFor != nil else { return nil }
        clock += 1
        let c = TogetherCommand(action: action, playhead: playhead, seq: clock, from: me.id, waitingFor: waitingFor)
        lastCommand = (c.seq, c.from); lastCommandAt = now()
        playheads[me.id] = playhead
        drift.reset(); mismatchSince = nil
        noteCommand(c, by: "You")
        send(.command(c))
        return c
    }

    /// Every couple of seconds from the player: where it is, how it's doing.
    /// Also forgets people who've gone quiet, and runs the party's clocks.
    public func heartbeat(_ playhead: TogetherPlayhead?, status: TogetherParticipant.Status,
                          match: TogetherRelease.Match? = nil) {
        if let playhead {
            playheads[me.id] = playhead
            send(.state(from: me.id, playhead))
        }
        if status != me.status || (match != nil && match != me.match) {
            me.status = status
            if let match { me.match = match }
            send(.presence(me))
        }
        let t = now()
        var lost = false
        for (id, at) in heard where t.timeIntervalSince(at) > Self.goneAfter {
            if let p = others[id] { note("\(p.name) left") }
            others[id] = nil; playheads[id] = nil; heard[id] = nil; lost = true
        }
        if lost { settleHost(); checkUpNextReady() }
        tick()
    }

    /// Runs the up-next countdown; called by the heartbeat and by the party's
    /// own second-by-second timer.
    public func tick() {
        guard let upNext, let upNextEndsAt, now() >= upNextEndsAt else { return }
        due(upNext)
    }

    private func send(_ message: TogetherMessage) { outgoing.yield(message) }

    // MARK: Who you are

    /// "Change for this party": another name or avatar, without touching the profile.
    public func rename(_ name: String, symbol: String? = nil, color: Int? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        me.name = String(trimmed.prefix(40))
        if let symbol { me.symbol = symbol }
        if let color { me.color = color }
        send(.presence(me))
    }

    // MARK: Chat and reactions

    /// Sends a chat line (cut to 500 characters). Nil when it's empty.
    @discardableResult
    public func say(_ text: String, replyingTo reply: TogetherChatMessage? = nil, at position: TimeInterval? = nil) -> TogetherChatMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let m = TogetherChatMessage(from: me.id, name: me.name, symbol: me.symbol, color: me.color, text: trimmed, sentAt: now(),
                                    position: position,
                                    replyTo: reply.map { .init(id: $0.id, name: $0.name, text: String($0.text.prefix(120))) },
                                    mentions: TogetherChatMessage.mentions(in: trimmed, people: Array(others.values)))
        append(.message(m))
        lastTypingSent = nil
        send(.chat(m))
        return m
    }

    /// A quick reaction: floats up for everyone (you too), and counts on `message`.
    @discardableResult
    public func react(_ emoji: String, to message: TogetherChatMessage? = nil) -> TogetherReaction {
        let r = TogetherReaction(from: me.id, name: me.name, emoji: emoji, sentAt: now(), onMessage: message?.id)
        addReaction(r)
        onReaction?(r)
        send(.reaction(r))
        return r
    }

    /// Typing in the chat: tells the others at most every couple of seconds.
    public func typing() {
        let t = now()
        if let last = lastTypingSent, t.timeIntervalSince(last) < 2.5 { return }
        lastTypingSent = t
        send(.typing(from: me.id))
    }

    /// "Alex is typing…": the names, now.
    public var typingNames: [String] {
        _ = typingRevision
        let t = now()
        return typingAt.filter { t.timeIntervalSince($0.value) < Self.typingLasts }
            .compactMap { others[$0.key]?.name }.sorted()
    }

    /// 😂 3, 🔥 1 on a message, in the bar's order.
    public func reactionCounts(on messageID: String) -> [(emoji: String, count: Int)] {
        var counts: [String: Int] = [:]
        for r in reactions where r.onMessage == messageID { counts[r.emoji, default: 0] += 1 }
        return counts.sorted {
            let a = TogetherReaction.quick.firstIndex(of: $0.key) ?? 99, b = TogetherReaction.quick.firstIndex(of: $1.key) ?? 99
            return a != b ? a < b : $0.key < $1.key
        }.map { ($0.key, $0.value) }
    }

    // MARK: Stepping away

    /// Step Away: pause just for you. Nobody waits for you, you're not the
    /// anchor, and the room's commands wait until Catch Up.
    public func stepAway() {
        guard !me.away else { return }
        me.away = true
        note("You stepped away")
        send(.presence(me))
        checkUpNextReady()
    }

    /// Catch Up: back with the party. Returns where it is now, to jump to.
    @discardableResult
    public func catchUp() -> TogetherPlayhead? {
        guard me.away else { return nil }
        me.away = false
        drift.reset(); mismatchSince = nil
        lastCommandAt = now()
        send(.presence(me))
        return partyPlayhead
    }

    /// Where the party is now: the anchor's playhead, run forward to now.
    public var partyPlayhead: TogetherPlayhead? {
        let t = now()
        guard let anchor, anchor.id != me.id, let theirs = playheads[anchor.id] else { return nil }
        return TogetherPlayhead(position: theirs.position(at: t), paused: theirs.paused, rate: theirs.rate, sentAt: t)
    }

    // MARK: The host

    public var isHost: Bool { settings?.host == me.id }

    /// The host as a participant (you, or someone here).
    public var hostParticipant: TogetherParticipant? {
        guard let id = settings?.host else { return nil }
        return id == me.id ? me : others[id]
    }

    /// Everyone here, you first, then by when they joined.
    public var everyone: [TogetherParticipant] {
        [me] + others.values.sorted { ($0.joinedAt, $0.id) < ($1.joinedAt, $1.id) }
    }

    /// The longest-present participant other than `id`, who takes over as host
    /// (and hands newcomers the chat).
    private func successor(excluding id: String) -> TogetherParticipant? {
        everyone.filter { $0.id != id }.min { ($0.joinedAt, $0.id) < ($1.joinedAt, $1.id) }
    }

    /// The host is gone: the longest-present takes over, and says so.
    private func settleHost() {
        guard let settings, settings.host != me.id, others[settings.host] == nil else { return }
        guard let next = everyone.min(by: { ($0.joinedAt, $0.id) < ($1.joinedAt, $1.id) }), next.id == me.id else { return }
        updateSettings { $0.host = me.id }
        note("You're the host now")
    }

    private func updateSettings(_ change: (inout TogetherPartySettings) -> Void) {
        guard var s = settings else { return }
        change(&s)
        clock += 1
        s.seq = clock; s.from = me.id
        settings = s
        send(.settings(s))
    }

    private func apply(_ s: TogetherPartySettings) {
        let old = settings
        settings = s
        if s.ended { end("\(others[s.from]?.name ?? "The host") ended the party."); return }
        if s.removed.contains(me.id) { end("You were removed from the party."); return }
        // Everyone here when it was locked is admitted; anyone else is a newcomer it's locked to.
        if s.locked, !s.admitted.contains(me.id) { end("This party is locked."); return }
        for id in s.removed { others[id] = nil; playheads[id] = nil }
        if old?.host != s.host, old != nil {
            note(s.host == me.id ? "You're the host now" : "\(others[s.host]?.name ?? "Someone") is the host now")
        }
        if old?.hostOnlyControls != s.hostOnlyControls, old != nil {
            note(s.hostOnlyControls ? "Only \(hostParticipant?.name ?? "the host") controls playback" : "Everyone controls playback")
        }
    }

    private func end(_ reason: String) {
        guard endedReason == nil else { return }
        endedReason = reason
        onEnded?(reason)
    }

    /// Host only: "Only I Control Playback".
    public func setHostOnlyControls(_ on: Bool) {
        guard isHost else { return }
        updateSettings { $0.hostOnlyControls = on }
        note(on ? "Only you control playback" : "Everyone controls playback")
    }

    /// Host only: lock the party to newcomers (everyone here now stays in).
    public func setLocked(_ on: Bool) {
        guard isHost else { return }
        let ids = everyone.map(\.id)
        updateSettings { $0.locked = on; $0.admitted = on ? ids : [] }
        note(on ? "You locked the party" : "You unlocked the party")
    }

    /// Host only: removes someone for the rest of the party.
    public func remove(_ id: String) {
        guard isHost, id != me.id else { return }
        let name = others[id]?.name
        updateSettings { $0.removed.append(id) }
        others[id] = nil; playheads[id] = nil
        if let name { note("You removed \(name)") }
    }

    /// Host only: hands the party to someone else.
    public func makeHost(_ id: String) {
        guard isHost, let p = others[id] else { return }
        updateSettings { $0.host = id; $0.hostOnlyControls = false }
        note("\(p.name) is the host now")
    }

    /// Host only: ends the party for everyone (then leave).
    public func endForEveryone() {
        guard isHost else { return }
        updateSettings { $0.ended = true }
    }

    /// Host only: starts the lobby's 3, 2, 1 from `position`.
    public func startCountdown(from position: TimeInterval, seconds: Int = 3) {
        guard isHost else { return }
        let d = TogetherCountdown(position: position, seconds: seconds, from: me.id)
        countdownEndsAt = now().addingTimeInterval(TimeInterval(seconds))
        updateSettings { $0.lobby = false }
        send(.countdown(d))
        onCountdown?(d)
    }

    /// Host only: adds a title to "Up next in the party".
    public func enqueue(_ item: TogetherQueueItem) {
        guard isHost else { return }
        updateSettings { $0.queue.append(item) }
    }

    /// Host only: takes a title off the queue.
    public func dequeue(_ id: String) {
        guard isHost else { return }
        updateSettings { $0.queue.removeAll { $0.id == id } }
    }

    // MARK: Up next

    /// Host only: proposes what plays next (the next episode, or the queue's first).
    public func proposeUpNext(_ item: TogetherQueueItem, fromQueue: Bool) {
        guard isHost, upNext?.item.key != item.key else { return }
        let u = TogetherUpNext(item: item, fromQueue: fromQueue, from: me.id)
        upNext = u; upNextEndsAt = nil; dueSent = nil
        me.upNextReady = nil
        send(.upNext(u))
        onUpNext?(u)
    }

    /// This device found its copy of up next.
    public func upNextFound(_ id: String) {
        guard upNext?.id == id, me.upNextReady != id else { return }
        me.upNextReady = id
        send(.presence(me))
        checkUpNextReady()
    }

    /// Cancel: nobody's next episode starts.
    public func cancelUpNext() {
        guard var u = upNext else { return }
        u.phase = .cancelled; u.by = me.name; u.from = me.id
        upNext = nil; upNextEndsAt = nil
        note("You cancelled \(u.item.subtitle ?? u.item.name)")
        send(.upNext(u))
    }

    /// Play Now: skip the countdown.
    public func playUpNextNow() {
        guard var u = upNext else { return }
        u.phase = .now; u.by = me.name; u.from = me.id
        upNext = u
        send(.upNext(u))
        due(u)
    }

    private func receiveUpNext(_ u: TogetherUpNext) {
        switch u.phase {
        case .pending:
            guard upNext?.id != u.id else { return }
            upNext = u; upNextEndsAt = nil; dueSent = nil
            onUpNext?(u)
        case .cancelled:
            guard upNext?.id == u.id else { return }
            upNext = nil; upNextEndsAt = nil
            note("\(u.by ?? "Someone") cancelled \(u.item.subtitle ?? u.item.name)")
        case .now:
            upNext = u
            due(u)
        }
    }

    /// Everyone watching has found their copy: the ten seconds start.
    private func checkUpNextReady() {
        guard let upNext, upNext.phase == .pending, upNextEndsAt == nil else { return }
        let watching = everyone.filter { !$0.away }
        guard !watching.isEmpty, watching.allSatisfy({ $0.upNextReady == upNext.id }) else { return }
        upNextEndsAt = now().addingTimeInterval(TimeInterval(TogetherUpNext.countdown))
    }

    private func due(_ u: TogetherUpNext) {
        guard dueSent != u.id else { return }
        dueSent = u.id
        upNextEndsAt = nil
        if isHost, u.fromQueue { updateSettings { $0.queue.removeAll { $0.id == u.item.id } } }
        onUpNextDue?(u)
    }

    // MARK: Staying in step

    /// The participant everyone lines up with: present longest, able to play
    /// it, and not stepped away.
    public var anchor: TogetherParticipant? {
        everyone
            .filter { if case .unavailable = $0.status { false } else { !$0.away } }
            .min { ($0.joinedAt, $0.id) < ($1.joinedAt, $1.id) }
    }

    /// People the others are waiting on: still opening the title, or buffering
    /// (not those who stepped away on purpose).
    public var waitingFor: [TogetherParticipant] {
        guard title != nil else { return [] }
        return others.values.filter { !$0.away && ($0.status == .loading || $0.status == .buffering) }.sorted { $0.name < $1.name }
    }

    /// People whose sources don't have the title.
    public var unavailable: [TogetherParticipant] {
        others.values.filter { if case .unavailable = $0.status { true } else { false } }.sorted { $0.name < $1.name }
    }

    public enum Fix: Equatable, Sendable {
        case none
        case drift(DriftCorrector.Correction)
        /// The anchor is paused while this plays (or the other way round) and
        /// no command explains it: a pause or play went missing. Match it.
        case match(TogetherPlayhead)
    }

    /// What this player should do to stay with the anchor, given where it is.
    public func fix(for local: TogetherPlayhead) -> Fix {
        let t = now()
        guard !me.away, let anchor, anchor.id != me.id, let theirs = playheads[anchor.id] else { return .none }
        if let lastCommandAt, t.timeIntervalSince(lastCommandAt) < Self.settleAfterCommand { return .none }
        if theirs.paused != local.paused {
            let since = mismatchSince ?? t
            mismatchSince = since
            guard t.timeIntervalSince(since) >= Self.adoptAfter else { return .none }
            mismatchSince = nil; drift.reset()
            return .match(TogetherPlayhead(position: theirs.position(at: t), paused: theirs.paused, rate: theirs.rate, sentAt: t))
        }
        mismatchSince = nil
        guard !local.paused else {
            // Both paused: line up the frame only when it's well off.
            let gap = abs(local.position - theirs.position)
            return gap >= drift.seekBeyond ? .drift(.seek(to: theirs.position)) : .none
        }
        let correction = drift.correct(local: local.position(at: t), anchor: theirs.position(at: t), rate: theirs.rate)
        return correction == .none ? .none : .drift(correction)
    }
}
