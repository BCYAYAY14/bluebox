import Domain
import Foundation
@testable import MediaSources
import Testing

/// A fresh folder of empty "videos" under the temporary directory.
private func makeFolder(_ files: [String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "bluebox-scan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in files {
        let url = dir.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
    return dir
}

private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

@Suite struct LocalFolderScanTests {
    @Test func picksUpTheWiderSetOfVideoTypesInAnyCase() throws {
        let dir = try makeFolder(["A.mkv", "B.WMV", "C.mpg", "D.flv", "E.mts", "F.vob", "notes.txt", "cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(names(try LocalFolderSource.videoFiles(in: dir)) == ["A.mkv", "B.WMV", "C.mpg", "D.flv", "E.mts", "F.vob"])
    }

    @Test func dropsSamplesButNotTitlesThatContainTheWord() throws {
        let dir = try makeFolder(["The Sampler.mp4","Movie.2010.mkv", "Movie.2010-sample.mkv",
                                  "sample.mkv", "Other.Sample.mkv", "Release/Sample/clip.mkv", "Release/Film.mkv"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = names(try LocalFolderSource.videoFiles(in: dir))
        #expect(found.contains("The Sampler.mp4"))
        #expect(found.contains("Movie.2010.mkv"))
        #expect(found.contains("Film.mkv"))
        #expect(!found.contains("Movie.2010-sample.mkv"))
        #expect(!found.contains("sample.mkv"))
        #expect(!found.contains("Other.Sample.mkv"))
        #expect(!found.contains("clip.mkv"))
    }

    @Test func scansSubfoldersAndSymlinkedFolders() throws {
        let dir = try makeFolder(["Show/Season 1/Show.S01E01.mkv"])
        let elsewhere = try makeFolder(["Linked.Film.2001.mkv"])
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "More"), withDestinationURL: elsewhere)
        #expect(Set(names(try LocalFolderSource.videoFiles(in: dir))) == ["Show.S01E01.mkv", "Linked.Film.2001.mkv"])
    }

    @Test func aMissingFolderOrAFileIsAnErrorNotAnEmptyList() throws {
        let gone = FileManager.default.temporaryDirectory.appending(path: "bluebox-gone-\(UUID().uuidString)")
        #expect(throws: LocalFolderError.missing("Films")) { try LocalFolderSource.videoFiles(in: gone, name: "Films") }
        let dir = try makeFolder(["A.mkv"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: LocalFolderError.notAFolder("A.mkv")) { try LocalFolderSource.videoFiles(in: dir.appending(path: "A.mkv")) }
    }

    @Test func anUnreadableFolderIsNotPermittedRatherThanEmpty() throws {
        let dir = try makeFolder(["A.mkv"])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        #expect(throws: LocalFolderError.notPermitted("Films")) { try LocalFolderSource.videoFiles(in: dir, name: "Films") }
    }

    @Test func aBookmarkThatNoLongerResolvesKeepsTheSourceWithAReason() async throws {
        let config = SourceConfiguration(id: SourceID("local-x"), kind: .localFolder, name: "Films",
                                         settings: ["bookmark": Data("not a bookmark".utf8).base64EncodedString(), "path": "/nowhere/Films"])
        let source = try LocalFolderSource.fromConfiguration(config, matcher: nil)
        #expect(source.rootURL.path == "/nowhere/Films")
        let health = await source.testConnection()
        #expect(!health.ok)
        #expect(health.message.contains("Films"))
        await #expect(throws: LocalFolderError.self) { try await source.catalog() }
    }

    @Test func eachTitleIsLookedUpOncePerScan() async throws {
        let dir = try makeFolder(["Harbor.Lights.S01E01.mkv", "Harbor.Lights.S01E02.mkv", "Harbor.Lights.S02E01.mkv",
                                  "Big.Buck.Bunny.2008.mkv", "Big.Buck.Bunny.2008.Extended.mkv"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = Switch()
        let source = LocalFolderSource(id: SourceID("local"), name: "Mixed", folderURL: dir, usesSecurityScope: false) { parsed in
            calls.called()
            switch parsed.kind {
            case .movie: return .movie(tmdbID: 10378)
            case .episode(let s, let e): return .episode(seriesID: 77, season: s, episode: e)
            }
        }
        let keys = Set(try await source.catalog().compactMap(\.mediaKey))
        #expect(calls.calls == 2)
        #expect(keys == [.movie(tmdbID: 10378), .episode(seriesID: 77, season: 1, episode: 1),
                         .episode(seriesID: 77, season: 1, episode: 2), .episode(seriesID: 77, season: 2, episode: 1)])
    }

    @Test func fixMatchOverridesWinAndResetGoesBackToTheAutomaticMatch() async throws {
        let dir = try makeFolder(["The.Office.S01E01.mkv"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let overrides = MatchOverrides()
        let source = LocalFolderSource(id: SourceID("local"), name: "TV", folderURL: dir, usesSecurityScope: false,
                                       matcher: { _ in .episode(seriesID: 2996, season: 1, episode: 1) }, overrides: overrides)
        let file = try #require(try await source.catalog().first)
        #expect(file.mediaKey == .episode(seriesID: 2996, season: 1, episode: 1))
        #expect(await source.parsedName(of: file.id)?.title == "The Office")

        overrides.set(.title(.episode(seriesID: 2316, season: 1, episode: 1)), source: SourceID("local"), variant: file.id)
        #expect(try await source.catalog().first?.mediaKey == .episode(seriesID: 2316, season: 1, episode: 1))
        #expect(try await source.variants(for: .episode(seriesID: 2316, season: 1, episode: 1)).count == 1)

        overrides.set(.unmatched, source: SourceID("local"), variant: file.id)
        #expect(try await source.catalog().first?.mediaKey == nil)

        overrides.set(nil, source: SourceID("local"), variant: file.id)
        #expect(try await source.catalog().first?.mediaKey == .episode(seriesID: 2996, season: 1, episode: 1))
    }
}
