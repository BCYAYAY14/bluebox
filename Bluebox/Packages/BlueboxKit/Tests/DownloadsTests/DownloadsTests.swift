import Domain
@testable import Downloads
import Foundation
import Testing

/// Serves fixed bodies for download tasks in an ephemeral session.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String: (Int, Data)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.bodies[request.url!.path] ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct DownloadsTests {
    func manager(_ dir: URL = tempDir()) -> DownloadManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return DownloadManager(directory: dir, configuration: config, subtitleFetch: { url in
            StubProtocol.bodies[url.path]!.1
        })
    }

    static func tempDir() -> URL { FileManager.default.temporaryDirectory.appending(path: "dl-\(UUID().uuidString)") }
    func tempDir() -> URL { Self.tempDir() }

    func resource(_ path: String, downloadable: Bool = true, container: String = "mp4", subs: [ExternalSubtitle] = []) -> PlaybackResource {
        let v = MediaVariant(id: path, sourceID: SourceID("src"), mediaKey: .movie(tmdbID: 1), displayName: "Movie",
                             container: container, location: .remote, isDownloadable: downloadable)
        return PlaybackResource(variant: v, url: URL(string: "https://media.test\(path)")!, externalSubtitles: subs)
    }

    func waitFor(_ m: DownloadManager, _ id: String, _ done: (DownloadRecord) -> Bool) async throws -> DownloadRecord {
        for _ in 0..<200 {
            if let r = m.all().first(where: { $0.id == id }), done(r) { return r }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    @Test func downloadsFileAndSubtitlesThenPlaysFromDownloadsSource() async throws {
        let body = Data((0..<50_000).map { UInt8($0 % 251) })
        StubProtocol.bodies = ["/movie.mp4": (200, body), "/movie.en.vtt": (200, Data("WEBVTT\n".utf8))]
        let m = manager()
        let sub = ExternalSubtitle(id: "s", url: URL(string: "https://media.test/movie.en.vtt")!, languageCode: "en", label: "English", format: "vtt")
        let r0 = try m.start(resource("/movie.mp4", subs: [sub]), key: .movie(tmdbID: 1), title: "Movie")
        let r = try await waitFor(m, r0.id) { $0.state == .completed && !$0.subtitleFiles.isEmpty }
        #expect(try Data(contentsOf: try #require(m.fileURL(r))) == body)
        #expect(r.receivedBytes == 50_000)

        let source = DownloadsSource(manager: m)
        let variants = try await source.variants(for: .movie(tmdbID: 1))
        #expect(variants.count == 1 && variants[0].location == .downloaded)
        let resolved = try await source.resolve(variants[0])
        #expect(resolved.url.isFileURL)
        #expect(resolved.externalSubtitles.first?.languageCode == "en")
        #expect(try String(contentsOf: resolved.externalSubtitles[0].url, encoding: .utf8) == "WEBVTT\n")

        // Survives a restart.
        let reopened = manager(m.directory)
        #expect(reopened.all().first?.state == .completed)

        m.delete(r.id)
        #expect(m.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: m.fileURL(r)!.path))
        #expect(try await source.variants(for: .movie(tmdbID: 1)).isEmpty)
    }

    @Test func refusesStreamsAndDuplicates() async throws {
        StubProtocol.bodies = ["/a.mp4": (200, Data(count: 10))]
        let m = manager()
        #expect(throws: DownloadError.notDownloadable) { try m.start(resource("/x.m3u8", downloadable: false, container: "m3u8"), key: nil, title: "x") }
        let r = try m.start(resource("/a.mp4"), key: nil, title: "a")
        _ = try await waitFor(m, r.id) { $0.state == .completed }
        #expect(throws: DownloadError.alreadyDownloaded) { try m.start(resource("/a.mp4"), key: nil, title: "a") }
    }

    @Test func serverErrorsFailTheDownload() async throws {
        StubProtocol.bodies = ["/gone.mp4": (404, Data("not found".utf8))]
        let m = manager()
        let r = try m.start(resource("/gone.mp4"), key: nil, title: "gone")
        let done = try await waitFor(m, r.id) { if case .failed = $0.state { true } else { false } }
        #expect(done.fileName == nil)
    }

    @Test func chooserPrefersDownloadedCopies() {
        let remote = MediaVariant(id: "r", sourceID: SourceID("jf"), mediaKey: nil, displayName: "r", container: "mp4", location: .remote)
        let saved = MediaVariant(id: "d", sourceID: SourceID("downloads"), mediaKey: nil, displayName: "d", container: "mp4", location: .downloaded)
        let last = LastPlayedSource(sourceID: SourceID("jf"), variantID: "r", playedAt: .now)
        #expect(VariantChooser.choose(from: [remote, saved], item: last, canAttempt: { _ in true })?.id == "d")
    }
}
