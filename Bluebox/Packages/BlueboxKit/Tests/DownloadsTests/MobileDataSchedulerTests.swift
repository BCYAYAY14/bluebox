import Domain
@testable import Downloads
import Foundation
import Testing

/// Settings › Mobile Data rules in the download queue.
@Suite struct MobileDataSchedulerTests {
    private func record(_ id: String, torrent: Bool, allows: Bool? = nil) -> DownloadRecord {
        let variantID = torrent ? String(repeating: "a", count: 40) + ":0" : "https://example.com/\(id).mp4"
        let origin = MediaVariant(id: variantID, sourceID: SourceID("addons"), mediaKey: nil, displayName: id,
                                  location: .remote, isDownloadable: true)
        var r = DownloadRecord(id: id, mediaKey: nil, title: id, subtitle: nil, origin: origin, state: .queued,
                               receivedBytes: 0, expectedBytes: nil, createdAt: .now, fileName: nil, subtitleFiles: [])
        r.allowsMobileData = allows
        return r
    }

    private let mobile = DownloadConditions(isExpensive: true)

    @Test func downloadNowSkipsWiFiOnly() {
        let plan = DownloadScheduler.plan(records: [record("now", torrent: false, allows: true), record("wait", torrent: false)],
                                          running: [], settings: DownloadSettings(wifiOnly: true), conditions: mobile)
        #expect(plan.start == ["now"])
        #expect(plan.waits["wait"] == .wifi)
    }

    @Test func downloadOnWiFiLaterWaitsEvenWithWiFiOnlyOff() {
        let plan = DownloadScheduler.plan(records: [record("later", torrent: false, allows: false)], running: [],
                                          settings: DownloadSettings(wifiOnly: false), conditions: mobile)
        #expect(plan.start.isEmpty && plan.waits["later"] == .wifi)
        let onWiFi = DownloadScheduler.plan(records: [record("later", torrent: false, allows: false)], running: [],
                                            settings: DownloadSettings(wifiOnly: false), conditions: DownloadConditions())
        #expect(onWiFi.start == ["later"])
    }

    @Test func torrentsWaitWhenNotAllowedOnMobileData() {
        var conditions = mobile
        conditions.torrentsAllowedOnMobileData = false
        let plan = DownloadScheduler.plan(records: [record("t", torrent: true), record("h", torrent: false)], running: [],
                                          settings: DownloadSettings(wifiOnly: false), conditions: conditions)
        #expect(plan.waits["t"] == .wifi)
        #expect(plan.start == ["h"])
    }

    @Test func lowDataModeCountsAsMobileData() {
        #expect(NetworkPathInfo(isOnline: true, isConstrained: true, usesWiFi: true).isMobileData)
    }
}
