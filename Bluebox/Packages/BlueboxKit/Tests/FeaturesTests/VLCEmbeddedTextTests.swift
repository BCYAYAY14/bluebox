import Domain
import Foundation
import Playback
import Subtitles
import Testing
@testable import VLCPlayback

/// VLC's subtitle tracks line up with the file's by order, after any closed
/// captions VLC found in the video; anything that doesn't line up stays VLC's.
@Suite @MainActor struct VLCFileTrackMappingTests {
    let file = [MatroskaTrack(number: 3, type: 0x11, codecID: "S_TEXT/UTF8"),
                MatroskaTrack(number: 4, type: 0x11, codecID: "S_HDMV/PGS"),
                MatroskaTrack(number: 5, type: 0x11, codecID: "S_TEXT/ASS")]

    @Test func matchesByOrderSkippingCaptions() {
        let listed: [(id: String, format: String?)] = [("cc", "CC"), ("a", "SRT"), ("b", "PGS"), ("c", "ASS")]
        #expect(VLCEngine.matroskaTrack(for: "a", listed: listed, fileTracks: file)?.number == 3)
        #expect(VLCEngine.matroskaTrack(for: "b", listed: listed, fileTracks: file)?.number == 4)
        #expect(VLCEngine.matroskaTrack(for: "c", listed: listed, fileTracks: file)?.number == 5)
        #expect(VLCEngine.matroskaTrack(for: "cc", listed: listed, fileTracks: file) == nil)
    }

    @Test func mismatchesStayWithVLC() {
        // A track short (VLC left one out): nothing is matched.
        #expect(VLCEngine.matroskaTrack(for: "a", listed: [("a", "SRT"), ("c", "ASS")], fileTracks: file) == nil)
        // The formats disagree: that text track isn't taken over.
        #expect(VLCEngine.matroskaTrack(for: "a", listed: [("a", "ASS"), ("b", "PGS"), ("c", "ASS")], fileTracks: file) == nil)
    }
}

/// Plays a real MKV through VLC and checks its SubRip track reaches the
/// overlay text with VLC's own track off. Opt in with a file whose first
/// subtitle track is SubRip with a line on screen at 0:05 and at 0:15:
///
///     ffmpeg -f lavfi -i testsrc2=size=640x360:rate=24 -f lavfi -i sine -i lines.srt -i signs.ass -t 30 \
///       -map 0 -map 1 -map 2 -map 3 -c:v libx264 -pix_fmt yuv420p -c:a aac -c:s:0 srt -c:s:1 ass subtitles.mkv
///     BLUEBOX_SUBTITLE_MKV=/path/to/subtitles.mkv swift test --filter VLCEmbeddedTextPlaybackTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_SUBTITLE_MKV"] != nil))
@MainActor
struct VLCEmbeddedTextPlaybackTests {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BLUEBOX_SUBTITLE_MKV"] ?? "/")

    func waitFor(_ seconds: Double = 8, _ condition: () -> Bool) async {
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func subRipTrackGoesToTheOverlay() async throws {
        let v = MediaVariant(id: "s", sourceID: SourceID("downloads"), mediaKey: nil, displayName: "s",
                             container: "mkv", location: .downloaded)
        let engine = VLCEngine()
        try await engine.load(PlaybackResource(variant: v, url: url), startAt: nil)
        await waitFor { engine.snapshot.embeddedSubtitles.contains { $0.format == "SRT" && $0.drawnByBluebox } }
        let srt = try #require(engine.snapshot.embeddedSubtitles.first { $0.format == "SRT" })
        #expect(srt.drawnByBluebox)
        engine.selectEmbeddedSubtitle(srt.id)
        #expect(!engine.snapshot.drawsEmbeddedSubtitles)
        #expect(engine.player.selectedSubtitleTrack == nil, "VLC's own track is off")

        await engine.seek(to: 5)
        engine.play()
        await waitFor { engine.snapshot.embeddedSubtitleText != nil }
        #expect(engine.snapshot.embeddedSubtitleText != nil)

        // A seek far on: the feed reads the new stretch.
        await engine.seek(to: 15)
        await waitFor { engine.snapshot.embeddedSubtitleText != nil && engine.snapshot.position > 14 }
        #expect(engine.snapshot.embeddedSubtitleText != nil)

        // The delay moves the lines: 30 s later, nothing is on yet at 0:15.
        engine.setEmbeddedSubtitleDelay(30)
        await waitFor(2) { engine.snapshot.embeddedSubtitleText == nil }
        #expect(engine.snapshot.embeddedSubtitleText == nil)
        engine.setEmbeddedSubtitleDelay(0)

        // Styled ASS stays with VLC.
        if let ass = engine.snapshot.embeddedSubtitles.first(where: { $0.format == "ASS" }) {
            await waitFor(4) { false }
            let current = try #require(engine.snapshot.embeddedSubtitles.first { $0.id == ass.id })
            #expect(!current.drawnByBluebox)
            engine.selectEmbeddedSubtitle(ass.id)
            #expect(engine.snapshot.drawsEmbeddedSubtitles)
            await waitFor(3) { engine.player.selectedSubtitleTrack?.id == ass.id }
            #expect(engine.player.selectedSubtitleTrack?.id == ass.id)
        }
        engine.stop()
    }
}
