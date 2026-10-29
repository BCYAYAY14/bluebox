import Domain
import Foundation
import Playback
import Sync

/// Watches the player from outside (it reads `AppModel.activePlayer`'s public
/// state once a second) and turns what it sees into Trakt scrobbles: start
/// when playback starts or resumes, pause, and stop with the progress when the
/// item ends, changes (Up Next) or the player closes.
@MainActor
final class ScrobbleObserver {
    /// What the last tick saw.
    struct Seen: Equatable {
        var key: MediaKey
        var playing: Bool
        var progress: Double
    }

    enum Event: Equatable {
        case start(MediaKey, Double)
        case pause(MediaKey, Double)
        case stop(MediaKey, Double)
    }

    private var task: Task<Void, Never>?
    private(set) var seen: Seen?
    /// The item that already ended, so it isn't started again while the player
    /// sits on its last frame.
    private var ended: MediaKey?

    func start(_ app: AppModel) {
        task?.cancel()
        task = Task { [weak self, weak app] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let app else { return }
                let session = app.activePlayer
                let events = self.step(key: session?.item?.key, snapshot: session?.snapshot)
                for event in events {
                    switch event {
                    case .start(let k, let p): app.trakt.scrobble(.start, key: k, progress: p)
                    case .pause(let k, let p): app.trakt.scrobble(.pause, key: k, progress: p)
                    case .stop(let k, let p): app.trakt.scrobble(.stop, key: k, progress: p)
                    }
                }
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    /// One observation → the scrobbles it implies. Pure apart from `seen`/`ended`.
    func step(key: MediaKey?, snapshot: PlaybackSnapshot?) -> [Event] {
        var events: [Event] = []
        if let s = seen, s.key != key {
            // Closed, or another item (Up Next, Next Episode) started.
            events.append(.stop(s.key, s.progress))
            seen = nil
        }
        guard let key, let snapshot, let duration = snapshot.duration, duration > 0 else { return events }
        let progress = min(max(snapshot.position / duration * 100, 0), 100)
        if snapshot.status == .ended {
            if let s = seen { events.append(.stop(s.key, 100)) }
            seen = nil
            ended = key
            return events
        }
        if ended == key, snapshot.status != .playing { return events }
        if ended != key { ended = nil }
        switch (seen?.playing, snapshot.status) {
        case (nil, .playing), (false?, .playing):
            if ended == key { ended = nil }  // replayed from the end
            events.append(.start(key, progress))
            seen = Seen(key: key, playing: true, progress: progress)
        case (true?, .paused):
            events.append(.pause(key, progress))
            seen?.playing = false
            seen?.progress = progress
        default:
            seen?.progress = progress
        }
        return events
    }
}
