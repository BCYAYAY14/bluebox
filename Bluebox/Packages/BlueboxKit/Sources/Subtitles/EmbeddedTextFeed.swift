import Foundation

/// Cues of a video's embedded text tracks, read from the file a little
/// ahead of the playhead, for players that would otherwise draw them
/// themselves (VLC). `follow` is called as playback moves; it reads the
/// next stretch when what's been read runs short, and starts over at a seek.
///
/// SubRip and WebVTT tracks are always Bluebox's to draw. ASS/SSA tracks are
/// only while their lines carry no override tags: the verdict is pending
/// until the first lines have been read, and turns to `.player` (for good)
/// at the first styled line.
@MainActor
public final class EmbeddedTextFeed {
    public enum Verdict: Sendable, Equatable { case pending, bluebox, player }

    /// The file's subtitle tracks in declaration order (empty until read).
    public private(set) var tracks: [MatroskaTrack] = []
    /// The file isn't Matroska, or its index couldn't be read.
    public private(set) var failed = false
    /// Called when tracks, a verdict or the cues change.
    public var onChange: (() -> Void)?

    /// How far back a stretch starts after a seek, for lines already showing.
    static let lookback: TimeInterval = 10
    /// How far ahead a stretch reads, and how little left ahead starts the next.
    static let readAhead: TimeInterval = 30
    static let lowWater: TimeInterval = 12
    /// A line without a duration (rare) shows this long.
    static let defaultDuration: TimeInterval = 4

    private let reader: MatroskaSubtitleReader
    private var loadTask: Task<Void, Never>?
    private var stores: [Int: Store] = [:]

    struct Store {
        var cues: [SubtitleCue] = []
        var seen: Set<SubtitleCue> = []
        var timeline = SubtitleTimeline(cues: [])
        /// Stretches of the file already read (seconds), merged.
        var covered: [Range<TimeInterval>] = []
        var task: Task<Void, Never>?
        var reading: Range<TimeInterval>?
        var verdict: Verdict
        var retryAt: ContinuousClock.Instant?
    }

    public init(source: any ByteSource) {
        reader = MatroskaSubtitleReader(source: source)
    }

    public init(reader: MatroskaSubtitleReader) {
        self.reader = reader
    }

    deinit {
        loadTask?.cancel()
        for store in stores.values { store.task?.cancel() }
    }

