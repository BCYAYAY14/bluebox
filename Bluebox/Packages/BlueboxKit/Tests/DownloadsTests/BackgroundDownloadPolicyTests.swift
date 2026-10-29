import Domain
@testable import Downloads
import Foundation
import Testing

/// When Bluebox keeps itself running in the background for torrent downloads.
@Suite struct BackgroundDownloadPolicyTests {
    private func record(_ id: String, torrent: Bool = true, state: DownloadRecord.State = .downloading,
                        allows: Bool? = nil) -> DownloadRecord {
        let variantID = torrent ? String(repeating: "b", count: 40) + ":\(id.count)" : "https://example.com/\(id).mp4"
        let origin = MediaVariant(id: variantID, sourceID: SourceID("addons"), mediaKey: nil, displayName: id,
                                  location: .remote, isDownloadable: true)
        var r = DownloadRecord(id: id, mediaKey: nil, title: id, subtitle: nil, origin: origin, state: state,
                               receivedBytes: 0, expectedBytes: nil, createdAt: .now, fileName: nil, subtitleFiles: [])
        r.allowsMobileData = allows
        return r
    }

    private func decide(_ records: [DownloadRecord], settings: DownloadSettings = DownloadSettings(),
                        conditions: DownloadConditions = DownloadConditions(), holds: [String: String] = [:],
                        playing: Bool = false) -> BackgroundDownloadPolicy.Decision {
        BackgroundDownloadPolicy.decide(records: records, settings: settings, conditions: conditions, holds: holds,
                                        isPlaying: playing)
    }

    @Test func onByDefault() {
        #expect(DownloadSettings().keepDownloadingInBackground)
        let old = try! JSONDecoder().decode(DownloadSettings.self, from: Data(#"{"maxConcurrent":2}"#.utf8))
        #expect(old.keepDownloadingInBackground)
    }

    @Test func keepsAliveWhileATorrentDownloads() {
        #expect(decide([record("t")]) == .keepAlive)
        #expect(decide([record("t", state: .queued)]) == .keepAlive)
    }

    @Test func settingOffStops() {
        var settings = DownloadSettings()
        settings.keepDownloadingInBackground = false
        #expect(decide([record("t")], settings: settings) == .stop(.settingOff))
    }

    @Test func nothingToDownloadStops() {
        #expect(decide([]) == .stop(.nothingToDownload))
        #expect(decide([record("done", state: .completed), record("p", state: .paused),
                        record("f", state: .failed("x"))]) == .stop(.nothingToDownload))
        // HTTP downloads use a background URLSession and don't need the app.
        #expect(decide([record("h", torrent: false)]) == .stop(.nothingToDownload))
    }

    @Test func playbackKeepsTheAppRunningInstead() {
        #expect(decide([record("t")], playing: true) == .playbackKeepsAlive)
        #expect(decide([], playing: true) == .stop(.nothingToDownload))
    }

    @Test func wifiOnlyOnMobileDataStops() {
        let mobile = DownloadConditions(isExpensive: true)
        #expect(decide([record("t")], settings: DownloadSettings(wifiOnly: true), conditions: mobile) == .stop(.waitingForWiFi))
        #expect(decide([record("t")], settings: DownloadSettings(wifiOnly: false), conditions: mobile) == .keepAlive)
        // "Download Now" on mobile data overrides Wi‑Fi Only.
        #expect(decide([record("t", allows: true)], settings: DownloadSettings(wifiOnly: true), conditions: mobile) == .keepAlive)
    }

    @Test func mobileDataTorrentRuleStops() {
        let conditions = DownloadConditions(isExpensive: true, torrentsAllowedOnMobileData: false)
        #expect(decide([record("t")], settings: DownloadSettings(wifiOnly: false), conditions: conditions) == .stop(.waitingForWiFi))
    }

    @Test func offlineStops() {
        #expect(decide([record("t")], conditions: DownloadConditions(isOnline: false)) == .stop(.offline))
    }

    @Test func heldStops() {
        #expect(decide([record("t")], holds: ["t": "Streaming"]) == .stop(.held))
    }

    @Test func ignoresTheBackgroundSuspension() {
        // Suspended torrents are the result of stopping, not a reason to.
        #expect(decide([record("t", state: .queued)], conditions: DownloadConditions(torrentsSuspended: true)) == .keepAlive)
    }

    @Test func aTorrentQueuedBehindOthersCounts() {
        let settings = DownloadSettings(maxConcurrent: 1)
        #expect(decide([record("h", torrent: false), record("t", state: .queued)], settings: settings) == .keepAlive)
    }

    @Test func oneRunnableTorrentIsEnough() {
        let mobile = DownloadConditions(isExpensive: true)
        let records = [record("wait"), record("now", allows: true)]
        #expect(decide(records, settings: DownloadSettings(wifiOnly: true), conditions: mobile) == .keepAlive)
    }
}
