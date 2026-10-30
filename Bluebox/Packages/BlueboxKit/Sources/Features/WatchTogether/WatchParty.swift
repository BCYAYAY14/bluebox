import Domain
import Foundation
import Observation
import Playback
import Sync
#if os(macOS)
import AppKit
#else
import AudioToolbox
#endif

/// A Watch Party as the app sees it: the room, the player it's joined to,
/// and what the party's UI shows (the chat panel, reactions floating up,
/// messages over the film, the lobby's 3-2-1, up next). `AppModel.party`
/// holds the one you're in; AppModel+WatchParty.swift starts and joins them.
@MainActor @Observable
public final class WatchParty {
    public enum Phase: Equatable {
        case connecting
        /// Finding this device's copy of what the party is watching.
        case finding(String)
        case watching
        /// The party is over for you (removed, locked out, ended, or the room couldn't be reached).
        case ended(String)
    }

    /// Something floating up over the video: one emoji, or a burst merged ("😂 ×6").
    public struct Float: Identifiable, Equatable {
        public let id: String
        public let emoji: String
        public var count: Int
        /// 0…1 across the float lane, so a burst spreads out.
        public let lane: Double
        public let born: Date
    }

    public let room: TogetherRoom
    public let invite: TogetherInvite
    public private(set) var phase: Phase = .connecting
    /// The chat panel beside the video (Mac) or over/under it (iPhone).
    public var chatOpen = true {
        didSet { if chatOpen { unread = 0; bubbles = [] } }
    }
    /// Muted: no sounds and nothing over the film for this party.
    public var muted = false
    public var replyingTo: TogetherChatMessage?
    public private(set) var floats: [Float] = []
    /// The last messages, shown over the film for a few seconds while the chat is closed.
    public private(set) var bubbles: [TogetherChatMessage] = []
    public private(set) var unread = 0
    /// The lobby's 3, 2, 1, while it counts.
    public private(set) var countdown: Int?
    /// Up next's seconds left, once everyone's copy is found.
    public private(set) var upNextRemaining: Int?
    /// Your copy is a different length from the party's.
    public private(set) var copyProblem: String?
    /// Messages naming you, so the panel can highlight them.
    public private(set) var mentionedIDs: Set<String> = []

    /// Settings › Playback › Show Party Messages Over the Video.
    public static let bubblesKey = "bluebox.party.bubbles"
    static let bubbleLife: TimeInterval = 6
    static let floatLife: TimeInterval = 2.2

    @ObservationIgnored var playback: TogetherPlayback?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var countdownFrom: TimeInterval?
    @ObservationIgnored private var waitingPaused = false
    @ObservationIgnored private var proposedAfter: String?
    @ObservationIgnored private var joinedFilm = false

