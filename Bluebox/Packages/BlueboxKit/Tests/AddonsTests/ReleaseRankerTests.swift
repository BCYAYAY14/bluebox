@testable import Addons
import Foundation
import Testing

/// Builds releases from a file name and a few numbers.
enum Make {
    static let gb: Int64 = 1_073_741_824

    static func torrent(_ id: String, _ file: String, seeders: Int?, gb size: Double? = nil, addon: String = "a",
                        fileIndex: Int? = 0, binge: String? = nil, text: String? = nil) -> AddonRelease {
        let hash = String(repeating: id, count: 40 / max(id.count, 1) + 1).prefix(40)
        return AddonRelease(id: "\(hash):\(fileIndex ?? -1)", title: text ?? file, name: addon, infoHash: String(hash),
                            fileIndex: fileIndex, trackers: [], seeders: seeders, sizeText: nil, resolution: nil,
                            container: nil, url: nil, addonID: addon, addonName: addon.uppercased(),
                            bingeGroup: binge, filename: file, videoSize: size.map { Int64($0 * Double(gb)) })
    }

    static func link(_ id: String, _ file: String, cache: CacheState, gb size: Double? = nil, addon: String = "a",
                     hash: String? = nil) -> AddonRelease {
        let url = URL(string: "https://debrid.example/\(hash ?? id)/\(id).mkv")!
        return AddonRelease(id: url.absoluteString, title: file, name: addon, infoHash: nil, fileIndex: nil, trackers: [],
                            seeders: nil, sizeText: nil, resolution: nil, container: nil, url: url, addonID: addon,
                            addonName: addon.uppercased(), cache: cache, filename: file,
                            videoSize: size.map { Int64($0 * Double(gb)) })
    }
}

@Suite struct ReleaseRankerTests {
    private func ids(_ releases: [AddonRelease], _ context: RankingContext) -> [String] {
        ReleaseRanker.rank(releases, context: context).map { String($0.title.prefix(while: { $0 != "." })) }
    }

    @Test func cachedLinksThenHealthyTorrentsThenTheRest() {
        let found = [
            Make.torrent("1", "dead.1080p.WEB-DL.x264", seeders: 0, gb: 2),
            Make.torrent("2", "thin.1080p.WEB-DL.x264", seeders: 2, gb: 2),
            Make.link("3", "uncached.1080p.WEB-DL.x264", cache: .uncached, gb: 2),
            Make.torrent("4", "healthy.1080p.WEB-DL.x264", seeders: 80, gb: 2),
            Make.link("5", "cached.1080p.WEB-DL.x264", cache: .cached, gb: 2),
            Make.torrent("6", "unknown.1080p.WEB-DL.x264", seeders: nil, gb: 2),
        ]
        #expect(ids(found, RankingContext()) == ["cached", "healthy", "thin", "unknown", "uncached", "dead"])
    }

    @Test func sizePerMinuteKeepsRemuxesAndStarvedEncodesBack() {
        // A 2-hour film at 1080p: 38 GB is a remux (≈320 MB/min), 600 MB is starved (≈5 MB/min).
        let found = [
            Make.torrent("1", "remux.1080p.BluRay.REMUX.AVC", seeders: 300, gb: 38),
            Make.torrent("2", "tiny.1080p.WEBRip.x264", seeders: 300, gb: 0.6),
            Make.torrent("3", "right.1080p.WEB-DL.x264", seeders: 40, gb: 6),
        ]
        let context = RankingContext(runtimeMinutes: 120)
        #expect(ids(found, context) == ["right", "tiny", "remux"])
        #expect(ReleaseRanker.sizeFit(found[0], runtimeMinutes: 120) == .large)
        #expect(ReleaseRanker.sizeFit(found[1], runtimeMinutes: 120) == .small)
        // The same 6 GB is too much for a 20-minute episode.
        #expect(ReleaseRanker.sizeFit(found[2], runtimeMinutes: 20) == .large)
    }

    @Test func codecsTheDeviceDecodes() {
        let found = [
            Make.torrent("1", "av1.1080p.WEB-DL.AV1", seeders: 50, gb: 3),
            Make.torrent("2", "hevc.1080p.WEB-DL.x265", seeders: 50, gb: 3),
            Make.torrent("3", "avc.1080p.WEB-DL.x264", seeders: 50, gb: 3),
        ]
        let old = DeviceProfile(decodesHEVC: false, decodesAV1: false, displaysHDR: false, displaysDolbyVision: false)
        #expect(ids(found, RankingContext(device: old)) == ["avc", "av1", "hevc"])
        // HEVC on a modern device is as good as H.264; the add-on's order decides.
        #expect(ids(found, RankingContext(device: .typical)) == ["hevc", "avc", "av1"])
        let m3 = DeviceProfile(decodesHEVC: true, decodesAV1: true, displaysHDR: true, displaysDolbyVision: true)
        #expect(ids(found, RankingContext(device: m3)) == ["av1", "hevc", "avc"])
    }

