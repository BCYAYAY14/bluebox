import Addons
import Domain
import Foundation
import Playback
import Sync

/// Joins a `TogetherRoom` to this device's player: what you do goes to the
/// room, what the others do comes back to the player, and every couple of
/// seconds it says where it is and lines up with the room's anchor.
///
/// Echo: a command applied from the room goes through the same `PlayerSession`
/// calls you'd use, which report it on `onTransport`; `applying` keeps those
/// from being sent straight back.
@MainActor
public final class TogetherPlayback {
    public let room: TogetherRoom
    public let session: PlayerSession
    /// How well this device's copy matches the party's (the lobby shows it).
    public var match: TogetherRelease.Match?

    /// How often each player says where it is.
    public static let heartbeatInterval: Duration = .seconds(2)
    /// A command closer than this to where the player already is doesn't seek
    /// (seeking re-buffers, which is worse than a small gap the drift
    /// correction closes anyway).
    static let seekThreshold: TimeInterval = 0.75

    private var applying = false
    private var beat: Task<Void, Never>?
    private let now: @MainActor () -> Date

    public init(room: TogetherRoom, session: PlayerSession, now: @escaping @MainActor () -> Date = Date.init) {
        self.room = room; self.session = session; self.now = now
    }

    public func attach() {
        session.onTransport = { [weak self] event in self?.local(event) }
        room.onCommand = { [weak self] command in self?.apply(command) }
        beat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let self, !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    public func detach() {
        beat?.cancel(); beat = nil
        session.onTransport = nil
        room.onCommand = nil
        session.engine.setRate(session.chosenRate ?? 1)  // drop any nudge
    }

    /// This player, now.
    var playhead: TogetherPlayhead {
        TogetherPlayhead(position: session.displayPosition, paused: !session.appearsPlaying,
                         rate: session.chosenRate ?? 1, sentAt: now())
    }

    var status: TogetherParticipant.Status {
        if match == TogetherRelease.Match.none { return .unavailable("A copy of another length") }
        return switch session.snapshot.status {
        case .idle, .loading: .loading
        case .buffering: .buffering
        case .failed(let e): .unavailable(e.localizedDescription)
        case .playing, .paused, .ended: .ready
        }
    }

    // MARK: You → the room

    func local(_ event: PlayerTransportEvent) {
        guard !applying else { return }
        let rate = session.chosenRate ?? 1
        let t = now()
        let sent: TogetherCommand?
        switch event {
        case .play(let at): sent = room.perform(.play, playhead: TogetherPlayhead(position: at, paused: false, rate: rate, sentAt: t))
        case .pause(let at): sent = room.perform(.pause, playhead: TogetherPlayhead(position: at, paused: true, rate: rate, sentAt: t))
        case .seek(let to, let playing):
            sent = room.perform(.seek, playhead: TogetherPlayhead(position: to, paused: !playing, rate: rate, sentAt: t))
        case .rate(let r):
            sent = room.perform(.rate, playhead: TogetherPlayhead(position: session.displayPosition, paused: !session.appearsPlaying,
                                                                  rate: r, sentAt: t))
        }
        // The host has the remote: put this player back where the party is.
        if sent == nil, !room.me.away, !room.canControl, let party = room.partyPlayhead {
            Task { await self.move(to: party, setRate: true) }
        }
    }

    /// The anchor pauses everyone while someone buffers, and plays again once they've caught up.
    func pauseForWaiting(_ names: [String]) {
        guard session.appearsPlaying else { return }
        room.perform(.pause, playhead: TogetherPlayhead(position: session.displayPosition, paused: true,
                                                        rate: session.chosenRate ?? 1, sentAt: now()), waitingFor: names)
        applyLocally { session.togglePlayPause() }
    }

    func resumeAfterWaiting() {
        guard !session.appearsPlaying else { return }
        room.perform(.play, playhead: TogetherPlayhead(position: session.displayPosition, paused: false,
                                                       rate: session.chosenRate ?? 1, sentAt: now()), waitingFor: [])
        applyLocally { session.togglePlayPause() }
    }

    /// Changes this player without telling the room (Step Away, the lobby's 3-2-1, Catch Up).
    func applyLocally(_ change: () -> Void) {
        applying = true
        defer { applying = false }
        change()
    }

    // MARK: The room → you

    func apply(_ command: TogetherCommand) {
        let target = command.playhead
        Task { await self.move(to: target, setRate: command.action == .rate) }
    }

    /// Puts the player where `target` says, through the session (as if tapped), unechoed.
    func move(to target: TogetherPlayhead, setRate: Bool) async {
        applying = true
        defer { applying = false }
        if setRate || target.rate != (session.chosenRate ?? 1) { session.setRate(target.rate) }
        let position = target.position(at: now())
        if abs(session.displayPosition - position) > Self.seekThreshold { await session.seek(to: position) }
        if session.appearsPlaying == target.paused { session.togglePlayPause() }
    }

    // MARK: Staying in step

    func tick() async {
        room.heartbeat(session.item == nil ? nil : playhead, status: status, match: match)
        guard session.item != nil else { return }
        switch room.fix(for: playhead) {
        case .none: break
        case .match(let target): await move(to: target, setRate: false)
        case .drift(.nudge(let rate)), .drift(.restore(let rate)):
            // The engine only: the session's chosen speed (and the room's) stays as it was.
            session.engine.setRate(rate)
        case .drift(.seek(let to)):
            applying = true
            defer { applying = false }
            await session.seek(to: to)
        case .drift(.none): break
        }
    }
}

extension TogetherRelease {
    /// What another device needs to find the copy this one is playing.
    public init(_ variant: MediaVariant, duration: TimeInterval?) {
        let torrent = StremioSource.torrent(fromVariantID: variant.id)
        let size = variant.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let label = [variant.resolution, size].compactMap { $0 }.joined(separator: " · ")
        self.init(infoHash: torrent.map { _ in String(variant.id.split(separator: ":")[0]) }, fileIndex: torrent?.fileIndex,
                  // Debrid links' IDs are URLs carrying the owner's token, and a folder's are paths: never sent.
                  releaseID: torrent == nil && !variant.id.contains("/") ? variant.id : nil,
                  fileName: variant.displayName, sizeBytes: variant.sizeBytes, duration: duration,
                  label: label.isEmpty ? variant.displayName : label)
    }

    /// What another device needs to find this release.
    public init(_ release: AddonRelease, duration: TimeInterval? = nil) {
        let label = [release.info.resolution, release.info.source?.title, release.sizeText]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        self.init(infoHash: release.infoHash, fileIndex: release.fileIndex,
                  // A link's ID is its URL, which carries the owner's debrid token: never sent.
                  releaseID: release.infoHash == nil && release.url != nil ? nil : release.id,
                  fileName: release.filenameHint, sizeBytes: release.videoSize ?? release.info.sizeBytes,
                  duration: duration, label: label.isEmpty ? release.name : label)
    }

    /// The best of this device's releases for the one being watched, if any matches.
    public func bestMatch(in releases: [AddonRelease]) -> (release: AddonRelease, match: Match)? {
        releases
            .map { ($0, match(TogetherRelease($0))) }
            .filter { $0.1 != .none }
            .max { $0.1 < $1.1 }
            .map { (release: $0.0, match: $0.1) }
    }
}
