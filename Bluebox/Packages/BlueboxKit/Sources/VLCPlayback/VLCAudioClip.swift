import AVFoundation
import Foundation
import SwiftVLC

/// A stretch of a video's soundtrack as a 16 kHz mono WAV file, for Sync to
/// the Audio's speech recognition and generated subtitles.
///
/// Files AVFoundation can open (MP4, M4A, MOV, WAV, MP3…) are read with
/// `AVAssetReader` over exactly the stretch asked for. Anything else is
/// decoded by libVLC's transcoder (any container and codec VLC plays, files
/// or http). Writing to a file isn't held to the playback clock, so a minute
/// of sound takes a fraction of a second.
///
/// Under stream output libVLC honours `start-time` for some demuxers (MP4,
/// WAV) and ignores it for others (MKV decodes from the beginning), but
/// always stops exactly at `stop-time`. So only the last `duration` seconds
/// are kept: they end at the stop time whatever came before. A seek is sent
/// only when the decode is plainly running from the beginning and slowly (a
/// network stream): measured on local files, a seek after `start-time` had
/// already applied cut an M4A clip to 8 s, and libVLC ignored it on MKV.
@MainActor
public enum VLCAudioClip {
    public enum Failure: Error, LocalizedError, Equatable {
        /// libVLC couldn't open or decode the video's sound.
        case couldNotDecode
        /// Less than half a second of sound came out (no audio track there, or a broken part of the file).
        case noSound
        /// Still decoding when the deadline passed.
        case timedOut(seconds: Int)

        public var errorDescription: String? {
            switch self {
            case .couldNotDecode: "Bluebox couldn't decode the sound of this video."
            case .noSound: "This part of the video has no sound Bluebox could read."
            case .timedOut: "Reading the sound of this video took too long."
            }
        }
    }

    /// Writes the sound from `start` for `duration` seconds to `destination`.
    /// - Parameter headers: the resource's; libVLC takes the user agent and referrer.
    /// - Returns: the time in the video the clip starts at (`start`, or later when less was decoded).
    @discardableResult
    public static func extract(_ url: URL, headers: [String: String] = [:], start: TimeInterval, duration: TimeInterval,
                               to destination: URL) async throws -> TimeInterval {
        try? FileManager.default.removeItem(at: destination)
        let start = max(0, start)
        if url.isFileURL, let from = try await Task.detached(priority: .userInitiated, operation: {
            try await VLCAudioClip.read(url, start: start, duration: duration, to: destination)
        }).value {
            return from
        }
        try Task.checkCancellation()
        // Gone (an unmounted drive, a deleted download): libVLC would just sit there.
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { throw Failure.couldNotDecode }
        return try await decode(url, headers: headers, start: start, duration: duration, to: destination)
    }

    // MARK: AVFoundation

