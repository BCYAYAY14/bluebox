import Domain
@testable import Features
import Foundation
import SkipSegments
import Testing

@Suite struct HandoffPayloadTests {
    @Test func roundTripsThroughUserInfo() {
        let p = WatchActivityPayload(key: .episode(seriesID: 1396, season: 1, episode: 2), title: "Breaking Bad",
                                     subtitle: "S1·E2 · Cat's in the Bag", position: 1234, profileID: "kids",
                                     sourceID: "addons", variantID: String(repeating: "a", count: 40) + ":3", container: "mkv")
        #expect(WatchActivityPayload(userInfo: p.userInfo) == p)
    }

    @Test func rejectsForeignActivities() {
        #expect(WatchActivityPayload(userInfo: nil) == nil)
        #expect(WatchActivityPayload(userInfo: ["title": "No key"]) == nil)
    }

    @Test func refreshesOnlyOnRealChanges() {
        let base = WatchActivityPayload(key: .movie(tmdbID: 603), title: "The Matrix", position: 100)
        var moved = base
        moved.position = 125
        #expect(!WatchHandoff.needsRefresh(old: base, new: moved))  // under 30 s
        moved.position = 131
        #expect(WatchHandoff.needsRefresh(old: base, new: moved))
        var other = base
        other.key = .movie(tmdbID: 604)
        #expect(WatchHandoff.needsRefresh(old: base, new: other))
        #expect(WatchHandoff.needsRefresh(old: nil, new: base))
    }

    @Test func onlyAddonTorrentsTravel() {
        let addons = SourceID("addons")
        let hash = String(repeating: "b", count: 40)
        let torrent = MediaVariant(id: "\(hash):0", sourceID: addons, mediaKey: nil, displayName: "x", container: "mkv", location: .remote)
        #expect(WatchActivityPayload.handoffVariant(torrent, addonsID: addons)?.id == "\(hash):0")
        let debrid = MediaVariant(id: "https://debrid.example/abc", sourceID: addons, mediaKey: nil, displayName: "x", location: .remote)
        #expect(WatchActivityPayload.handoffVariant(debrid, addonsID: addons) == nil)
        let local = MediaVariant(id: "\(hash):0", sourceID: SourceID("folder"), mediaKey: nil, displayName: "x", location: .localFile)
        #expect(WatchActivityPayload.handoffVariant(local, addonsID: addons) == nil)
    }
}

@Suite struct ScrubThumbnailTests {
    @Test func bucketsScaleWithLength() {
        #expect(ScrubThumbnailer.bucketSeconds(for: 60) == 2)        // short clip: every 2 s
        #expect(ScrubThumbnailer.bucketSeconds(for: 2400) == 10)     // 40-minute episode
        #expect(ScrubThumbnailer.bucketSeconds(for: 3 * 3600) == 15) // capped
        #expect(ScrubThumbnailer.bucketIndex(0.5, duration: 2400, bucket: 10) == 120)
        #expect(ScrubThumbnailer.bucketIndex(1.2, duration: 2400, bucket: 10) == 240)  // clamped
    }

    @Test func streamGateNeedsHeadTailAndTheSpot() {
        let mb: Int64 = 1 << 20
        let w = StreamGate.windows(fileLength: 1000 * mb, centre: 500 * mb, pad: 10 * mb, edge: mb)
        #expect(w == [0..<mb, (999 * mb)..<(1000 * mb), (490 * mb)..<(510 * mb)])
        let start = StreamGate.windows(fileLength: 100 * mb, centre: 0, pad: 3 * mb, edge: mb)
        #expect(start[2] == 0..<(3 * mb))
    }
}

@MainActor
@Suite struct SkipControllerTests {
    private func controller(_ segments: [SkipSegment]) async -> SkipController {
        let c = SkipController()
        c.setResultForTesting(SkipSegmentResolver.Result(segments: segments, sources: [.chapters]))
        return c
    }

    @Test func automaticIntroSkipsOnceOnly() async {
        let c = await controller([SkipSegment(kind: .intro, start: 60, end: 120, source: .chapters)])
        let first = c.update(position: 61, duration: 1400, introMode: .automatic, creditsMode: .button, hasNext: true,
                             enabled: true, isScrubbing: false)
        #expect(first == .seek(120))
        // Seeking back into it doesn't skip it again.
        let again = c.update(position: 70, duration: 1400, introMode: .automatic, creditsMode: .button, hasNext: true,
                             enabled: true, isScrubbing: false)
        #expect(again == nil)
        #expect(c.offer == nil)
    }

    @Test func buttonModeOffersAndAccepts() async {
        let c = await controller([SkipSegment(kind: .credits, start: 1300, end: nil, source: .theIntroDB)])
        _ = c.update(position: 1305, duration: 1400, introMode: .button, creditsMode: .button, hasNext: true,
                     enabled: true, isScrubbing: false)
        #expect(c.offer == .nextEpisode)
        #expect(c.usesCrowdSources)
        #expect(c.accept() == .playNext)
    }

    @Test func watchCreditsDismisses() async {
        let c = await controller([SkipSegment(kind: .credits, start: 1300, end: nil, source: .chapters)])
        _ = c.update(position: 1305, duration: 1400, introMode: .button, creditsMode: .button, hasNext: true,
                     enabled: true, isScrubbing: false)
        c.dismiss()
        _ = c.update(position: 1310, duration: 1400, introMode: .button, creditsMode: .button, hasNext: true,
                     enabled: true, isScrubbing: false)
        #expect(c.offer == nil)
    }

    @Test func disabledForShowOrWhileScrubbing() async {
        let c = await controller([SkipSegment(kind: .intro, start: 60, end: 120, source: .chapters)])
        #expect(c.update(position: 61, duration: 1400, introMode: .automatic, creditsMode: .button, hasNext: true,
                         enabled: false, isScrubbing: false) == nil)
        #expect(c.update(position: 61, duration: 1400, introMode: .automatic, creditsMode: .button, hasNext: true,
                         enabled: true, isScrubbing: true) == nil)
    }
}