    @Test func hdrOnlyWhereTheScreenShowsIt() {
        let found = [
            Make.torrent("1", "dvonly.2160p.WEB-DL.DV.x265", seeders: 50, gb: 15),
            Make.torrent("2", "hdr.2160p.WEB-DL.HDR10.x265", seeders: 50, gb: 15),
            Make.torrent("3", "sdr.2160p.WEB-DL.x265", seeders: 50, gb: 15),
        ]
        let sdrScreen = RankingContext(preferredResolution: "2160p", device: .typical)
        #expect(ids(found, sdrScreen) == ["sdr", "hdr", "dvonly"])
        let hdrScreen = RankingContext(preferredResolution: "2160p",
                                       device: DeviceProfile(decodesHEVC: true, decodesAV1: false, displaysHDR: true, displaysDolbyVision: true))
        #expect(ids(found, hdrScreen) == ["dvonly", "hdr", "sdr"])
    }

    @Test func audioInYourLanguage() {
        let found = [
            Make.torrent("1", "italian.1080p.WEB-DL.ITA.x264", seeders: 50, gb: 3),
            Make.torrent("2", "unknown.1080p.WEB-DL.x264", seeders: 50, gb: 3),
            Make.torrent("3", "english.1080p.WEB-DL.ENG.x264", seeders: 50, gb: 3),
            Make.torrent("4", "multi.1080p.WEB-DL.MULTi.x264", seeders: 50, gb: 3),
        ]
        #expect(ids(found, RankingContext(audioLanguage: "en")) == ["english", "unknown", "multi", "italian"])
        #expect(ids(found, RankingContext(audioLanguage: "it-IT")).first == "italian")
        #expect(ids(found, RankingContext(audioLanguage: nil)) == ["italian", "unknown", "english", "multi"])
    }

    @Test func preferredResolutionStepsDownBeforeUp() {
        let found = [
            Make.torrent("1", "uhd.2160p.WEB-DL.x265", seeders: 50, gb: 12),
            Make.torrent("2", "hd.720p.WEB-DL.x264", seeders: 50, gb: 1.5),
            Make.torrent("3", "fhd.1080p.WEB-DL.x264", seeders: 50, gb: 3),
        ]
        #expect(ids(found, RankingContext(preferredResolution: "1080p")) == ["fhd", "hd", "uhd"])
        #expect(ids(found, RankingContext(preferredResolution: nil)) == ["uhd", "fhd", "hd"])
    }

    @Test func seedersAndAddonOrderBreakTies() {
        let found = [
            Make.torrent("1", "few.1080p.WEB-DL.x264", seeders: 9, gb: 3, addon: "a"),
            Make.torrent("2", "many.1080p.WEB-DL.x264", seeders: 900, gb: 3, addon: "b"),
            Make.torrent("3", "fromA.1080p.WEB-DL.x264", seeders: 905, gb: 3, addon: "a"),
        ]
        let bySeeders = RankingContext(sort: .seeders, addonOrder: ["a", "b"])
        #expect(ids(found, bySeeders) == ["fromA", "many", "few"])  // 900 and 905 tie; a is first
        let byQuality = RankingContext(sort: .quality, addonOrder: ["b", "a"])
        #expect(ids(found, byQuality) == ["many", "few", "fromA"])
    }

