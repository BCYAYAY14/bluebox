import Domain
import Foundation
@testable import MediaSources
import Testing
import TestingSupport

/// AllDebrid and Debrid-Link's libraries, every service's plan, and how
/// refused requests read — all against canned answers, no real keys.
@Suite struct DebridAccountTests {
    static let key = "FAKE-TEST-KEY"

    func reply(_ json: String, status: Int = 200) -> FixtureHTTPClient.Reply { .init(status: status, body: Data(json.utf8)) }

    // MARK: 401 and 403

    @Test func unknownKeyAndRefusedAccountAreTold() async throws {
        let http = FixtureHTTPClient()
        http.on("rest/1.0/user", reply("{}", status: 401))
        let api = RealDebridAPI(key: Self.key, http: http, base: URL(string: "https://rd.test/rest/1.0/")!)
        await #expect(throws: SourceError.unauthorized) { try await api.accountInfo() }

        // 403: the key is known, but the account may not do this (expired, not premium, locked).
        http.on("rest/1.0/user", reply(#"{"error":"permission_denied"}"#, status: 403))
        await #expect(throws: DebridLinkError(.planExpired, service: "Real-Debrid")) { try await api.accountInfo() }
        let source = DebridLibrarySource(api: api, matcher: nil)
        let health = await source.testConnection()
        #expect(!health.ok && health.message.contains("Real-Debrid plan has expired"))
    }

    // MARK: AllDebrid

    func allDebrid() -> (FixtureHTTPClient, AllDebridAPI) {
        let http = FixtureHTTPClient()
        http.on("magnet/status", reply(#"""
        {"status":"success","data":{"magnets":[
          {"id":101,"filename":"Sintel.2010.1080p","statusCode":4,"status":"Ready","uploadDate":1700000000,"completionDate":1700000100},
          {"id":"102","filename":"Open.Show.S01.1080p","statusCode":4,"status":"Ready","uploadDate":1700000200}
        ]}}
        """#))
        http.on("magnet/files", reply(#"""
        {"status":"success","data":{"magnets":[
          {"id":"101","files":[{"n":"Sintel.2010.1080p.mkv","s":1900000000,"l":"https://alldebrid.com/f/AAA"},
                               {"n":"Sintel.nfo","s":900,"l":"https://alldebrid.com/f/NFO"}]},
          {"id":"102","files":[{"n":"Open.Show.S01.1080p","e":[
              {"n":"S01E01.mkv","s":800000000,"l":"https://alldebrid.com/f/E1"},
              {"n":"Sample","e":[{"n":"sample.mkv","s":9000,"l":"https://alldebrid.com/f/SMP"}]}]}]}
        ]}}
        """#))
        http.on("link/unlock", reply(#"{"status":"success","data":{"link":"https://cdn.alldebrid.example/dl/sintel.mkv","filename":"Sintel.2010.1080p.mkv"}}"#))
        http.on("v4/user", reply(#"{"status":"success","data":{"user":{"username":"viewer","isPremium":true,"premiumUntil":"4102444800"}}}"#))
        return (http, AllDebridAPI(key: Self.key, http: http, base: URL(string: "https://ad.test/")!))
    }

    @Test func allDebridListsReadyVideosInFolders() async throws {
        let (http, api) = allDebrid()
        let files = try await api.files()
        #expect(Set(files.map(\.filename)) == ["Sintel.2010.1080p.mkv", "S01E01.mkv"])
        let episode = try #require(files.first { $0.filename == "S01E01.mkv" })
        #expect(episode.parentName == "Open.Show.S01.1080p" && episode.sizeBytes == 800_000_000)
        #expect(episode.reference == "https://alldebrid.com/f/E1")
        let movie = try #require(files.first { $0.filename.hasPrefix("Sintel") })
        #expect(movie.addedAt == Date(timeIntervalSince1970: 1_700_000_100))

        let status = try #require(http.requests.first { $0.url!.path.hasSuffix("magnet/status") })
        #expect(status.url!.path == "/v4.1/magnet/status" && status.httpMethod == "POST")
        #expect(String(decoding: status.httpBody ?? Data(), as: UTF8.self) == "status=ready")
        let batch = String(decoding: try #require(http.requests.first { $0.url!.path.hasSuffix("magnet/files") }?.httpBody), as: UTF8.self)
        #expect(batch.contains("id%5B%5D=101") || batch.contains("id[]=101"))

        let link = try await api.link(for: movie)
        #expect(link.absoluteString == "https://cdn.alldebrid.example/dl/sintel.mkv")
        // The key travels only in the Authorization header.
        for r in http.requests {
            #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
            #expect(!r.url!.absoluteString.contains(Self.key))
        }
        let account = try await api.accountInfo()
        #expect(account == DebridAccount(name: "viewer", premiumUntil: Date(timeIntervalSince1970: 4_102_444_800), isPremium: true))
    }

    @Test func allDebridErrorsReadLikeTheOthers() async throws {
        let http = FixtureHTTPClient()
        let api = AllDebridAPI(key: Self.key, http: http, base: URL(string: "https://ad.test/")!)
        http.on("v4/user", reply(#"{"status":"error","error":{"code":"AUTH_BAD_APIKEY","message":"The auth apikey is invalid"}}"#))
        await #expect(throws: SourceError.unauthorized) { try await api.accountInfo() }
        http.on("v4/user", reply(#"{"status":"error","error":{"code":"AUTH_BLOCKED","message":"Blocked"}}"#))
        await #expect(throws: DebridLinkError(.planExpired, service: "AllDebrid")) { try await api.accountInfo() }
        http.on("v4/user", reply(#"{"status":"success","data":{"user":{"username":"free","isPremium":false,"premiumUntil":0}}}"#))
        #expect(try await api.accountInfo() == DebridAccount(name: "free", premiumUntil: nil, isPremium: false))
    }

    // MARK: Debrid-Link

    @Test func debridLinkPagesThroughFinishedFiles() async throws {
        let http = FixtureHTTPClient()
        http.on("seedbox/list",
                reply(#"""
                {"success":true,"value":[{"id":"T1","name":"Sintel.2010.1080p","created":1700000000,"files":[
                  {"id":"F1","name":"Sintel.2010.1080p.mkv","size":1900000000,"downloadPercent":100,"downloadUrl":"https://dl.debrid-link.example/F1/sintel.mkv"},
                  {"id":"F2","name":"Sintel.srt","size":1000,"downloadPercent":100,"downloadUrl":"https://dl.debrid-link.example/F2/sintel.srt"}]}],
                 "pagination":{"page":0,"pages":2,"next":1,"previous":-1}}
                """#),
                reply(#"""
                {"success":true,"value":[{"id":"T2","name":"Tears.of.Steel","created":1700000500,"files":[
                  {"id":"F3","name":"Tears.of.Steel.mkv","size":700000000,"downloadPercent":42,"downloadUrl":"https://dl.debrid-link.example/F3/tos.mkv"}]}],
                 "pagination":{"page":1,"pages":2,"next":-1,"previous":0}}
                """#))
        http.on("account/infos", reply(#"{"success":true,"value":{"pseudo":"viewer","email":"viewer@example.com","accountType":1,"premiumLeft":864000}}"#))
        let api = DebridLinkAPI(key: Self.key, http: http, base: URL(string: "https://dl.test/api/v2/")!)
        let files = try await api.files()
        // Still downloading (42%) and not a video: left out.
        #expect(files.map(\.id) == ["dl:T1:F1"])
        #expect(files[0].parentName == "Sintel.2010.1080p" && files[0].addedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(http.requests.filter { $0.url!.path.hasSuffix("seedbox/list") }.count == 2)
        #expect(try await api.link(for: files[0]).absoluteString == "https://dl.debrid-link.example/F1/sintel.mkv")

        let account = try await api.accountInfo()
        #expect(account.name == "viewer" && account.isPremium)
        #expect(account.daysLeft() == 9 || account.daysLeft() == 10)  // ten days from "now", give or take the second

        http.on("account/infos", reply(#"{"success":false,"error":"badToken"}"#, status: 401))
        await #expect(throws: SourceError.unauthorized) { try await api.accountInfo() }
        http.on("account/infos", reply(#"{"success":false,"error":"badToken"}"#))
        await #expect(throws: SourceError.unauthorized) { try await api.accountInfo() }
    }

    // MARK: Plans of the others

    @Test func everyServiceReadsItsPlan() async throws {
        let http = FixtureHTTPClient()
        http.on("rest/1.0/user", reply(#"{"username":"rd-viewer","type":"premium","premium":864000,"expiration":"2100-01-01T00:00:00.000Z"}"#))
        let rd = try await RealDebridAPI(key: Self.key, http: http, base: URL(string: "https://rd.test/rest/1.0/")!).accountInfo()
        #expect(rd.name == "rd-viewer" && rd.isPremium)
        #expect(rd.premiumUntil == ISO8601DateFormatter().date(from: "2100-01-01T00:00:00Z"))

        http.on("account/info", reply(#"{"status":"success","customer_id":1234567,"premium_until":4102444800}"#))
        let pm = try await PremiumizeAPI(key: Self.key, http: http, base: URL(string: "https://pm.test/api/")!).accountInfo()
        #expect(pm == DebridAccount(name: "Customer 1234567", premiumUntil: Date(timeIntervalSince1970: 4_102_444_800), isPremium: true))
        http.on("account/info", reply(#"{"status":"success","customer_id":"1234567","premium_until":false}"#))
        let pmFree = try await PremiumizeAPI(key: Self.key, http: http, base: URL(string: "https://pm.test/api/")!).accountInfo()
        #expect(pmFree == DebridAccount(name: "Customer 1234567", premiumUntil: nil, isPremium: false))

        http.on("user/me", reply(#"{"success":true,"data":{"email":"tb@example.com","plan":2,"premium_expires_at":"2100-01-01T00:00:00Z"}}"#))
        let tb = try await TorBoxAPI(key: Self.key, http: http, base: URL(string: "https://tb.test/v1/api/")!).accountInfo()
        #expect(tb.name == "tb@example.com" && tb.isPremium && tb.premiumUntil != nil)
        // An end date already past is no plan, whatever the plan field says.
        http.on("user/me", reply(#"{"success":true,"data":{"email":"tb@example.com","plan":2,"premium_expires_at":"2001-01-01T00:00:00Z"}}"#))
        #expect(try await TorBoxAPI(key: Self.key, http: http, base: URL(string: "https://tb.test/v1/api/")!).accountInfo().isPremium == false)
    }

    @Test func daysLeftCountsWholeDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func account(_ days: Double) -> DebridAccount {
            DebridAccount(name: "x", premiumUntil: now.addingTimeInterval(days * 86_400), isPremium: true)
        }
        #expect(account(12.5).daysLeft(now: now) == 12)
        #expect(account(0.2).daysLeft(now: now) == 0)
        #expect(account(-3).daysLeft(now: now) == 0)
        #expect(DebridAccount(name: "x", premiumUntil: nil, isPremium: true).daysLeft(now: now) == nil)
        #expect(DebridService.allCases.count == 5)
    }
}
