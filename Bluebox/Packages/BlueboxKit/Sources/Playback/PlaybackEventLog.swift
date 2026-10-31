import Foundation

/// One thing that happened while a video played: opened, playing, buffering
/// and for how long, a seek, a track or speed change, an error. For the Stats
/// card's timeline and the copied diagnostics report.
public struct PlaybackEvent: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case info, warning, error }

    public let id: Int
    /// Where playback was, in seconds into the video.
    public let position: TimeInterval
    public let date: Date
    /// A short title that can be translated ("Buffering", "Seeked").
    public let title: String
    /// The names and numbers that go with it ("2.1 s", "14:02 → 21:10"), never translated.
    public var detail: String?
    public var kind: Kind

    public init(id: Int, position: TimeInterval, date: Date, title: String, detail: String? = nil, kind: Kind = .info) {
        self.id = id; self.position = position; self.date = date; self.title = title; self.detail = detail; self.kind = kind
    }
}

/// The last `capacity` events of the video that's playing, oldest first.
public struct PlaybackEventLog: Equatable, Sendable {
    public static let capacity = 50

    public private(set) var events: [PlaybackEvent] = []
    /// Times playback stopped to wait for data after it first played.
    public private(set) var stalls = 0
    /// How long those waits lasted in all, in seconds (waits still going aren't counted).
    public private(set) var stalledFor: TimeInterval = 0
    private var nextID = 0
    private var hasPlayed = false
    /// The buffering event that's still going, and when it began.
    private var buffering: Wait?
    private struct Wait: Equatable { let id: Int; let since: Date; let stall: Bool }

    public init() {}

    public mutating func reset() { self = PlaybackEventLog() }

    public mutating func record(_ title: String, detail: String? = nil, kind: PlaybackEvent.Kind = .info,
                                position: TimeInterval, at date: Date = Date()) {
        events.append(PlaybackEvent(id: nextID, position: position, date: date, title: title, detail: detail, kind: kind))
        nextID += 1
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
    }

    /// Notes a change of the engine's status. Buffering is one event that
    /// gets its length when it ends; repeats of the same status are skipped.
    public mutating func statusChanged(from old: PlaybackStatus, to new: PlaybackStatus, position: TimeInterval, at date: Date = Date()) {
        guard old != new else { return }
        if let b = buffering, new != .buffering {
            let length = max(0, date.timeIntervalSince(b.since))
            if let i = events.firstIndex(where: { $0.id == b.id }) { events[i].detail = Self.duration(length) }
            if b.stall { stalledFor += length }
            buffering = nil
        }
        switch new {
        case .idle: return
        case .loading: record("Loading", position: position, at: date)
        case .playing:
            hasPlayed = true
            record("Playing", position: position, at: date)
        case .paused: record("Paused", position: position, at: date)
        case .buffering:
            if hasPlayed { stalls += 1 }
            record("Buffering", kind: .warning, position: position, at: date)
            buffering = Wait(id: nextID - 1, since: date, stall: hasPlayed)
        case .ended: record("Ended", position: position, at: date)
        case .failed(let error): record("Error", detail: error.localizedDescription, kind: .error, position: position, at: date)
        }
    }

    /// "2.1 s", "1 min 4 s".
    public static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(format: "%.1f s", seconds) : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }

    /// A playback time as the player shows it: "4:05", "1:02:09".
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