    @Test func sameGroupNextEpisode() {
        let found = [
            Make.torrent("1", "Show.S01E02.1080p.WEB-DL.x264-OTHER", seeders: 400, gb: 2),
            Make.torrent("2", "Show.S01E02.720p.WEB-DL.x264-NTb", seeders: 30, gb: 1),
            Make.torrent("3", "Show.S01E02.1080p.WEB-DL.x264-NTb", seeders: 30, gb: 2),
            Make.torrent("4", "Show.S01E02.1080p.WEB-DL.x264-PACK", seeders: 30, gb: 2, binge: "torrentio|abc"),
            Make.torrent("5", "Show.S01E02.1080p.WEB-DL.x264-DEAD", seeders: 0, gb: 2, binge: "torrentio|abc"),
        ]
        let choice = ShowChoice(group: "ntb", resolution: "1080p", bingeGroup: "torrentio|abc", addonID: "a")
        let ranked = ReleaseRanker.rank(found, context: RankingContext(showChoice: choice)).map(\.group)
        // Binge group, then group at the same resolution, then same group at another; a dead torrent stays last.
        #expect(ranked == ["PACK", "NTb", "NTb", "OTHER", "DEAD"])
        #expect(ReleaseRanker.rank(found, context: RankingContext(showChoice: choice))[2].resolution == "720p")
        #expect(ChoiceMatch.of(found[2], choice) == .groupAndResolution)
        #expect(ChoiceMatch.of(found[1], choice) == .group)
        #expect(!ChoiceMatch.of(found[0], choice).isMatch)
        // Turned off in Settings: no preference.
        var settings = AddonSettings()
        settings.rememberShowChoices = false
        #expect(RankingContext(settings: settings, canStreamTorrents: true, showChoice: choice).showChoice == nil)
    }

    @Test func showChoicesNeedSomethingSpecific() {
        let plain = Make.torrent("1", "Show.S01E01.1080p.WEB-DL", seeders: 3)
        #expect(!ShowChoice(plain).isUseful)
        #expect(ShowChoice(Make.torrent("2", "Show.S01E01.1080p.WEB-DL-GRP", seeders: 3)).isUseful)
    }

    @Test func hiddenQualitiesApplyToEveryAddon() {
        let found = [
            Make.torrent("1", "cam.2024.HDCAM.x264-GRP", seeders: 900, gb: 1, addon: "b"),
            Make.torrent("2", "tele.2024.HDTS.x264-GRP", seeders: 900, gb: 1, addon: "b"),
            Make.torrent("3", "good.2024.1080p.WEB-DL.x264-GRP", seeders: 10, gb: 3, addon: "b"),
            Make.torrent("4", "threed.2024.1080p.3D.HSBS.BluRay.x264-GRP", seeders: 10, gb: 3, addon: "b"),
        ]
        #expect(ids(found, RankingContext(hiddenQualities: [.cam, .threed])) == ["good"])
    }

    @Test func torrentsDroppedWhereTheyCantStream() {
        let found = [Make.torrent("1", "p2p.1080p", seeders: 100), Make.link("2", "link.1080p", cache: .unknown)]
        #expect(ids(found, RankingContext(canStreamTorrents: false)) == ["link"])
    }

    // MARK: Mobile data

    @Test func dataSaverCapsAt720pAndPrefersTheSmallest() {
        let ranking = MobileDataRanking(maxResolution: "720p", preferSmallest: true, allowsTorrents: true, allowsDebrid: true)
        let found = [Make.torrent("1", "big1080.1080p.WEB-DL", seeders: 50, gb: 4), Make.torrent("2", "big720.720p.WEB-DL", seeders: 50, gb: 1.4),
                     Make.torrent("3", "small720.720p.WEB-DL", seeders: 50, gb: 0.7), Make.torrent("4", "uhd.2160p.WEB-DL", seeders: 50, gb: 14)]
        let ranked = ids(found, RankingContext(mobileData: ranking))
        #expect(Array(ranked.prefix(2)) == ["small720", "big720"])
        #expect(Set(ranked.suffix(2)) == ["big1080", "uhd"])  // above the cap: last
        #expect(ranking.isAboveCap(found[0]) && !ranking.isAboveCap(found[1]))
        // Off mobile data the same list ranks as before.
        #expect(ids(found, RankingContext()).first == "big1080")
    }

    @Test func automaticCapsAt1080p() {
        let ranking = MobileDataRanking(maxResolution: "1080p", preferSmallest: false, allowsTorrents: true, allowsDebrid: true)
        let found = [Make.torrent("1", "uhd.2160p.WEB-DL", seeders: 50), Make.torrent("2", "fhd.1080p.WEB-DL", seeders: 50)]
        #expect(ids(found, RankingContext(preferredResolution: nil, mobileData: ranking)) == ["fhd", "uhd"])
    }

    @Test func debridOnlyDropsPeerToPeer() {
        let debridOnly = MobileDataRanking(maxResolution: nil, preferSmallest: false, allowsTorrents: false, allowsDebrid: true)
        let found = [Make.torrent("1", "p2p.1080p", seeders: 50), Make.link("2", "rd.1080p", cache: .cached)]
        #expect(ids(found, RankingContext(mobileData: debridOnly)) == ["rd"])
        let never = MobileDataRanking(maxResolution: nil, preferSmallest: false, allowsTorrents: false, allowsDebrid: false)
        #expect(ids(found, RankingContext(mobileData: never)).isEmpty)
    }
}

