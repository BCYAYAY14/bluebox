import Domain
import Foundation
import Playback
import SwiftVLC
import Testing
@testable import VLCPlayback

/// Plays real files through both engines and checks what the Stats card
/// reads from them: codecs, size, frame rate, HDR, bit depth, audio and frame
/// counts. Opt in with a folder of files made by ffmpeg:
///
///     ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=24000/1001 -f lavfi -i sine=sample_rate=48000 -t 6 \
///       -filter_complex "[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a]" -map 0:v -map "[a]" \
///       -c:v libx265 -pix_fmt yuv420p10le -x265-params colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc \
///       -c:a eac3 hdr10.mkv
///     ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=50 -t 6 -c:v libx265 -pix_fmt yuv420p10le \
///       -x265-params colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc hlg.mkv
///     ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=25 -f lavfi -i sine=sample_rate=48000 -t 6 -ac 2 \
///       -c:v libx264 -pix_fmt yuv420p -c:a aac sdr.mp4
///     ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=24000/1001 -t 6 -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p10le \
///       -x265-params colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc hdr10.mp4
///     BLUEBOX_STATS_MEDIA=/path/to/folder swift test --filter LocalFileDiagnosticsTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_STATS_MEDIA"] != nil))
@MainActor
struct LocalFileDiagnosticsTests {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BLUEBOX_STATS_MEDIA"] ?? "/")

    /// VLC decodes only with a video output; a test has no window to give it,
    /// so it draws into libVLC's dummy output.
    func vlc() throws -> VLCEngine {
        VLCEngine(instance: try VLCInstance(arguments: VLCInstance.defaultArguments + ["--vout=vdummy"]))
    }

    func play(_ engine: any PlaybackEngine, _ name: String) async throws -> PlaybackDiagnostics {
        let url = folder.appending(path: name)
        let v = MediaVariant(id: name, sourceID: SourceID("downloads"), mediaKey: nil, displayName: name,
                             container: url.pathExtension, location: .downloaded)
        try await engine.load(PlaybackResource(variant: v, url: url), startAt: nil)
        engine.play()
        try await Task.sleep(for: .seconds(3))
        let d = engine.diagnostics()
        print("STATS \(name) \(d.engine): \(d)")
        engine.stop()
        return d
    }

    @Test(.timeLimit(.minutes(1))) func vlcReadsHDR10() async throws {
        let d = try await play(try vlc(), "hdr10.mkv")
        #expect(d.videoCodec == "HEVC")
        #expect(d.videoSize == CGSize(width: 1280, height: 720))
        #expect(abs((d.frameRate ?? 0) - 23.976) < 0.01)
        #expect(d.dynamicRange == .hdr10)
        #expect(d.colour == "PQ · BT.2020")
        #expect(d.bitDepth == 10)
        #expect(d.audioCodec == "E-AC-3")
        #expect(d.audioChannels == 6)
        #expect(d.audioSampleRate == 48000)
        #expect((d.displayedFrames ?? 0) > 30)
        #expect((d.decodedFrames ?? 0) > 30)
        #expect((d.readBytes ?? 0) > 0)
    }

    @Test(.timeLimit(.minutes(1))) func vlcReadsHLG() async throws {
        let d = try await play(try vlc(), "hlg.mkv")
        #expect(d.dynamicRange == .hlg)
        #expect(d.colour == "HLG · BT.2020")
        #expect(d.bitDepth == 10)
        #expect(d.frameRate == 50)
        #expect(d.audioCodec == nil)
    }

    @Test(.timeLimit(.minutes(1))) func vlcReadsSDR() async throws {
        let d = try await play(try vlc(), "sdr.mp4")
        #expect(d.videoCodec == "H.264")
        #expect(d.dynamicRange == .sdr)
        #expect(d.colour == "BT.709")
        #expect(d.bitDepth == 8)
        #expect(d.audioCodec == "AAC")
        #expect(d.audioChannels == 2)
    }

    @Test(.timeLimit(.minutes(1))) func avPlayerReadsSDR() async throws {
        let d = try await play(AVPlayerEngine(), "sdr.mp4")
        #expect(d.videoCodec == "H.264")
        #expect(d.videoSize == CGSize(width: 1920, height: 1080))
        #expect(d.frameRate == 25)
        #expect(d.audioCodec == "AAC")
        #expect(d.audioChannels == 2)
        #expect(d.audioSampleRate == 48000)
        // AVPlayer keeps an access log only for streams; a local file has none.
        #expect(d.droppedFrames == nil && d.bitrate == nil)
    }

    @Test(.timeLimit(.minutes(1))) func avPlayerReadsHDR10() async throws {
        let d = try await play(AVPlayerEngine(), "hdr10.mp4")
        #expect(d.videoCodec == "HEVC")
        #expect(d.dynamicRange == .hdr10)
        #expect(d.colour == "PQ · BT.2020")
        #expect(d.bitDepth == 10)
    }
}
