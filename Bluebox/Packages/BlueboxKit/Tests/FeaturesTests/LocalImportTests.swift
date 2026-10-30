import Domain
import Foundation
@testable import Features
@testable import MediaSources
import Testing
import UniformTypeIdentifiers

/// Adding folders and opening several files at once, as Settings › Sources,
/// File › Open… and a drop on the window do.
@Suite @MainActor struct LocalImportTests {
    private func makeFolder(_ files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bluebox-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            let url = dir.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return dir
    }

    @Test func addingAFolderRegistersItAndCountsItsVideos() async throws {
        let dir = try makeFolder(["Big.Buck.Bunny.2008.mkv", "Show/Season 1/Harbor.Lights.S01E01.MKV", "Clip.wmv", "Old.mpg",
                                  "Holiday Sampler.mp4", "readme.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppModel.demo(seed: false)
        let count = try await app.addLocalFolder(dir)
        #expect(count == 5)
        let config = try #require(app.sourceConfigurations.first { $0.kind == .localFolder })
        #expect(config.settings["path"] == dir.standardizedFileURL.path)
        let source = try #require(await app.registry.source(config.id) as? LocalFolderSource)
        #expect(try await source.catalog().count == 5)
    }

    @Test func theSameFolderTwiceIsRefused() async throws {
        let dir = try makeFolder(["A.mkv"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppModel.demo(seed: false)
        try await app.addLocalFolder(dir)
        await #expect(throws: LocalFolderAddError.alreadyAdded(dir.lastPathComponent)) { try await app.addLocalFolder(dir) }
        #expect(app.sourceConfigurations.filter { $0.kind == .localFolder }.count == 1)
    }

    @Test func aFolderThatCantBeReadIsNotAdded() async throws {
        let gone = FileManager.default.temporaryDirectory.appending(path: "bluebox-gone-\(UUID().uuidString)")
        let app = AppModel.demo(seed: false)
        await #expect(throws: LocalFolderError.self) { try await app.addLocalFolder(gone) }
        #expect(!app.sourceConfigurations.contains { $0.kind == .localFolder })
    }

    @Test func droppingAFolderSaysHowManyVideosItHasOrThatItIsEmpty() async throws {
        let full = try makeFolder(["A.mkv", "B.mp4"])
        let empty = try makeFolder(["notes.txt"])
        defer { try? FileManager.default.removeItem(at: full); try? FileManager.default.removeItem(at: empty) }
        let app = AppModel.demo(seed: false)
        await app.addFolderReporting(full)
        #expect(app.toast?.message?.contains("2 videos") == true)
        await app.addFolderReporting(empty)
        #expect(app.toast?.message?.contains("no videos") == true)
        await app.addFolderReporting(full)
        #expect(app.alert?.message.contains("already") == true)
    }

    @Test func droppingSeveralFoldersAddsEveryOne() async throws {
        let a = try makeFolder(["A.mkv"]), b = try makeFolder(["B.mkv"])
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let app = AppModel.demo(seed: false)
        await app.openExternal([.folder(a), .folder(b)])
        #expect(app.sourceConfigurations.filter { $0.kind == .localFolder }.count == 2)
    }

    @Test func droppingNothingBlueboxOpensSaysSo() async {
        let app = AppModel.demo(seed: false)
        await app.openExternal([], ignored: ["notes.txt"])
        #expect(app.alert?.title.contains("notes.txt") == true)
    }

    @Test func fixMatchMovesAWholeSeasonAndKeepsEpisodeNumbers() async throws {
        let dir = try makeFolder(["The.Office.S01E01.mkv", "The.Office.S01E02.mkv", "The.Office.2005.mkv"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppModel.demo(seed: false)
        try await app.addLocalFolder(dir)
        let id = try #require(app.sourceConfigurations.first { $0.kind == .localFolder }?.id)
        let source = try #require(await app.registry.source(id) as? LocalFolderSource)
        let first = try #require(try await source.catalog().first { $0.displayName == "The.Office.S01E01" })
        let request = await app.fixMatchRequest(for: first)
        // The other episode is a sibling; the film of the same name isn't.
        #expect(request.siblings.map(\.variant.displayName) == ["The.Office.S01E02"])
        let us = Title(key: .series(tmdbID: 2316), kind: .series, name: "The Office")
        #expect(app.applyMatch(us, to: [request.file] + request.siblings) == 2)
        let keys = Set(try await source.catalog().compactMap(\.mediaKey))
        #expect(keys.isSuperset(of: [.episode(seriesID: 2316, season: 1, episode: 1), .episode(seriesID: 2316, season: 1, episode: 2)]))
        app.resetMatch([first])
        #expect(app.matchOverride(for: first) == nil)
    }

    @Test func theOpenPickerAcceptsEveryScannedVideoType() {
        let types = OpenFilesImporter.contentTypes
        #expect(types.contains(.folder))
        #expect(types.contains { $0.preferredFilenameExtension == "mkv" || $0.conforms(to: .movie) })
        #expect(ExternalItem.classify(URL(fileURLWithPath: "/tmp/x.wmv"), isDirectory: false) == .videoFile(URL(fileURLWithPath: "/tmp/x.wmv")))
    }
}
