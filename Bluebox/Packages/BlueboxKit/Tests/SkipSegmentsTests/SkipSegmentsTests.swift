import Foundation
import Metadata
@testable import SkipSegments
import Testing

// MARK: - Fakes

/// Answers by URL host, counting requests.
private final class FakeHTTP: HTTPClient, @unchecked Sendable {
    let lock = NSLock()
    var responses: [String: (Int, String)] = [:]
    var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host() ?? ""
        let (status, body) = lock.withLock {
            requests.append(request)
            return responses[host] ?? (404, #"{"error":"no data","code":"no_submissions"}"#)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func count(_ host: String) -> Int { lock.withLock { requests.filter { $0.url?.host() == host }.count } }
}

private struct Fixed: SkipSegmentFetching {
    let source: SkipSegment.Source
    let result: [SkipSegment]
    func segments(for query: SkipSegmentQuery) async throws -> [SkipSegment] { result }
}

// Verbatim shapes from the live APIs (28 October 2026).
private let tidbEpisodeJSON = #"""
{"tvdb_id":81189,"type":"tv","season":1,"episode":2,"group_duration_ms":2901920,
 "intro":[{"start_ms":314568,"end_ms":330969,"confidence":0.56,"submission_count":6}],
 "credits":[{"start_ms":2843000,"end_ms":null,"confidence":0.1,"submission_count":1}]}
"""#
private let theIntroDBMovie = #"""
{"tvdb_id":169,"type":"movie","intro":[{"start_ms":null,"end_ms":40000}],"credits":[{"start_ms":7726802,"end_ms":null}]}
"""#
private let introDBEpisode = #"""
{"imdb_id":"tt0903747","media_type":"tv","is_movie":false,"season":1,"episode":2,
 "intro":{"start_sec":314.5,"end_sec":331,"start_ms":314500,"end_ms":331000,"confidence":1,"submission_count":5,"updated_at":"2026-08-23T05:11:33.337Z"},
 "recap":null,
 "outro":{"start_sec":2843,"end_sec":2901,"start_ms":2843000,"end_ms":2901000,"confidence":1,"submission_count":1,"updated_at":"2026-04-14T12:21:31.428Z"},
 "post_credits":null,"no_intro":false,"no_recap":false,"no_outro":false}
"""#
private let jellyfinSegments = #"""
{"Items":[{"Id":"a","ItemId":"x","Type":"Intro","StartTicks":600000000,"EndTicks":1500000000},
          {"Id":"b","ItemId":"x","Type":"Outro","StartTicks":25000000000,"EndTicks":26000000000},
          {"Id":"c","ItemId":"x","Type":"Commercial","StartTicks":1,"EndTicks":2}],"TotalRecordCount":3}
"""#

// MARK: - Chapters

@Suite struct ChapterSegmentTests {
    @Test(arguments: [
        ("Intro", SkipSegment.Kind.intro), ("Opening", .intro), ("Opening Credits", .intro), ("OP", .intro),
        ("Main Titles", .intro), ("Previously On", .recap), ("Recap", .recap),
        ("End Credits", .credits), ("Credits", .credits), ("ED", .credits), ("Ending", .credits), ("Outro", .credits),
        ("Preview", .preview), ("Next Episode", .preview),
    ])
    func namedChapters(title: String, kind: SkipSegment.Kind) {
        #expect(ChapterSegments.kind(ofTitle: title) == kind)
    }

    @Test(arguments: ["Chapter 1", "Chapter 12", "00:05:12.000", "Ed's Story", "The Opera", "Endgame", "Part 2", ""])
    func genericChaptersMeanNothing(title: String) {
        #expect(ChapterSegments.kind(ofTitle: title) == nil)
    }

    @Test func sectionsRunToTheNextChapter() {
        let chapters = [ChapterMark(title: "Prologue", start: 0), ChapterMark(title: "Opening", start: 95),
                        ChapterMark(title: "Part A", start: 185), ChapterMark(title: "Ending", start: 1300),
                        ChapterMark(title: "Preview", start: 1390)]
        let s = ChapterSegments.segments(from: chapters, duration: 1420)
        #expect(s == [SkipSegment(kind: .intro, start: 95, end: 185, source: .chapters),
                      SkipSegment(kind: .credits, start: 1300, end: 1390, source: .chapters),
                      SkipSegment(kind: .preview, start: 1390, end: nil, source: .chapters)])
    }

    @Test func mislabelledHugeIntroIsDropped() {
        let chapters = [ChapterMark(title: "Intro", start: 0), ChapterMark(title: "Credits", start: 2500)]
        let s = ChapterSegments.segments(from: chapters, duration: 2700)
        #expect(s.map(\.kind) == [.credits])
    }

    @Test func adjacentCreditChaptersMerge() {
        let chapters = [ChapterMark(title: "Story", start: 0), ChapterMark(title: "Credits", start: 1000),
                        ChapterMark(title: "End Credits", start: 1060), ChapterMark(title: "Stinger", start: 1200)]
        let s = ChapterSegments.segments(from: chapters, duration: 1260)
        #expect(s == [SkipSegment(kind: .credits, start: 1000, end: 1200, source: .chapters)])
    }
}

// MARK: - Parsing

@Suite struct SegmentParsingTests {
    @Test func theIntroDBEpisode() throws {
        let s = try TheIntroDBClient.parse(Data(tidbEpisodeJSON.utf8))
        #expect(s.count == 2)
        #expect(s[0].kind == .intro && abs(s[0].start - 314.568) < 0.001 && abs((s[0].end ?? 0) - 330.969) < 0.001)
        #expect(s[1].kind == .credits && s[1].start == 2843 && s[1].end == nil)
        #expect(s.allSatisfy { $0.source == .theIntroDB })
    }

    @Test func theIntroDBNullStartMeansFromTheBeginning() throws {
        let s = try TheIntroDBClient.parse(Data(theIntroDBMovie.utf8))
        #expect(s.first == SkipSegment(kind: .intro, start: 0, end: 40, source: .theIntroDB))
    }

    @Test func introDBMapsOutroToCredits() throws {
        let s = try IntroDBClient.parse(Data(introDBEpisode.utf8))
        #expect(s == [SkipSegment(kind: .intro, start: 314.5, end: 331, source: .introDB),
                      SkipSegment(kind: .credits, start: 2843, end: 2901, source: .introDB)])
    }

    @Test func jellyfinTicks() throws {
        let s = try JellyfinSegmentsClient.parse(Data(jellyfinSegments.utf8))
        #expect(s == [SkipSegment(kind: .intro, start: 60, end: 150, source: .jellyfin),
                      SkipSegment(kind: .credits, start: 2500, end: 2600, source: .jellyfin)])
    }

    @Test func requestsUseTheDocumentedParameters() {
        let q = SkipSegmentQuery(duration: 2901.9, tmdbID: 1396, imdbID: "tt0903747", season: 1, episode: 2)
        let tidb = TheIntroDBClient(http: FakeHTTP()).request(for: q)?.url?.absoluteString
        #expect(tidb == "https://api.theintrodb.org/v4/media?tmdb_id=1396&season=1&episode=2&duration_ms=2901900")
        let idb = IntroDBClient(http: FakeHTTP()).request(for: q)?.url?.absoluteString
        #expect(idb == "https://api.introdb.app/segments?imdb_id=tt0903747&season=1&episode=2")
        // IntroDB needs an IMDb ID.
        #expect(IntroDBClient(http: FakeHTTP()).request(for: SkipSegmentQuery(tmdbID: 1)) == nil)
    }

    @Test func jellyfinRefFromStreamURL() {
        let url = URL(string: "https://jf.example.com:8920/base/Videos/abc123/stream.mp4?static=true&ApiKey=tok")!
        let ref = JellyfinItemRef(streamURL: url, itemID: "abc123")
        #expect(ref?.server.absoluteString == "https://jf.example.com:8920/base")
        #expect(ref?.token == "tok")
        #expect(JellyfinItemRef(streamURL: URL(string: "https://example.com/movie.mp4")!, itemID: "x") == nil)
    }
}

// MARK: - Choosing a source

@Suite struct SourceChoiceTests {
    let chapterCredits = SkipSegment(kind: .credits, start: 1300, end: nil, source: .chapters)
    let crowdIntro = SkipSegment(kind: .intro, start: 60, end: 120, source: .theIntroDB)
    let crowdCredits = SkipSegment(kind: .credits, start: 1250, end: nil, source: .theIntroDB)

    @Test func bestSourceWinsPerKind() {
        let merged = SkipSegmentPlanner.merge([[chapterCredits], [crowdIntro, crowdCredits]], duration: 1400)
        #expect(merged == [crowdIntro, chapterCredits])
    }

    @Test func otherReleasesAreRejected() {
        // Timed on a cut 10 minutes longer: the credits fall past this file's end.
        let late = SkipSegment(kind: .credits, start: 2000, end: 2100, source: .introDB)
        let long = SkipSegment(kind: .intro, start: 0, end: 900, source: .introDB)
        #expect(SkipSegmentPlanner.merge([[late, long]], duration: 1800).isEmpty)
        // Slightly past the end is rounding, kept and run to the end.
        let near = SkipSegment(kind: .credits, start: 1700, end: 1805, source: .introDB)
        #expect(SkipSegmentPlanner.merge([[near]], duration: 1800).first?.end == nil)
    }

    @Test func crowdOnlyWhenSomethingIsMissing() {
        #expect(SkipSegmentPlanner.needsCrowdSources([], isEpisode: true))
        #expect(SkipSegmentPlanner.needsCrowdSources([chapterCredits], isEpisode: true))
        #expect(!SkipSegmentPlanner.needsCrowdSources([crowdIntro, chapterCredits], isEpisode: true))
        #expect(!SkipSegmentPlanner.needsCrowdSources([chapterCredits], isEpisode: false))
    }

    @Test func resolverOrderAndCache() async {
        let http = FakeHTTP()
        http.responses["api.theintrodb.org"] = (200, tidbEpisodeJSON)
        http.responses["api.introdb.app"] = (200, introDBEpisode)
        let resolver = SkipSegmentResolver(jellyfin: nil, crowd: [TheIntroDBClient(http: http), IntroDBClient(http: http)],
                                           cache: SkipSegmentCache(file: nil))
        let q = SkipSegmentQuery(duration: 2902, tmdbID: 1396, imdbID: "tt0903747", season: 1, episode: 2)
        let first = await resolver.resolve(q)
        // TheIntroDB had both the intro and the credits, so IntroDB isn't asked.
        #expect(first.sources == [.theIntroDB])
        #expect(first.segments.map(\.kind) == [.intro, .credits])
        #expect(http.count("api.introdb.app") == 0)
        _ = await resolver.resolve(q)
        #expect(http.count("api.theintrodb.org") == 1)  // cached
    }

    @Test func chaptersBeatCrowdAndSkipTheNetwork() async {
        let http = FakeHTTP()
        let resolver = SkipSegmentResolver(jellyfin: nil, crowd: [TheIntroDBClient(http: http)], cache: SkipSegmentCache(file: nil))
        let q = SkipSegmentQuery(chapters: [ChapterMark(title: "Story", start: 0), ChapterMark(title: "Intro", start: 30),
                                            ChapterMark(title: "Part A", start: 100), ChapterMark(title: "Credits", start: 1300)],
                                 duration: 1400, tmdbID: 1, season: 1, episode: 1)
        let r = await resolver.resolve(q)
        #expect(r.sources == [.chapters])
        #expect(http.requests.isEmpty)
    }

    @Test func jellyfinBeforeCrowd() async {
        let jf = Fixed(source: .jellyfin, result: [SkipSegment(kind: .intro, start: 60, end: 150, source: .jellyfin)])
        let crowd = Fixed(source: .theIntroDB, result: [crowdIntro, crowdCredits])
        let resolver = SkipSegmentResolver(jellyfin: jf, crowd: [crowd], cache: SkipSegmentCache(file: nil))
        let ref = JellyfinItemRef(server: URL(string: "https://jf.local")!, itemID: "x", token: "t")
        let r = await resolver.resolve(SkipSegmentQuery(duration: 1400, tmdbID: 1, season: 1, episode: 1, jellyfin: ref))
        #expect(r.segments.first { $0.kind == .intro }?.source == .jellyfin)
        #expect(r.segments.first { $0.kind == .credits }?.source == .theIntroDB)
    }

    @Test func crowdTurnedOffForTheShow() async {
        let crowd = Fixed(source: .theIntroDB, result: [crowdIntro])
        let resolver = SkipSegmentResolver(jellyfin: nil, crowd: [crowd], cache: SkipSegmentCache(file: nil))
        let r = await resolver.resolve(SkipSegmentQuery(duration: 1400, tmdbID: 1, season: 1, episode: 1, allowsCrowdSources: false))
        #expect(r.segments.isEmpty)
    }

    @Test func missesExpireSoonerThanHits() async {
        final class Now: @unchecked Sendable { var t = Date(timeIntervalSince1970: 0) }
        let now = Now()
        let cache = SkipSegmentCache(file: nil, now: { now.t })
        await cache.store([], for: "miss")
        await cache.store([crowdIntro], for: "hit")
        now.t += 13 * 3600
        #expect(await cache.value(for: "miss") == nil)
        #expect(await cache.value(for: "hit") == [crowdIntro])
        now.t += 7 * 24 * 3600
        #expect(await cache.value(for: "hit") == nil)
    }
}

// MARK: - What the player offers

@Suite struct OfferTests {
    let segments = [SkipSegment(kind: .recap, start: 0, end: 40, source: .chapters),
                    SkipSegment(kind: .intro, start: 60, end: 120, source: .chapters),
                    SkipSegment(kind: .credits, start: 1300, end: nil, source: .chapters)]

    private func offer(_ t: TimeInterval, intro: SkipSegmentPlanner.Mode = .button, credits: SkipSegmentPlanner.Mode = .button,
                       next: Bool = true) -> SkipSegmentPlanner.Offer? {
        SkipSegmentPlanner.offer(at: t, segments: segments, duration: 1400, introMode: intro, creditsMode: credits, hasNextEpisode: next)?.0
    }

    @Test func offersFollowThePlayhead() {
        #expect(offer(5) == .skip(.recap, to: 40))
        #expect(offer(50) == nil)
        #expect(offer(61) == .skip(.intro, to: 120))
        #expect(offer(119) == nil)  // too late to bother
        #expect(offer(1310) == .nextEpisode)
        #expect(SkipSegmentPlanner.title(for: .skip(.recap, to: 40)) == "Skip Recap")
    }

    @Test func modes() {
        #expect(offer(61, intro: .off) == nil)
        #expect(offer(1310, credits: .off) == nil)
        let auto = SkipSegmentPlanner.offer(at: 61, segments: segments, duration: 1400, introMode: .automatic,
                                            creditsMode: .button, hasNextEpisode: true)
        #expect(auto?.auto == true)
    }

    @Test func filmCreditsOnlyWithSomethingAfter() {
        // Credits to the end of a film: nothing to skip to.
        #expect(offer(1310, next: false) == nil)
        let mid = [SkipSegment(kind: .credits, start: 1200, end: 1300, source: .chapters)]
        let o = SkipSegmentPlanner.offer(at: 1210, segments: mid, duration: 1400, introMode: .button, creditsMode: .button,
                                         hasNextEpisode: false)
        #expect(o?.0 == .skip(.credits, to: 1300))
    }
}
