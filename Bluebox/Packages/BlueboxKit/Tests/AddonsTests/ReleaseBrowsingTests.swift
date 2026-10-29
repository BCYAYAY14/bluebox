@testable import Addons
import Foundation
import Testing

/// The release picker's chips, groups, folded duplicates and row tags.
@Suite struct ReleaseBrowsingTests {
    private func names(_ releases: [AddonRelease]) -> [String] {
        releases.map { String($0.fileName.prefix(while: { $0 != "." })) }
    }

    // MARK: Chips

    private let mixed = [
        Make.torrent("1", "uhd.2160p.WEB-DL.DV.HDR10.HEVC.Atmos", seeders: 40, gb: 18),
        Make.torrent("2", "fhd.1080p.BluRay.x264", seeders: 200, gb: 4),
        Make.link("3", "cached.1080p.WEB-DL.x264", cache: .cached, gb: 2),
        Make.link("4", "uncached.720p.WEB-DL.x264", cache: .uncached, gb: 1),
        Make.torrent("5", "french.1080p.WEB-DL.x264.FRENCH", seeders: 10, gb: 1.5),
        Make.torrent("6", "nosize.1080p.WEB-DL.x264", seeders: 10),
        Make.torrent("7", "old.480p.DVDRip.XviD", seeders: 3, gb: 0.7),
    ]

    @Test func noChipsKeepsEverything() {
        #expect(!ReleaseFilter().isActive)
        #expect(ReleaseFilter().apply(mixed).count == mixed.count)
    }

    @Test func qualityChipsWidenEachOther() {
        let uhdOnly = ReleaseFilter(tiers: [.uhd])
        #expect(names(uhdOnly.apply(mixed)) == ["uhd"])
        let both = ReleaseFilter(tiers: [.uhd, .hd])
        #expect(names(both.apply(mixed)) == ["uhd", "uncached"])
    }

    @Test func chipsOfDifferentKindsNarrow() {
        let f = ReleaseFilter(tiers: [.fullHD], instantOnly: true)
        #expect(names(f.apply(mixed)) == ["cached"])
    }

    @Test func hdrChipKeepsHDRAndDolbyVision() {
        #expect(names(ReleaseFilter(hdrOnly: true).apply(mixed)) == ["uhd"])
    }

    @Test func sizeCapDropsUnknownSizes() {
        let f = ReleaseFilter(sizeCap: .twoGB)
        #expect(names(f.apply(mixed)) == ["cached", "uncached", "french", "old"])
        #expect(ReleaseSizeCap.fiveGB.title == "≤ 5 GB")
    }

    @Test func languageChipCountsUnmarkedReleasesAsEnglish() {
        let english = ReleaseFilter(language: "en")
        #expect(!names(english.apply(mixed)).contains("french"))
        #expect(names(english.apply(mixed)).contains("fhd"))
        let french = ReleaseFilter(language: "fr-FR")
        #expect(names(french.apply(mixed)) == ["french"])
        let multi = Make.torrent("8", "multi.1080p.WEB-DL.MULTi", seeders: 5, gb: 2)
        #expect(french.matches(multi))
    }

    // MARK: Groups

    @Test func groupsByQualityBestFirstKeepingOrder() {
        let sections = ReleaseCollapser.sections(mixed, filter: ReleaseFilter())
        #expect(sections.map(\.tier) == [.uhd, .fullHD, .hd, .other])
        #expect(sections.map { $0.tier.title } == ["4K", "1080p", "720p", "Other"])
        #expect(names(sections[1].clusters.map(\.lead)) == ["fhd", "cached", "french", "nosize"])
        #expect(sections.reduce(0) { $0 + $1.count } == mixed.count)
    }

    @Test func emptyGroupsAreLeftOut() {
        let sections = ReleaseCollapser.sections(mixed, filter: ReleaseFilter(tiers: [.hd, .uhd]))
        #expect(sections.map(\.tier) == [.uhd, .hd])
    }

    @Test func tiersFromResolutions() {
        #expect(QualityTier(resolution: "2160p") == .uhd)
        #expect(QualityTier(resolution: "1440p") == .fullHD)
        #expect(QualityTier(resolution: "720p") == .hd)
        #expect(QualityTier(resolution: "480p") == .other)
        #expect(QualityTier(resolution: nil) == .other)
    }

    // MARK: Near-duplicates

    @Test func foldsTheSameEncodeAtNearlyTheSameSize() {
        let found = [
            Make.torrent("1", "a.1080p.BluRay.x265-NTb", seeders: 200, gb: 2.00),
            Make.torrent("2", "b.1080p.BluRay.x265-PSA", seeders: 20, gb: 2.04),   // 2% bigger: folds
            Make.torrent("3", "c.1080p.BluRay.x265-RARBG", seeders: 20, gb: 2.20), // 10% bigger: its own row
            Make.torrent("4", "d.1080p.WEB-DL.x265", seeders: 20, gb: 2.01),       // other source
            Make.torrent("5", "e.1080p.BluRay.x264", seeders: 20, gb: 2.01),       // other codec
            Make.torrent("6", "f.720p.BluRay.x265", seeders: 20, gb: 2.01),        // other resolution
        ]
        let rows = ReleaseCollapser.collapse(found)
        #expect(names(rows.map(\.lead)) == ["a", "c", "d", "e", "f"])
        #expect(names(rows[0].similar) == ["b"])
        #expect(rows[0].all.count == 2)
    }

