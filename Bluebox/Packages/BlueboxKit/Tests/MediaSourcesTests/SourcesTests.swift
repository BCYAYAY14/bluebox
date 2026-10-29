import Domain
import Foundation
@testable import MediaSources
import Testing

@Suite struct MediaNameParserTests {
    @Test(arguments: [
        ("The.Matrix.1999.1080p.BluRay.x264.mkv", "The Matrix", 1999, "1080p", "mkv"),
        ("Tears of Steel (2012).mov", "Tears of Steel", 2012, nil, "mov"),
        ("Blade_Runner_2049_2017_2160p.mp4", "Blade Runner 2049", 2017, "4K", "mp4"),
        ("Amélie [2001] 720p.m4v", "Amélie", 2001, "720p", "m4v"),
    ] as [(String, String, Int?, String?, String)])
    func movies(_ file: String, _ title: String, _ year: Int?, _ res: String?, _ ext: String) {
        let p = MediaNameParser.parse(filename: file)
        #expect(p.title == title)
        #expect(p.year == year)
        #expect(p.kind == .movie)
        #expect(p.resolution == res)
        #expect(p.container == ext)
    }

    @Test func movieWithoutYearStopsAtNoise() {
        let p = MediaNameParser.parse(filename: "Big Buck Bunny 1080p x264.mp4")
        #expect(p.title == "Big Buck Bunny")
        #expect(p.year == nil)
    }

    @Test(arguments: [
        ("Severance.S01E03.In.Perpetuity.1080p.mkv", "Severance", 1, 3),
        ("Show Name - 2x05 - Title.mp4", "Show Name", 2, 5),
        ("the_office_s09e23.mp4", "the office", 9, 23),
    ] as [(String, String, Int, Int)])
    func episodes(_ file: String, _ title: String, _ s: Int, _ e: Int) {
        let p = MediaNameParser.parse(filename: file)
        #expect(p.title == title)
        #expect(p.kind == .episode(season: s, episode: e))
    }

    @Test func normalization() {
        #expect(MediaNameParser.normalized("Amélie & Co.") == MediaNameParser.normalized("amelie and co"))
    }
}

@Suite struct DirectURLSourceTests {
    @Test func validation() throws {
        try DirectURLSource.validate(URL(string: "https://cdn.example.com/a.mp4")!)
        try DirectURLSource.validate(URL(string: "http://192.168.1.20:8096/a.mp4")!)
        try DirectURLSource.validate(URL(string: "http://nas.local/a.mp4")!)
        #expect(throws: SourceError.self) { try DirectURLSource.validate(URL(string: "http://example.com/a.mp4")!) }
        #expect(throws: SourceError.self) { try DirectURLSource.validate(URL(string: "ftp://example.com/a.mp4")!) }
        #expect(throws: SourceError.self) { try DirectURLSource.validate(URL(string: "file:///etc/passwd")!) }
        #expect(!DirectURLSource.isLocalNetworkHost("172.32.0.1"))
        #expect(DirectURLSource.isLocalNetworkHost("172.16.0.1"))
    }

    @Test func addMatchResolve() async throws {
        let s = DirectURLSource()
        let key = MediaKey.movie(tmdbID: 1)
        try await s.add(.init(url: URL(string: "https://x.example/movie.mp4")!, title: "M", mediaKey: key))
        try await s.add(.init(url: URL(string: "https://x.example/live.m3u8")!, title: "Live"))
        let vs = try await s.variants(for: key)
        #expect(vs.count == 1)
        #expect(vs[0].isDownloadable)
        let all = try await s.catalog()
        #expect(all.first { $0.container == "m3u8" }?.isDownloadable == false)
        let r = try await s.resolve(vs[0])
        #expect(r.url.lastPathComponent == "movie.mp4")
        await s.remove(URL(string: "https://x.example/movie.mp4")!)
        await #expect(throws: SourceError.notFound) { try await s.resolve(vs[0]) }
    }
}

@Suite struct LocalFolderSourceTests {
    func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bluebox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "Sub"), withIntermediateDirectories: true)
        for name in ["Tears.of.Steel.2012.720p.mov", "Sub/Harbor.Lights.S01E02.mkv", "Sub/sample.mkv",
                     "notes.txt", "Tears.of.Steel.2012.720p.en.srt", "Tears.of.Steel.2012.720p.srt", ".hidden.mp4"] {
            try Data("x".utf8).write(to: dir.appending(path: name))
        }
        return dir
    }

    @Test func scansMatchesAndFindsSidecars() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = LocalFolderSource(id: SourceID("local"), name: "Movies", folderURL: dir, usesSecurityScope: false) { parsed in
            switch parsed.kind {
            case .movie where parsed.title == "Tears of Steel": .movie(tmdbID: 133701)
            case .episode(let s, let e) where parsed.title == "Harbor Lights": .episode(seriesID: 9_100_001, season: s, episode: e)
            default: nil
            }
        }
        let all = try await source.catalog()
        #expect(all.count == 2)  // excludes sample, hidden, non-video
        #expect(all.allSatisfy { $0.location == .localFile && !$0.isDownloadable })

        let tos = try await source.variants(for: .movie(tmdbID: 133701))
        #expect(tos.count == 1)
        #expect(tos[0].resolution == "720p")
        let r = try await source.resolve(tos[0])
        #expect(r.externalSubtitles.count == 2)
        #expect(r.externalSubtitles.contains { $0.languageCode == "en" })

        #expect(try await source.variants(for: .episode(seriesID: 9_100_001, season: 1, episode: 2)).count == 1)
        #expect(await source.testConnection().ok)
    }

    @Test func deletedFileIsNotFound() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = LocalFolderSource(id: SourceID("local"), name: "Movies", folderURL: dir, usesSecurityScope: false)
        let v = try #require(try await source.catalog().first { $0.container == "mov" })
        try FileManager.default.removeItem(at: dir.appending(path: "Tears.of.Steel.2012.720p.mov"))
        await #expect(throws: SourceError.notFound) { try await source.resolve(v) }
    }

    @Test func missingFolderFailsHealthCheck() async {
        let source = LocalFolderSource(id: SourceID("x"), name: "Gone", folderURL: URL(fileURLWithPath: "/nonexistent-\(UUID())"), usesSecurityScope: false)
        #expect(await !source.testConnection().ok)
    }
}

@Suite struct PublicCatalogTests {
    @Test func entriesMapToCatalogKeys() async throws {
        let s = PublicCatalogSource()
        let v = try await s.variants(for: .movie(tmdbID: 133701))
        #expect(v.count == 1)
        let r = try await s.resolve(v[0])
        #expect(r.url.scheme == "https")
        #expect(r.externalSubtitles.contains { $0.languageCode == "en" })
        #expect(Set(PublicCatalogSource.defaultEntries.flatMap(\.subtitles).map(\.id)).count
                == PublicCatalogSource.defaultEntries.flatMap(\.subtitles).count)
    }
}