    /// Reads the file's tracks (once).
    public func start() {
        guard loadTask == nil else { return }
        let reader = reader
        loadTask = Task { [weak self] in
            let result: Result<[MatroskaTrack], Error>
            do { result = .success(try await reader.subtitleTracks()) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let tracks): self.tracks = tracks
            case .failure: self.failed = true
            }
            self.onChange?()
        }
    }

    /// Waits for `start`'s read (tests).
    public func ready() async { await loadTask?.value }

    public func verdict(track: Int) -> Verdict {
        guard let codec = tracks.first(where: { $0.number == track })?.textCodec else { return .player }
        return stores[track]?.verdict ?? (codec.isASS ? .pending : .bluebox)
    }

    /// The text of `track` at a time in the file's clock, nil when there's none.
    public func text(track: Int, at time: TimeInterval) -> String? {
        stores[track]?.timeline.text(at: time)
    }

    /// The lines of `track` read so far, in order, on the file's clock.
    public func cues(track: Int) -> [SubtitleCue] {
        stores[track]?.timeline.cues ?? []
    }

    /// Reads every line of `track` up to `end` in one go (the Lines page and
    /// Sync to the Audio want them all). Local files only: over the network it
    /// would fetch the whole video.
    public func readAll(track number: Int, until end: TimeInterval) {
        guard !failed, end.isFinite, end > 0, let codec = tracks.first(where: { $0.number == number })?.textCodec else { return }
        var store = stores[number] ?? Store(verdict: codec.isASS ? .pending : .bluebox)
        defer { stores[number] = store }
        guard store.verdict != .player else { return }
        if store.covered.contains(where: { $0.lowerBound <= 0 && $0.upperBound >= end }) { return }
        if let reading = store.reading, reading.lowerBound <= 0, reading.upperBound >= end { return }
        store.task?.cancel()
        let range = 0..<end
        store.reading = range
        store.retryAt = nil
        store.task = read(track: number, codec: codec, range: range)
    }

    /// Makes sure the lines of `tracks` around `time` are read or being read.
    public func follow(tracks wanted: Set<Int>, at time: TimeInterval) {
        guard !failed, !tracks.isEmpty, time.isFinite else { return }
        for number in wanted {
            guard let codec = tracks.first(where: { $0.number == number })?.textCodec else { continue }
            var store = stores[number] ?? Store(verdict: codec.isASS ? .pending : .bluebox)
            defer { stores[number] = store }
            if store.verdict == .player { continue }
            let t = max(0, time)
            let current = store.covered.first { $0.contains(t) || $0.upperBound == t }
            if let current, current.upperBound - t >= Self.lowWater { continue }
            if let reading = store.reading {
                if reading.lowerBound <= t + 1, reading.upperBound > t { continue }
                store.task?.cancel()  // a seek away from what's being read
                store.task = nil; store.reading = nil
            }
            if let retry = store.retryAt, ContinuousClock.now < retry { continue }
            let from = current?.upperBound ?? max(0, t - Self.lookback)
            let range = from..<(max(from, t) + Self.readAhead)
            store.reading = range
            store.task = read(track: number, codec: codec, range: range)
        }
    }

    private func read(track: Int, codec: EmbeddedTextCodec, range: Range<TimeInterval>) -> Task<Void, Never> {
        let reader = reader
        return Task { [weak self] in
            let result: Result<[MatroskaBlock], Error>
            do { result = .success(try await reader.blocks(track: track, from: range.lowerBound, to: range.upperBound)) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, let self else { return }
            self.finish(track: track, codec: codec, range: range, result: result)
        }
    }

    private func finish(track: Int, codec: EmbeddedTextCodec, range: Range<TimeInterval>, result: Result<[MatroskaBlock], Error>) {
        guard var store = stores[track], store.reading == range else { return }
        store.task = nil; store.reading = nil
        switch result {
        case .failure:
            // A piece that didn't arrive in time, a dropped connection: try again shortly.
            store.retryAt = .now + .seconds(3)
            stores[track] = store
            return
        case .success(let blocks):
            store.retryAt = nil
            store.covered = Self.merging(range, into: store.covered)
            if codec.isASS, !blocks.isEmpty {
                if blocks.contains(where: { EmbeddedTextCodec.hasOverrideTags($0.payload) }) {
                    store.verdict = .player
                } else if store.verdict == .pending {
                    store.verdict = .bluebox
                }
            }
            var added = false
            let ordered = blocks.sorted { $0.start < $1.start }
            for (i, block) in ordered.enumerated() {
                guard let text = codec.text(block.payload) else { continue }
                // No duration: until the next line at most, not on top of it.
                let next = ordered[(i + 1)...].first { $0.start > block.start }?.start
                let end = block.start + (block.duration ?? min(Self.defaultDuration, (next ?? .infinity) - block.start))
                let cue = SubtitleCue(start: block.start, end: end, text: text)
                if store.seen.insert(cue).inserted { store.cues.append(cue); added = true }
            }
            if added { store.timeline = SubtitleTimeline(cues: store.cues) }
            stores[track] = store
            onChange?()
        }
    }

    static func merging(_ range: Range<TimeInterval>, into ranges: [Range<TimeInterval>]) -> [Range<TimeInterval>] {
        var all = (ranges + [range]).sorted { $0.lowerBound < $1.lowerBound }
        var out: [Range<TimeInterval>] = []
        while !all.isEmpty {
            let next = all.removeFirst()
            if let last = out.last, next.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, next.upperBound)
            } else {
                out.append(next)
            }
        }
        return out
    }
}
