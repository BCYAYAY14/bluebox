import Foundation

/// Minimal transport seam so services can be tested with fixtures.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await attempt(request)
        } catch let e as URLError where Self.retriesOnce(e, method: request.httpMethod) {
            // iOS drops pooled connections when the app wakes or the network changes
            // (-1005), and briefly reports "not connected" at launch. One quiet retry
            // turns those into a normal load instead of an error screen.
            try await Task.sleep(for: .milliseconds(700))
            return try await attempt(request)
        }
    }

    private func attempt(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// Reads (GET and HEAD) that failed for a reason worth one more try.
    static func retriesOnce(_ error: URLError, method: String?) -> Bool {
        guard ["GET", "HEAD"].contains((method ?? "GET").uppercased()) else { return false }
        return [.networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .dnsLookupFailed, .secureConnectionFailed].contains(error.code)
    }
}