    init(room: TogetherRoom, invite: TogetherInvite, app: AppModel) {
        self.room = room; self.invite = invite; self.app = app
        room.onMessage = { [weak self] m in self?.heard(m) }
        room.onReaction = { [weak self] r in self?.float(r.emoji) }
        room.onCountdown = { [weak self] d in self?.countdownFrom = d.position }
        room.onEnded = { [weak self] reason in
            guard let self else { return }
            self.phase = .ended(reason)
            Task { await self.app?.partyEnded(self, reason: reason) }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    func stop() {
        timer?.cancel(); timer = nil
        playback?.detach(); playback = nil
    }

    // MARK: What the UI reads

    public var isHost: Bool { room.isHost }
    public var isLobby: Bool { room.settings?.lobby == true && countdown == nil }
    public var people: [TogetherParticipant] { room.everyone }
    public var title: TogetherTitle? { room.title }
    public var away: Bool { room.me.away }
    public var showsBubbles: Bool { UserDefaults.standard.object(forKey: Self.bubblesKey) as? Bool ?? true }

    /// "In step", "Waiting for Alex", "you're away".
    public var stateLine: String {
        if away { return "you're away" }
        if isLobby { return "in the lobby" }
        let waiting = room.waitingFor.map(\.name)
        if !waiting.isEmpty { return "waiting for " + ListFormatter.localizedString(byJoining: waiting) }
        return "in step"
    }

    // MARK: Joining the player

    /// Joins the room to the player that just opened (again, after each title).
    func attach(_ session: PlayerSession, match: TogetherRelease.Match?) {
        playback?.detach()
        let p = TogetherPlayback(room: room, session: session)
        p.match = match
        p.attach()
        playback = p
        // The party decides what plays next, not the player's own Up Next.
        session.autoplayNext = false
        joinedFilm = false
        copyProblem = nil
        phase = .watching
    }

    func finding(_ what: String) { phase = .finding(what) }

    func failed(_ reason: String) {
        copyProblem = reason
        phase = .watching
    }

    // MARK: Chat

    public func send(_ text: String) {
        let at = playback?.session.displayPosition
        room.say(text, replyingTo: replyingTo, at: at)
        replyingTo = nil
    }

    public func react(_ emoji: String, to message: TogetherChatMessage? = nil) {
        room.react(emoji, to: message)
    }

    private func heard(_ m: TogetherChatMessage) {
        let mentioned = m.mentions.contains(room.me.id)
        if mentioned {
            mentionedIDs.insert(m.id)
            if !muted { Self.playMentionSound() }
        }
        guard !chatOpen else { return }
        unread += 1
        if !muted, showsBubbles {
            bubbles = Array((bubbles + [m]).suffix(2))
        }
    }

    private func float(_ emoji: String) {
        let now = Date()
        // A burst of the same one merges into one that counts up.
        if let i = floats.lastIndex(where: { $0.emoji == emoji && now.timeIntervalSince($0.born) < 1.2 }) {
            floats[i].count += 1
            return
        }
        floats.append(Float(id: UUID().uuidString, emoji: emoji, count: 1, lane: .random(in: 0...1), born: now))
    }

    static func playMentionSound() {
        #if os(macOS)
        NSSound(named: "Tink")?.play()
        #else
        AudioServicesPlaySystemSound(1003)
        #endif
    }

    // MARK: Stepping away

    public func stepAway() {
        guard let playback, !away else { return }
        room.stepAway()
        if playback.session.appearsPlaying { playback.applyLocally { playback.session.togglePlayPause() } }
    }

    public func catchUp() {
        guard let playback else { return }
        if let target = room.catchUp() {
            Task { await playback.move(to: target, setRate: false) }
        } else if !playback.session.appearsPlaying {
            playback.applyLocally { playback.session.togglePlayPause() }
        }
    }

    // MARK: The lobby

    /// The host's Start: everyone counts down together and plays.
    public func startTogether() {
        guard let playback else { return }
        room.startCountdown(from: playback.session.displayPosition)
    }

    // MARK: The clock

    private func tick() async {
        let now = Date()
        room.tick()
        floats.removeAll { now.timeIntervalSince($0.born) > Self.floatLife }
        if let first = bubbles.first, now.timeIntervalSince(first.sentAt) > Self.bubbleLife || chatOpen {
            bubbles.removeFirst()
        }
        upNextRemaining = room.upNextEndsAt.map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }

        guard let playback else { return }
        let session = playback.session
        let duration = session.snapshot.duration ?? 0
        // The host tells the room what's playing once the player knows its length (same-length copies need it).
        if room.isHost, room.title == nil || room.title?.key != session.item?.key.rawValue,
           let item = session.item, let resource = session.currentResource, duration > 0 {
            room.start(TogetherTitle(key: item.key.rawValue, name: item.title, subtitle: item.subtitle,
                                     release: TogetherRelease(resource.variant, duration: duration)))
        }
        checkLength(session)

        // The lobby's 3, 2, 1, then everyone plays from the same frame.
        if let ends = room.countdownEndsAt, let from = countdownFrom {
            let left = ends.timeIntervalSince(now)
            if left > 0 {
                countdown = Int(left.rounded(.up))
            } else {
                countdown = nil; countdownFrom = nil
                joinedFilm = true
                if !away { await playback.move(to: TogetherPlayhead(position: from, paused: false, sentAt: now), setRate: false) }
            }
        }

        // Joining mid-film: jump to where the party is, once this player has opened.
        if !joinedFilm, room.settings?.lobby == false, countdownFrom == nil, duration > 0, !room.isHost {
            joinedFilm = true
            if let there = room.partyPlayhead { await playback.move(to: there, setRate: true) }
        }

        // Everyone waits for whoever buffers: the anchor pauses the room, and plays again after.
        if room.anchor?.id == room.me.id, room.settings?.lobby == false, countdownFrom == nil {
            let waiting = room.waitingFor.map(\.name)
            if !waiting.isEmpty, session.appearsPlaying, !waitingPaused {
                waitingPaused = true
                playback.pauseForWaiting(waiting)
            } else if waiting.isEmpty, waitingPaused {
                waitingPaused = false
                playback.resumeAfterWaiting()
            }
        }

        // The episode ended: the host proposes what's next for everyone.
        if room.isHost, let key = session.item?.key, proposedAfter != key.rawValue, session.snapshot.status == .ended
            || (duration > 0 && session.snapshot.position >= duration - 1) {
            proposedAfter = key.rawValue
            await app?.proposeNext(after: key, in: self)
        }
    }

    /// A copy that isn't the party's own is checked against its length once the player knows it.
    private func checkLength(_ session: PlayerSession) {
        guard let playback, playback.match == nil, let theirs = room.title?.release.duration,
              session.item?.key.rawValue == room.title?.key, let mine = session.snapshot.duration, mine > 0 else { return }
        if abs(mine - theirs) < TogetherRelease.lengthTolerance {
            playback.match = .sameLength
        } else {
            playback.match = TogetherRelease.Match.none
            copyProblem = "Your copy is \(TogetherRoom.timecode(mine)) long and the party's is \(TogetherRoom.timecode(theirs)), so it won't line up. Try another release from the title page."
        }
    }
}