    /// The stretch read by `AVAssetReader`, to the sample. Nil when
    /// AVFoundation can't open the file or has no sound track in it (MKV,
    /// a torrent's file without its index yet), for libVLC to try.
    nonisolated static func read(_ url: URL, start: TimeInterval, duration: TimeInterval, to destination: URL) async throws -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16_000),
                                       duration: CMTime(seconds: duration, preferredTimescale: 16_000))
        guard reader.startReading() else { return nil }
        var pcm = Data()
        var first: TimeInterval?
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { continue }
            // A buffer that starts before the stretch (a codec's whole packet): only from the start on.
            if first == nil, pts.isFinite, pts < start {
                let skip = min(bytes.count, Int(((start - pts) * 16_000).rounded()) * 2)
                bytes = bytes.dropFirst(skip)
                first = pts + Double(skip / 2) / 16_000
            } else if first == nil {
                first = pts.isFinite ? pts : start
            }
            pcm.append(bytes)
        }
        guard reader.status == .completed else { return nil }
        let keep = min(pcm.count / 2 * 2, Int(duration * 16_000) * 2)
        guard keep > 16_000, let first else { throw Failure.noSound }  // under half a second of sound
        try (wavHeader(dataBytes: keep) + pcm.prefix(keep)).write(to: destination)
        return first
    }

    // MARK: libVLC

    static func decode(_ url: URL, headers: [String: String], start: TimeInterval, duration: TimeInterval,
                       to destination: URL) async throws -> TimeInterval {
        let media = try Media(url: url)
        let path = destination.path.replacingOccurrences(of: "\"", with: "")
        media.addOption(":sout=#transcode{vcodec=none,scodec=none,acodec=s16l,channels=1,samplerate=16000}:std{access=file,mux=wav,dst=\"\(path)\"}")
        media.addOption(":no-sout-video")
        media.addOption(":no-sout-spu")
        media.addOption(":start-time=\(String(format: "%.2f", start))")
        media.addOption(":stop-time=\(String(format: "%.2f", start + duration))")
        for (name, value) in headers {
            switch name.lowercased() {
            case "user-agent": media.addOption(":http-user-agent=\(value)")
            case "referer", "referrer": media.addOption(":http-referrer=\(value)")
            default: break
            }
        }
        let player = Player(instance: .shared)
        try player.play(media)
        defer { player.stop() }
        // Generous: a network file can be slow to read.
        let limit = max(30, duration * 3)
        let began = ContinuousClock.now
        var playingSince: ContinuousClock.Instant?
        var started = false, sought = false
        while true {
            try Task.checkCancellation()
            // libVLC's own state, not `player.state`: that's a copy updated from
            // events on the main actor, and lags. Read stale, it said "idle"
            // while sound was being written (the clip was cut short and its
            // start misreported), or never said "stopped" (a stretch waited out
            // the whole deadline).
            switch player.nativePlaybackState {
            case .opening, .buffering, .paused:
                started = true
            case .playing:
                started = true
                let now = ContinuousClock.now
                playingSince = playingSince ?? now
                // From the beginning (more written than the stretch) and slowly
                // enough that reaching the start would take a while: seek there.
                if !sought, start > duration, let since = playingSince {
                    let written = soundSeconds(destination)
                    let elapsed = seconds(now - since)
                    if elapsed >= 0.5, written > duration, (start - written) / max(written / elapsed, 1) > 5 {
                        sought = true
                        try? player.seek(to: .milliseconds(Int64(start * 1000)))
                    }
                }
            case .stopped, .stopping, .idle:
                // Stopped before it began is the moment after `play`; once it
                // has run (or written sound between two looks), it's done.
                // `.stopping` is still writing: wait for `.stopped`.
                let wrote = soundSeconds(destination) > 0
                // Never seen starting, seconds on, with nothing written: it failed
                // to open between two looks (or never tried).
                if !started, !wrote, seconds(.now - began) > 3 { throw Failure.couldNotDecode }
                guard player.nativePlaybackState == .stopped, started || wrote else { break }
                player.stop()
                // Off the main thread: decoded from the beginning, the WAV can be
                // a hundred megabytes or more, read and rewritten while the film plays.
                let kept = try await Task.detached(priority: .userInitiated) {
                    try VLCAudioClip.keepLast(duration, of: destination)
                }.value
                try Task.checkCancellation()
                // What's kept ends at the stop time.
                return start + duration - kept
            case .error:
                throw Failure.couldNotDecode
            }
            guard seconds(.now - began) < limit else { throw Failure.timedOut(seconds: Int(limit)) }
            try await Task.sleep(for: .milliseconds(started ? 50 : 20))
        }
    }

    /// Seconds of sound in the WAV written so far (16 kHz mono, 16-bit).
    nonisolated static func soundSeconds(_ url: URL) -> TimeInterval {
        Double(max(0, ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) - 44)) / 32_000
    }

    nonisolated static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Cuts the WAV down to its last `seconds` (16 kHz mono, 16-bit) with a
    /// fresh header, and returns how many seconds it holds.
    @discardableResult
    nonisolated static func keepLast(_ seconds: TimeInterval, of url: URL) throws -> TimeInterval {
        guard let data = try? Data(contentsOf: url) else { throw Failure.noSound }
        guard let marker = data.range(of: Data("data".utf8)), marker.upperBound + 4 <= data.count else { throw Failure.noSound }
        let samples = data[(marker.upperBound + 4)...]
        let keep = min(samples.count / 2 * 2, Int(seconds * 16_000) * 2)
        guard keep > 16_000 else { throw Failure.noSound }  // under half a second of sound
        try (wavHeader(dataBytes: keep) + samples.suffix(keep)).write(to: url)
        return Double(keep / 2) / 16_000
    }

    nonisolated static func wavHeader(dataBytes: Int) -> Data {
        var h = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); h.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        h.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return h
    }
}