@Suite struct DeduplicationTests {
    @Test func sameTorrentFromTwoAddonsBecomesOne() {
        var fromA = Make.torrent("ab", "Film.2020.1080p.WEB-DL.x264-GRP", seeders: 10, gb: 2, addon: "a", fileIndex: nil)
        fromA.seeders = 10
        let fromB = Make.torrent("ab", "Film.2020.1080p.WEB-DL.x264-GRP", seeders: 25, gb: 2, addon: "b", fileIndex: 3)
        let merged = ReleaseDeduplicator.merge([[fromA], [fromB]])
        #expect(merged.count == 1)
        #expect(merged[0].addonID == "a")              // the first add-on's copy is kept
        #expect(merged[0].fileIndex == 3)              // …with the file index it lacked
        #expect(merged[0].id.hasSuffix(":3"))
        #expect(merged[0].seeders == 25)               // and the better seeder count
        #expect(merged[0].alsoFrom == ["B"])
    }

    @Test func differentFilesOfASeasonPackStayApart() {
        let e1 = Make.torrent("cd", "Show.S01E01.1080p-GRP", seeders: 10, addon: "a", fileIndex: 1)
        let e2 = Make.torrent("cd", "Show.S01E02.1080p-GRP", seeders: 10, addon: "b", fileIndex: 2)
        #expect(ReleaseDeduplicator.merge([[e1], [e2]]).count == 2)
    }

    @Test func linksAndTorrentsOfOneReleaseBothStay() {
        let hash = String(repeating: "ef", count: 20)
        let torrent = Make.torrent("ef", "Film.2020.1080p-GRP", seeders: 10, gb: 2)
        let link = Make.link("x", "Film.2020.1080p-GRP", cache: .cached, gb: 2, hash: hash)
        let link2 = Make.link("y", "Film.2020.1080p-GRP.mkv", cache: .unknown, gb: 2, addon: "b", hash: hash)
        let merged = ReleaseDeduplicator.merge([[torrent, link], [link2]])
        #expect(merged.count == 2)
        #expect(merged.first { $0.isDebrid }?.cache == .cached)
    }

    @Test func noHashFallsBackToNameAndSize() {
        let a = Make.link("1", "Film.2020.1080p.WEB-DL.x264-GRP.mkv", cache: .unknown, gb: 2.000, addon: "a")
        let b = Make.link("2", "Film.2020.1080p.WEB-DL.x264-GRP.mkv", cache: .unknown, gb: 2.005, addon: "b")
        let c = Make.link("3", "Film.2020.1080p.WEB-DL.x264-GRP.mkv", cache: .unknown, gb: 3.1, addon: "b")
        #expect(ReleaseDeduplicator.merge([[a], [b, c]]).count == 2)
    }
}

@Suite struct AirPlayRankingTests {
    private func names(_ releases: [AddonRelease], airPlaying: Bool) -> [String] {
        var device = DeviceProfile.typical
        device.airPlaying = airPlaying
        return ReleaseRanker.rank(releases, context: RankingContext(device: device))
            .map { String($0.title.prefix(while: { $0 != "." })) }
    }

    @Test func mp4FirstWhileAirPlaying() {
        let found = [
            Make.link("1", "cached.1080p.WEB-DL.x264.mkv", cache: .cached, gb: 2),
            Make.torrent("2", "healthy.1080p.WEB-DL.x264.mkv", seeders: 80, gb: 2),
            Make.torrent("3", "thinmp4.1080p.WEB-DL.x264.mp4", seeders: 2, gb: 2),
            Make.torrent("4", "movie.1080p.WEB-DL.x264.m4v", seeders: 60, gb: 2),
        ]
        #expect(names(found, airPlaying: false) == ["cached", "healthy", "movie", "thinmp4"])
        #expect(names(found, airPlaying: true) == ["movie", "thinmp4", "cached", "healthy"])
    }

    @Test func deadMP4sDontJumpTheQueue() {
        let found = [
            Make.torrent("1", "dead.1080p.WEB-DL.x264.mp4", seeders: 0, gb: 2),
            Make.torrent("2", "healthy.1080p.WEB-DL.x264.mkv", seeders: 80, gb: 2),
            Make.torrent("3", "quick.1080p.WEB-DL.x264.mov", seeders: 40, gb: 2),
        ]
        #expect(names(found, airPlaying: true) == ["quick", "healthy", "dead"])
    }
}
