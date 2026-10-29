import Domain
import Foundation
import Metadata

/// Loads JSON fixtures bundled with this module.
public enum Fixtures {
    public static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing fixture \(name).json")
        }
        return data
    }

    /// Self-generated 12 s H.264/AAC MP4 (320×180, test pattern) with English and
    /// Spanish audio tracks and an English mov_text subtitle. Created with
    /// ffmpeg's lavfi sources; no third-party content, freely redistributable.
    public static var testVideoURL: URL {
        Bundle.module.url(forResource: "bluebox-test", withExtension: "mp4", subdirectory: "Fixtures/media")!
    }

    /// SRT matching the test video's embedded subtitle (cues at 1–3 s and 5–7 s).
    public static var testSubtitleURL: URL {
        Bundle.module.url(forResource: "en", withExtension: "srt", subdirectory: "Fixtures/media")!
    }
}

/// HTTP client that answers from a route table and records requests.
public final class FixtureHTTPClient: HTTPClient, @unchecked Sendable {
    public struct Reply: Sendable {
        public var status: Int
        public var body: Data
        public var headers: [String: String]
        public init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status; self.body = body; self.headers = headers
        }
        public static func fixture(_ name: String) -> Reply { Reply(body: Fixtures.data(name)) }
    }

    private let lock = NSLock()
    private var routes: [String: [Reply]] = [:]
    private var _requests: [URLRequest] = []
    public var error: URLError?

    public init() {}

    /// Replies are consumed in order; the last one repeats.
    public func on(_ pathSuffix: String, _ replies: Reply...) {
        lock.withLock { routes[pathSuffix] = replies }
    }

    public var requests: [URLRequest] { lock.withLock { _requests } }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply? = try lock.withLock {
            _requests.append(request)
            if let error { throw error }
            let path = request.url!.path
            guard let key = routes.keys.filter({ path.hasSuffix($0) }).max(by: { $0.count < $1.count }),
                  var list = routes[key], !list.isEmpty else { return nil }
            let r = list.count > 1 ? list.removeFirst() : list[0]
            routes[key] = list
            return r
        }
        let r = reply ?? Reply(status: 404)
        let response = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        return (r.body, response)
    }
}

/// Configurable source for registry and resolution tests.
public struct MockMediaSource: MediaSource {
    public let id: SourceID
    public let kind: SourceKind
    public let displayName: String
    public let capabilities: SourceCapabilities
    public var variantsByKey: [MediaKey: [MediaVariant]]
    public var failure: SourceError?
    public var delay: Duration?

    public init(
        id: String, kind: SourceKind = .directURL, capabilities: SourceCapabilities = [.browse, .play],
        variantsByKey: [MediaKey: [MediaVariant]] = [:], failure: SourceError? = nil, delay: Duration? = nil
    ) {
        self.id = SourceID(id); self.kind = kind; self.displayName = id; self.capabilities = capabilities
        self.variantsByKey = variantsByKey; self.failure = failure; self.delay = delay
    }

    public static func variant(_ vid: String, source: String, key: MediaKey?, container: String = "mp4",
                               location: StorageLocation = .remote, downloadable: Bool = false) -> MediaVariant {
        MediaVariant(id: vid, sourceID: SourceID(source), mediaKey: key, displayName: vid, container: container,
                     location: location, isDownloadable: downloadable)
    }

    public func catalog() async throws -> [MediaVariant] {
        if let failure { throw failure }
        return variantsByKey.values.flatMap { $0 }
    }

    public func variants(for key: MediaKey) async throws -> [MediaVariant] {
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return variantsByKey[key] ?? []
    }

    public func resolve(_ variant: MediaVariant) async throws -> PlaybackResource {
        if let failure { throw failure }
        return PlaybackResource(variant: variant, url: URL(string: "https://example.invalid/\(variant.id).\(variant.container ?? "mp4")")!)
    }

    public func testConnection() async -> SourceHealth { SourceHealth(ok: failure == nil, message: failure?.localizedDescription ?? "OK") }
}

public extension WatchProgress {
    static func fixture(_ key: MediaKey, _ position: TimeInterval, of duration: TimeInterval? = 3600,
                        completed: Bool = false, at seconds: TimeInterval, device: String? = nil) -> WatchProgress {
        WatchProgress(key: key, position: position, duration: duration, isCompleted: completed,
                      updatedAt: Date(timeIntervalSince1970: seconds), deviceID: device)
    }
}