    @Test func foldsTheSameInfoHashWhateverItsName() {
        let torrent = Make.torrent("abc", "Show.1080p.WEB-DL.x264", seeders: 50, gb: 2)
        let debrid = Make.link("xyz", "Different.Name.2160p.mkv", cache: .cached, gb: 9, hash: torrent.infoHash)
        let rows = ReleaseCollapser.collapse([debrid, torrent])
        #expect(rows.count == 1)
        #expect(rows[0].lead.id == debrid.id)
    }

    @Test func unknownSizesDontFold() {
        let rows = ReleaseCollapser.collapse([
            Make.torrent("1", "a.1080p.BluRay.x265", seeders: 5),
            Make.torrent("2", "b.1080p.BluRay.x265", seeders: 5),
        ])
        #expect(rows.count == 2)
    }

    @Test func comparesWithTheRowsLeadSoSmallStepsDontChain() {
        let rows = ReleaseCollapser.collapse([
            Make.torrent("1", "a.1080p.BluRay.x265", seeders: 5, gb: 2.00),
            Make.torrent("2", "b.1080p.BluRay.x265", seeders: 5, gb: 2.05),  // 2.4%: folds
            Make.torrent("3", "c.1080p.BluRay.x265", seeders: 5, gb: 2.10),  // 4.8% from the lead: new row
        ])
        #expect(names(rows.map(\.lead)) == ["a", "c"])
    }

    @Test func hdrAndSDRCopiesStayApart() {
        let rows = ReleaseCollapser.collapse([
            Make.torrent("1", "a.2160p.WEB-DL.HEVC", seeders: 5, gb: 10),
            Make.torrent("2", "b.2160p.WEB-DL.HDR.HEVC", seeders: 5, gb: 10),
        ])
        #expect(rows.count == 2)
    }

    // MARK: Tags

    @Test func plainTagsInOrder() {
        let remux = Make.torrent("1", "x.2160p.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.Atmos", seeders: 120, gb: 60)
        #expect(ReleaseTag.tags(for: remux, smallBelow: nil) == [.fast, .hdr, .dolbyVision, .atmos, .remux])
        #expect(ReleaseTag.tags(for: remux, smallBelow: nil).map(\.title) == ["Fast", "HDR", "DV", "Atmos", "Remux"])

        let cached = Make.link("2", "y.1080p.WEB-DL.x264", cache: .cached, gb: 2)
        #expect(ReleaseTag.tags(for: cached, smallBelow: nil) == [.cached])
        let uncached = Make.link("3", "z.1080p.WEB-DL.x264", cache: .uncached, gb: 2)
        #expect(ReleaseTag.tags(for: uncached, smallBelow: nil).isEmpty)
    }

    @Test func dolbyVisionAloneIsntAlsoHDR() {
        let dv = Make.torrent("1", "x.2160p.WEB-DL.DV.HEVC", seeders: 5, gb: 15)
        #expect(ReleaseTag.tags(for: dv, smallBelow: nil) == [.dolbyVision])
    }

    @Test func fastNeedsABigSwarm() {
        let thin = Make.torrent("1", "x.1080p.WEB-DL.x264", seeders: ReleaseTag.fastSeeders - 1, gb: 2)
        let big = Make.torrent("2", "x.1080p.WEB-DL.x264", seeders: ReleaseTag.fastSeeders, gb: 2)
        #expect(!ReleaseTag.tags(for: thin, smallBelow: nil).contains(.fast))
        #expect(ReleaseTag.tags(for: big, smallBelow: nil).contains(.fast))
    }

    @Test func smallIsUnderMostOfTheTypicalSizeAtItsQuality() {
        let found = [
            Make.torrent("1", "a.1080p.WEB-DL.x264", seeders: 5, gb: 1.0),
            Make.torrent("2", "b.1080p.WEB-DL.x264", seeders: 5, gb: 4.0),
            Make.torrent("3", "c.1080p.WEB-DL.x264", seeders: 5, gb: 5.0),
            Make.torrent("4", "d.2160p.WEB-DL.x265", seeders: 5, gb: 2.0),  // only one 4K: no judgement
        ]
        let thresholds = ReleaseTag.smallThresholds(found)
        #expect(thresholds[.uhd] == nil)
        let cut = try! #require(thresholds[.fullHD])
        #expect(cut == Int64(4.0 * Double(Make.gb) * ReleaseTag.smallShare))
        #expect(ReleaseTag.tags(for: found[0], smallBelow: cut).contains(.small))
        #expect(!ReleaseTag.tags(for: found[1], smallBelow: cut).contains(.small))
    }

    // MARK: Search's chips

    @Test func cachedOffersAreEmptyBeforeAnySearch() async {
        let source = StremioSource(settings: AddonSettings(), debridKey: "", imdbID: { _ in nil })
        #expect(await source.cachedOffers().isEmpty)
    }
}
