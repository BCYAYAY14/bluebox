import Foundation
import Observation

/// A look at a party before joining it, for the invitation (Join the Party):
/// who's hosting, what's on, who's there, and whether it has started. It
/// listens on the room's channel and asks with `.peek`; the people there
/// answer as they would a hello, but don't count you as here. Nobody
/// answering (an empty room, or only older versions in it) leaves the
/// invitation with what the link says.
@MainActor @Observable
public final class TogetherPeek {
    public enum Situation: Equatable, Sendable {
        /// Reaching the room, or waiting for the first answer.
        case looking
        /// Nobody answered: an empty room, or only older versions of Bluebox in it.
        case quiet
        /// Nobody has pressed Start.
        case lobby
        /// Under way: where the party is now, when anyone has said (paused or playing).
        case playing(TogetherPlayhead?)
        /// In, but the host hasn't picked anything yet.
        case picking
        case locked
        case ended
        /// The room couldn't be reached; the reason is shown.
        case unreachable(String)
    }

    /// Everyone who answered, by device ID.
    public private(set) var people: [String: TogetherParticipant] = [:]
    public private(set) var title: TogetherTitle?
    public private(set) var settings: TogetherPartySettings?
    public private(set) var playheads: [String: TogetherPlayhead] = [:]
    public private(set) var connection: TogetherConnection = .connecting
    /// Someone in the room has answered.
    public private(set) var answered = false
    /// Connected, asked `attempts` times, and nobody answered.
    public internal(set) var gaveUp = false

    /// This device's ID, so a locked party's admitted list can be checked.
    public let id: String
    let transport: any TogetherTransport
    let now: @MainActor () -> Date
    let askEvery: Duration
    let attempts: Int
    @ObservationIgnored private var titleOrder: (seq: Int, from: String)?
    @ObservationIgnored private var inbox: Task<Void, Never>?
    @ObservationIgnored private var asking: Task<Void, Never>?

    /// Asks every `askEvery` until someone answers, giving up after `attempts`.
    public init(id: String, transport: any TogetherTransport, askEvery: Duration = .seconds(2), attempts: Int = 3,
                now: @escaping @MainActor () -> Date = Date.init) {
        self.id = id; self.transport = transport; self.askEvery = askEvery; self.attempts = attempts; self.now = now
    }

    public func start() async {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
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

    /// Stops listening; joining makes its own connection.
    public func stop() async {
        asking?.cancel(); asking = nil
        inbox?.cancel(); inbox = nil
        await transport.stop()
    }

    private enum Event: Sendable { case message(TogetherMessage), connection(TogetherConnection) }

    private func connectionChanged(_ c: TogetherConnection) {
        connection = c
        // Ask again on every (re)connect until someone answers.
        guard c == .connected, !answered else { return }
        asking?.cancel()
        let transport = transport, id = id, every = askEvery, attempts = attempts
        asking = Task { @MainActor [weak self] in
            for _ in 0..<attempts {
                guard let self, !self.answered, !Task.isCancelled else { return }
                await transport.send(.peek(from: id))
                try? await Task.sleep(for: every)
            }
            guard let self, !Task.isCancelled else { return }
            if !self.answered { self.gaveUp = true }
        }
    }

    func receive(_ message: TogetherMessage) {
        switch message {
        case .hello(let p), .presence(let p):
            guard p.id != id else { return }
            people[p.id] = p
            answered = true
        case .title(let t, let from, let seq):
            if let o = titleOrder, seq != o.seq ? seq < o.seq : from < o.from { return }
            titleOrder = (seq, from)
            if t.key != title?.key || t.release != title?.release { playheads.removeAll() }
            title = t
            answered = true
        case .state(let from, let p):
            playheads[from] = p
        case .settings(let s):
            guard s.isNewer(than: settings) else { return }
            settings = s
            answered = true
        case .countdown:
            settings?.lobby = false
        case .leave(let from):
            people[from] = nil; playheads[from] = nil
        case .command(let c):
            playheads[c.from] = c.playhead
        default:
            break
        }
    }

    // MARK: What the invitation reads

    public var host: TogetherParticipant? { settings.flatMap { people[$0.host] } }

    /// Everyone here, the host first, then by when they joined.
    public var everyone: [TogetherParticipant] {
        let hostID = settings?.host
        return people.values.sorted {
            if ($0.id == hostID) != ($1.id == hostID) { return $0.id == hostID }
            return ($0.joinedAt, $0.id) < ($1.joinedAt, $1.id)
        }
    }

    /// Where the party is now: the longest-present watcher's playhead, run forward to now.
    public var partyPlayhead: TogetherPlayhead? {
        let anchor = people.values
            .filter { if case .unavailable = $0.status { false } else { !$0.away && playheads[$0.id] != nil } }
            .min { ($0.joinedAt, $0.id) < ($1.joinedAt, $1.id) }
        guard let anchor, let theirs = playheads[anchor.id] else { return nil }
        let t = now()
        return TogetherPlayhead(position: theirs.position(at: t), paused: theirs.paused, rate: theirs.rate, sentAt: t)
    }

    public var situation: Situation {
        if case .failed(let why) = connection { return .unreachable(why) }
        if let settings {
            if settings.ended { return .ended }
            if settings.locked, !settings.admitted.contains(id) { return .locked }
        }
        guard answered else { return gaveUp ? .quiet : .looking }
        if settings?.lobby == true { return .lobby }
        guard title != nil else { return .picking }
        return .playing(partyPlayhead)
    }
}
