import Domain
@testable import Features
import Foundation
import Persistence
import Playback
import Subtitles
import Sync
import Testing

/// A Watch Party's commands applied to a real `PlayerSession`, over an engine
/// whose seeks take as long as the test says (a stream's can take seconds),
/// and what this device sends back to the room meanwhile.
@MainActor
@Suite(.serialized) struct TogetherPlaybackTests {
    static let resource = PlaybackResource(
        variant: MediaVariant(id: "v", sourceID: SourceID("s"), mediaKey: nil, displayName: "v", container: "mp4", location: .remote),
        url: URL(string: "https://example.invalid/v.mp4")!
    )

    func until(_ timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func commands(_ link: RecordingTogetherLink) -> [TogetherCommand] {
        link.sent.compactMap { if case .command(let c) = $0 { c } else { nil } }
    }

    /// Was: the host seeked, then paused while this device's seek was still
    /// going. The pause's move finished first and cleared the one shared
    /// "applying" flag; then the seek's move carried on, saw the player paused
    /// where its command said playing, played again, and (no longer
    /// "applying") sent that play to the room, so everyone un-paused.
    @Test func aPauseDuringASeekStaysPausedAndIsntSentBack() async throws {
        let engine = SlowSeekEngine()
        let player = PlayerSession(engine: engine, progress: try LibraryStore.make(inMemory: true))
        await player.start(NowPlayingItem(key: .movie(tmdbID: 1), title: "Dune"), resource: Self.resource, autoplay: false)
        player.togglePlayPause()  // playing, before the party is joined
        #expect(player.appearsPlaying)

        let at = Date(timeIntervalSince1970: 10_000)
        let link = RecordingTogetherLink()
        let room = TogetherRoom(me: TogetherParticipant(id: "bo", name: "Bo", joinedAt: at), transport: link, now: { at })
        await room.join()
        let playback = TogetherPlayback(room: room, session: player, now: { at })
        playback.attach()
        defer { playback.detach() }

        // The host skips ahead (playing): this device's seek takes a while…
        engine.holdSeeks = true
        playback.apply(TogetherCommand(action: .seek, playhead: TogetherPlayhead(position: 600, paused: false, sentAt: at),
                                       seq: 1, from: "alice"))
        #expect(await until { engine.seeksWaiting == 1 })
        // …and pauses before it lands.
        playback.apply(TogetherCommand(action: .pause, playhead: TogetherPlayhead(position: 600, paused: true, sentAt: at),
                                       seq: 2, from: "alice"))
        #expect(await until { !player.appearsPlaying })

        engine.holdSeeks = false
        #expect(await until { engine.seeksWaiting == 0 && engine.snapshot.position == 600 })
        try await Task.sleep(for: .milliseconds(150))  // the seek's move finishes, and anything it sent goes out
        #expect(!player.appearsPlaying)
        #expect(engine.snapshot.status == .paused)
        #expect(commands(link).isEmpty)

        // Nothing overlapping: a play from the room still plays, unechoed.
        playback.apply(TogetherCommand(action: .play, playhead: TogetherPlayhead(position: 600, paused: false, sentAt: at),
                                       seq: 3, from: "alice"))
        #expect(await until { player.appearsPlaying })
        try await Task.sleep(for: .milliseconds(50))
        #expect(commands(link).isEmpty)
    }

    /// Two skips in a row, the first still seeking when the second (paused)
    /// lands: the older one doesn't flip play/pause once it finishes, and
    /// nothing goes back to the room.
    @Test func anOlderSeekNeverUndoesANewerOne() async throws {
        let engine = SlowSeekEngine()
        let player = PlayerSession(engine: engine, progress: try LibraryStore.make(inMemory: true))
        await player.start(NowPlayingItem(key: .movie(tmdbID: 1), title: "Dune"), resource: Self.resource, autoplay: false)

        let at = Date(timeIntervalSince1970: 10_000)
        let link = RecordingTogetherLink()
        let room = TogetherRoom(me: TogetherParticipant(id: "bo", name: "Bo", joinedAt: at), transport: link, now: { at })
        await room.join()
        let playback = TogetherPlayback(room: room, session: player, now: { at })
        playback.attach()
        defer { playback.detach() }

        engine.holdSeeks = true
        playback.apply(TogetherCommand(action: .seek, playhead: TogetherPlayhead(position: 600, paused: false, sentAt: at),
                                       seq: 1, from: "alice"))
        #expect(await until { engine.seeksWaiting == 1 })
        playback.apply(TogetherCommand(action: .seek, playhead: TogetherPlayhead(position: 1_200, paused: true, sentAt: at),
                                       seq: 2, from: "alice"))
        #expect(await until { engine.seeksWaiting == 2 })
        engine.holdSeeks = false
        #expect(await until { engine.seeksWaiting == 0 })
        try await Task.sleep(for: .milliseconds(150))
        #expect(!player.appearsPlaying)  // the newer command said paused
        #expect(commands(link).isEmpty)
    }
}

/// A Realtime room that only records what's sent.
final class RecordingTogetherLink: TogetherTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [TogetherMessage] = []
    var sent: [TogetherMessage] { lock.withLock { messages } }

    func start(onMessage: @escaping @Sendable (TogetherMessage) -> Void,
               onConnection: @escaping @Sendable (TogetherConnection) -> Void) async {
        onConnection(.connected)
    }

    func send(_ message: TogetherMessage) async -> Bool {
        lock.withLock { messages.append(message) }
        return true
    }

    func stop() async {}
}

/// A player engine whose seeks wait while `holdSeeks` is on.
@MainActor
final class SlowSeekEngine: PlaybackEngine {
    static let supportedContainers: Set<String> = ["mp4"]
    var snapshot = PlaybackSnapshot() { didSet { onChange?(snapshot) } }
    var onChange: ((PlaybackSnapshot) -> Void)?
    var holdSeeks = false
    private(set) var seeksWaiting = 0

    func load(_ resource: PlaybackResource, startAt: TimeInterval?) async throws {
        var s = PlaybackSnapshot()
        s.status = .paused
        s.duration = 3600
        s.position = startAt ?? 0
        snapshot = s
    }
    func play() { snapshot.status = .playing }
    func pause() { snapshot.status = .paused }
    func seek(to seconds: TimeInterval) async {
        seeksWaiting += 1
        while holdSeeks { try? await Task.sleep(for: .milliseconds(5)) }
        seeksWaiting -= 1
        snapshot.position = seconds
    }
    func scrub(to seconds: TimeInterval) {}
    func setRate(_ rate: Float) { snapshot.rate = rate }
    func selectAudio(_ trackID: String?) {}
    func selectEmbeddedSubtitle(_ trackID: String?) {}
    func selectSecondaryEmbeddedSubtitle(_ trackID: String?) {}
    func stop() { snapshot.status = .idle }
    func setVideoAdjustments(_ adjustments: VideoAdjustments) {}
    func setVolume(_ volume: Float, muted: Bool) {}
    func setAudioDelay(_ seconds: TimeInterval) {}
    var supportsAudioDelay: Bool { true }
    func setSubtitleBurnIn(_ burnIn: SubtitleBurnIn?) {}
}
