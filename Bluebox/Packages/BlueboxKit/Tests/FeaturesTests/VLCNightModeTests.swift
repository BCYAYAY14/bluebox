import Domain
import Foundation
import Playback
import SwiftVLC
import Testing
@testable import VLCPlayback

/// Opt-in: plays a quiet tone through `VLCEngine` into a WAV file (libVLC's
/// `afile` output), turns Night Mode on halfway, and checks the compressor
/// really runs: its +8 dB make-up lifts a −40 dBFS tone well clear of where
/// it was. Before, Night Mode on VLC changed nothing.
///
///     BLUEBOX_VLC_AUDIO=1 swift test --filter VLCNightModeTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_VLC_AUDIO"] != nil))
struct VLCNightModeTests {
    @Test func nightModeLiftsAQuietToneLive() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bluebox-night-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = dir.appending(path: "tone.wav")
        try Self.wav(seconds: 10, dBFS: -40).write(to: tone)

        // Turning a filter on rebuilds libVLC's audio output, and the afile
        // output then starts its file afresh: each capture is measured at its end.
        let plain = try await Self.capture(tone, to: dir.appending(path: "plain.wav"), nightAt: nil)
        let night = try await Self.capture(tone, to: dir.appending(path: "night.wav"), nightAt: 2)
        // An equaliser change resets libVLC's filter chain to "equalizer": the compressor must come back.
        let both = try await Self.capture(tone, to: dir.appending(path: "both.wav"), nightAt: 2, equalizerAt: 4)
        print("NIGHT plain \(plain) dBFS, night \(night) dBFS, night then equaliser \(both) dBFS")
        #expect(plain < -38 && plain > -42)  // the tone as it is
        #expect(night - plain > 5)            // the compressor's +8 dB make-up, switched on live
        // Bass Boost leaves 1 kHz alone but has a −4 dB preamp: about −44 dBFS
        // without the compressor, about −36 with it.
        #expect(both - plain > 2)             // still there after the equaliser changed
    }

    /// Plays the tone to 7 s into `out`, turning Night Mode on at `nightAt`;
    /// the level of the last two seconds written.
    static func capture(_ tone: URL, to out: URL, nightAt: Double?, equalizerAt: Double? = nil) async throws -> Double {
        let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + [
            "--aout=afile", "--audiofile-file=\(out.path)", "--audiofile-format=s16", "--audiofile-channels=1",
        ])
        let engine = VLCEngine(instance: instance)
        let variant = MediaVariant(id: "tone", sourceID: SourceID("downloads"), mediaKey: nil, displayName: "tone",
                                   container: "wav", location: .downloaded)
        try await engine.load(PlaybackResource(variant: variant, url: tone), startAt: nil)
        engine.play()
        if let nightAt {
            try await wait { engine.snapshot.position >= nightAt }
            engine.setAudioEffects(AudioEffects(nightMode: true))
        }
        if let equalizerAt {
            try await wait { engine.snapshot.position >= equalizerAt }
            engine.setAudioEffects(AudioEffects(nightMode: true, equalizer: EqualizerSettings().applying(.bassBoost)))
        }
        try await wait { engine.snapshot.position >= 7 }
        engine.stop()
        let samples = try Self.samples(of: out)
        let end = Double(samples.count) / 48_000
        return dB(samples, from: max(end - 2.5, 0), to: end - 0.5, rate: 48_000)
    }

    static func wait(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !done() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A 1 kHz mono 16-bit tone at 48 kHz.
    static func wav(seconds: Double, dBFS: Double) -> Data {
        let rate = 48_000, n = Int(seconds * Double(rate))
        let amp = pow(10, dBFS / 20) * sqrt(2) * 32767  // RMS at dBFS
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            var v = Int16(amp * sin(2 * .pi * 1000 * Double(i) / Double(rate))).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var d = Data("RIFF".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(36 + pcm.count); d.append(contentsOf: Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Data("data".utf8)); u32(pcm.count); d.append(pcm)
        return d
    }

    /// The 16-bit samples after the WAV header's "data" chunk.
    static func samples(of url: URL) throws -> [Int16] {
        let d = try Data(contentsOf: url)
        guard let r = d.range(of: Data("data".utf8)) else { return [] }
        let body = d[(r.upperBound + 4)...]
        return body.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    static func dB(_ s: [Int16], from: Double, to: Double, rate: Double) -> Double {
        let a = min(Int(from * rate), s.count), b = min(Int(to * rate), s.count)
        guard b > a else { return -.infinity }
        let sum = s[a..<b].reduce(0.0) { $0 + pow(Double($1) / 32768, 2) }
        return 10 * log10(sum / Double(b - a))
    }
}
