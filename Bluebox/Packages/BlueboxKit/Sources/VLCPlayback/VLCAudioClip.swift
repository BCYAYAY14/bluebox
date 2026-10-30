import Foundation
import SwiftVLC

/// A stretch of a video's soundtrack as a 16 kHz mono WAV file, decoded by
/// libVLC's transcoder (any container and codec VLC plays, files or http),
/// for Sync to the Audio's speech recognition. Writing to a file isn't held
/// to the playback clock, so a minute of sound takes about a second.
///
/// Under stream output libVLC ignores `start-time` (it decodes from the
/// beginning) but stops exactly at `stop-time`. So the player is sent to the
/// start once it runs, and only the last `duration` seconds are kept: they
/// end at the stop time whatever came before the seek landed.
@MainActor
public enum VLCAudioClip {
    public enum Failure: Error, LocalizedError {
        case noSound
        public var errorDescription: String? { "Bluebox couldn't read the sound of this video." }
    }

    /// Writes the sound from `start` for `duration` seconds to `destination`.
    public static func extract(_ url: URL, start: TimeInterval, duration: TimeInterval, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let media = try Media(url: url)
        let path = destination.path.replacingOccurrences(of: "\"", with: "")
        media.addOption(":sout=#transcode{vcodec=none,scodec=none,acodec=s16l,channels=1,samplerate=16000}:std{access=file,mux=wav,dst=\"\(path)\"}")
        media.addOption(":no-sout-video")
        media.addOption(":no-sout-spu")
        media.addOption(":start-time=\(String(format: "%.2f", max(0, start)))")
        media.addOption(":stop-time=\(String(format: "%.2f", max(0, start) + duration))")
        let player = Player(instance: .shared)
        try player.play(media)
        defer { player.stop() }
        // Generous: a network file can be slow to seek and read.
        let deadline = ContinuousClock.now + .seconds(max(30, duration * 3))
        var started = false, sought = start < 1
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(sought ? 100 : 15))
            switch player.state {
            case .playing:
                started = true
                if !sought { sought = true; try? player.seek(to: .milliseconds(Int64(start * 1000))) }
            case .opening, .buffering, .paused: started = true
            case .stopped, .stopping, .idle:
                if started { player.stop(); return try keepLast(duration, of: destination) }
            case .error: throw Failure.noSound
            }
        }
        throw Failure.noSound
    }

    /// Cuts the WAV down to its last `seconds` (16 kHz mono, 16-bit) with a fresh header.
    static func keepLast(_ seconds: TimeInterval, of url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let marker = data.range(of: Data("data".utf8)), marker.upperBound + 4 <= data.count else { throw Failure.noSound }
        let samples = data[(marker.upperBound + 4)...]
        let keep = min(samples.count / 2 * 2, Int(seconds * 16_000) * 2)
        guard keep > 16_000 else { throw Failure.noSound }  // under half a second of sound
        try (wavHeader(dataBytes: keep) + samples.suffix(keep)).write(to: url)
    }

    static func wavHeader(dataBytes: Int) -> Data {
        var h = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); h.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        h.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return h
    }
}
