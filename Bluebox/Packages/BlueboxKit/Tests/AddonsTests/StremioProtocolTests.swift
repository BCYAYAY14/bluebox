@testable import Addons
import Foundation
import Testing

@Suite struct StreamParsingTests {
    private func parse(_ json: String, addon: String = "torrentio") throws -> StreamResponse {
        try StreamParser.parse(Data(json.utf8), addonID: addon, addonName: addon.capitalized)
    }

    @Test func torrentioMovieStreams() throws {
        let response = try parse(StreamFixtures.torrentioMovie)
        #expect(response.releases.count == 5)
        #expect(response.notices.isEmpty)
        let uhd = response.releases[0]
        #expect(uhd.id == "64877b5490208c3015c0f5121287949d62622e54:0")
        #expect(uhd.infoHash == "64877b5490208c3015c0f5121287949d62622e54")
        #expect(uhd.fileIndex == 0)
        #expect(uhd.resolution == "2160p")
        #expect(uhd.seeders == 0)
        #expect(uhd.sizeText == "4.78 GB")
        #expect(uhd.sizeBytes == Int64(4.78 * 1_073_741_824))
        #expect(uhd.bingeGroup == "torrentio|4k|x264")
        #expect(uhd.fileName == "Sintel.4K.UHD.ENG.FLAC.ITA.ENG.Sub.DMRip.1744p.X264_ZMachine.mkv")
        #expect(uhd.container == "mkv")
        #expect(uhd.info.videoCodec == .h264)
        #expect(uhd.info.languages == ["en", "it"])
        #expect(uhd.addonID == "torrentio")

        let yts = response.releases[1]
        #expect(yts.resolution == "720p")
        #expect(yts.seeders == 20)
        #expect(yts.group == "YTS")
        #expect(yts.info.source == .bluRay)
        #expect(yts.container == "mp4")

        // No file index: libtorrent picks the largest file.
        let noIndex = response.releases[4]
        #expect(noIndex.fileIndex == nil)
        #expect(noIndex.id.hasSuffix(":-1"))
        #expect(noIndex.trackers == ["udp://tracker.opentrackr.org:1337/announce"])
        #expect(noIndex.magnet?.contains("&tr=udp%3A%2F%2Ftracker.opentrackr.org") == true)
        #expect(noIndex.fileName == "Sintel [H264 - Eng - Multisubs] [Tntvillage]")
        // "Multi Subs" is subtitles, not audio.
        #expect(noIndex.info.languages == ["en"])
    }

    @Test func stremThruUsesVideoSizeAndAudioFlags() throws {
        let response = try parse(StreamFixtures.stremThruMovie, addon: "stremthru")
        let uhd = response.releases[0]
        #expect(uhd.sizeBytes == 5_490_455_272)
        #expect(uhd.seeders == 4)
        #expect(uhd.resolution == "2160p")
        #expect(uhd.group == "MaLLIeHbKa")
        #expect(uhd.info.languages == ["ru", "uk", "en"])   // 🎙️ line, not 💬
        #expect(uhd.info.audio.contains(.dts) && uhd.info.audio.contains(.dd))
        let web = response.releases[1]
        #expect(web.sizeBytes == 576_700_012)
        #expect(web.sizeText == "550 MB")                  // 💾 (file) wins over 📦
        #expect(web.info.source == .webDL)
        #expect(web.fileName == "classicalhd-sintel.2010.en-1080p.mkv")
    }

    @Test func episodeStreamsCarryPacksHDRAndTrackers() throws {
        let response = try parse(StreamFixtures.torrentioEpisode)
        let remux = response.releases[0]
        #expect(remux.info.source == .remux)
        #expect(remux.info.hdr == [.dolbyVision, .hdr10])
        #expect(remux.info.videoCodec == .hevc)
        #expect(remux.info.audio.contains(.atmos) && remux.info.audio.contains(.trueHD) && remux.info.audio.contains(.dtsHDMA))
        #expect(remux.info.channels == "7.1")
        #expect(remux.group == "PB69")
        let pack = response.releases[1]
        #expect(pack.fileIndex == 72)
        #expect(pack.id == "3bd99063ff49e4633f2a3f19754f6e3875cd35f7:72")
        #expect(pack.trackers == ["udp://opentor.net:6969", "http://retracker.local/announce"])
        #expect(pack.resolution == "2160p")
        #expect(pack.info.isDolbyVision)
        #expect(pack.info.languages == ["en", "ru"])
        let multi = response.releases[3]
        #expect(multi.info.languages.first == "multi")
        #expect(multi.info.languages.contains("fr"))
        #expect(multi.group == "QTZ")
    }

    @Test func debridLinksAndTheirCacheMarkers() throws {
        let response = try parse(StreamFixtures.torrentioDebrid)
        #expect(response.releases.count == 2)
        let cached = response.releases[0]
        #expect(cached.isDebrid)
        #expect(cached.cache == .cached)
        #expect(cached.startsInstantly)
        #expect(cached.magnet == nil)
        #expect(cached.contentHash == "43f4001de4ab25d521c63684e2b69804193ed9d9")
        #expect(cached.group == "NTb")
        let uncached = response.releases[1]
        #expect(uncached.cache == .uncached)
        #expect(!uncached.startsInstantly)
        #expect(uncached.resolution == "2160p")
    }

