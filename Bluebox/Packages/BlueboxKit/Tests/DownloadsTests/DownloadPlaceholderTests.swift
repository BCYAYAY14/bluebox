import Domain
@testable import Downloads
import Foundation
import Testing

/// A finished transfer that is a debrid add-on's notice clip isn't kept as the download.
@Suite struct DownloadPlaceholderTests {
    let gb: Int64 = 1_073_741_824

    @Test func noticeClipByWhereTheLinkEnded() {
        let clip = URL(string: "https://torrentio.strem.fun/videos/failed_access_v3.mp4")!
        #expect(DownloadManager.placeholderProblem(finalURL: clip, receivedBytes: 300_000, expectedBytes: nil) == .planExpired)
        // Named even when the size would pass.
        #expect(DownloadManager.placeholderProblem(finalURL: clip, receivedBytes: 2 * gb, expectedBytes: 2 * gb) == .planExpired)
    }

    @Test func farSmallerThanTheReleaseIsRefused() {
        let cdn = URL(string: "https://x.download.real-debrid.com/d/1/Sintel.mkv")!
        #expect(DownloadManager.placeholderProblem(finalURL: cdn, receivedBytes: 400_000, expectedBytes: 2 * gb) == .failed)
        #expect(DownloadManager.placeholderProblem(finalURL: cdn, receivedBytes: 2 * gb - 4096, expectedBytes: 2 * gb) == nil)
        // No size to go by: kept, whatever its size (a direct link or a Jellyfin file).
        #expect(DownloadManager.placeholderProblem(finalURL: cdn, receivedBytes: 400_000, expectedBytes: nil) == nil)
        #expect(DownloadManager.placeholderProblem(finalURL: nil, receivedBytes: nil, expectedBytes: 2 * gb) == nil)
    }
}
