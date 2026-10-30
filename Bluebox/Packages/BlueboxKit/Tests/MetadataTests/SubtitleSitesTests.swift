import Compression
import Domain
import Foundation
@testable import Metadata
import Testing

@Suite struct SubtitleSearchMergeTests {
    func sub(_ site: SubtitleSite, _ release: String, _ lang: String = "en", downloads: Int = 0, mt: Bool = false) -> OnlineSubtitle {
        OnlineSubtitle(site: site, source: .url(URL(string: "https://x.test/\(site.rawValue)/\(release)/\(lang)")!, headers: [:]),
                       language: lang, release: release, downloadCount: downloads, machineTranslated: mt)
    }

    @Test func bestMatchForTheReleaseFirst() {
        let playing = "Dexter.Resurrection.S01E01.1080p.WEB.h264-ETHEL"
        let merged = SubtitleSearchMerge.merge([
            [sub(.subdl, "Dexter Resurrection 1x01 WEB", downloads: 50_000)],
            [sub(.openSubtitles, "Dexter.Resurrection.S01E01.1080p.WEB.h264-ETHEL", downloads: 10)],
            [sub(.podnapisi, "Dexter.Resurrection.S01E01.720p.HDTV-OTHER", downloads: 900)],
        ], release: playing, languages: ["en"])
        #expect(merged.first?.site == .openSubtitles)
        #expect(merged.count == 3)
    }

    @Test func languagesInOrderThenDownloadsMachineTranslationsLast() {
        let merged = SubtitleSearchMerge.merge([
            [sub(.openSubtitles, "A", "fr", downloads: 9000), sub(.openSubtitles, "B", "en", downloads: 10)],
            [sub(.subdl, "C", "en", downloads: 500), sub(.subdl, "D", "en", downloads: 99_999, mt: true)],
        ], release: nil, languages: ["en", "fr"])
        #expect(merged.map(\.release) == ["C", "B", "A", "D"])
    }

    @Test func dropsTheSameResultTwice() {
        let a = sub(.subdl, "A")
        #expect(SubtitleSearchMerge.merge([[a], [a]], release: nil, languages: []).count == 1)
    }

    @Test func matchScores() {
        let playing = "Movie.2019.1080p.BluRay.x264-GROUP"
        #expect(SubtitleSearchMerge.matchScore(playing, playing) == 100)
        #expect(SubtitleSearchMerge.matchScore("Movie.2019.720p.BluRay.x264-GROUP.srt", playing) >= SubtitleSearchMerge.exactThreshold)
        #expect(SubtitleSearchMerge.matchScore("Movie 2019 WEB-DL", playing) < SubtitleSearchMerge.exactThreshold)
    }
}

/// A ZIP with one deflated and one stored file.
func makeZip(_ files: [(String, Data, Bool)]) -> Data {
    var out = Data(), central = Data()
    func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
    func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
    for (name, data, deflate) in files {
        var body = data
        if deflate {
            var dst = [UInt8](repeating: 0, count: data.count + 64)
            let n = data.withUnsafeBytes { src in
                compression_encode_buffer(&dst, dst.count, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
            body = Data(dst.prefix(n))
        }
        let offset = out.count
        let nameData = Data(name.utf8)
        let method = deflate ? 8 : 0
        let local: [Data] = [le32(0x0403_4B50), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                             le32(body.count), le32(data.count), le16(nameData.count), le16(0), nameData, body]
        local.forEach { out.append($0) }
        let entry: [Data] = [le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                             le32(body.count), le32(data.count), le16(nameData.count), le16(0), le16(0), le16(0), le16(0), le32(0),
                             le32(offset), nameData]
        entry.forEach { central.append($0) }
    }
    let start = out.count
    out += central
    let end: [Data] = [le32(0x0605_4B50), le16(0), le16(0), le16(files.count), le16(files.count), le32(central.count), le32(start), le16(0)]
    end.forEach { out.append($0) }
    return out
}

@Suite struct ZipAndFetchTests {
    let srt = Data(String(repeating: "1\n00:00:01,000 --> 00:00:02,000\nHello there\n\n", count: 20).utf8)

    @Test func readsStoredAndDeflatedEntries() {
        let zip = makeZip([("readme.txt", Data("hi".utf8), false), ("Movie.en.srt", srt, true)])
        let entries = ZipArchive.entries(zip)
        #expect(entries.map(\.path) == ["readme.txt", "Movie.en.srt"])
        #expect(entries.last?.data == srt)
        #expect(ZipArchive.isZip(zip) && !ZipArchive.isZip(srt))
    }

    @Test func picksTheEpisodesFileFromAPack() throws {
        let other = Data(srt.prefix(200))
        let zip = makeZip([("Show.S01E01.srt", srt, true), ("Show.S01E02.srt", other, false), ("info.nfo", Data("x".utf8), false)])
        let file = try #require(OnlineSubtitleFile.extract(zip, episode: (1, 2)))
        #expect(file.data == other && file.format == "srt")
        // A plain file passes through.
        #expect(OnlineSubtitleFile.extract(srt, episode: nil)?.data == srt)
    }
}

final class FakeSubtitleSites: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { urls.append(r.url!) }
        let body: Data
        switch r.url!.host() {
        case "api.subdl.com":
            body = try! JSONSerialization.data(withJSONObject: ["status": true, "subtitles": [
                ["release_name": "Movie.2019.1080p.WEB-GRP", "language": "EN", "url": "/subtitle/1-2.zip", "hi": true],
                ["name": "SUBDL::x.zip", "language": "FR", "url": "/subtitle/3-4.zip"],
            ]])
        case "www.podnapisi.net":
            body = Data("""
            <results><pagination><current>1</current><count>1</count></pagination>
            <subtitle><pid>AbC1</pid><title>Movie</title><year>2019</year><language>en</language><flags>nh</flags>
            <release>Movie.2019.BluRay-X Movie.2019.WEB-Y</release><downloads>42</downloads></subtitle>
            </results>
            """.utf8)
        default: body = Data()
        }
        return (body, HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct SubtitleSiteClientTests {
    @Test func subdl() async throws {
        let http = FakeSubtitleSites()
        let found = try await SubdlService(apiKey: "k", http: http).search(imdbID: "tt1", episode: (1, 3), languages: ["en", "fr"])
        #expect(found.count == 2)
        #expect(found[0].release == "Movie.2019.1080p.WEB-GRP" && found[0].language == "en" && found[0].hearingImpaired)
        guard case .url(let url, _) = found[0].source else { Issue.record("not a URL"); return }
        #expect(url.absoluteString == "https://dl.subdl.com/subtitle/1-2.zip")
        let q = URLComponents(url: http.urls[0], resolvingAgainstBaseURL: false)!.queryItems!
        #expect(q.contains(URLQueryItem(name: "languages", value: "EN,FR")))
        #expect(q.contains(URLQueryItem(name: "season_number", value: "1")) && q.contains(URLQueryItem(name: "type", value: "tv")))
    }

    @Test func podnapisi() async throws {
        let found = try await PodnapisiService(http: FakeSubtitleSites()).search(title: "Movie", year: 2019, episode: nil, languages: ["en"])
        #expect(found.count == 1)
        #expect(found[0].release == "Movie.2019.BluRay-X" && found[0].downloadCount == 42 && found[0].hearingImpaired)
        guard case .url(let url, _) = found[0].source else { Issue.record("not a URL"); return }
        #expect(url.absoluteString == "https://www.podnapisi.net/subtitles/AbC1/download?container=zip")
    }
}
