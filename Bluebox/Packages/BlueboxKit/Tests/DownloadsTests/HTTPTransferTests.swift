import Domain
@testable import Downloads
import Foundation
import Testing

/// Answers with headers and some bytes, then never finishes: a transfer in progress.
final class HangingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "1000000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(count: 1000))
    }
    override func stopLoading() {}
}

/// Every HTTP task the manager launches: (id, from resume data, cellular allowed).
private final class Launches: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [(String, Bool, Bool)] = []
    var all: [(String, Bool, Bool)] { lock.withLock { _all } }
    func add(_ id: String, _ resumed: Bool, _ cellular: Bool) { lock.withLock { _all.append((id, resumed, cellular)) } }
}

@Suite(.serialized) struct HTTPTransferTests {
    func resource(_ path: String) -> PlaybackResource {
        let v = MediaVariant(id: path, sourceID: SourceID("src"), mediaKey: .movie(tmdbID: 1), displayName: "Movie",
                             container: "mp4", location: .remote, isDownloadable: true)
        return PlaybackResource(variant: v, url: URL(string: "https://media.test\(path)")!)
    }

    func manager(_ dir: URL = DownloadsTests.tempDir(), protocolClass: AnyClass = HangingProtocol.self,
                 settings: DownloadSettings = DownloadSettings(wifiOnly: true), startsQueue: Bool = true) -> DownloadManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        return DownloadManager(directory: dir, configuration: config, settings: settings, startsQueue: startsQueue,
                               monitorsNetwork: false)
    }

    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    /// Wi‑Fi Only is enforced by the session a transfer runs in, so changing
    /// it moves running transfers to the matching session.
    @Test func changingWifiOnlyMovesRunningTransfers() async throws {
        let launches = Launches()
        let m = manager()
        m.onHTTPLaunch = { launches.add($0, $1, $2) }
        let res = resource("/big.mp4")
        m.resolveResource = { _ in res }
        let r = try m.start(res, key: .movie(tmdbID: 1), title: "Big")
        try await until { launches.all.count == 1 }
        #expect(launches.all.last?.2 == false)  // Wi‑Fi Only: no cellular

        m.update(settings: DownloadSettings(wifiOnly: false))
        try await until { launches.all.count == 2 }
        #expect(launches.all.last?.0 == r.id)
        #expect(launches.all.last?.2 == true)
        #expect(m.record(id: r.id)?.state == .downloading)

        m.update(settings: DownloadSettings(wifiOnly: false))  // no change: nothing restarts
        try await Task.sleep(for: .milliseconds(100))
        #expect(launches.all.count == 2)
        m.delete(r.id)
    }

    /// Pause then a quick resume: the resume waits for the paused transfer's
    /// resume data instead of starting from zero.
    @Test func quickResumeWaitsForResumeData() async throws {
        let launches = Launches()
        let m = manager(startsQueue: false)
        m.onHTTPLaunch = { launches.add($0, $1, $2) }
        let res = resource("/movie.mp4")
        m.resolveResource = { _ in res }
        let r = try m.start(res, key: .movie(tmdbID: 1), title: "Movie")
        m.pause(r.id)
        m.expectResumeData(r.id)  // as if the paused transfer's data is still being produced
        m.activate()
        m.resume(r.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(launches.all.isEmpty)  // waiting, not restarting from zero

        m.resumeDataArrived(r.id, Self.resumeData)
        try await until { !launches.all.isEmpty }
        #expect(launches.all.first?.1 == true)  // continued from the resume data
        m.delete(r.id)
        #expect(!FileManager.default.fileExists(atPath: m.directory.appending(path: ".resume-\(DownloadManager.safeName(r.id))").path))
    }

    static let resumeData = try! PropertyListSerialization.data(fromPropertyList: [
        "NSURLSessionDownloadURL": "https://media.test/movie.mp4", "NSURLSessionResumeBytesReceived": 1000,
        "NSURLSessionResumeInfoVersion": 2,
    ], format: .binary, options: 0)

    /// A corrupt resume file made URLSession throw an Objective-C exception
    /// (a crash); now the download starts over instead.
    @Test func corruptResumeDataStartsOver() async throws {
        let launches = Launches()
        let m = manager(startsQueue: false)
        m.onHTTPLaunch = { launches.add($0, $1, $2) }
        let res = resource("/corrupt.mp4")
        m.resolveResource = { _ in res }
        let r = try m.start(res, key: .movie(tmdbID: 1), title: "Corrupt")
        m.pause(r.id)
        try Data("not a plist".utf8).write(to: m.directory.appending(path: ".resume-\(DownloadManager.safeName(r.id))"))
        #expect(!DownloadManager.isUsableResumeData(Data("not a plist".utf8)))
        #expect(DownloadManager.isUsableResumeData(Self.resumeData))
        m.activate()
        m.resume(r.id)
        try await until { !launches.all.isEmpty }
        #expect(launches.all.first?.1 == false)
        m.delete(r.id)
    }

    /// A transfer from before a relaunch that finishes before the sessions
    /// report their tasks keeps its file instead of being deleted and fetched again.
    @Test func finishedTransferFromBeforeRelaunchIsKept() async throws {
        let m = manager(startsQueue: false)
        let r = try m.start(resource("/done.mp4"), key: .movie(tmdbID: 1), title: "Done")
        #expect(m.record(id: r.id)?.state == .queued)

        let finished = FileManager.default.temporaryDirectory.appending(path: "dl-done-\(UUID().uuidString)")
        try Data(count: 4_096).write(to: finished)
        let task = URLSession(configuration: .ephemeral).downloadTask(with: URL(string: "https://media.test/done.mp4")!)
        task.taskDescription = r.id
        m.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: finished)

        let done = try #require(m.record(id: r.id))
        #expect(done.state == .completed)
        #expect(done.receivedBytes == 4_096)
        #expect(FileManager.default.fileExists(atPath: try #require(m.fileURL(done)).path))

        // A transfer of something paused or deleted is still thrown away.
        let other = try m.start(resource("/paused.mp4"), key: .movie(tmdbID: 2), title: "Paused")
        m.pause(other.id)
        let stray = FileManager.default.temporaryDirectory.appending(path: "dl-stray-\(UUID().uuidString)")
        try Data(count: 10).write(to: stray)
        let task2 = URLSession(configuration: .ephemeral).downloadTask(with: URL(string: "https://media.test/paused.mp4")!)
        task2.taskDescription = other.id
        m.urlSession(URLSession.shared, downloadTask: task2, didFinishDownloadingTo: stray)
        #expect(m.record(id: other.id)?.state == .paused)
    }
}
