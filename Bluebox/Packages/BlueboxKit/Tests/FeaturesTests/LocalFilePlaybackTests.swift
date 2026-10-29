import Domain
import Foundation
import Playback
import Testing
@testable import VLCPlayback

/// VLC must not be opened with `:start-time`: libVLC 4 then reports the length
/// minus the start time and takes seeks relative to it, while the clock stays
/// absolute (a resumed episode showed a full scrub bar with 0:00 left).
@Suite @MainActor struct VLCMediaOptionsTests {
    func resource(_ url: String) -> PlaybackResource {
        let v = MediaVariant(id: "x", sourceID: SourceID("downloads"), mediaKey: nil, displayName: "x",
                             container: "mkv", location: .downloaded)
        return PlaybackResource(variant: v, url: URL(string: url)!)
    }

    @Test func resumeOpensPausedInsteadOfShiftingTheTimeline() {
        let file = resource("file:///var/mobile/Downloads/torrents/ep/Show.S02E10.mkv")
        let options = VLCEngine.mediaOptions(for: file, startAt: 754.2)
        #expect(options == [":start-paused"])
        #expect(!options.contains { $0.hasPrefix(":start-time") })
        #expect(VLCEngine.mediaOptions(for: file, startAt: nil).isEmpty)
        #expect(VLCEngine.mediaOptions(for: file, startAt: 0).isEmpty)

        let stream = VLCEngine.mediaOptions(for: resource("http://127.0.0.1:8080/stream/abc"), startAt: 30)
        #expect(stream.contains(":start-paused"))
        #expect(!stream.contains { $0.hasPrefix(":start-time") })
    }
}

/// Plays real files on disk through both engines: the timeline the scrub bar
/// reads stays absolute and full-length after resuming and seeking. Opt in
/// with a folder holding `sample.mkv` and `sample.mp4` (same content, 3+ min):
///
///     ffmpeg -f lavfi -i testsrc2=size=640x360:rate=24 -f lavfi -i sine -t 180 \
///       -c:v libx264 -pix_fmt yuv420p -c:a aac sample.mkv
///     ffmpeg -i sample.mkv -c copy sample.mp4
///     BLUEBOX_LOCAL_MEDIA=/path/to/folder swift test --filter LocalFileTimelineTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BLUEBOX_LOCAL_MEDIA"] != nil))
@MainActor
struct LocalFileTimelineTests {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BLUEBOX_LOCAL_MEDIA"] ?? "/")

    func resource(_ name: String) -> PlaybackResource {
        let url = folder.appending(path: name)
        let v = MediaVariant(id: name, sourceID: SourceID("downloads"), mediaKey: nil, displayName: name,
                             container: url.pathExtension, location: .downloaded)
        return PlaybackResource(variant: v, url: url)
    }

    func settle(_ seconds: Double = 1) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    func near(_ a: TimeInterval?, _ b: TimeInterval, _ tolerance: TimeInterval = 1.5) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tolerance
    }

    func check(_ make: () -> any PlaybackEngine, file: String) async throws {
        // Full length, from a plain open.
        let plain = make()
        try await plain.load(resource(file), startAt: nil)
        plain.play()
        await settle()
        let length = try #require(plain.snapshot.duration)
        #expect(length > 120)
        plain.stop()

        // Resumed: the length is unchanged and the clock starts at the resume point.
        let engine = make()
        try await engine.load(resource(file), startAt: 60)
        #expect(near(engine.snapshot.position, 60))
        engine.play()
        await settle()
        #expect(near(engine.snapshot.duration, length, 0.5), "\(file): duration \(String(describing: engine.snapshot.duration)) vs \(length)")
        #expect(near(engine.snapshot.position, 61))
        #expect(engine.snapshot.status == .playing)
        #expect(PlaybackTimeline(position: engine.snapshot.position, duration: engine.snapshot.duration).fraction < 0.5)

        // Scrubbing lands where asked, late and early in the file.
        await engine.seek(to: length - 30)
        await settle(0.5)
        #expect(near(engine.snapshot.position, length - 30), "\(file): position \(engine.snapshot.position) after seeking to \(length - 30)")
        #expect(engine.snapshot.status == .playing)
        await engine.seek(to: 10)
        await settle(0.5)
        #expect(near(engine.snapshot.position, 10), "\(file): position \(engine.snapshot.position) after seeking to 10")
        engine.stop()

        // A resume point in the closing stretch starts over.
        let late = make()
        try await late.load(resource(file), startAt: length - 3)
        late.play()
        await settle()
        #expect(late.snapshot.position < 3, "\(file): resumed at \(late.snapshot.position)")
        #expect(late.snapshot.status == .playing)
        late.stop()
    }

    @Test(.timeLimit(.minutes(2))) func vlcKeepsAnAbsoluteFullLengthTimeline() async throws {
        try await check({ VLCEngine() }, file: "sample.mkv")
    }

    @Test(.timeLimit(.minutes(2))) func avPlayerKeepsAnAbsoluteFullLengthTimeline() async throws {
        try await check({ AVPlayerEngine() }, file: "sample.mp4")
    }
}
