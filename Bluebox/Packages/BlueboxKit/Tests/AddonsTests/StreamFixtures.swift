// Stream and manifest responses in the shapes the Stremio add-on SDK
// documents (docs/api/responses/stream.md, manifest.md), trimmed from what
// public add-ons return for openly licensed films (Sintel, tt1727587) and a
// series episode. Debrid examples use made-up keys and hosts.

import Foundation

enum StreamFixtures {
    static let torrentioMovie = #"""
    {"streams":[
    {"name":"Torrentio\n4k","title":"Sintel 4K UHD ENG FLAC ITA ENG Sub DMRip 1744p X264 ZMachine\n👤 0 💾 4.78 GB ⚙️ MagnetDL\n🇬🇧 / 🇮🇹","infoHash":"64877b5490208c3015c0f5121287949d62622e54","fileIdx":0,"behaviorHints":{"bingeGroup":"torrentio|4k|x264","filename":"Sintel.4K.UHD.ENG.FLAC.ITA.ENG.Sub.DMRip.1744p.X264_ZMachine.mkv"}},
    {"name":"Torrentio\n720p","title":"Sintel 2010 720p BluRay\n👤 20 💾 136.47 MB ⚙️ YTS","infoHash":"a779fa758f2229586eebc2e5960eb32fe5659596","fileIdx":0,"behaviorHints":{"bingeGroup":"torrentio|720p|BluRay|x264","filename":"Sintel.2010.720p.BluRay.x264.AAC-[YTS.MX].mp4"}},
    {"name":"Torrentio\n720p","title":"Sintel (2010) BRRip 720p X264 -MitZep [Short Animation]\n👤 0 💾 116.62 MB ⚙️ MagnetDL","infoHash":"a80774f4eb08ddfbce02e96fbcc10207952dd5d3","fileIdx":1,"behaviorHints":{"bingeGroup":"torrentio|720p|BRRip|x264","filename":"Sintel (2010) BRRip 720p x264 -MitZep.mkv"}},
    {"name":"Torrentio","title":"Sintel\n👤 3 💾 441.89 MB ⚙️ ThePirateBay","infoHash":"19288989fd99a41ad24f30c23b0271e0a825ac5f","fileIdx":0,"behaviorHints":{"bingeGroup":"torrentio|x264","filename":"Sintel.2010.2K.SURROUND.x264-VODO.mp4"}},
    {"name":"Torrentio","title":"Sintel [H264 - Eng - Multisubs] [Tntvillage]\n👤 1 💾 441.52 MB ⚙️ ThePirateBay\nMulti Subs / 🇬🇧","infoHash":"a41915eababbf8d37ff5f96c0db70a289d1b206c","behaviorHints":{"bingeGroup":"torrentio|h264"},"sources":["tracker:udp://tracker.opentrackr.org:1337/announce","dht:a41915eababbf8d37ff5f96c0db70a289d1b206c"]}
    ]}
    """#

    static let stremThruMovie = #"""
    {"streams":[
    {"infoHash":"c334138ef5bfc2d568ea7324e0e2a3a7ec229bdd","name":"[P2P]\nTorz\n4k","description":"🎞️ H264\n🎧 DTS Lossy, DD | stereo, 5.1\n📦 5.1 GB 〽️ 6.2 MB/s 👤 4\n🎙️ 🇷🇺 🇺🇦 🇬🇧\n💬 🇷🇺 🇺🇦 🇬🇧\n⚙️ MaLLIeHbKa 🔍 Knaben\n📄 Sintel.2010.4K.DMRip.x264.DD.DTS.SRT-MaLLIeHbKa.mkv","behaviorHints":{"bingeGroup":"torz:c334138ef5bfc2d568ea7324e0e2a3a7ec229bdd","videoHash":"d8844e2e8c930971","videoSize":5490455272,"filename":"Sintel.2010.4K.DMRip.x264.DD.DTS.SRT-MaLLIeHbKa.mkv"}},
    {"infoHash":"43f4001de4ab25d521c63684e2b69804193ed9d9","name":"[P2P]\nTorz\n1080p","description":"💿 WEB 🎞️ H264\n🎧 stereo\n💾 550 MB 📦 557 MB 〽️ 649 KB/s 👤 12\n🎙️ 🇬🇧\n💬 🇬🇧 🇩🇪 🇪🇸 🇫🇷 🇮🇹 🇵🇹 🇳🇱 🇸🇪 🇩🇰 🇫🇮 🇳🇴\n⚙️ CLASSiCALHD 🔍 TorrentGalaxyClone\n📄 classicalhd-sintel.2010.en-1080p.mkv","behaviorHints":{"bingeGroup":"torz:43f4001de4ab25d521c63684e2b69804193ed9d9","videoHash":"7af826add7776dd3","videoSize":576700012,"filename":"classicalhd-sintel.2010.en-1080p.mkv"}},
    {"infoHash":"a779fa758f2229586eebc2e5960eb32fe5659596","name":"[P2P]\nTorz\n720p","description":"💿 BluRay 🎞️ H264\n🎧 stereo\n📦 136 MB 〽️ 161 KB/s 👤 10\n🔍 Knaben\n📄 Sintel.2010.720p.BluRay.x264.AAC-[YTS.MX].mp4","behaviorHints":{"bingeGroup":"torz:a779fa758f2229586eebc2e5960eb32fe5659596","videoHash":"42fafe99aca69677","videoSize":143100616,"filename":"Sintel.2010.720p.BluRay.x264.AAC-[YTS.MX].mp4"}}
    ]}
    """#

    static let torrentioEpisode = #"""
    {"streams":[
    {"name":"Torrentio\n4k DV | HDR","title":"Game.of.Thrones.S01.2160p.DoVi.HDR.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.7.1.Atmos-PB69\nGame.of.Thrones.S01E01.2160p.DoVi.HDR.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.7.1.Atmos-PB69.mkv\n👤 22 💾 31.9 GB ⚙️ TorrentGalaxy","infoHash":"f33ce65b218f7c51d65a69d90b09e46c2381c8ef","fileIdx":0,"behaviorHints":{"bingeGroup":"torrentio|f33ce65b218f7c51d65a69d90b09e46c2381c8ef","filename":"Game.of.Thrones.S01E01.2160p.DoVi.HDR.BluRay.REMUX.HEVC.DTS-HD.MA.TrueHD.7.1.Atmos-PB69.mkv"}},
    {"name":"Torrentio\n4k DV | HDR","title":"Season pack UHD BDRemux 2160p | 4K | HDR | Dolby Vision Profile 8\nSeason 1/S01E01. Winter Is Coming.mkv\n👤 11 💾 24.08 GB ⚙️ Rutor\n🇬🇧 / 🇷🇺","infoHash":"3bd99063ff49e4633f2a3f19754f6e3875cd35f7","fileIdx":72,"behaviorHints":{"bingeGroup":"torrentio|3bd99063ff49e4633f2a3f19754f6e3875cd35f7","filename":"S01E01. Winter Is Coming.mkv"},"sources":["tracker:udp://opentor.net:6969","tracker:http://retracker.local/announce","dht:3bd99063ff49e4633f2a3f19754f6e3875cd35f7"]},
    {"name":"Torrentio\n1080p","title":"Game.of.Thrones.S01.1080p.BluRay.x264-NTb\nGame.of.Thrones.S01E01.1080p.BluRay.x264-NTb.mkv\n👤 140 💾 2.9 GB ⚙️ 1337x","infoHash":"aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11","fileIdx":0,"behaviorHints":{"bingeGroup":"torrentio|1080p|BluRay|x264","filename":"Game.of.Thrones.S01E01.1080p.BluRay.x264-NTb.mkv"}},
    {"name":"Torrentio\n1080p","title":"Game of Thrones S01 MULTi VFI 1080p 10bit HDR BluRay TrueHD Atmos 7.1 x265-QTZ\n👤 22 💾 4.78 GB ⚙️ Torrent9\nMulti Audio / 🇫🇷","infoHash":"106e91b93321f9c8aeeeb32ea6c92317327e7b3b","fileIdx":0,"behaviorHints":{"bingeGroup":"torrentio|106e91b93321f9c8aeeeb32ea6c92317327e7b3b","filename":"Game of Thrones S01E01 MULTi VFI 1080p 10bit HDR BluRay TrueHD Atmos 7.1 x265-QTZ.mkv"}}
    ]}
    """#

    /// Torrentio with a debrid key: links instead of info hashes, cached ones marked "+".
    static let torrentioDebrid = #"""
    {"streams":[
    {"name":"[RD+] Torrentio\n1080p","title":"Sintel.2010.1080p.WEB-DL.H264.AAC-NTb\n👤 30 💾 1.2 GB ⚙️ 1337x","url":"https://torrentio.strem.fun/realdebrid/KEY/43f4001de4ab25d521c63684e2b69804193ed9d9/null/0/Sintel.2010.1080p.mkv","behaviorHints":{"bingeGroup":"torrentio|1080p|WEB-DL","filename":"Sintel.2010.1080p.WEB-DL.H264.AAC-NTb.mkv"}},
    {"name":"[RD download] Torrentio\n4k","title":"Sintel.2010.2160p.UHD.BluRay.x265.HDR.Atmos-FLUX\n👤 9 💾 14.1 GB ⚙️ TorrentGalaxy","url":"https://torrentio.strem.fun/realdebrid/KEY/c334138ef5bfc2d568ea7324e0e2a3a7ec229bdd/null/0/Sintel.2160p.mkv","behaviorHints":{"bingeGroup":"torrentio|4k|HDR","filename":"Sintel.2010.2160p.UHD.BluRay.x265.HDR.Atmos-FLUX.mkv"}}
    ]}
    """#

    /// What add-ons send instead of results: a message dressed as a stream.
    static let cometNotice = #"""
    {"streams":[{"description":"Non-debrid searches disabled on ElfHosted, use a debrid provider or another instance","name":"[⛔️] Comet","url":"https://comet.example/playback/abc"}]}
    """#

    static let rejectedKey = #"""
    {"streams":[{"name":"[RD] Torrentio\nInvalid RD api key","title":"Invalid Real-Debrid API key. Check your configuration.","url":"https://torrentio.strem.fun/videos/failed_access_v2.mp4"}]}
    """#

    /// Kinds Bluebox can't play, a malformed entry, and a base32 info hash.
    static let mixedKinds = #"""
    {"streams":[
    {"ytId":"eRsGyueVLvQ","name":"Trailer"},
    {"externalUrl":"https://example.com/watch","name":"Open in browser"},
    {"nzbUrl":"https://example.com/file.nzb","name":"Usenet"},
    {"url":"https://cdn.example.com/needs-headers.mp4","name":"Proxy","behaviorHints":{"notWebReady":true,"proxyHeaders":{"request":{"Referer":"https://x"}}}},
    42,
    {"infoHash":"MFRGGZDFMZTWQ2LKNNWG23TPOBYXE43U","fileIdx":"2","name":"Base32 1080p","title":"Some.Film.2019.1080p.WEB-DL.x264-GRP\n👤 7 💾 1.4 GB"},
    {"url":"https://cdn.example.com/sintel-1080p.mp4","name":"Direct 1080p","description":"Sintel 1080p MP4","behaviorHints":{"filename":"sintel-1080p.mp4","videoSize":"642000000"}}
    ]}
    """#

    static let torrentioManifest = #"""
    {"id":"com.stremio.torrentio.addon","version":"0.0.15","name":"Torrentio","description":"Provides torrent streams.","catalogs":[],"resources":[{"name":"stream","types":["movie","series","anime"],"idPrefixes":["tt","kitsu"]}],"types":["movie","series","anime","other"],"behaviorHints":{"configurable":true,"configurationRequired":false}}
    """#

    /// Resources as plain strings: the manifest's own types and prefixes apply.
    static let stringResourceManifest = #"""
    {"id":"org.example.streams","version":"1.0.0","name":"Example Streams","description":"","resources":["catalog","stream"],"types":["movie"],"idPrefixes":["tt"],"catalogs":[]}
    """#

    static let catalogOnlyManifest = #"""
    {"id":"org.example.catalog","version":"1.0.0","name":"Just Lists","description":"","resources":["catalog","meta"],"types":["movie","series"],"catalogs":[{"type":"movie","id":"top","name":"Top"}]}
    """#

    /// Only TV channels: nothing Bluebox can stream or show.
    static let channelsOnlyManifest = #"""
    {"id":"org.example.tv","version":"1.0.0","name":"Just Channels","description":"","resources":["catalog","meta"],"types":["tv"],"catalogs":[{"type":"tv","id":"live","name":"Live"}]}
    """#

    static let animeOnlyManifest = #"""
    {"id":"org.example.anime","version":"1.0.0","name":"Anime Only","description":"","resources":[{"name":"stream","types":["series"],"idPrefixes":["kitsu:"]}],"types":["series"],"catalogs":[]}
    """#

    static let needsConfigManifest = #"""
    {"id":"org.example.debrid","version":"2.1.0","name":"Needs Setup","description":"","resources":["stream"],"types":["movie","series"],"catalogs":[],"behaviorHints":{"configurable":true,"configurationRequired":true}}
    """#
}