    @Test func messagesDressedAsStreamsAreNotReleases() throws {
        let notice = try parse(StreamFixtures.cometNotice, addon: "comet")
        #expect(notice.releases.isEmpty)
        #expect(notice.notices.count == 1)
        #expect(!notice.debridRejected)
        let rejected = try parse(StreamFixtures.rejectedKey)
        #expect(rejected.releases.isEmpty)
        #expect(rejected.debridRejected)
    }

    @Test func skipsWhatCantPlayAndReadsLenientNumbers() throws {
        let response = try parse(StreamFixtures.mixedKinds, addon: "x")
        #expect(response.releases.count == 2)
        let base32 = response.releases[0]
        #expect(base32.infoHash == "6162636465666768696a6b6c6d6e6f7071727374")
        #expect(base32.fileIndex == 2)                     // "2" as a string
        #expect(base32.seeders == 7)
        let direct = response.releases[1]
        #expect(direct.isDebrid && direct.cache == .unknown)
        #expect(direct.sizeBytes == 642_000_000)           // videoSize as a string
        #expect(direct.resolution == "1080p")
        #expect(direct.container == "mp4")
    }

    @Test func garbageIsAnError() {
        #expect(throws: AddonError.unexpectedResponse) { try StreamParser.parse(Data("<html>".utf8)) }
        #expect(throws: AddonError.unexpectedResponse) { try StreamParser.parse(Data("{\"metas\":[]}".utf8)) }
        #expect((try? StreamParser.parse(Data("{\"streams\":[]}".utf8)).releases.isEmpty) == true)
    }
}

@Suite struct ManifestTests {
    private func manifest(_ json: String) throws -> AddonManifest {
        try JSONDecoder().decode(AddonManifest.self, from: Data(json.utf8))
    }

    @Test func objectResourcesWithTypesAndPrefixes() throws {
        let m = try manifest(StreamFixtures.torrentioManifest)
        #expect(m.offersStreams(type: "movie") && m.offersStreams(type: "series"))
        #expect(m.streamTypes == ["movie", "series"])
        #expect(m.version == "0.0.15")
        try AddonClient.validate(m)
    }

    @Test func stringResourcesUseTheManifestsTypes() throws {
        let m = try manifest(StreamFixtures.stringResourceManifest)
        #expect(m.streamTypes == ["movie"])
        try AddonClient.validate(m)
    }

    @Test func rejectsAddonsThatCantFindReleases() throws {
        // Lists alone are fine now (rows on Home); TV channels alone aren't.
        try AddonClient.validate(try manifest(StreamFixtures.catalogOnlyManifest))
        #expect(throws: AddonError.noStreams("Just Channels")) { try AddonClient.validate(try manifest(StreamFixtures.channelsOnlyManifest)) }
        #expect(throws: AddonError.noStreams("Anime Only")) { try AddonClient.validate(try manifest(StreamFixtures.animeOnlyManifest)) }
        #expect(throws: AddonError.needsConfiguration("Needs Setup")) { try AddonClient.validate(try manifest(StreamFixtures.needsConfigManifest)) }
    }
}

@Suite struct AddonURLTests {
    @Test func normalisesPastedLinks() throws {
        #expect(try AddonURL.base(from: "stremio://torrentio.strem.fun/sort=seeders/manifest.json").absoluteString
                == "https://torrentio.strem.fun/sort=seeders")
        #expect(try AddonURL.base(from: " https://example.com/abc/manifest.json?x=1#y \n").absoluteString == "https://example.com/abc")
        #expect(try AddonURL.base(from: "https://example.com/").absoluteString == "https://example.com")
        #expect(try AddonURL.base(from: "example.com/config").absoluteString == "https://example.com/config")
        #expect(try AddonURL.base(from: "http://public.example.com/manifest.json").scheme == "https")
        #expect(try AddonURL.base(from: "http://192.168.1.5.local:7000/manifest.json").scheme == "http")
        // Configuration segments with escapes survive.
        #expect(try AddonURL.base(from: "https://torrentio.strem.fun/sort=size%7Cqualityfilter=cam/manifest.json").absoluteString
                == "https://torrentio.strem.fun/sort=size%7Cqualityfilter=cam")
    }

    @Test func rejectsWhatIsntALink() {
        for bad in ["", "   ", "not a link", "ftp://example.com/manifest.json", "https://"] {
            #expect(throws: AddonError.invalidAddonURL) { try AddonURL.base(from: bad) }
        }
    }

    @Test func requestPaths() {
        let base = URL(string: "https://torrentio.strem.fun/sort=seeders")!
        #expect(StreamRequest(imdbID: "tt1727587").url(base: base).absoluteString
                == "https://torrentio.strem.fun/sort=seeders/stream/movie/tt1727587.json")
        #expect(StreamRequest(imdbID: "tt0944947", season: 1, episode: 2).url(base: base).absoluteString
                == "https://torrentio.strem.fun/sort=seeders/stream/series/tt0944947:1:2.json")
    }
}
