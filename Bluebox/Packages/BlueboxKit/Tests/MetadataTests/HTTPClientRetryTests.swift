import Foundation
@testable import Metadata
import Testing

struct HTTPClientRetryTests {
    @Test func retriesDroppedReadsOnce() {
        #expect(URLSessionHTTPClient.retriesOnce(URLError(.networkConnectionLost), method: "GET"))
        #expect(URLSessionHTTPClient.retriesOnce(URLError(.notConnectedToInternet), method: nil))
        #expect(URLSessionHTTPClient.retriesOnce(URLError(.cannotConnectToHost), method: "head"))
    }

    @Test func neverRetriesWritesOrSlowServers() {
        #expect(!URLSessionHTTPClient.retriesOnce(URLError(.networkConnectionLost), method: "POST"))
        #expect(!URLSessionHTTPClient.retriesOnce(URLError(.timedOut), method: "GET"))
        #expect(!URLSessionHTTPClient.retriesOnce(URLError(.cancelled), method: "GET"))
        #expect(!URLSessionHTTPClient.retriesOnce(URLError(.badServerResponse), method: "GET"))
    }
}
