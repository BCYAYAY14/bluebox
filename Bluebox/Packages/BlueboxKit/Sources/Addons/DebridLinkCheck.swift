import Domain
import Foundation

/// Where a link ended up and how big its body is, read from the headers alone.
public struct LinkProbe: Sendable, Equatable {
    public var finalURL: URL
    public var status: Int
    /// The whole body's size: `Content-Range`'s total, else `Content-Length` when the range was ignored.
    public var totalBytes: Int64?

    public init(finalURL: URL, status: Int, totalBytes: Int64?) {
        self.finalURL = finalURL; self.status = status; self.totalBytes = totalBytes
    }
}

/// Follows a link's redirects and reads its headers, without its body.
public protocol LinkProber: Sendable {
    func probe(_ url: URL) async throws -> LinkProbe
}

/// Asks for the first byte only; the headers arrive, the transfer is cancelled.
public struct URLSessionLinkProber: LinkProber {
    let session: URLSession
    let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 8) {
        self.session = session; self.timeout = timeout
    }

    public func probe(_ url: URL) async throws -> LinkProbe {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return LinkProbe(finalURL: http.url ?? url, status: http.statusCode, totalBytes: Self.totalBytes(http))
    }

    static func totalBytes(_ response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            return total
        }
        guard response.statusCode == 200 else { return nil }
        return response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
    }
}

/// Checks a debrid link before it plays or downloads: one of the add-ons'
/// notice clips (`DebridPlaceholder`) comes back as the problem it names.
public enum DebridLinkCheck {
    /// The problem, or nil when the link looks like the release. A link that
    /// can't be checked (offline, a timeout, an error status) is nil too:
    /// playing it says what's wrong better than a guess would.
    public static func problem(for url: URL, expectedBytes: Int64?, prober: any LinkProber) async -> DebridProblem? {
        if let named = DebridPlaceholder.problem(for: url) { return named }
        guard let probe = try? await prober.probe(url) else { return nil }
        if let named = DebridPlaceholder.problem(for: probe.finalURL) { return named }
        guard (200..<300).contains(probe.status) else { return nil }
        return DebridPlaceholder.problem(totalBytes: probe.totalBytes, expectedBytes: expectedBytes)
    }

    /// Throws `DebridLinkError` when the link is a notice clip.
    public static func verify(_ url: URL, expectedBytes: Int64?, service: String?, prober: any LinkProber) async throws {
        if let problem = await problem(for: url, expectedBytes: expectedBytes, prober: prober) {
            throw DebridLinkError(problem, service: service)
        }
    }
}
