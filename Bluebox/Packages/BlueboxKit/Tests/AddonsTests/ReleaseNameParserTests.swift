@testable import Addons
import Foundation
import Testing

@Suite struct ReleaseNameParserTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var resolution: String?
        var source: ReleaseInfo.Source?
        var codec: ReleaseInfo.VideoCodec?
        var hdr: [ReleaseInfo.HDRFormat] = []
        var audio: [ReleaseInfo.AudioFormat] = []
        var channels: String?
        var group: String?
        var languages: [String] = []
        var tenBit = false
        var container: String?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "The.Last.of.Us.S01E03.Long.Long.Time.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv",
             resolution: "2160p", source: .webDL, codec: .hevc, hdr: [.dolbyVision, .hdr10], audio: [.atmos, .ddPlus],
             channels: "5.1", group: "FLUX", container: "mkv"),
        Case(name: "Oppenheimer.2023.1080p.BluRay.x264-SPARKS", resolution: "1080p", source: .bluRay, codec: .h264, group: "SPARKS"),
        Case(name: "Dune.Part.Two.2024.2160p.UHD.BluRay.REMUX.HDR10+.HEVC.TrueHD.7.1.Atmos-FraMeSToR.mkv",
             resolution: "2160p", source: .remux, codec: .hevc, hdr: [.hdr10Plus], audio: [.atmos, .trueHD],
             channels: "7.1", group: "FraMeSToR", container: "mkv"),
        Case(name: "Severance.S02E01.1080p.ATVP.WEB-DL.DDP5.1.H.264-NTb", resolution: "1080p", source: .webDL, codec: .h264,
             audio: [.ddPlus], channels: "5.1", group: "NTb"),
        Case(name: "Shogun.2024.S01E01.720p.HDTV.x264-SYNCOPY", resolution: "720p", source: .hdtv, codec: .h264, group: "SYNCOPY"),
        Case(name: "Some.Movie.2023.HDCAM.x264-NOGRP", source: .cam, codec: .h264, group: "NOGRP"),
        Case(name: "Some.Movie.2023.HDTS.720p.x264-NOGRP", resolution: "720p", source: .telesync, codec: .h264, group: "NOGRP"),
        Case(name: "Some.Movie.2023.DVDScr.XviD-NOGRP.avi", source: .screener, codec: .xvid, group: "NOGRP", container: "avi"),
        Case(name: "Big.Buck.Bunny.2008.1080p.WEBRip.AV1.Opus.5.1-Blender.mkv", resolution: "1080p", source: .webRip, codec: .av1,
             audio: [.opus], channels: "5.1", group: "Blender", container: "mkv"),
        Case(name: "Tears.of.Steel.2012.4K.UHD.HDR.10bit.x265.AAC-Blender", resolution: "2160p", codec: .hevc, hdr: [.hdr10],
             audio: [.aac], group: "Blender", tenBit: true),
        Case(name: "[SubsPlease] Frieren - 12 (1080p) [A1B2C3D4].mkv", resolution: "1080p", group: "SubsPlease", container: "mkv"),
        Case(name: "Movie.Name.2019.1080p.BluRay.DTS-HD.MA.5.1.x264-GRP", resolution: "1080p", source: .bluRay, codec: .h264,
             audio: [.dtsHDMA], channels: "5.1", group: "GRP"),
        Case(name: "Movie Name (2019) [1080p] [BluRay] [5.1] [YTS.MX]", resolution: "1080p", source: .bluRay, channels: "5.1", group: "YTS"),
        Case(name: "Film.2021.MULTi.TRUEFRENCH.1080p.WEB.H264-FRATERNiTY", resolution: "1080p", source: .webDL, codec: .h264,
             group: "FRATERNiTY", languages: ["multi", "fr"]),
        Case(name: "Film.2020.ITA.ENG.1080p.BluRay.x265.AC3-iDN_CreW", resolution: "1080p", source: .bluRay, codec: .hevc,
             audio: [.dd], languages: ["en", "it"]),
        Case(name: "Film.2020.1080p.WEB-DL.DUAL.AAC2.0.H.264-GRP", resolution: "1080p", source: .webDL, codec: .h264,
             audio: [.aac], channels: "2.0", group: "GRP", languages: ["multi"]),
        Case(name: "Show.S03E05.HLG.2160p.WEB.h265-GRP", resolution: "2160p", source: .webDL, codec: .hevc, hdr: [.hlg], group: "GRP"),
        Case(name: "Old.Film.1985.DVDRip.XviD.MP3-aXXo", resolution: "480p", source: .dvdRip, codec: .xvid, audio: [.mp3], group: "aXXo"),
        Case(name: "Film.2022.1920x1080.WEB-DL.EAC3-GRP", resolution: "1080p", source: .webDL, audio: [.ddPlus], group: "GRP"),
        Case(name: "Film.2022.1080p.WEB-DL.H264.SDR-GRP", resolution: "1080p", source: .webDL, codec: .h264, group: "GRP"),
        Case(name: "Sintel.2010.4K.DMRip.x264.DD.DTS.SRT-MaLLIeHbKa.mkv", resolution: "2160p", codec: .h264, audio: [.dts, .dd],
             group: "MaLLIeHbKa", container: "mkv"),
    ]

    @Test(arguments: cases) func parses(_ c: Case) {
        let info = ReleaseNameParser.parse(c.name)
        #expect(info.resolution == c.resolution)
        #expect(info.source == c.source)
        #expect(info.videoCodec == c.codec)
        #expect(info.hdr == c.hdr)
        #expect(info.audio == c.audio)
        #expect(info.channels == c.channels)
        #expect(info.group == c.group)
        #expect(info.languages == c.languages)
        #expect(info.tenBit == c.tenBit)
        #expect(info.container == c.container)
    }

    @Test func groupsNeedARealGroup() {
        #expect(ReleaseNameParser.parse("Film.2020.1080p.WEB-DL").group == nil)
        #expect(ReleaseNameParser.parse("Film.2020.1080p.BluRay.x264").group == nil)
        #expect(ReleaseNameParser.parse("Film 2020 - 1080p").group == nil)
        #expect(ReleaseNameParser.parse("Film.2020.1080p.WEB-DL.DTS-HD").group == nil)
    }

    @Test func threeDAndOddResolutions() {
        #expect(ReleaseNameParser.parse("Avatar.2009.1080p.3D.HSBS.BluRay.x264-GRP").is3D)
        #expect(ReleaseNameParser.parse("Wide.Film.2019.1080p.x264").resolution == "1080p")
        #expect(ReleaseNameParser.parse("Wide.Film.2019.800p.x264").resolution == "720p")
        #expect(ReleaseNameParser.parse("Something.Without.Facts").resolution == nil)
        // A ".ts" container isn't a telesync.
        #expect(ReleaseNameParser.parse("Concert.2019.1080p.HDTV.ts").source == .hdtv)
    }

    @Test func addOnStatistics() {
        let torrentio = ReleaseNameParser.statistics(in: "Sintel 2010 720p BluRay\n👤 20 💾 136.47 MB ⚙️ YTS")
        #expect(torrentio.seeders == 20)
        #expect(torrentio.sizeText == "136.47 MB")
        #expect(torrentio.sizeBytes == Int64(136.47 * 1_048_576))
        let stremthru = ReleaseNameParser.statistics(in: "📦 557 MB 〽️ 649 KB/s 👤 12")
        #expect(stremthru.sizeText == "557 MB")            // not the speed
        #expect(stremthru.seeders == 12)
        #expect(ReleaseNameParser.statistics(in: "💾 550 MB 📦 557 MB").sizeText == "550 MB")
        #expect(ReleaseNameParser.statistics(in: "Size: 1,4 GiB Seeders: 33").sizeText == "1.4 GB")
        #expect(ReleaseNameParser.statistics(in: "Size: 1,4 GiB Seeders: 33").seeders == 33)
        #expect(ReleaseNameParser.statistics(in: "nothing here") == .init())
    }

    @Test func flagsBecomeLanguages() {
        #expect(ReleaseNameParser.flagLanguages("🇬🇧 / 🇮🇹 / 🇺🇸") == ["en", "it"])
        #expect(ReleaseNameParser.flagLanguages("🇧🇷 🇯🇵") == ["pt", "ja"])
        #expect(ReleaseNameParser.flagLanguages("no flags") == [])
    }

    @Test func labelAndDescriptionTogether() {
        // The label's "4k DV | HDR" fills what the file name doesn't say.
        let info = ReleaseNameParser.parse(label: "Torrentio\n4k DV | HDR", description: "Some.Show.S01E01.WEB-DL.mkv\n👤 5 💾 9 GB",
                                           filename: "Some.Show.S01E01.WEB-DL.mkv")
        #expect(info.resolution == "2160p")
        #expect(info.hdr == [.dolbyVision, .hdr10])
        #expect(info.source == .webDL)
        #expect(info.seeders == 5)
        #expect(info.sizeText == "9 GB")
    }
}
