@testable import Addons
import Domain
import Foundation
import Testing

/// Answers every probe the same way, or fails.
private struct FakeProber: LinkProber {
    var result: LinkProbe?
    func probe(_ url: URL) async throws -> LinkProbe {
        guard let result else { throw URLError(.notConnectedToInternet) }
        return result
    }
}

@Suite struct DebridPlaceholderTests {
    func problem(_ link: String) -> DebridProblem? { DebridPlaceholder.problem(for: URL(string: link)!) }

    @Test func torrentioClipsByName() {
        let host = "https://torrentio.strem.fun"
        #expect(problem("\(host)/videos/failed_access_v3.mp4") == .planExpired)
        #expect(problem("\(host)/videos/failed_access_v2.mp4") == .planExpired)  // older versions too
        #expect(problem("\(host)/videos/blocked_access_v2.mp4") == .planExpired)
        #expect(problem("\(host)/videos/downloading_v3.mp4") == .notCachedYet)
        #expect(problem("\(host)/videos/limits_exceeded_v2.mp4") == .limitReached)
        #expect(problem("\(host)/videos/failed_rar_v3.mp4") == .archiveUnsupported)
        #expect(problem("\(host)/videos/download_failed_v3.mp4") == .failed)
        #expect(problem("\(host)/videos/failed_too_big_v2.mp4") == .failed)
        #expect(problem("\(host)/videos/failed_something_new_v9.mp4") == .failed)
    }

    @Test func mediaFusionAndCometClips() {
        let mf = "https://mediafusion.elfhosted.com/static/exceptions"
        #expect(problem("\(mf)/torrent_downloading.mp4") == .notCachedYet)
        #expect(problem("\(mf)/need_premium.mp4") == .planExpired)
        #expect(problem("\(mf)/invalid_token.mp4") == .keyRejected)
        #expect(problem("\(mf)/daily_download_limit.mp4") == .limitReached)
        #expect(problem("\(mf)/no_matching_file.mp4") == .failed)
        let comet = "https://comet.test/comet/assets/status_videos"
        #expect(problem("\(comet)/MEDIA_NOT_CACHED_YET.mp4") == .notCachedYet)
        #expect(problem("\(comet)/MUST_BE_PREMIUM.mp4") == .planExpired)
        #expect(problem("\(comet)/AUTH_BAD_APIKEY.mp4") == .keyRejected)
        #expect(problem("\(comet)/MONTHLY_LIMIT.mp4") == .limitReached)
        #expect(problem("\(comet)/SOMETHING_ELSE.mp4") == .failed)
    }

    @Test func realReleasesAreNotClips() {
        #expect(problem("https://abc.download.real-debrid.com/d/XYZ/Sintel.2010.1080p.mkv") == nil)
        #expect(problem("https://cdn.test/videos/Sintel.2010.1080p.mp4") == nil)  // no version suffix
        #expect(problem("https://cdn.test/videos/sintel_v2.mp4") == nil)  // not one of Torrentio's names
        #expect(problem("https://cdn.test/exceptions/need_premium.mp4") == nil)  // not under /static
        #expect(problem("https://cdn.test/UNKNOWN.mp4") == nil)  // Comet's names count only in its folder
        #expect(problem("https://torrentio.strem.fun/videos/failed_access_v3.mkv") == nil)
    }

    @Test func sizeFarUnderTheReleaseIsAClip() {
        let gb: Int64 = 1_073_741_824
        #expect(DebridPlaceholder.problem(totalBytes: 400_000, expectedBytes: 2 * gb) == .failed)
        #expect(DebridPlaceholder.problem(totalBytes: 2 * gb - 10, expectedBytes: 2 * gb) == nil)
        #expect(DebridPlaceholder.problem(totalBytes: gb / 10, expectedBytes: gb) == nil)  // 10%: a smaller copy, not a clip
        #expect(DebridPlaceholder.problem(totalBytes: 400_000, expectedBytes: nil) == .failed)
        #expect(DebridPlaceholder.problem(totalBytes: 800 * 1_048_576, expectedBytes: nil) == nil)
        #expect(DebridPlaceholder.problem(totalBytes: nil, expectedBytes: gb) == nil)
    }

    @Test func checkFollowsTheRedirect() async {
        let link = URL(string: "https://torrentio.strem.fun/resolve/realdebrid/KEY/abc/null/0/Sintel.mkv")!
        let expired = FakeProber(result: LinkProbe(finalURL: URL(string: "https://torrentio.strem.fun/videos/failed_access_v3.mp4")!,
                                                   status: 200, totalBytes: 300_000))
        #expect(await DebridLinkCheck.problem(for: link, expectedBytes: 2_000_000_000, prober: expired) == .planExpired)

        // Comet sends its clip as the link's own body: caught by size.
        let comet = FakeProber(result: LinkProbe(finalURL: link, status: 206, totalBytes: 250_000))
        #expect(await DebridLinkCheck.problem(for: link, expectedBytes: 2_000_000_000, prober: comet) == .failed)

        let fine = FakeProber(result: LinkProbe(finalURL: URL(string: "https://x.download.real-debrid.com/d/1/Sintel.mkv")!,
                                                status: 206, totalBytes: 1_900_000_000))
        #expect(await DebridLinkCheck.problem(for: link, expectedBytes: 2_000_000_000, prober: fine) == nil)

        // Offline, or an error status: no guess; playing it says what's wrong.
        #expect(await DebridLinkCheck.problem(for: link, expectedBytes: 2_000_000_000, prober: FakeProber(result: nil)) == nil)
        let gone = FakeProber(result: LinkProbe(finalURL: link, status: 404, totalBytes: 12))
        #expect(await DebridLinkCheck.problem(for: link, expectedBytes: 2_000_000_000, prober: gone) == nil)
    }

    @Test func sourceNamesTheServiceInTheError() async throws {
        var settings = AddonSettings()
        settings.debrid = .realDebrid
        let prober = FakeProber(result: LinkProbe(finalURL: URL(string: "https://torrentio.strem.fun/videos/limits_exceeded_v2.mp4")!,
                                                  status: 200, totalBytes: 300_000))
        let source = StremioSource(settings: settings, debridKey: "KEY", imdbID: { _ in nil },
                                   choices: MemoryShowChoiceStore(), prober: prober)
        let release = AddonRelease(id: "r", title: "Sintel 1080p", name: "[RD+] Torrentio", infoHash: nil, fileIndex: nil,
                                   trackers: [], seeders: nil, sizeText: nil, resolution: "1080p", container: "mkv",
                                   url: URL(string: "https://torrentio.strem.fun/resolve/realdebrid/KEY/abc/null/0/Sintel.mkv")!)
        await #expect(throws: DebridLinkError(.limitReached, service: "Real-Debrid")) { try await source.check(release) }
        let message = DebridLinkError(.limitReached, service: "Real-Debrid").localizedDescription
        #expect(message.contains("Real-Debrid's download limit"))
        #expect(!DebridProblem.limitReached.isPerRelease && DebridProblem.notCachedYet.isPerRelease)
    }

    @Test func probeReadsTheWholeSize() {
        let url = URL(string: "https://x.test/a.mkv")!
        let ranged = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                                     headerFields: ["Content-Range": "bytes 0-0/1900000000", "Content-Length": "1"])!
        #expect(URLSessionLinkProber.totalBytes(ranged) == 1_900_000_000)
        let whole = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "250000"])!
        #expect(URLSessionLinkProber.totalBytes(whole) == 250_000)
        let unknown = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Length": "1"])!
        #expect(URLSessionLinkProber.totalBytes(unknown) == nil)
    }
}
